#!r6rs
;;; The accounts suite: an email, a username and a password, checked as
;;; pure functions (slice 3, "Smaller choices").
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo accounts))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (repeat-string s n)
  (if (= n 0) "" (string-append s (repeat-string s (- n 1)))))

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(define (email s) (attempt (lambda () (normalise-email s))))

(test-begin "accounts")

;;; normalise-email

(test-equal "email: plain" "a@b.c" (email "a@b.c"))
(test-equal "email: lowercased" "kishu@example.com" (email "Kishu@Example.COM"))
(test-equal "email: trimmed" "a@b.c" (email " \t a@b.c \n"))
(test-equal "email: non-ASCII left as it is" "\xc9;a@b.c" (email "\xc9;A@B.C"))
(test-equal "email: a non-ASCII letter is not lowercased" "\x3a3;@x.y" (email "\x3a3;@X.Y"))
(test-equal "email: 254 bytes" #t
  (string? (email (string-append (repeat-string "a" 242) "@example.com"))))
(test-equal "email: 255 bytes" #f
  (email (string-append (repeat-string "a" 243) "@example.com")))
(test-equal "email: two-byte characters count as bytes" #f
  (email (string-append (repeat-string "\xe9;" 128) "@x.y")))
(test-equal "email: no @" #f (email "abc"))
(test-equal "email: two @" #f (email "a@b@c"))
(test-equal "email: nothing before @" #f (email "@b.c"))
(test-equal "email: nothing after @" #f (email "a@"))
(test-equal "email: empty" #f (email ""))
(test-equal "email: blank" #f (email "   "))
(test-equal "email: space inside" #f (email "a b@c.d"))
(test-equal "email: newline inside" #f (email "a@b\n.c"))
(test-equal "email: NUL inside" #f (email "a\x0;@b.c"))
(test-equal "email: DEL inside" #f (email "a\x7f;@b.c"))
(test-equal "email: not a string" #f (email 5))

;; DEL and C1 controls: a terminal can read U+009B as the start of an
;; escape, and `user add` prints the email back
(define c1-cases
  (list (cons "U+007F" (integer->char #x7f)) (cons "U+0080" (integer->char #x80))
        (cons "U+009B" (integer->char #x9b)) (cons "U+009F" (integer->char #x9f))))

(for-each
 (lambda (c)
   (test-equal (string-append "email: " (car c) " inside is refused")
     '(#f #f)
     (list (email (string-append "a" (string (cdr c)) "@b.c"))
           (email (string-append "a@b.c" (string (cdr c)))))))
 c1-cases)

(test-equal "email: ordinary non-ASCII still passes: e acute, U+00A1 (just past C1), CJK"
  '("\xe9;t\xe9;@b.c" "\xa1;hola@b.c" "\x65e5;\x672c;@\x65e5;\x672c;.jp")
  (list (email "\xe9;t\xe9;@b.c") (email "\xa1;hola@b.c") (email "\x65e5;\x672c;@\x65e5;\x672c;.jp")))
(test-equal "email: #f" #f (email #f))

;;; username-problem

(define (user s) (attempt (lambda () (username-problem s))))

(test-equal "user: simple" #f (user "kishu"))
(test-equal "user: digit first" #f (user "9lives"))
(test-equal "user: underscore and hyphen inside" #f (user "a_b-c"))
(test-equal "user: 32 characters" #f (user (make-string 32 #\a)))
(test-equal "user: 33 characters" 'too-long (user (make-string 33 #\a)))
(test-equal "user: empty" 'empty (user ""))
(test-equal "user: capital" 'bad-character (user "aB"))
(test-equal "user: capital first" 'bad-first-character (user "Ab"))
(test-equal "user: underscore first" 'bad-first-character (user "_a"))
(test-equal "user: hyphen first" 'bad-first-character (user "-a"))
(test-equal "user: space" 'bad-character (user "a b"))
(test-equal "user: non-ASCII" 'bad-character (user "a\xe9;"))
(test-equal "user: not a string" 'not-a-string (user 'a))

(for-each
 (lambda (c)
   (test-equal (string-append "user: " (car c) " inside is a bad character, first a bad first character")
     '(bad-character bad-first-character)
     (list (user (string-append "a" (string (cdr c)) "b"))
           (user (string-append (string (cdr c)) "ab")))))
 c1-cases)

;;; password-problem

(define (pw s) (attempt (lambda () (password-problem s))))

(test-equal "password: 8 characters" #f (pw "12345678"))
(test-equal "password: 7 characters" 'too-short (pw "1234567"))
(test-equal "password: empty" 'too-short (pw ""))
(test-equal "password: 8 non-ASCII characters are 8 characters" #f (pw (make-string 8 (integer->char #x3bb))))
(test-equal "password: 1024 bytes" #f (pw (make-string 1024 #\a)))
(test-equal "password: 1025 bytes" 'too-long (pw (make-string 1025 #\a)))
(test-equal "password: 512 two-byte characters are 1024 bytes" #f (pw (make-string 512 (integer->char #xe9))))
(test-equal "password: 513 two-byte characters" 'too-long (pw (make-string 513 (integer->char #xe9))))
(test-equal "password: not a string" 'not-a-string (pw 12345678))
(test-equal "password: spaces are allowed" #f (pw "        "))

(test-assert "password: the answer never contains the password"
  (for-all
   (lambda (p)
     (let ((r (pw p)))
       (or (not r)
           (and (symbol? r)
                (not (string-index-of (symbol->string r) p))))))
   '("shrt!" "hunter22-secret" "abc" "toolongtoolongtoolong")))

(test-end "accounts")

(exit (suite-exit-status runner))
