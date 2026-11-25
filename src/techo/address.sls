#!r6rs
;;; (techo address): a client's address as a rate-limit key (L3) and the
;;; client's address out of X-Forwarded-For (L4). Pure.
;;;
;;; An address is parsed to its bits first, so every spelling of one address
;;; has one key. IPv4 is four decimal parts. IPv6 is eight 16-bit groups.
(library (techo address)
  (export address-key entry->address client-address)
  (import (rnrs))

  ;; split-on : Char String -> (Listof String)
  ;; Keeps empty pieces: "a::b" on #\: is ("a" "" "b").
  (define (split-on ch s)
    (let loop ((i 0) (start 0) (acc '()))
      (cond ((= i (string-length s))
             (reverse (cons (substring s start i) acc)))
            ((char=? (string-ref s i) ch)
             (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
            (else (loop (+ i 1) start acc)))))

  ;; index-of : Char String -> (U Natural #f)
  (define (index-of ch s)
    (let loop ((i 0))
      (cond ((= i (string-length s)) #f)
            ((char=? (string-ref s i) ch) i)
            (else (loop (+ i 1))))))

  ;; digit-value : Char Natural -> (U Natural #f)   (radix 10 or 16)
  (define (digit-value c radix)
    (let ((n (cond ((char<=? #\0 c #\9) (- (char->integer c) 48))
                   ((char<=? #\a c #\f) (+ 10 (- (char->integer c) 97)))
                   ((char<=? #\A c #\F) (+ 10 (- (char->integer c) 65)))
                   (else #f))))
      (and n (< n radix) n)))

  ;; parse-digits : String Natural Natural -> (U Natural #f)
  ;; The value of 1 to max-len digits of the radix, else #f.
  (define (parse-digits s radix max-len)
    (and (<= 1 (string-length s) max-len)
         (let loop ((i 0) (acc 0))
           (if (= i (string-length s))
               acc
               (let ((d (digit-value (string-ref s i) radix)))
                 (and d (loop (+ i 1) (+ (* acc radix) d))))))))

  ;; parse-v4 : String -> (U (List Byte Byte Byte Byte) #f)
  (define (parse-v4 s)
    (let ((parts (split-on #\. s)))
      (and (= (length parts) 4)
           (let ((nums (map (lambda (p)
                              (and (not (and (> (string-length p) 1)
                                             (char=? (string-ref p 0) #\0)))
                                   (let ((n (parse-digits p 10 3)))
                                     (and n (<= n 255) n))))
                            parts)))
             (and (for-all values nums) nums)))))

  ;; v4-groups : (List Byte Byte Byte Byte) -> (List Natural Natural)
  (define (v4-groups b)
    (list (+ (* 256 (car b)) (cadr b))
          (+ (* 256 (caddr b)) (cadddr b))))

  ;; parse-groups : (Listof String) Boolean -> (U (Listof Natural) #f)
  ;; Hex groups, 1 to 4 digits. When tail-ok?, the last piece may be a
  ;; dotted IPv4, which is two groups.
  (define (parse-groups pieces tail-ok?)
    (let loop ((ps pieces) (acc '()))
      (cond ((null? ps) (reverse acc))
            ((and tail-ok? (null? (cdr ps)) (index-of #\. (car ps)))
             (let ((v4 (parse-v4 (car ps))))
               (and v4 (reverse (append (reverse (v4-groups v4)) acc)))))
            (else
             (let ((g (parse-digits (car ps) 16 4)))
               (and g (loop (cdr ps) (cons g acc))))))))

  ;; find-double-colon : String -> (U Natural #f)
  (define (find-double-colon s)
    (let loop ((i 0))
      (cond ((>= (+ i 1) (string-length s)) #f)
            ((and (char=? (string-ref s i) #\:) (char=? (string-ref s (+ i 1)) #\:)) i)
            (else (loop (+ i 1))))))

  ;; parse-v6 : String -> (U (List Natural x8) #f)
  ;; A zone id (from the first %) is dropped.
  (define (parse-v6 text)
    (let* ((pc (index-of #\% text))
           (s (if pc (substring text 0 pc) text))
           (dc (find-double-colon s)))
      (if (not dc)
          (let ((gs (parse-groups (split-on #\: s) #t)))
            (and gs (= (length gs) 8) gs))
          (let ((left (substring s 0 dc))
                (right (substring s (+ dc 2) (string-length s))))
            (and (not (find-double-colon right))
                 (not (and (> (string-length right) 0)
                           (char=? (string-ref right 0) #\:)))
                 (let ((l (if (string=? left "") '() (parse-groups (split-on #\: left) #f)))
                       (r (if (string=? right "") '() (parse-groups (split-on #\: right) #t))))
                   (and l r
                        (<= (+ (length l) (length r)) 7)
                        (append l
                                (zeros (- 8 (length l) (length r)))
                                r))))))))

  ;; zeros : Natural -> (Listof 0)
  (define (zeros n) (if (= n 0) '() (cons 0 (zeros (- n 1)))))

  ;; take : (Listof A) Natural -> (Listof A)
  (define (take l n)
    (if (= n 0) '() (cons (car l) (take (cdr l) (- n 1)))))

  ;; hex4 : Natural -> String
  ;; Exactly four lowercase hex digits.
  (define (hex4 n)
    (let ((digits "0123456789abcdef"))
      (list->string
       (map (lambda (shift)
              (string-ref digits (mod (div n (expt 16 shift)) 16)))
            '(3 2 1 0)))))

  ;; join-dots : (Listof Natural) -> String
  (define (join-dots ns)
    (let loop ((ns (cdr ns)) (acc (number->string (car ns))))
      (if (null? ns)
          acc
          (loop (cdr ns) (string-append acc "." (number->string (car ns)))))))

  ;; address-key : (U String #f) -> String
  ;; "v4:a.b.c.d", "v6:" and the first 64 bits as 16 hex digits, or "unknown".
  ;; An IPv6 address in ::ffff:0:0/96 gives its IPv4 key.
  (define (address-key text)
    (cond
      ((not (string? text)) "unknown")
      ((parse-v4 text)
       => (lambda (b) (string-append "v4:" (join-dots b))))
      ((parse-v6 text)
       => (lambda (g)
            (if (and (for-all zero? (take g 5)) (= (list-ref g 5) #xffff))
                (let ((hi (list-ref g 6)) (lo (list-ref g 7)))
                  (string-append "v4:" (join-dots (list (div hi 256) (mod hi 256)
                                                        (div lo 256) (mod lo 256)))))
                (apply string-append "v6:" (map hex4 (take g 4))))))
      (else "unknown")))

  ;; port-digits? : String -> Boolean   (1 to 5 digits)
  (define (port-digits? s) (and (parse-digits s 10 5) #t))

  ;; entry->address : String -> (U String #f)
  ;; One trimmed X-Forwarded-For entry. Strips an IPv4 port, brackets, or
  ;; brackets and a port. Answers the bare address text, else #f.
  (define (entry->address e)
    (let ((n (string-length e)))
      (cond
        ((= n 0) #f)
        ((char=? (string-ref e 0) #\[)
         (let ((close (index-of #\] e)))
           (and close
                (let ((inner (substring e 1 close))
                      (rest (substring e (+ close 1) n)))
                  (and (or (string=? rest "")
                           (and (char=? (string-ref rest 0) #\:)
                                (port-digits? (substring rest 1 (string-length rest)))))
                       (index-of #\: inner)
                       (parse-v6 inner)
                       inner)))))
        ((parse-v4 e) e)
        (else
         (let ((parts (split-on #\: e)))
           (cond ((and (= (length parts) 2) (parse-v4 (car parts)) (port-digits? (cadr parts)))
                  (car parts))
                 ((parse-v6 e) e)
                 (else #f)))))))

  ;; trim : String -> String   (spaces and tabs)
  (define (trim s)
    (let* ((blank? (lambda (c) (or (char=? c #\space) (char=? c #\tab))))
           (n (string-length s))
           (a (let loop ((i 0)) (if (and (< i n) (blank? (string-ref s i))) (loop (+ i 1)) i)))
           (b (let loop ((j n)) (if (and (> j a) (blank? (string-ref s (- j 1)))) (loop (- j 1)) j))))
      (substring s a b)))

  ;; client-address : Natural (Listof String) (U String #f) -> (U String #f)
  ;; N = 0 is the peer. Else the Nth entry from the end of every field's
  ;; entries, joined in order; the peer when the list is short or the entry
  ;; is no address.
  (define (client-address n fields peer)
    (if (= n 0)
        peer
        (let* ((entries (filter (lambda (s) (> (string-length s) 0))
                                (map trim
                                     (apply append (map (lambda (f) (split-on #\, f)) fields)))))
               (len (length entries)))
          (if (< len n)
              peer
              (or (entry->address (list-ref entries (- len n))) peer)))))
  )
