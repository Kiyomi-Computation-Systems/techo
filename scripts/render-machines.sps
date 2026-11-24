#!r6rs
;;; Prints one machines document to standard output. With no argument, the
;;; text (machines-document) renders from the migrate tables, for
;;; .plans/machines/migrate.md; with `doorway`, the text (doorway-document)
;;; renders from the doorway's three tables, for .plans/machines/doorway.md;
;;; with `key`, (key-document) renders D5's table, for .plans/machines/key.md.
;;; `make machines` writes the three files, and tests/test-migrations.sps,
;;; tests/test-transaction.sps and tests/test-keys.sps hold each to its function.
(import (rnrs)
        (techo keys)
        (techo migrations)
        (techo transaction))

(define which (let ((args (cdr (command-line)))) (if (null? args) "migrate" (car args))))

(put-string (current-output-port)
            (cond ((string=? which "migrate") (machines-document))
                  ((string=? which "doorway") (doorway-document))
                  ((string=? which "key") (key-document))
                  (else (assertion-violation 'render-machines
                          "name `migrate`, `doorway` or `key`" which))))
(flush-output-port (current-output-port))
