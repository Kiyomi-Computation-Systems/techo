#!r6rs
;;; The stack suite: proves the library path. circuit, chez-sqlite3,
;;; chez-curl and threading import together from their places on `make
;;; test`'s path, and each answers one small fact. No network.
;;;
;;;   (circuit)       make-res builds a response whose status reads back
;;;   (chez-sqlite3)  `select 1` on a :memory: database answers 1
;;;   (http-client)   the session constructor is a procedure
;;;   (threading)     a ~> chain has its value
;;;   (http-server)   exports await-outside, so the path takes the server
;;;                   from its submodule, 0.12.0, ahead of Akku's 0.11.0
;;;                   (ADR-0011, amended), and circuit hands on the same one
;;;   (chez-sodium)   blake2b of a fixed input is the known hash,
;;;                   random-bytes answers fresh bytes, and a password's
;;;                   hash verifies it and no other
;;;   (unique-id)     a generator makes version 7 ids, each greater
;;;
;;; Everything that can raise is computed under a guard, and a raise comes
;;; out as a sentinel the expected value never is, so a failure names what
;;; was raised, never #f.
(import (rnrs)
        (rnrs eval)
        (srfi :64)
        (techo-testing)
        (circuit)
        (chez-sqlite3)
        (http-client)
        (threading))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(test-begin "stack")

(test-equal "circuit: make-res's status reads back"
  200
  (attempt (lambda () (res-status (make-res 200 '() "ok")))))

(test-equal "circuit: make-res's body reads back"
  "ok"
  (attempt (lambda () (res-body (make-res 200 '() "ok")))))

(test-equal "chez-sqlite3: select 1 on :memory: answers 1"
  1
  (attempt
   (lambda ()
     (call-with-database ":memory:"
       (lambda (db)
         (vector-ref (query-row db "select 1") 0))))))

(test-equal "threading: a ~> chain has its value"
  7
  (attempt (lambda () (~> 3 (+ 1) (* 2) (- 1)))))

(test-equal "chez-curl: make-http-session is a procedure"
  #t
  (attempt (lambda () (procedure? make-http-session))))

;; Looked up at run time: a missing export would otherwise stop the suite at
;; expansion, before any test is named.
;; exported : Symbol Datum -> (U Any (List 'raised String))
(define (exported name library)
  (attempt (lambda () (eval name (environment library)))))

(test-equal "chez-http-server: (http-server) exports await-outside"
  #t
  (let ((v (exported 'await-outside '(http-server))))
    (if (procedure? v) #t v)))

(test-equal "circuit: (circuit http-server) hands on the server's await-outside"
  #t
  (let ((ours (exported 'await-outside '(circuit http-server)))
        (theirs (exported 'await-outside '(http-server))))
    (if (and (procedure? ours) (eq? ours theirs)) #t (list ours theirs))))

(test-equal "circuit: (circuit http-server) exports http-server-config-error?"
  #t
  (let ((v (exported 'http-server-config-error? '(circuit http-server))))
    (if (procedure? v) #t v)))

;; chez-sodium and unique-id, looked up at run time for the same reason. A
;; program that imports chez-sodium's verbs dies before its first line when
;; libsodium is missing, so an import here would name no test.
;; run-in : Datum Datum -> (U Any (List 'raised String))
(define (run-in expr . libraries)
  (attempt (lambda () (eval expr (apply environment libraries)))))

;; hex : Bytevector -> String
;; Lowercase: Chez's number->string writes A to F in capitals.
(define (hex bv)
  (apply string-append
         (map (lambda (b)
                (string-append (if (< b 16) "0" "")
                               (string-downcase (number->string b 16))))
              (bytevector->u8-list bv))))

(test-equal "chez-sodium: blake2b of 32 bytes of 01 is the known 32 bytes"
  "f40ceaf86e5776923332b8d8fd3bef849cadb19c6996bc272af1f648d9566a4c"
  (let ((v (run-in '(blake2b (make-bytevector 32 1)) '(rnrs) '(chez-sodium))))
    (if (bytevector? v) (hex v) v)))

(test-equal "chez-sodium: random-bytes 32 answers 32 bytes, twice different"
  '(32 32 #f)
  (run-in '(let ((a (random-bytes 32)) (b (random-bytes 32)))
             (list (bytevector-length a) (bytevector-length b) (equal? a b)))
          '(rnrs) '(chez-sodium)))

;; password-verify takes the hash first. The limits here are the smallest
;; libsodium allows (1 pass, 8 MiB), so the suite stays quick.
(test-equal "chez-sodium: a password's hash is argon2id, verifies it and no other, and is current at its limits"
  '("$argon2id$" #t #f #f #t)
  (run-in '(let* ((small (make-password-limits 1 8192))
                  (h (password-hash "correct horse" small)))
             (list (substring h 0 10)
                   (password-verify h "correct horse")
                   (password-verify h "wrong horse")
                   (password-needs-rehash? h small)
                   (password-needs-rehash? h 'interactive)))
          '(rnrs) '(chez-sodium)))

(test-equal "unique-id: a generator over a fixed clock and bytes makes a version 7 id, then a greater one"
  '(7 "01935e11-" #t)
  (run-in '(let* ((g (make-uuid-generator (lambda () 1732450000000)
                                          (lambda (n) (make-bytevector n 5))))
                  (a (generate-v7 g))
                  (b (generate-v7 g)))
             (list (uuid-version a)
                   (substring (uuid->string a) 0 9)
                   (uuid<? a b)))
          '(rnrs) '(unique-id) '(unique-id generator)))

(test-end "stack")

(exit (suite-exit-status runner))
