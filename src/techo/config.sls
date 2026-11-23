#!r6rs
;;; (techo config): the environment, read once, as a value.
;;;
;;; Pure: the caller passes the lookup that stands in for getenv, so tests
;;; pass their own and nothing here reads the process environment. Each
;;; variable is one row of `variables`: its name and a checker. Adding a
;;; variable is adding a row and a field.
(library (techo config)
  (export read-config config? config-db-path problem->string)
  (import (rnrs))

  (define-record-type config
    (fields db-path))

  ;; check-db-path : (U String #f) -> (U Symbol #f)
  ;; The reason VALUE is refused, or #f when it is good.
  (define (check-db-path value)
    (cond ((not value) 'missing)
          ((string=? value "") 'empty)
          ((not (char=? (string-ref value 0) #\/)) 'not-absolute)
          ;; SQLite drops a trailing slash and opens the file; Chez's
          ;; file-exists? says no such file. The two must agree on what is
          ;; missing, or migrate's read-only first look is skipped.
          ((char=? (string-ref value (- (string-length value) 1)) #\/)
           'names-a-directory)
          (else #f)))

  ;; variables : (Listof (Pairof String (-> (U String #f) (U Symbol #f))))
  (define variables
    (list (cons "TECHO_DB_PATH" check-db-path)))

  ;; read-config : (String -> (U String #f)) -> (values (U Config #f) (Listof Problem))
  ;; Problem is (Pairof String Symbol): the variable's name and why it is refused.
  ;; Either a Config and '(), or #f and one or more problems, in table order.
  (define (read-config lookup)
    (let* ((values-read (map (lambda (row) (lookup (car row))) variables))
           (problems
            (let loop ((rows variables) (vals values-read) (acc '()))
              (if (null? rows)
                  (reverse acc)
                  (let ((reason ((cdar rows) (car vals))))
                    (loop (cdr rows) (cdr vals)
                          (if reason
                              (cons (cons (caar rows) reason) acc)
                              acc)))))))
      (if (null? problems)
          (values (make-config (car values-read)) '())
          (values #f problems))))

  ;; config? : Any -> Boolean
  ;; (config? is the record predicate.)

  ;; config-db-path : Config -> String
  ;; (config-db-path is the record accessor for TECHO_DB_PATH.)

  ;; problem->string : Problem -> String
  ;; One line for a person, naming the variable, never its value.
  ;; An unknown reason is an assertion violation.
  (define (problem->string problem)
    (let ((name (car problem)) (reason (cdr problem)))
      (case reason
        ((missing) (string-append name " is not set"))
        ((empty) (string-append name " is empty"))
        ((not-absolute)
         (string-append name " must be an absolute path (start with /)"))
        ((names-a-directory)
         (string-append name " must name a file (it ends with /)"))
        (else (assertion-violation 'problem->string "unknown reason" reason)))))
)
