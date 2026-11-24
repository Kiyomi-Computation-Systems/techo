#!r6rs
;;; (migrations-fixture): the test list of migrations, in one place for the
;;; integration suite and tests/migrate-child.sps. It is the whole shipped
;;; list, then the tests' own two migrations, numbered after the shipped
;;; list's last version, so a new shipped migration moves them up.
(library (migrations-fixture)
  (export fixture-migrations fixture-shipped-version
          fixture-notes-version fixture-tags-version fixture-latest-version)
  (import (rnrs) (techo migrations))

  ;; fixture-shipped-version : Natural
  ;; The last version of the shipped list.
  (define fixture-shipped-version (latest-version migrations))

  ;; fixture-notes-version, fixture-tags-version : Natural
  ;; The versions of the fixture's own migrations.
  (define fixture-notes-version (+ fixture-shipped-version 1))
  (define fixture-tags-version (+ fixture-shipped-version 2))

  ;; fixture-latest-version : Natural
  (define fixture-latest-version fixture-tags-version)

  ;; fixture-migrations : (Listof Migration)
  (define fixture-migrations
    (append migrations
            (list (list fixture-notes-version "notes"
                        (list "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT"
                              "CREATE INDEX notes_body ON notes(body)"))
                  (list fixture-tags-version "tags"
                        (list "CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT")))))
)
