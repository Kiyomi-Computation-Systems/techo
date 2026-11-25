#!r6rs
;;; (techo config): the environment, read once, as a value.
;;;
;;; Pure: the caller passes the lookup that stands in for getenv, so tests
;;; pass their own and nothing here reads the process environment. Each
;;; variable is one row of `variables`: its name and a checker. Adding a
;;; variable is adding a row and a field.
(library (techo config)
  (export read-config config? config-db-path config-db-readers
          config-behind-proxy problem->string)
  (import (rnrs))

  (define-record-type config
    (fields db-path db-readers behind-proxy))

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

  ;; readers-of : (U String #f) -> (U Natural #f)
  ;; The number VALUE writes in decimal digits (ASCII 0 to 9, at least one),
  ;; 2 when unset, else #f. Not yet range-checked.
  (define (readers-of value)
    (cond ((not value) 2)
          ((and (positive? (string-length value))
                (for-all (lambda (c) (char<=? #\0 c #\9)) (string->list value)))
           (string->number value 10))
          (else #f)))

  ;; check-db-readers : (U String #f) -> (U Symbol #f)
  (define (check-db-readers value)
    (let ((n (readers-of value)))
      (if (and n (<= 1 n 16)) #f 'not-1-to-16)))

  ;; proxies-of : (U String #f) -> (U Natural #f)
  ;; The number VALUE writes in decimal digits (same rule as readers-of),
  ;; 0 when unset, else #f. Not yet range-checked.
  (define (proxies-of value)
    (if value (readers-of value) 0))

  ;; check-behind-proxy : (U String #f) -> (U Symbol #f)
  (define (check-behind-proxy value)
    (let ((n (proxies-of value)))
      (if (and n (<= 0 n 8)) #f 'not-0-to-8)))

  ;; variables : (Listof (List String Checker Reader))
  ;; A row is the variable's name, its checker (the reason it is refused, or
  ;; #f) and its reader (the field's value, once the checker passed).
  (define variables
    (list (list "TECHO_DB_PATH" check-db-path (lambda (v) v))
          (list "TECHO_DB_READERS" check-db-readers readers-of)
          (list "TECHO_BEHIND_PROXY" check-behind-proxy proxies-of)))

  ;; read-config : (String -> (U String #f)) -> (values (U Config #f) (Listof Problem))
  ;; Problem is (Pairof String Symbol): the variable's name and why it is refused.
  ;; Either a Config and '(), or #f and one or more problems, in table order.
  (define (read-config lookup)
    (let* ((values-read (map (lambda (row) (lookup (car row))) variables))
           (problems
            (let loop ((rows variables) (vals values-read) (acc '()))
              (if (null? rows)
                  (reverse acc)
                  (let ((reason ((cadar rows) (car vals))))
                    (loop (cdr rows) (cdr vals)
                          (if reason
                              (cons (cons (caar rows) reason) acc)
                              acc)))))))
      (if (null? problems)
          (values (apply make-config
                 (map (lambda (row v) ((caddr row) v)) variables values-read)) '())
          (values #f problems))))

  ;; config? : Any -> Boolean
  ;; (config? is the record predicate.)

  ;; config-db-path : Config -> String
  ;; (config-db-path is the record accessor for TECHO_DB_PATH.)

  ;; config-db-readers : Config -> Natural
  ;; (config-db-readers is the record accessor for TECHO_DB_READERS: 1 to 16,
  ;; 2 when unset.)

  ;; config-behind-proxy : Config -> Natural
  ;; (config-behind-proxy is the record accessor for TECHO_BEHIND_PROXY: 0 to
  ;; 8, 0 when unset.)

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
        ((not-1-to-16)
         (string-append name " must be a whole number from 1 to 16"))
        ((not-0-to-8)
         (string-append name " must be a whole number from 0 to 8"))
        (else (assertion-violation 'problem->string "unknown reason" reason)))))
)
