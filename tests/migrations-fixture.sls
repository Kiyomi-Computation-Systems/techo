#!r6rs
;;; (migrations-fixture): the test list of migrations, in one place for the
;;; integration suite and tests/migrate-child.sps. Migration 1 is the shipped
;;; one; 2 and 3 are the tests' own.
(library (migrations-fixture)
  (export fixture-migrations)
  (import (rnrs) (techo migrations))

  ;; fixture-migrations : (Listof Migration)
  (define fixture-migrations
    (list (car migrations)
          (list 2 "notes"
                (list "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT"
                      "CREATE INDEX notes_body ON notes(body)"))
          (list 3 "tags"
                (list "CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT"))))
)
