#!r6rs
;;; Prints one machines document to standard output. With no argument, the
;;; text (machines-document) renders from the migrate tables, for
;;; .plans/machines/migrate.md; with `doorway`, the text (doorway-document)
;;; renders from the doorway's three tables, for .plans/machines/doorway.md;
;;; with `key`, (key-document) renders D5's table, for .plans/machines/key.md;
;;; with `login`, (login-document) renders L1's table, for
;;; .plans/machines/login.md; with `write`, (write-document) renders slice 4's
;;; D5 table, for .plans/machines/write.md; with `lifecycle`,
;;; (lifecycle-document) renders slice 4b's table, for
;;; .plans/machines/lifecycle.md; with `task`, (task-document) renders slice
;;; 6's task table, for .plans/machines/task.md. `make machines` writes the
;;; seven files, and tests/test-migrations.sps, tests/test-transaction.sps,
;;; tests/test-keys.sps, tests/test-login.sps, tests/test-nodes.sps and
;;; tests/test-tasks.sps hold each to its function.
(import (rnrs)
        (techo keys)
        (only (techo login) login-document)
        (only (techo nodes) write-document lifecycle-document)
        (only (techo tasks) task-document)
        (techo migrations)
        (techo transaction))

(define which (let ((args (cdr (command-line)))) (if (null? args) "migrate" (car args))))

(put-string (current-output-port)
            (cond ((string=? which "migrate") (machines-document))
                  ((string=? which "doorway") (doorway-document))
                  ((string=? which "key") (key-document))
                  ((string=? which "login") (login-document))
                  ((string=? which "write") (write-document))
                  ((string=? which "lifecycle") (lifecycle-document))
                  ((string=? which "task") (task-document))
                  (else (assertion-violation 'render-machines
                          "name `migrate`, `doorway`, `key`, `login`, `write`, `lifecycle` or `task`"
                          which))))
(flush-output-port (current-output-port))
