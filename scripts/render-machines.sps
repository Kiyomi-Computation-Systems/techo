#!r6rs
;;; Prints .plans/machines/migrate.md to standard output: the text
;;; (machines-document) renders from the migrate tables. `make machines`
;;; writes it to the file, and tests/test-migrations.sps holds the file to
;;; the same function.
(import (rnrs) (techo migrations))

(put-string (current-output-port) (machines-document))
(flush-output-port (current-output-port))
