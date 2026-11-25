#!r6rs
;;; Prints one machines document to standard output. With no argument, the
;;; text (machines-document) renders from the migrate tables, for
;;; .plans/machines/migrate.md; with `doorway`, the text (doorway-document)
;;; renders from the doorway's three tables, for .plans/machines/doorway.md;
;;; with `key`, (key-document) renders D5's table, for .plans/machines/key.md;
;;; with `login`, (login-document) renders L1's table, for
;;; .plans/machines/login.md. `make machines` writes the four files, and
;;; tests/test-migrations.sps, tests/test-transaction.sps, tests/test-keys.sps
;;; and tests/test-login.sps hold each to its function.
(import (rnrs)
        (techo keys)
        (only (techo login) login-document)
        (techo migrations)
        (techo transaction))

(define which (let ((args (cdr (command-line)))) (if (null? args) "migrate" (car args))))

(put-string (current-output-port)
            (cond ((string=? which "migrate") (machines-document))
                  ((string=? which "doorway") (doorway-document))
                  ((string=? which "key") (key-document))
                  ((string=? which "login") (login-document))
                  (else (assertion-violation 'render-machines
                          "name `migrate`, `doorway`, `key` or `login`" which))))
(flush-output-port (current-output-port))
