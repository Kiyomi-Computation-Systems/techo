#!r6rs
;;; A test program, not a suite: `migrate!` with the fixture list, stopped
;;; inside a transaction so the parent can `kill -9` it (ADR-0012, clause 6).
;;;
;;;   migrate-child.sps DB READY-FILE KIND N
;;;
;;; The observer counts the commands of kind KIND (a symbol's name, such as
;;; foreign-key-check). At the N-th it writes READY-FILE and sleeps for an
;;; hour. If the run ends first, it prints the result's lines and exits 0.
(import (rnrs)
        (only (chezscheme) sleep make-time)
        (techo db)
        (techo migrations)
        (migrations-fixture))

(let* ((args (cdr (command-line)))
       (db (car args))
       (ready (cadr args))
       (kind (string->symbol (caddr args)))
       (n (string->number (cadddr args)))
       (seen 0))
  (let ((result
         (migrate! db fixture-migrations
                   (lambda (command)
                     (when (eq? (car command) kind)
                       (set! seen (+ seen 1))
                       (when (= seen n)
                         (call-with-output-file ready
                           (lambda (p) (put-string p "ready\n")))
                         (sleep (make-time 'time-duration 0 3600))))))))
    (for-each (lambda (l) (put-string (current-output-port) l) (newline (current-output-port)))
              (result->lines result))
    (flush-output-port (current-output-port))
    (exit 0)))
