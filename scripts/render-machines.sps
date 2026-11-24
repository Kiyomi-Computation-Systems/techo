#!r6rs
;;; Prints one machines document to standard output. With no argument, the
;;; text (machines-document) renders from the migrate tables, for
;;; .plans/machines/migrate.md; with `doorway`, the text (doorway-document)
;;; renders from the doorway's three tables, for .plans/machines/doorway.md.
;;; `make machines` writes both files, and tests/test-migrations.sps and
;;; tests/test-transaction.sps hold each file to its function.
(import (rnrs)
        (techo migrations)
        (techo transaction))

(define which (let ((args (cdr (command-line)))) (if (null? args) "migrate" (car args))))

(put-string (current-output-port)
            (cond ((string=? which "migrate") (machines-document))
                  ((string=? which "doorway") (doorway-document))
                  (else (assertion-violation 'render-machines
                          "name `migrate` or `doorway`" which))))
(flush-output-port (current-output-port))
