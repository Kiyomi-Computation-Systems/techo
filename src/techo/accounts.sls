#!r6rs
;;; (techo accounts): what an account's email, username and password must
;;; look like. Pure: no database, no hashing (ADR-0007).
;;;
;;;   normalise-email   an email trimmed and lowercased, or #f
;;;   username-problem  why a username is not valid, or #f
;;;   password-problem  why a password is not valid, or #f
(library (techo accounts)
  (export normalise-email username-problem password-problem)
  (import (rnrs))

  ;; ascii-lower : Char -> Char
  ;; Lowercases A-Z only, to agree with SQLite's `lower`.
  (define (ascii-lower c)
    (if (and (char>=? c #\A) (char<=? c #\Z))
        (integer->char (+ (char->integer c) 32))
        c))

  ;; control? : Char -> Boolean
  ;; C0 (below U+0020), DEL (U+007F) and C1 (U+0080 to U+009F): a terminal
  ;; can read U+009B as the start of an escape.
  (define (control? c)
    (let ((n (char->integer c))) (or (< n 32) (<= 127 n 159))))

  ;; trim : String -> String
  (define (trim s)
    (let* ((n (string-length s))
           (start (let loop ((i 0))
                    (if (and (< i n) (char-whitespace? (string-ref s i))) (loop (+ i 1)) i)))
           (end (let loop ((j n))
                  (if (and (> j start) (char-whitespace? (string-ref s (- j 1))))
                      (loop (- j 1))
                      j))))
      (substring s start end)))

  ;; normalise-email : Any -> (U String #f)
  ;; Trims, lowercases ASCII letters only, then requires at most 254 bytes
  ;; of UTF-8, exactly one @ with a character on each side, and no
  ;; whitespace or control character. #f otherwise. Never raises.
  (define (normalise-email x)
    (and (string? x)
         (let* ((t (trim x))
                (s (list->string (map ascii-lower (string->list t))))
                (n (string-length s))
                (ats (let loop ((i 0) (acc '()))
                       (cond ((= i n) (reverse acc))
                             ((char=? (string-ref s i) #\@) (loop (+ i 1) (cons i acc)))
                             (else (loop (+ i 1) acc))))))
           (and (> n 0)
                (<= n 254)
                (<= (bytevector-length (string->utf8 s)) 254)
                (= (length ats) 1)
                (> (car ats) 0)
                (< (car ats) (- n 1))
                (not (exists (lambda (c) (or (char-whitespace? c) (control? c)))
                             (string->list s)))
                s))))

  ;; username-problem : Any -> (U #f Symbol)
  ;; Valid is [a-z0-9][a-z0-9_-]{0,31}. Otherwise one of not-a-string, empty,
  ;; too-long, bad-first-character, bad-character.
  (define (username-problem x)
    (define (lower-or-digit? c)
      (or (and (char>=? c #\a) (char<=? c #\z)) (and (char>=? c #\0) (char<=? c #\9))))
    (cond ((not (string? x)) 'not-a-string)
          ((= (string-length x) 0) 'empty)
          ((> (string-length x) 32) 'too-long)
          ((not (lower-or-digit? (string-ref x 0))) 'bad-first-character)
          ((not (for-all (lambda (c) (or (lower-or-digit? c) (char=? c #\_) (char=? c #\-)))
                         (string->list x)))
           'bad-character)
          (else #f)))

  ;; password-problem : Any -> (U #f Symbol)
  ;; Valid is at least 8 characters and at most 1024 bytes of UTF-8.
  ;; Otherwise not-a-string, too-short or too-long. The answer never holds
  ;; the password.
  (define (password-problem x)
    (cond ((not (string? x)) 'not-a-string)
          ((< (string-length x) 8) 'too-short)
          ((> (string-length x) 1024) 'too-long)
          ((> (bytevector-length (string->utf8 x)) 1024) 'too-long)
          (else #f)))
)
