#!r6rs
;;; The config suite: (techo config) turns an environment lookup into a
;;; Config, or into the list of what is wrong. The lookup is a procedure,
;;; so these tests never touch the real environment.
;;;
;;; Everything that can raise is computed under a guard, and a raise comes
;;; out as a sentinel the expected value never is, so a failure names what
;;; was raised, never #f.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo config))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; env : (Listof (Pairof String String)) -> (String -> (U String #f))
(define (env alist)
  (lambda (name)
    (let ((p (assoc name alist)))
      (and p (cdr p)))))

;; run : (String -> (U String #f)) -> (List (U Config #f) (Listof Problem))
(define (run lookup)
  (call-with-values (lambda () (read-config lookup)) list))

;; run-problems : lookup -> (U (Listof Problem) (List 'raised String))
(define (run-problems lookup)
  (attempt (lambda () (cadr (run lookup)))))

(test-begin "config")

(test-equal "good: no problems"
  '()
  (run-problems (env '(("TECHO_DB_PATH" . "/var/lib/techo/techo.db")))))

(test-equal "good: the answer is a config"
  #t
  (attempt (lambda () (config? (car (run (env '(("TECHO_DB_PATH" . "/a/b")))))))))

(test-equal "good: the db path reads back"
  "/var/lib/techo/techo.db"
  (attempt
   (lambda ()
     (config-db-path
      (car (run (env '(("TECHO_DB_PATH" . "/var/lib/techo/techo.db")))))))))

(test-equal "trailing slash: a lone / names a directory"
  '(#f (("TECHO_DB_PATH" . names-a-directory)))
  (attempt (lambda () (run (env '(("TECHO_DB_PATH" . "/")))))))
(test-equal "trailing slash: /var/lib/techo/techo.db/ names a directory"
  '(#f (("TECHO_DB_PATH" . names-a-directory)))
  (attempt (lambda () (run (env '(("TECHO_DB_PATH" . "/var/lib/techo/techo.db/")))))))
(test-equal "problem->string: names-a-directory names the variable"
  "TECHO_DB_PATH must name a file (it ends with /)"
  (attempt (lambda () (problem->string '("TECHO_DB_PATH" . names-a-directory)))))

(test-equal "config?: a string is not a config"
  #f
  (attempt (lambda () (config? "/a/b"))))

(test-equal "config?: #f is not a config"
  #f
  (attempt (lambda () (config? #f))))

(test-equal "bad: no config, only #f"
  #f
  (attempt (lambda () (car (run (env '()))))))

(test-equal "missing: the variable is named with reason missing"
  '(("TECHO_DB_PATH" . missing))
  (run-problems (env '())))

(test-equal "empty: reason empty"
  '(("TECHO_DB_PATH" . empty))
  (run-problems (env '(("TECHO_DB_PATH" . "")))))

(test-equal "relative: reason not-absolute"
  '(("TECHO_DB_PATH" . not-absolute))
  (run-problems (env '(("TECHO_DB_PATH" . "data/techo.db")))))

(test-equal "relative: a dot-slash path is not absolute"
  '(("TECHO_DB_PATH" . not-absolute))
  (run-problems (env '(("TECHO_DB_PATH" . "./techo.db")))))

(test-equal "lookup: asked for the variable by its name, once"
  '("TECHO_DB_PATH")
  (let ((asked '()))
    (attempt
     (lambda ()
       (read-config (lambda (name) (set! asked (cons name asked)) "/x"))
       asked))))

(test-equal "problem->string: missing names the variable"
  "TECHO_DB_PATH is not set"
  (attempt (lambda () (problem->string '("TECHO_DB_PATH" . missing)))))

(test-equal "problem->string: empty names the variable"
  "TECHO_DB_PATH is empty"
  (attempt (lambda () (problem->string '("TECHO_DB_PATH" . empty)))))

(test-equal "problem->string: not-absolute names the variable"
  "TECHO_DB_PATH must be an absolute path (start with /)"
  (attempt (lambda () (problem->string '("TECHO_DB_PATH" . not-absolute)))))

(test-equal "problem->string: another name is used as given"
  "TECHO_OTHER is not set"
  (attempt (lambda () (problem->string '("TECHO_OTHER" . missing)))))

;; contains? : String String -> Boolean
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

(test-equal "problem->string: never includes the value"
  '(#f)
  (attempt
   (lambda ()
     (let ((problems (cadr (run (env '(("TECHO_DB_PATH" . "hunter2/secret.db")))))))
       (map (lambda (p) (contains? (problem->string p) "hunter2")) problems)))))

(test-equal "problem->string: an unknown reason is an assertion violation"
  'assertion
  (guard (e ((assertion-violation? e) 'assertion)
            (#t (list 'raised (describe e))))
    (problem->string '("TECHO_DB_PATH" . bogus))
    'no-raise))

(test-end "config")

(exit (suite-exit-status runner))
