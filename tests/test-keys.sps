#!r6rs
;;; The keys suite: D5's table, D3's secret and header, D9's ids and paging,
;;; and a key's name. All pure.
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (techo-testing)
        (techo machine)
        (techo keys))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-kind : (-> Any) -> (U 'no-raise 'assertion 'other)
(define (raised-kind thunk)
  (guard (e ((assertion-violation? e) 'assertion)
            (#t 'other))
    (thunk)
    'no-raise))

(define (read-file path)
  (attempt (lambda () (call-with-input-file path get-string-all))))

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(define (repeat-string s n)
  (if (= n 0) "" (string-append s (repeat-string s (- n 1)))))

(test-begin "keys")

;;; D5's table

(define (key-problems rows)
  (attempt (lambda () (machine-problems (make-machine rows) '(none) #f key-cant-happen))))

(test-equal "table: machine-problems with no end answers ()"
  '()
  (key-problems key-rows))

(test-equal "table: it has eleven rows"
  11
  (length key-rows))

(test-equal "table: dropping a row is reported"
  '((unlisted-gap active revoke) (unreachable revoked))
  (key-problems (filter (lambda (r) (not (and (eq? (car r) 'active) (eq? (cadr r) 'revoke))))
                        key-rows)))

(test-equal "table: pointing revoke at active is reported"
  '((unreachable revoked))
  (key-problems (map (lambda (r)
                       (if (and (eq? (car r) 'active) (eq? (cadr r) 'revoke))
                           (list (car r) (cadr r) 'active (cadddr r) (list-ref r 4))
                           r))
                     key-rows)))

(test-equal "table: the can't-happen pairs, four of them, each with a reason"
  '((active create) (revoked create)
    (none regenerate-self) (revoked regenerate-self))
  (map (lambda (c) (list (car c) (cadr c))) key-cant-happen))

(test-assert "table: every reason is a non-empty string"
  (for-all (lambda (c) (and (string? (caddr c)) (> (string-length (caddr c)) 0)))
           key-cant-happen))

;; stepped : StateKind EventKind -> (List StateKind CommandKind)
(define (stepped s e)
  (attempt (lambda () (call-with-values (lambda () (key-step s e)) list))))

(define d5
  '((none create active insert)
    (none check none refuse-401)
    (none revoke none refuse-404)
    (none regenerate-other none refuse-404)
    (active check active admit)
    (active regenerate-self active replace-hash)
    (active regenerate-other active refuse-403)
    (active revoke revoked set-revoked)
    (revoked check revoked refuse-401)
    (revoked revoke revoked nothing)
    (revoked regenerate-other revoked refuse-403)))

(for-each
 (lambda (row)
   (test-equal (string-append "step: " (symbol->string (car row)) " + "
                              (symbol->string (cadr row)))
     (list (caddr row) (cadddr row))
     (stepped (car row) (cadr row))))
 d5)

(test-equal "step: the rows are exactly D5's, in order"
  (map (lambda (r) (list (car r) (cadr r) (caddr r) (cadddr r))) d5)
  (map (lambda (r) (list (car r) (cadr r) (caddr r) (cadddr r))) key-rows))

(test-equal "step: a can't-happen pair raises an assertion violation"
  'assertion
  (raised-kind (lambda () (key-step 'active 'create))))

(test-equal "step: revoked + regenerate-self raises"
  'assertion
  (raised-kind (lambda () (key-step 'revoked 'regenerate-self))))

;;; The secret

(define (iota* n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))
(define fixed-bytes (u8-list->bytevector (iota* 32)))

(test-equal "secret: 32 bytes 0..31"
  "techo_000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  (attempt (lambda () (key-secret fixed-bytes))))

(test-equal "secret: lowercase on purpose, 0xAB is ab"
  (string-append "techo_" (repeat-string "ab" 32))
  (attempt (lambda () (key-secret (make-bytevector 32 #xAB)))))

(test-equal "secret: 70 characters"
  70
  (attempt (lambda () (string-length (key-secret (make-bytevector 32 255))))))

(test-equal "secret: 31 bytes raises"
  'assertion
  (raised-kind (lambda () (key-secret (make-bytevector 31 1)))))

(test-equal "secret: 33 bytes raises"
  'assertion
  (raised-kind (lambda () (key-secret (make-bytevector 33 1)))))

(test-equal "secret: a string raises"
  'assertion
  (raised-kind (lambda () (key-secret "techo"))))

(define good (string-append "techo_" (repeat-string "0f" 32)))

(test-equal "secret?: a good one" #t (key-secret? good))
(test-equal "secret?: capitals are not it" #f
  (key-secret? (string-append "techo_" (repeat-string "0F" 32))))
(test-equal "secret?: 63 digits" #f
  (key-secret? (substring good 0 69)))
(test-equal "secret?: 65 digits" #f
  (key-secret? (string-append good "0")))
(test-equal "secret?: wrong prefix" #f
  (key-secret? (string-append "Techo_" (repeat-string "0f" 32))))
(test-equal "secret?: a non-hex digit" #f
  (key-secret? (string-append "techo_" (repeat-string "0f" 31) "0g")))
(test-equal "secret?: not a string" #f (key-secret? 'techo))
(test-equal "secret?: #f" #f (key-secret? #f))

;;; The header

(test-equal "bearer: a good header"
  good
  (attempt (lambda () (read-bearer (list (string-append "Bearer " good))))))
(test-equal "bearer: any letter case"
  good
  (attempt (lambda () (read-bearer (list (string-append "bEaReR " good))))))
(test-equal "bearer: lowercase scheme"
  good
  (attempt (lambda () (read-bearer (list (string-append "bearer " good))))))
(test-equal "bearer: no header" #f (attempt (lambda () (read-bearer '()))))
(test-equal "bearer: two headers" #f
  (attempt (lambda () (read-bearer (list (string-append "Bearer " good)
                                         (string-append "Bearer " good))))))
(test-equal "bearer: two spaces" #f
  (attempt (lambda () (read-bearer (list (string-append "Bearer  " good))))))
(test-equal "bearer: a tab" #f
  (attempt (lambda () (read-bearer (list (string-append "Bearer\t" good))))))
(test-equal "bearer: another scheme" #f
  (attempt (lambda () (read-bearer (list (string-append "Basic " good))))))
(test-equal "bearer: a scheme of six other letters" #f
  (attempt (lambda () (read-bearer (list (string-append "Bearex " good))))))
(test-equal "bearer: a scheme of six other characters" #f
  (attempt (lambda () (read-bearer (list (string-append "Token_ " good))))))
(test-equal "bearer: no scheme" #f
  (attempt (lambda () (read-bearer (list good)))))
(test-equal "bearer: trailing space" #f
  (attempt (lambda () (read-bearer (list (string-append "Bearer " good " "))))))
(test-equal "bearer: capital hex" #f
  (attempt (lambda () (read-bearer
                       (list (string-append "Bearer techo_" (repeat-string "0F" 32)))))))
(test-equal "bearer: empty string" #f (attempt (lambda () (read-bearer '("")))))
(test-equal "bearer: only the scheme" #f (attempt (lambda () (read-bearer '("Bearer ")))))

;; A small deterministic generator (a linear congruential one); no entropy.
(define (make-lcg seed)
  (let ((state seed))
    (lambda (n)
      (set! state (mod (+ (* state 1103515245) 12345) 2147483648))
      (mod (div state 65536) n))))

;; An alphabet that makes near misses likely.
(define alphabet
  (string->list "Bbearer techo_0123456789abcdefABCDEF \t\n\x0;\x7f;\xe9;\x3bb;\x1F600;-+"))

(define (random-string next)
  (let* ((roll (next 10))
         (len (cond ((= roll 0) 0) ((< roll 6) (next 90)) ((< roll 9) (next 200)) (else (+ 1000 (next 3000)))))
         (s (make-string len #\a))
         (alen (length alphabet)))
    (do ((i 0 (+ i 1))) ((= i len) s)
      (string-set! s i (list-ref alphabet (next alen))))))

(define (near-miss next)
  ;; a good header with one character changed, or a piece cut off
  (let* ((h (string-append (if (= 0 (next 2)) "Bearer " "bearer ") good))
         (i (next (string-length h)))
         (c (list-ref alphabet (next (length alphabet)))))
    (case (next 3)
      ((0) (let ((t (string-copy h))) (string-set! t i c) t))
      ((1) (substring h 0 i))
      (else (string-append (substring h 0 i) (string c) (substring h i (string-length h)))))))

(test-equal "bearer: never raises, any string, #f or a valid secret"
  'ok
  (let ((next (make-lcg 20260101)))
    (let loop ((n 0))
      (if (= n 4000)
          'ok
          (let* ((s (if (even? n) (random-string next) (near-miss next)))
                 (r (guard (e (#t (list 'raised s))) (read-bearer (list s)))))
            (if (or (not r) (key-secret? r))
                (loop (+ n 1))
                (list 'bad n s r)))))))

(test-equal "bearer: lists of random strings never raise either"
  'ok
  (let ((next (make-lcg 7)))
    (let loop ((n 0))
      (if (= n 500)
          'ok
          (let* ((l (let build ((k (next 4)) (acc '()))
                      (if (= k 0) acc (build (- k 1) (cons (random-string next) acc)))))
                 (r (guard (e (#t (list 'raised l))) (read-bearer l))))
            (if (or (not r) (key-secret? r))
                (loop (+ n 1))
                (list 'bad n r)))))))

;;; Ids and paging

(define id-text "0190b3a4-5c6d-7e8f-9a0b-1c2d3e4f5a6b")
(define id-bytes
  (u8-list->bytevector '(#x01 #x90 #xb3 #xa4 #x5c #x6d #x7e #x8f
                         #x9a #x0b #x1c #x2d #x3e #x4f #x5a #x6b)))

(test-equal "id: lowercase text" id-bytes (attempt (lambda () (parse-id id-text))))
(test-equal "id: uppercase text" id-bytes
  (attempt (lambda () (parse-id (string-upcase id-text)))))
(test-equal "id: a bad string" 'invalid (attempt (lambda () (parse-id "nope"))))
(test-equal "id: empty" 'invalid (attempt (lambda () (parse-id ""))))
(test-equal "id: not a string" 'invalid (attempt (lambda () (parse-id 5))))
(test-equal "id: #f" 'invalid (attempt (lambda () (parse-id #f))))
(test-equal "id->string: lowercase canonical"
  id-text (attempt (lambda () (id->string id-bytes))))
(test-equal "id->string: round trip of uppercase text"
  id-text (attempt (lambda () (id->string (parse-id (string-upcase id-text))))))

(test-equal "limit: absent is 50" 50 (attempt (lambda () (parse-limit #f))))
(test-equal "limit: 1" 1 (attempt (lambda () (parse-limit "1"))))
(test-equal "limit: 100" 100 (attempt (lambda () (parse-limit "100"))))
(test-equal "limit: 101 is capped" 100 (attempt (lambda () (parse-limit "101"))))
(test-equal "limit: leading zeros" 7 (attempt (lambda () (parse-limit "007"))))
(test-equal "limit: a huge number is capped"
  100 (attempt (lambda () (parse-limit (repeat-string "9" 400)))))
(for-each
 (lambda (s)
   (test-equal (string-append "limit: invalid " (call-with-string-output-port
                                                 (lambda (p) (write s p))))
     'invalid (attempt (lambda () (parse-limit s)))))
 '("0" "00" "-1" "+5" "1.5" "" "abc" "1e2" " 5" "5 " "0x10" "1/2" "\x663;"))

(test-equal "after: absent is #f" #f (attempt (lambda () (parse-after #f))))
(test-equal "after: an id" id-bytes (attempt (lambda () (parse-after id-text))))
(test-equal "after: junk" 'invalid (attempt (lambda () (parse-after "junk"))))
(test-equal "after: empty" 'invalid (attempt (lambda () (parse-after ""))))

;;; A key's name

(test-equal "name: one character" #f (attempt (lambda () (key-name-problem "a"))))
(test-equal "name: 64 characters" #f
  (attempt (lambda () (key-name-problem (make-string 64 #\a)))))
(test-equal "name: non-ASCII" #f (attempt (lambda () (key-name-problem "Kishu's \x3bb; laptop"))))
(test-equal "name: spaces inside are fine" #f
  (attempt (lambda () (key-name-problem "my phone"))))
(define (problem-symbol? x) (symbol? x))
(test-assert "name: empty" (problem-symbol? (attempt (lambda () (key-name-problem "")))))
(test-assert "name: 65 characters"
  (problem-symbol? (attempt (lambda () (key-name-problem (make-string 65 #\a))))))
(test-assert "name: newline"
  (problem-symbol? (attempt (lambda () (key-name-problem "a\nb")))))
(test-assert "name: DEL"
  (problem-symbol? (attempt (lambda () (key-name-problem "a\x7f;b")))))
(test-assert "name: NUL"
  (problem-symbol? (attempt (lambda () (key-name-problem "a\x0;b")))))
(test-assert "name: not a string"
  (problem-symbol? (attempt (lambda () (key-name-problem 5)))))
;; DEL and C1 controls: a terminal can read U+009B as the start of an escape
(for-each
 (lambda (c)
   (test-equal (string-append "name: " (car c) " is a control character")
     'control-character
     (attempt (lambda () (key-name-problem (string-append "lap" (string (integer->char (cdr c))) "top"))))))
 '(("U+007F" . #x7f) ("U+0080" . #x80) ("U+009B" . #x9b) ("U+009F" . #x9f)))

(test-equal "name: ordinary non-ASCII still passes: e acute, U+00A1 (just past C1), CJK"
  '(#f #f #f)
  (attempt (lambda () (list (key-name-problem "caf\xe9;")
                            (key-name-problem "\xa1;hola!")
                            (key-name-problem "\x65e5;\x672c;\x8a9e;")))))

(test-equal "name: the symbols differ by cause"
  '(empty too-long control-character not-a-string)
  (attempt (lambda () (list (key-name-problem "") (key-name-problem (make-string 65 #\a))
                            (key-name-problem "a\nb") (key-name-problem 5)))))

;;; The diagram, held to its file

(test-equal ".plans/machines/key.md is what the table renders"
  (attempt (lambda () (key-document)))
  (read-file ".plans/machines/key.md"))

(test-assert "the document has a diagram with the revoke edge"
  (let ((doc (attempt (lambda () (key-document)))))
    (and (string? doc)
         (string-index-of doc "stateDiagram-v2")
         (string-index-of doc "active --> revoked: revoke"))))

(test-end "keys")

(exit (suite-exit-status runner))
