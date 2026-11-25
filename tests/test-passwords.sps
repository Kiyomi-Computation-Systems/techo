#!r6rs
;;; The passwords suite: (techo passwords). The two prepare procedures are
;;; pure and tested fully. The real hashing verbs run at 'interactive in
;;; exactly three tests (each costs about 50 ms and 64 MiB).
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (only (chez-sodium) make-password-limits password-hash)
        (only (chez-sodium private conditions) make-sodium-failed)
        (techo-testing)
        (techo passwords))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (repeat-string s n)
  (if (= n 0) "" (string-append s (repeat-string s (- n 1)))))

(define nfd "e\x301;")                  ; e + combining acute
(define nfc "\xE9;")                    ; precomposed

(test-begin "passwords")

;;; prepare-password

(test-equal "prepare-password: NFD and NFC forms give the same NFC string"
  (list (string-append "caf" nfc "-secret") (string-append "caf" nfc "-secret"))
  (attempt (lambda ()
             (list (prepare-password (string-append "caf" nfd "-secret"))
                   (prepare-password (string-append "caf" nfc "-secret"))))))

(test-equal "prepare-password: 7 characters is too-short, exactly 8 passes"
  '(too-short "12345678")
  (attempt (lambda () (list (prepare-password "1234567") (prepare-password "12345678")))))

(test-equal "prepare-password: the empty string is too-short"
  'too-short
  (attempt (lambda () (prepare-password ""))))

(test-equal "prepare-password: 1,024 bytes pass, 1,025 are too-long"
  (list 1024 'too-long)
  (attempt (lambda ()
             (list (string-length (prepare-password (repeat-string "a" 1024)))
                   (prepare-password (repeat-string "a" 1025))))))

(test-equal "prepare-password: bytes count, not characters: 512 two-byte characters pass, 513 are too-long"
  (list 512 'too-long)
  (attempt (lambda ()
             (list (string-length (prepare-password (repeat-string nfc 512)))
                   (prepare-password (repeat-string nfc 513))))))

(test-equal "prepare-password: NFC shrinks a string across the minimum: 4 pairs are 8 characters raw but 4 composed, too-short"
  'too-short
  (attempt (lambda () (prepare-password (repeat-string nfd 4)))))

(test-equal "prepare-password: NFC shrinks a string under the maximum: 500 pairs are 1,500 raw bytes, 1,000 composed, so they pass"
  (list 500 1000)
  (attempt (lambda ()
             (let ((p (prepare-password (repeat-string nfd 500))))
               (list (string-length p) (bytevector-length (string->utf8 p)))))))

(test-equal "prepare-password: a non-string is not-a-string"
  '(not-a-string not-a-string not-a-string not-a-string)
  (attempt (lambda ()
             (list (prepare-password #f) (prepare-password 12345678)
                   (prepare-password (string->utf8 "12345678"))
                   (prepare-password 'password)))))

;;; prepare-login-password

(test-equal "prepare-login-password: no minimum: empty and short pass through"
  '("" "a")
  (attempt (lambda () (list (prepare-login-password "") (prepare-login-password "a")))))

(test-equal "prepare-login-password: NFD and NFC forms give the same NFC string"
  (list nfc nfc)
  (attempt (lambda () (list (prepare-login-password nfd) (prepare-login-password nfc)))))

(test-equal "prepare-login-password: 1,024 bytes pass, 1,025 are too-long, bytes not characters"
  (list 1024 'too-long 512 'too-long)
  (attempt (lambda ()
             (list (string-length (prepare-login-password (repeat-string "a" 1024)))
                   (prepare-login-password (repeat-string "a" 1025))
                   (string-length (prepare-login-password (repeat-string nfc 512)))
                   (prepare-login-password (repeat-string nfc 513))))))

(test-equal "prepare-login-password: NFC counts: 500 pairs are 1,500 raw bytes and pass"
  1000
  (attempt (lambda ()
             (bytevector-length (string->utf8 (prepare-login-password (repeat-string nfd 500)))))))

(test-equal "prepare-login-password: a non-string is not-a-string"
  '(not-a-string not-a-string)
  (attempt (lambda () (list (prepare-login-password #f) (prepare-login-password 42)))))

;;; The real verbs, at 'interactive: three tests

;; pinned : String     what a hash at 'interactive starts with: Argon2id,
;; 64 MiB (m=65536 KiB), 2 passes, 1 lane
(define pinned "$argon2id$v=19$m=65536,t=2,p=1$")

(test-equal "sodium-hash: starts with exactly the 64 MiB limits' prefix, verifies its password and not another"
  (list #t pinned #t #f)
  (attempt (lambda ()
             (let ((h (sodium-hash "correct horse battery")))
               (list (string? h)
                     (and (>= (string-length h) (string-length pinned))
                          (substring h 0 (string-length pinned)))
                     (sodium-verify h "correct horse battery")
                     (sodium-verify h "wrong horse battery"))))))

(test-equal "NFC and NFD forms of one password, each through prepare-password, verify against one hash"
  '(#t #t)
  (attempt (lambda ()
             (let ((h (sodium-hash (prepare-password (string-append "caf" nfc "-secret")))))
               (list (sodium-verify h (prepare-password (string-append "caf" nfc "-secret")))
                     (sodium-verify h (prepare-password (string-append "caf" nfd "-secret"))))))))

(test-equal "sodium-needs-rehash?: #f for a fresh hash, #t for one made at the smallest limits"
  '(#f #t)
  (attempt (lambda ()
             (list (sodium-needs-rehash? (sodium-hash "correct horse battery"))
                   (sodium-needs-rehash?
                    (password-hash "correct horse battery" (make-password-limits 1 8)))))))

;;; memory-short?

(test-equal "memory-short?: #f for things that are not a &sodium-failed"
  '(#f #f #f)
  (attempt (lambda () (list (memory-short? 'oops) (memory-short? (make-assertion-violation))
                            (memory-short? #f)))))

(test-equal "memory-short?: #t for a real &sodium-failed condition"
  #t
  (attempt (lambda () (memory-short? (make-sodium-failed "crypto_pwhash_str" -1)))))

(test-end "passwords")

(exit (suite-exit-status runner))
