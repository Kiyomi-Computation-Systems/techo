#!r6rs
;;; The stack suite: proves the library path. circuit, chez-sqlite3,
;;; chez-curl and threading import together from their places on `make
;;; test`'s path, and each answers one small fact. No network.
;;;
;;;   (circuit)       make-res builds a response whose status reads back
;;;   (chez-sqlite3)  `select 1` on a :memory: database answers 1
;;;   (http-client)   the session constructor is a procedure
;;;   (threading)     a ~> chain has its value
;;;
;;; Everything that can raise is computed under a guard, and a raise comes
;;; out as a sentinel the expected value never is, so a failure names what
;;; was raised, never #f.
(import (rnrs)
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

(test-end "stack")

(exit (suite-exit-status runner))
