#!r6rs
;;; The db suite: (techo db), the shell of `techo migrate`, and the clauses
;;; of "What the model assumes of SQLite" (slice 2 plan) that a single
;;; process can hold: 1 to 5 and 7 to 10. Clauses 6 and 11 need killed
;;; processes and are in the integration suite.
;;;
;;; Every database file is under build/test-db/<unique>/, made at the start
;;; (build/test-db is emptied first). Everything that can raise is computed
;;; under `attempt`, and a raise comes out as a value the expectation never
;;; is.
(import (rnrs)
        (only (chezscheme) mkdir directory-list delete-directory file-directory?
                           current-time time-second time-nanosecond)
        (srfi :64)
        (chez-sqlite3)
        (techo-testing)
        (techo migrations)
        (techo db))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-kind : (-> Any) -> Any
;; What a thunk raised: (sqlite CODE), assertion, or (other TEXT); 'no-raise
;; when it did not.
(define (raised-kind thunk)
  (guard (e ((sqlite-busy? e) 'busy)
            ((sqlite-error? e) (list 'sqlite (sqlite-error-code e)))
            ((assertion-violation? e) 'assertion)
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

;;; The directory

(define (rm-tree! p)
  (cond ((file-directory? p)
         (for-each (lambda (n) (rm-tree! (string-append p "/" n)))
                   (directory-list p))
         (delete-directory p))
        ((file-exists? p) (delete-file p))))

(define (make-dir! p) (unless (file-directory? p) (mkdir p #o755)))

(define test-dir
  (let ((t (current-time)))
    (guard (e (#t #f))
      (make-dir! "build")
      (rm-tree! "build/test-db")
      (make-dir! "build/test-db")
      (let ((d (string-append "build/test-db/"
                              (number->string (time-second t)) "-"
                              (number->string (time-nanosecond t)))))
        (make-dir! d)
        d))))

(define (path name) (string-append test-dir "/" name))

(define (clean! p)
  (for-each (lambda (s) (when (file-exists? (string-append p s))
                          (delete-file (string-append p s))))
            '("" "-wal" "-shm")))

;; read-bytes : String -> Bytevector    (get-bytevector-all gives eof for no bytes)
(define (read-bytes p)
  (let ((b (call-with-port (open-file-input-port p) get-bytevector-all)))
    (if (eof-object? b) (make-bytevector 0) b)))

(define (write-bytes! p bv)
  (call-with-port (open-file-output-port p (file-options no-fail))
    (lambda (port) (put-bytevector port bv))))

(define (copy-bytes! from to) (write-bytes! to (read-bytes from)))

;; now-ms : -> Integer
(define (now-ms)
  (let ((t (current-time 'time-monotonic)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))

;;; Plain chez-sqlite3 helpers

;; plain : String -> Database    (create, no waiting, nothing else set)
(define (plain p) (open-database p '((busy-timeout . 0))))

;; with-db : Database (Database -> A) -> A     closes it on the way out
(define (with-db db proc)
  (dynamic-wind (lambda () #f) (lambda () (proc db))
                (lambda () (guard (e (#t #f)) (close-database! db)))))

;; row : Database String -> (U (Listof Any) #f)
(define (row db sql)
  (let ((r (query-row db sql))) (and r (vector->list r))))

;; rows : Database String -> (Listof (Listof Any))
(define (rows db sql) (map vector->list (query db sql)))

;; make-file! : String (Listof String) -> Void
;; A file with SQLITE's own header, set up by plain calls and closed.
(define (make-file! p sqls)
  (clean! p)
  (with-db (plain p) (lambda (db) (for-each (lambda (s) (execute! db s)) sqls))))

;; facts-of : String -> DbFacts
;; Read through open-techo-db 'read-only, which is under test elsewhere.
(define (facts-of p)
  (with-db (open-techo-db p 'read-only) read-db-facts))

(define T techo-application-id)

;; shape : RawOutcome -> (List Symbol Boolean)
(define (shape o) (list (car o) (caddr o)))

;; run-cmds : Shell (Listof Command) -> (Listof RawOutcome)
(define (run-cmds sh cmds) (map (lambda (c) (perform! sh c)) cmds))

;; in-shell : String Natural (Shell -> A) -> A    closes whatever is open
(define (in-shell p timeout proc)
  (let ((sh (make-shell p timeout)))
    (dynamic-wind (lambda () #f) (lambda () (proc sh))
                  (lambda () (perform! sh '(close))))))

(test-begin "db")

;;; open-techo-db

;; settings-of : String Symbol Natural -> (List fk synchronous busy journal)
(define (settings-of p mode timeout)
  (with-db (open-techo-db p mode timeout)
    (lambda (db)
      (list (car (row db "PRAGMA foreign_keys"))
            (car (row db "PRAGMA synchronous"))
            (car (row db "PRAGMA busy_timeout"))
            (car (row db "PRAGMA journal_mode"))))))

(let ((p (path "settings.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "open-techo-db 'read-write: fk on, synchronous full, timeout, journal untouched"
    '(1 2 0 "delete")
    (attempt (lambda () (settings-of p 'read-write 0))))
  (test-equal "open-techo-db 'read-only: fk on, synchronous full, timeout, journal untouched"
    '(1 2 0 "delete")
    (attempt (lambda () (settings-of p 'read-only 0))))
  (test-equal "open-techo-db 'migrate: fk OFF, synchronous full, timeout, journal untouched"
    '(0 2 0 "delete")
    (attempt (lambda () (settings-of p 'migrate 0))))
  (test-equal "open-techo-db: the default busy timeout is busy-timeout-ms (5000)"
    (list 5000 5000 5000)
    (attempt
     (lambda ()
       (map (lambda (m)
              (with-db (open-techo-db p m)
                (lambda (db) (car (row db "PRAGMA busy_timeout")))))
            '(read-write read-only migrate)))))
  (test-equal "busy-timeout-ms is 5000" 5000 busy-timeout-ms)
  (test-equal "open-techo-db: a mode that is not one is refused, nothing opened"
    'assertion
    (raised-kind (lambda () (open-techo-db p 'create)))))

(let ((p (path "newfile.db")))
  (clean! p)
  (test-equal "open-techo-db 'migrate on a new file: journal stays delete, file made"
    '(#t (0 2 0 "delete"))
    (attempt (lambda ()
               (let ((s (settings-of p 'migrate 0)))
                 (list (file-exists? p) (cons 0 (cdr s))))))))

(let ((p (path "ro-missing.db")))
  (clean! p)
  (test-equal "open-techo-db 'read-only on a missing path raises cantopen, creates nothing"
    '((sqlite cantopen) #f)
    (attempt (lambda ()
               (list (raised-kind (lambda () (open-techo-db p 'read-only 0)))
                     (file-exists? p))))))

(let ((p (path "rw-missing.db")))
  (clean! p)
  (test-equal "open-techo-db 'read-write on a missing path raises cantopen, creates nothing"
    '((sqlite cantopen) #f)
    (attempt (lambda ()
               (list (raised-kind (lambda () (open-techo-db p 'read-write 0)))
                     (file-exists? p))))))

(let ((p (path "migrate-creates.db")))
  (clean! p)
  (test-equal "open-techo-db 'migrate on a missing path creates the file"
    #t
    (attempt (lambda ()
               (with-db (open-techo-db p 'migrate 0)
                 (lambda (db) (execute! db "create table t (x)")))
               (file-exists? p)))))

(let ((p (path "ro-write.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "open-techo-db 'read-only cannot write"
    '(sqlite readonly)
    (attempt (lambda ()
               (with-db (open-techo-db p 'read-only 0)
                 (lambda (db)
                   (raised-kind (lambda () (execute! db "insert into t values (1)")))))))))

;;; facts-sql and read-db-facts

(let ((p (path "facts-new.db")))
  (clean! p)
  (test-equal "facts-sql on a new file: one row, four columns: 0 0 0 delete"
    '((0 0 0 "delete"))
    (attempt (lambda () (with-db (plain p) (lambda (db) (rows db facts-sql))))))
  (test-equal "facts-sql is one statement: execute! takes it"
    'ok
    (attempt (lambda ()
               (with-db (plain p) (lambda (db) (execute! db facts-sql) 'ok)))))
  (test-equal "read-db-facts on a new file: the mode is a lower-case symbol"
    '(0 0 0 delete)
    (attempt (lambda () (with-db (plain p) read-db-facts)))))

(let ((p (path "facts-wal.db")))
  (make-file! p '("create table t (x)" "pragma application_id = 7"
                  "pragma user_version = 3"))
  (test-equal "facts-sql on a WAL file: the mode column is wal"
    '((7 3 1 "wal"))
    (attempt (lambda ()
               (with-db (plain p)
                 (lambda (db)
                   (execute! db "pragma journal_mode = wal")
                   (rows db facts-sql))))))
  (test-equal "read-db-facts on a WAL file: wal symbol"
    '(7 3 1 wal)
    (attempt (lambda () (with-db (plain p) read-db-facts)))))

(let ((p (path "facts-view.db")))
  (make-file! p '("create view v as select 1"))
  (test-equal "facts-sql on a file with only a view: the schema count is 1"
    '((0 0 1 "delete"))
    (attempt (lambda () (with-db (plain p) (lambda (db) (rows db facts-sql)))))))

(let ((p (path "facts-txn.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "facts-sql inside a transaction sees its uncommitted stamp and table"
    '(((0 0 1 "delete")) ((0 9 2 "delete")) ((0 0 1 "delete")))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (db)
           (let* ((before (rows db facts-sql))
                  (inside (begin (execute! db "begin immediate")
                                 (execute! db "pragma user_version = 9")
                                 (execute! db "create table u (y)")
                                 (rows db facts-sql)))
                  (after (begin (execute! db "rollback") (rows db facts-sql))))
             (list before inside after))))))))

;;; perform!, command by command

(let ((p (path "perf-missing.db")))
  (clean! p)
  (test-equal "perform! open-read-only on a missing file: missing, flag #f, nothing created"
    '((missing #f) #f #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (let ((o (perform! sh '(open-read-only))))
                     (list (shape o) (shell-database sh) (file-exists? p)))))))))

(let ((p (path "perf-missing-string.db")))
  (clean! p)
  (test-assert "perform! missing: the value is a reason string"
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh) (string? (cadr (perform! sh '(open-read-only))))))))))

(let ((p (path "perf-open.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "perform! open-read-only on a file: ok #t, flag #f, a connection"
    '((ok #t #f) #t)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (let ((o (perform! sh '(open-read-only))))
                     (list o (database? (shell-database sh)))))))))
  (test-equal "perform! open-read-write: ok, and creates a missing file"
    '((ok #t #f) #t)
    (attempt (lambda ()
               (let ((q (path "perf-open-rw-new.db")))
                 (clean! q)
                 (in-shell q 0
                   (lambda (sh)
                     (list (perform! sh '(open-read-write)) (file-exists? q))))))))
  (test-equal "perform! open-read-write opens with foreign keys off"
    '(0)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (row (shell-database sh) "PRAGMA foreign_keys"))))))
  (test-equal "perform! open-read-only opens with foreign keys on"
    '(1)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-only))
                   (row (shell-database sh) "PRAGMA foreign_keys"))))))
  (test-equal "perform! open when a connection is open: failed, the first stays"
    '((failed #f) #t)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-only))
                   (let ((o (perform! sh '(open-read-write))))
                     (list (shape o) (database? (shell-database sh))))))))))

(let ((p (path "perf-junk.db")))
  (clean! p)
  (write-bytes! p (make-bytevector 5000 120))
  (test-equal "perform! open-read-only on a file that is not a database: failed"
    '((failed #f) #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (let ((o (perform! sh '(open-read-only))))
                     (list (shape o) (shell-database sh))))))))
  (test-equal "perform! open-read-write on a file that is not a database: failed, with SQLite's words"
    '(failed "file is not a database")
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (let ((o (perform! sh '(open-read-write))))
                     (list (car o) (cadr o)))))))))

(let ((p (path "perf-nodir/x.db")))
  (test-equal "perform! open-read-write in a directory that is not there: failed"
    '(failed #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh) (shape (perform! sh '(open-read-write)))))))))

(let ((p (path "perf-facts.db")))
  (make-file! p '("create table t (x)" "pragma user_version = 4"))
  (test-equal "perform! read-facts: ok, the facts, flag #f"
    '(ok (0 4 1 delete) #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-only))
                   (perform! sh '(read-facts)))))))
  (test-equal "perform! read-facts inside a transaction: flag #t"
    '(ok (0 4 1 delete) #t)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(begin-immediate))
                   (perform! sh '(read-facts)))))))
  (test-equal "perform! with no connection: failed, flag #f, for each command that needs one"
    (map (lambda (c) '(failed #f))
         '((read-facts) (set-wal) (begin-immediate) (run-statement . "select 1")
           (foreign-key-check) (stamp . 1) (commit) (rollback)))
    (attempt (lambda ()
               (let ((sh (make-shell p 0)))
                 (map (lambda (c) (shape (perform! sh c)))
                      '((read-facts) (set-wal) (begin-immediate)
                        (run-statement . "select 1") (foreign-key-check)
                        (stamp . 1) (commit) (rollback))))))))

(let ((p (path "perf-wal.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "perform! set-wal: ok #t, flag #f, and the file reads wal"
    '((ok #t #f) wal)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (let ((o (perform! sh '(set-wal))))
                     (list o (cadddr (cadr (perform! sh '(read-facts)))))))))))
  (test-equal "perform! set-wal on a file already in WAL: ok"
    '(ok #t #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(set-wal)))))))
  (test-equal "perform! set-wal when SQLite answers another mode (an in-memory database says memory): failed"
    '(failed #f)
    (attempt (lambda ()
               (in-shell ":memory:" 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (shape (perform! sh '(set-wal))))))))
  (let ((q (path "perf-wal-ro.db")))
    (make-file! q '("create table t (x)"))
    (test-equal "perform! set-wal on a read-only connection of a file not in WAL: failed, nothing changed"
      '(failed delete)
      (attempt (lambda ()
                 (in-shell q 0
                   (lambda (sh)
                     (perform! sh '(open-read-only))
                     (let ((o (perform! sh '(set-wal))))
                       (list (car o)
                             (cadddr (cadr (perform! sh '(read-facts))))))))))))
  (let ((q (path "perf-wal-txn.db")))
    (make-file! q '("create table t (x)"))
    (test-equal "perform! set-wal inside a transaction: failed, flag #t"
      '(failed #t)
      (attempt (lambda ()
                 (in-shell q 0
                   (lambda (sh)
                     (perform! sh '(open-read-write))
                     (perform! sh '(begin-immediate))
                     (shape (perform! sh '(set-wal))))))))))

(let ((p (path "perf-txn.db")))
  (make-file! p '("create table t (x unique)"))
  (test-equal "perform! begin-immediate, commit: ok flags #t then #f"
    '((ok #t #t) (ok #t #f))
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (let* ((b (perform! sh '(begin-immediate)))
                          (c (perform! sh '(commit))))
                     (list b c)))))))
  (test-equal "perform! begin-immediate inside a transaction: failed, flag #t"
    '(failed #t)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(begin-immediate))
                   (shape (perform! sh '(begin-immediate))))))))
  (test-equal "perform! rollback: ok #t flag #f, and the change is gone"
    '((ok #t #f) (0))
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(begin-immediate))
                   (perform! sh '(run-statement . "insert into t values (1)"))
                   (let ((o (perform! sh '(rollback))))
                     (list o (row (shell-database sh) "select count(*) from t"))))))))
  (test-equal "perform! commit with no transaction: failed, flag #f"
    '(failed #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (shape (perform! sh '(commit))))))))
  (test-equal "perform! rollback with no transaction: failed, flag #f"
    '(failed #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (shape (perform! sh '(rollback)))))))))

(let ((p (path "perf-busy.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "perform! begin-immediate while another connection holds the lock: busy, flag #f; then ok once it lets go"
    '((busy #f) (ok #t))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (other)
           (execute! other "begin immediate")
           (in-shell p 0
             (lambda (sh)
               (perform! sh '(open-read-write))
               (let ((first (shape (perform! sh '(begin-immediate)))))
                 (execute! other "rollback")
                 (list first (shape (perform! sh '(begin-immediate))))))))))))
  (test-equal "perform! busy: the value is a reason string"
    #t
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (other)
           (execute! other "begin immediate")
           (in-shell p 0
             (lambda (sh)
               (perform! sh '(open-read-write))
               (string? (cadr (perform! sh '(begin-immediate))))))))))))

;; in-txn : String (Shell -> A) -> A    a migrate connection inside BEGIN IMMEDIATE
(define (in-txn p proc)
  (in-shell p 0
    (lambda (sh)
      (perform! sh '(open-read-write))
      (perform! sh '(begin-immediate))
      (proc sh))))

(let ((p (path "perf-stmt.db")))
  (make-file! p '("create table t (x unique)" "insert into t values (1)"))
  (test-equal "perform! run-statement ok: ok #t, flag #t in a transaction"
    '(ok #t #t)
    (attempt (lambda ()
               (in-txn p (lambda (sh)
                         (perform! sh '(run-statement . "insert into t values (2)")))))))
  (test-equal "perform! run-statement ok outside a transaction: flag #f"
    '(ok #t #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(run-statement . "select 1")))))))
  (test-equal "perform! run-statement failing: failed, the transaction still open"
    '(failed #t)
    (attempt (lambda ()
               (in-txn p (lambda (sh)
                         (shape (perform! sh '(run-statement . "insert into nosuch values (1)"))))))))
  (test-equal "perform! run-statement, a constraint failure: failed, flag #t, SQLite's words"
    '(failed #t "UNIQUE constraint failed: t.x")
    (attempt (lambda ()
               (in-txn p (lambda (sh)
                         (let ((o (perform! sh '(run-statement . "insert into t values (1)"))))
                           (list (car o) (caddr o) (cadr o))))))))
  (test-equal "perform! run-statement `insert or rollback` failing: failed, the transaction ended, flag #f"
    '(failed #f)
    (attempt (lambda ()
               (in-txn p (lambda (sh)
                         (shape (perform! sh '(run-statement . "insert or rollback into t values (1)"))))))))
  (test-equal "perform! run-statement `COMMIT`: ok, flag #f"
    '(ok #f)
    (attempt (lambda ()
               (in-txn p (lambda (sh)
                         (shape (perform! sh '(run-statement . "COMMIT"))))))))
  (test-equal "perform! run-statement with two statements: failed, nothing ran, the transaction open"
    '((failed #t) ())
    (attempt (lambda ()
               (in-txn p (lambda (sh)
                         (let ((o (perform! sh '(run-statement . "create table a (x); create table b (x)"))))
                           (list (shape o)
                                 (rows (shell-database sh)
                                       "select name from sqlite_schema where name in ('a','b')"))))))))
  (test-equal "perform! run-statement with no statement (empty, comment): failed"
    '((failed #t) (failed #t))
    (attempt (lambda ()
               (in-txn p (lambda (sh)
                         (list (shape (perform! sh '(run-statement . "")))
                               (shape (perform! sh '(run-statement . "-- nothing"))))))))))

(let ((p (path "perf-stamp.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "perform! stamp: ok #t, flag #t in a transaction, and user_version reads it, committed"
    '((ok #t #t) (7))
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(begin-immediate))
                   (let ((o (perform! sh '(stamp . 7))))
                     (perform! sh '(commit))
                     (list o (with-db (plain p)
                               (lambda (db) (row db "PRAGMA user_version"))))))))))
  (test-equal "perform! stamp: not an exact positive integer raises an assertion"
    '(assertion assertion assertion assertion assertion)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (map (lambda (k)
                          (raised-kind (lambda () (perform! sh (cons 'stamp k)))))
                        (list 0 -1 1.5 "1" '(1)))))))))

(let ((p (path "perf-stamp2.db")))
  (make-file! p '("pragma user_version = 7"))
  (test-equal "perform! stamp with a bad k leaves user_version as it was"
    '(7)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (raised-kind (lambda () (perform! sh '(stamp . 0))))
                   (row (shell-database sh) "PRAGMA user_version")))))))

(let ((p (path "perf-fk.db")))
  (make-file! p '("create table parent (id integer primary key)"
                  "create table child (pid integer references parent(id))"))
  (test-equal "perform! foreign-key-check, clean: ok, the empty list, flag #f"
    '(ok () #f)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(foreign-key-check)))))))
  (test-equal "perform! foreign-key-check with a dangling row: ok, one row naming it, flag #t in a transaction"
    '(ok ((child 1 parent 0)) #t)
    (attempt (lambda ()
               (in-shell p 0
                 (lambda (sh)
                   (perform! sh '(open-read-write))
                   (perform! sh '(begin-immediate))
                   (perform! sh '(run-statement . "insert into child values (5)"))
                   (let ((o (perform! sh '(foreign-key-check))))
                     (list (car o)
                           (map (lambda (r) (cons (string->symbol (car r))
                                                  (cons (cadr r)
                                                        (cons (string->symbol (caddr r))
                                                              (cdddr r)))))
                                (cadr o))
                           (caddr o)))))))))

(let ((p (path "perf-close.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "perform! close: ok #t flag #f, forgets the connection; closing again is ok"
    '((ok #t #f) #f (ok #t #f))
    (attempt (lambda ()
               (let ((sh (make-shell p 0)))
                 (perform! sh '(open-read-only))
                 (let* ((c (perform! sh '(close))) (db (shell-database sh))
                        (c2 (perform! sh '(close))))
                   (list c db c2))))))
  (test-equal "perform! close with a transaction open drops it: another connection can lock"
    'ok
    (attempt (lambda ()
               (let ((sh (make-shell p 0)))
                 (perform! sh '(open-read-write))
                 (perform! sh '(begin-immediate))
                 (perform! sh '(close))
                 (with-db (plain p)
                   (lambda (db) (execute! db "begin immediate") 'ok)))))))

(let ((p (path "perf-close-drop.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "perform! close with a transaction open drops its changes: the table is not there"
    '("t")
    (attempt (lambda ()
               (let ((sh (make-shell p 0)))
                 (perform! sh '(open-read-write))
                 (perform! sh '(begin-immediate))
                 (perform! sh '(run-statement . "create table u (x)"))
                 (perform! sh '(close))
                 (with-db (plain p)
                   (lambda (db)
                     (map car (rows db "select name from sqlite_schema order by name")))))))))

(test-equal "perform! pause: ok #t, flag #f, and it waits"
  '((ok #t #f) #t)
  (attempt (lambda ()
             (let* ((sh (make-shell (path "perf-pause.db") 0))
                    (t0 (now-ms))
                    (o (perform! sh '(pause . 120))))
               (list o (>= (- (now-ms) t0) 100))))))

(test-equal "perform! end, and a command that is not one: assertion violations"
  '(assertion assertion)
  (attempt (lambda ()
             (let ((sh (make-shell (path "perf-end.db") 0)))
               (list (raised-kind (lambda () (perform! sh '(end . whatever))))
                     (raised-kind (lambda () (perform! sh '(fly)))))))))

(test-equal "make-shell: no connection yet, both arities"
  '(#f #f)
  (attempt (lambda ()
             (list (shell-database (make-shell (path "x.db")))
                   (shell-database (make-shell (path "x.db") 0))))))

;;; The clauses

;; Clause 1: a transaction's changes take effect together or not at all.
(let ((p (path "c1.db")))
  (make-file! p '("create table keep (x)"))
  (test-equal "clause 1: a rolled-back transaction leaves no table, id or version"
    '((0 0 1 "delete") (0 0 1 "delete"))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (a)
           (with-db (plain p)
             (lambda (b)
               (execute! a "begin immediate")
               (execute! a "create table gone (x)")
               (execute! a "pragma application_id = 99")
               (execute! a "pragma user_version = 5")
               (execute! a "rollback")
               (list (row a facts-sql) (row b facts-sql)))))))))
  (test-equal "clause 1: a committed one lands whole, and another connection sees none before it"
    '((0 0 1 "delete") (99 5 2 "delete") (99 5 2 "delete"))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (a)
           (with-db (plain p)
             (lambda (b)
               (execute! a "begin immediate")
               (execute! a "create table landed (x)")
               (execute! a "pragma application_id = 99")
               (execute! a "pragma user_version = 5")
               (let ((during (row b facts-sql)))
                 (execute! a "commit")
                 (list during (row a facts-sql) (row b facts-sql)))))))))))

;; Clause 2: creating and dropping tables is part of the transaction.
(let ((p (path "c2.db")))
  (make-file! p '("create table keep (x)" "insert into keep values (1), (2)"))
  (test-equal "clause 2: create and drop roll back with the transaction"
    '((("keep")) ((2)))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (db)
           (execute! db "begin immediate")
           (execute! db "create table made (x)")
           (execute! db "drop table keep")
           (execute! db "rollback")
           (list (rows db "select name from sqlite_schema")
                 (rows db "select count(*) from keep"))))))))

;; Clause 3: BEGIN IMMEDIATE lets one in; another waits, then is told busy.
(let ((p (path "c3.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "clause 3: with timeout 0 the second BEGIN IMMEDIATE is busy at once; free after a commit"
    '(busy no-raise)
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (a)
           (with-db (plain p)
             (lambda (b)
               (execute! a "begin immediate")
               (let ((first (raised-kind (lambda () (execute! b "begin immediate")))))
                 (execute! a "commit")
                 (list first (raised-kind (lambda () (execute! b "begin immediate"))))))))))))
  (test-equal "clause 3: with a timeout, the second waits about that long, then is busy"
    '(busy #t)
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (a)
           (with-db (open-techo-db p 'migrate 250)
             (lambda (b)
               (execute! a "begin immediate")
               (let* ((t0 (now-ms))
                      (r (raised-kind (lambda () (execute! b "begin immediate")))))
                 (list r (>= (- (now-ms) t0) 200)))))))))))

;; Clause 4: outside a transaction a connection sees only what is committed,
;; and one statement sees one moment.
(let ((p (path "c4.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "clause 4: a reader sees only committed rows"
    '((0) (0) (1))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (w)
           (with-db (plain p)
             (lambda (r)
               (let ((before (row r "select count(*) from t")))
                 (execute! w "begin immediate")
                 (execute! w "insert into t values (1)")
                 (let ((during (row r "select count(*) from t")))
                   (execute! w "commit")
                   (list before during (row r "select count(*) from t")))))))))))
  (test-equal "clause 4: one statement sees one moment, though a commit lands under it (WAL)"
    '(1 2)
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (w)
           (execute! w "pragma journal_mode = wal")
           (execute! w "insert into t values (2), (3), (4), (5)")
           (with-db (plain p)
             (lambda (r)
               (let* ((seen 0)
                      (landed #f)
                      (before (row r "select count(*) from t"))
                      (total
                       (query-fold r "select x from t"
                                   (lambda (acc rw)
                                     (unless landed
                                       (set! landed #t)
                                       (execute! w "insert into t values (6), (7)"))
                                     (+ acc 1))
                                   0)))
                 ;; the fold read the 5 rows of its own moment, not 7
                 (list (if (= total (car before)) 1 0)
                       (if (= (car (row r "select count(*) from t")) 7) 2 0)))))))))))

;; Clause 5: a failure inside a transaction leaves it open or ends it, and
;; in-transaction? says which.
(let ((p (path "c5.db")))
  (make-file! p '("create table t (x unique)" "insert into t values (1)"))
  (test-equal "clause 5: a constraint failure leaves it open; insert or rollback ends it"
    '(#t #f)
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (db)
           (execute! db "begin immediate")
           (raised-kind (lambda () (execute! db "insert into t values (1)")))
           (let ((open (in-transaction? db)))
             (execute! db "rollback")
             (execute! db "begin immediate")
             (raised-kind (lambda () (execute! db "insert or rollback into t values (1)")))
             (list open (in-transaction? db)))))))))

;; Clause 7: a new file reads id 0, version 0 and an empty schema.
(let ((p (path "c7.db")) (q (path "c7-empty.db")))
  (clean! p) (clean! q)
  (write-bytes! q (make-bytevector 0))
  (test-equal "clause 7: a new file, and a file of no bytes, read 0 0 0"
    '((0 0 0 "delete") (0 0 0 "delete"))
    (attempt (lambda ()
               (list (with-db (plain p) (lambda (db) (row db facts-sql)))
                     (with-db (plain q) (lambda (db) (row db facts-sql))))))))

;; Clause 8: setting WAL is told busy at once while another connection
;; holds the write lock. (No race: the other connection holds BEGIN
;; IMMEDIATE on a file not in WAL.)
(let ((p (path "c8.db")))
  (make-file! p '("create table t (x)"))
  (test-equal "clause 8: set-wal is busy at once, though the timeout is 5000; then ok when released"
    '((busy #f) #t (ok #f))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (other)
           (execute! other "begin immediate")
           (in-shell p 5000
             (lambda (sh)
               (perform! sh '(open-read-write))
               (let* ((t0 (now-ms))
                      (o (perform! sh '(set-wal)))
                      (quick (< (- (now-ms) t0) 2000)))
                 (execute! other "rollback")
                 (list (shape o) quick (shape (perform! sh '(set-wal))))))))))))
  (test-equal "clause 8: the same by a plain journal_mode pragma: busy, not a silent no-op"
    '(busy)
    (attempt
     (lambda ()
       (let ((q (path "c8b.db")))
         (make-file! q '("create table t (x)"))
         (with-db (plain q)
           (lambda (other)
             (execute! other "begin immediate")
             (with-db (open-techo-db q 'migrate 5000)
               (lambda (db)
                 (list (raised-kind (lambda () (execute! db "pragma journal_mode = wal")))))))))))))

;; Clause 9: a read-only open never creates a file; reads a WAL file with no
;; -wal or -shm beside it; never changes a main file, a leftover -wal or not.
(let ((p (path "c9-wal.db")))
  (make-file! p '("create table t (x)" "insert into t values (1), (2)"))
  (with-db (plain p) (lambda (db) (execute! db "pragma journal_mode = wal")))
  (test-equal "clause 9: a cleanly closed WAL file has no -wal or -shm"
    '(#f #f)
    (list (file-exists? (string-append p "-wal"))
          (file-exists? (string-append p "-shm"))))
  (test-equal "clause 9: a read-only open reads it; the main file is byte for byte the same"
    '((0 0 1 wal) ((1) (2)) #t)
    (attempt
     (lambda ()
       (let ((before (read-bytes p)))
         (let ((out (with-db (open-techo-db p 'read-only 0)
                      (lambda (db)
                        (list (read-db-facts db) (rows db "select x from t order by x"))))))
           (append out (list (bytevector=? before (read-bytes p)))))))))
  (test-equal "clause 9: a read-only open of a missing path creates no file"
    '((sqlite cantopen) #f)
    (attempt (lambda ()
               (let ((q (path "c9-missing.db")))
                 (clean! q)
                 (list (raised-kind (lambda () (open-techo-db q 'read-only 0)))
                       (file-exists? q)))))))

;; A WAL file whose writer died: main + a leftover -wal, copied from a live
;; connection, so that nothing was folded in.
(define (leftover-copy! src dst)
  (clean! src) (clean! dst)
  (with-db (plain src)
    (lambda (db)
      (execute! db "pragma journal_mode = wal")
      (execute! db "pragma wal_autocheckpoint = 0")
      (execute! db "create table t (x)")
      (execute! db "insert into t values (1), (2), (3)")
      (copy-bytes! src dst)
      (copy-bytes! (string-append src "-wal") (string-append dst "-wal")))))

(let ((src (path "c9-src.db")) (ro (path "c9-ro.db")) (rw (path "c9-rw.db")))
  (leftover-copy! src ro)
  (copy-bytes! ro rw)
  (copy-bytes! (string-append ro "-wal") (string-append rw "-wal"))
  (test-equal "clause 9: the leftover copy has a -wal, and its main file lacks the rows"
    '(#t #t)
    (attempt (lambda ()
               (list (file-exists? (string-append ro "-wal"))
                     (> (bytevector-length (read-bytes (string-append ro "-wal"))) 0)))))
  (test-equal "clause 9: a read-only open and close sees the leftover -wal's rows, and leaves the main file the same"
    '(((1) (2) (3)) #t)
    (attempt
     (lambda ()
       (let* ((before (read-bytes ro))
              (seen (with-db (open-techo-db ro 'read-only 0)
                      (lambda (db) (rows db "select x from t order by x")))))
         (list seen (bytevector=? before (read-bytes ro)))))))
  (test-equal "clause 9: a migrate open and close of the same leftover changes the main file"
    '(((1) (2) (3)) #f)
    (attempt
     (lambda ()
       (let* ((before (read-bytes rw))
              (seen (with-db (open-techo-db rw 'migrate 0)
                      (lambda (db) (rows db "select x from t order by x")))))
         (list seen (bytevector=? before (read-bytes rw))))))))

;; Clause 10: PRAGMA foreign_keys is ignored inside a transaction, and
;; foreign_key_check there names a dangling row.
(let ((p (path "c10.db")))
  (make-file! p '("create table parent (id integer primary key)"
                  "create table child (pid integer references parent(id))"))
  (test-equal "clause 10: keys off, switching them on inside a transaction does nothing"
    '((0) (0) #t)
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'migrate 0)
         (lambda (db)
           (let ((before (row db "PRAGMA foreign_keys")))
             (execute! db "begin immediate")
             (execute! db "pragma foreign_keys = on")
             (let ((inside (row db "PRAGMA foreign_keys")))
               (execute! db "insert into child values (5)")
               (execute! db "rollback")
               (list before inside #t))))))))
  (test-equal "clause 10: keys on, switching them off inside a transaction does nothing"
    '((1) (1) constraint)
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db)
           (let ((before (row db "PRAGMA foreign_keys")))
             (execute! db "begin immediate")
             (execute! db "pragma foreign_keys = off")
             (let ((inside (row db "PRAGMA foreign_keys"))
                   (r (guard (e ((sqlite-constraint? e) 'constraint) (#t 'other))
                        (execute! db "insert into child values (5)")
                        'no-raise)))
               (execute! db "rollback")
               (list before inside r))))))))
  (test-equal "clause 10: foreign_key_check inside a transaction names the dangling row"
    '(("child" 1 "parent" 0))
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'migrate 0)
         (lambda (db)
           (execute! db "begin immediate")
           (execute! db "insert into child values (5)")
           (let ((r (rows db "PRAGMA foreign_key_check")))
             (execute! db "rollback")
             r)))))))

;;; migrate! and check-db, end to end

;; result-of : (-> Result) -> Result or raise text
(define (versions-of p)
  (with-db (plain p) (lambda (db) (car (row db "PRAGMA user_version")))))
(define (id-of p)
  (with-db (plain p) (lambda (db) (car (row db "PRAGMA application_id")))))
(define (tables-of p)
  (with-db (plain p)
    (lambda (db) (map car (rows db "select name from sqlite_schema where type = 'table' order by name")))))
(define (lock-free? p)
  (with-db (plain p)
    (lambda (db) (execute! db "begin immediate") (execute! db "rollback") #t)))

;; The machinery's tests below run on the shipped list's first migration alone
;; (a one-migration world); the shipped list as a whole is run here and in
;; "every shipped migration" below.
(define first-only (list (car migrations)))

;; objects in the shipped schema: accounts, api_keys, the index, and the
;; automatic indexes of the primary and unique keys, then migration 3, and migration 5's index (counted from sqlite_schema: 15).
(define shipped-objects 15)

(let ((p (path "m-missing.db")))
  (clean! p)
  (test-equal "migrate! on a missing file: every shipped version applied, converted; the file is current, in WAL, Techo's"
    (list (list 'applied (map car migrations) #t (latest-version migrations))
          (list T (latest-version migrations) shipped-objects 'wal) #t)
    (attempt (lambda ()
               (let ((r (migrate! p migrations)))
                 (list r (facts-of p) (lock-free? p))))))
  (test-equal "migrate! on that file again: nothing, not converted"
    (list 'nothing '() #f (latest-version migrations))
    (attempt (lambda () (migrate! p migrations)))))

(let ((p (path "m-ahead.db")))
  (make-file! p (list (string-append "pragma application_id = " (number->string T))
                      "pragma user_version = 9" "create table t (x)"))
  (test-equal "migrate! on a file made ahead by hand: refused, its bytes unchanged"
    '(refused #t)
    (attempt (lambda ()
               (let* ((before (read-bytes p))
                      (r (migrate! p first-only)))
                 (list (car r) (bytevector=? before (read-bytes p))))))))

(let ((p (path "m-foreign.db")))
  (make-file! p '("pragma application_id = 42" "pragma user_version = 1"
                  "create table t (x)"))
  (test-equal "migrate! on another program's file: refused, its bytes unchanged"
    '(refused #t)
    (attempt (lambda ()
               (let* ((before (read-bytes p))
                      (r (migrate! p first-only)))
                 (list (car r) (bytevector=? before (read-bytes p))))))))

(let ((p (path "m-foreign-wal.db")) (src (path "m-foreign-src.db")))
  (leftover-copy! src p)
  (test-equal "migrate! on another program's file with a leftover -wal: refused, the main file unchanged"
    '(refused #t)
    (attempt (lambda ()
               (let* ((before (read-bytes p))
                      (r (migrate! p first-only)))
                 (list (car r) (bytevector=? before (read-bytes p))))))))

(let ((cur (path "m-vac-src.db")) (copy (path "m-vac.db")))
  (clean! cur) (clean! copy)
  (migrate! cur first-only)
  (with-db (plain cur)
    (lambda (db) (execute! db (string-append "VACUUM INTO '" copy "'"))))
  (test-equal "the VACUUM INTO copy of a current WAL file is current but not in WAL"
    (list T 1 0 'delete)
    (attempt (lambda () (facts-of copy))))
  (test-equal "migrate! on the VACUUM INTO copy: nothing applied, converted, now in WAL"
    (list '(nothing () #t 1) (list T 1 0 'wal))
    (attempt (lambda () (list (migrate! copy first-only) (facts-of copy))))))

;; a longer list: migration 1 is the shipped one
(define (second-migration . stmts) (list 2 "two" stmts))
(define longer
  (append first-only
          (list (second-migration "create table two (x)"))))

(let ((cur (path "m-vac2-src.db")) (copy (path "m-vac2.db")))
  (clean! cur) (clean! copy)
  (migrate! cur first-only)
  (with-db (plain cur)
    (lambda (db) (execute! db (string-append "VACUUM INTO '" copy "'"))))
  (test-equal "migrate! on a VACUUM INTO copy that is behind: converted and applied (2)"
    (list '(applied (2) #t 2) (list T 2 1 'wal))
    (attempt (lambda () (list (migrate! copy longer) (facts-of copy))))))

(define three
  (append first-only
          (list (list 2 "two" '("create table first_table (x)"
                                "insert into no_such_table values (1)"))
                (list 3 "three" '("create table third (x)")))))

(let ((p (path "m-fail.db")))
  (clean! p)
  (test-equal "migrate! with a second statement that fails: failed 2, version 1, the first statement's table gone, no lock held"
    '(failed (1) #t 1 () #t)
    (attempt (lambda ()
               (let ((r (migrate! p three)))
                 (list (car r) (cadr r) (caddr r) (versions-of p)
                       (tables-of p) (lock-free? p))))))
  (test-equal "migrate! failing: the detail names the migration, SQLite's words and no commit"
    '(2 #f)
    (attempt (lambda ()
               (clean! p)
               (let* ((r (migrate! p three)) (d (cadddr r)))
                 (list (car d) (caddr d)))))))

(define hostile
  (append first-only
          (list (list 2 "two" '("create table first_table (x)" "COMMIT"
                                "create table after_commit (x)")))))

(let ((p (path "m-commit.db")))
  (clean! p)
  (test-equal "migrate! with COMMIT as a middle statement: failed 2 (R29), version still 1, no lock held"
    '(failed (1) 2 1 #t)
    (attempt (lambda ()
               (let ((r (migrate! p hostile)))
                 (list (car r) (cadr r) (car (cadddr r)) (versions-of p)
                       (lock-free? p))))))
  (test-equal "migrate! with COMMIT as a middle statement: the statements before it did commit, none after ran"
    '("first_table")
    (attempt (lambda () (filter (lambda (n) (member n '("first_table" "after_commit")))
                                (tables-of p))))))

(let ((p (path "m-observer.db")))
  (clean! p)
  (test-equal "migrate! calls the observer once per command, in order, before it is performed"
    '((open-read-only) (open-read-write) (read-facts) (set-wal) (read-facts)
      (begin-immediate) (read-facts)
      (run-statement . "PRAGMA application_id = 1952801640")
      (foreign-key-check) (stamp . 1) (commit) (close))
    (attempt (lambda ()
               (let ((seen '()))
                 (migrate! p first-only (lambda (c) (set! seen (cons c seen))))
                 (reverse seen)))))
  (test-equal "migrate! observer: a command is observed before the file shows its effect"
    '(#f #t)
    (attempt (lambda ()
               (clean! p)
               (let ((at-stamp #f) (after #f))
                 (migrate! p first-only
                           (lambda (c)
                             (when (eq? (car c) 'stamp)
                               (set! at-stamp (file-exists? p)))))
                 (list (not at-stamp) (= (versions-of p) 1)))))))

(let ((p (path "m-raise.db")))
  (clean! p)
  (test-equal "migrate! closes its connection when an observer raises: the lock is dropped, and nothing was committed"
    '(raised #t 0 0)
    (attempt (lambda ()
               (let ((r (guard (e (#t 'raised))
                          (migrate! p first-only
                                    (lambda (c)
                                      (when (eq? (car c) 'commit)
                                        (raise 'boom)))))))
                 (list r (lock-free? p) (versions-of p) (id-of p)))))))

(let ((p (path "m-shipped.db")))
  (clean! p)
  (test-equal "every shipped migration on a new file: all versions committed, the version and Techo's id read back"
    (list (map car migrations) (latest-version migrations) T)
    (attempt (lambda ()
               (let ((r (migrate! p migrations)))
                 (list (cadr r) (versions-of p) (id-of p))))))
  (test-equal "the shipped list passes check-migrations" '()
    (attempt (lambda () (check-migrations migrations)))))

;; check-db

;; verdict-kind : Verdict -> (U 'serve Symbol)
(define (verdict-kind v) (if (pair? v) (cadr v) v))

(let ((p (path "k-missing.db")))
  (clean! p)
  (test-equal "check-db on a missing file: refused as missing, and still missing"
    '(missing #f)
    (attempt (lambda () (list (verdict-kind (check-db p first-only))
                              (file-exists? p)))))
  (test-equal "check-db's refusal is (refuse KIND REASON) with a string reason"
    '(refuse missing #t)
    (attempt (lambda () (let ((v (check-db p first-only)))
                          (list (car v) (cadr v) (string? (caddr v))))))))

(let ((p (path "k-fresh.db")))
  (clean! p)
  (write-bytes! p (make-bytevector 0))
  (test-equal "check-db on a fresh file: refused as fresh, bytes unchanged"
    '(fresh #t)
    (attempt (lambda ()
               (let* ((before (read-bytes p)) (v (check-db p first-only)))
                 (list (verdict-kind v) (bytevector=? before (read-bytes p))))))))

(let ((p (path "k-behind.db")))
  (clean! p)
  (migrate! p first-only)
  (test-equal "check-db on a file behind a longer list: refused as behind"
    'behind
    (attempt (lambda () (verdict-kind (check-db p longer)))))
  (test-equal "check-db on that same file with the shipped list: serve"
    'serve
    (attempt (lambda () (check-db p first-only)))))

(let ((cur (path "k-unconv-src.db")) (p (path "k-unconv.db")))
  (clean! cur) (clean! p)
  (migrate! cur first-only)
  (with-db (plain cur)
    (lambda (db) (execute! db (string-append "VACUUM INTO '" p "'"))))
  (test-equal "check-db on a current file not in WAL: refused as unconverted, bytes unchanged"
    '(unconverted #t)
    (attempt (lambda ()
               (let* ((before (read-bytes p)) (v (check-db p first-only)))
                 (list (verdict-kind v) (bytevector=? before (read-bytes p))))))))

(let ((p (path "k-ahead.db")))
  (make-file! p (list (string-append "pragma application_id = " (number->string T))
                      "pragma user_version = 9" "create table t (x)"))
  (test-equal "check-db on an ahead file: refused as ahead, bytes unchanged"
    '(ahead #t)
    (attempt (lambda ()
               (let* ((before (read-bytes p)) (v (check-db p first-only)))
                 (list (verdict-kind v) (bytevector=? before (read-bytes p))))))))

(let ((p (path "k-foreign.db")))
  (make-file! p '("pragma application_id = 42" "create table t (x)"))
  (test-equal "check-db on another program's file: refused as foreign, bytes unchanged"
    '(foreign #t)
    (attempt (lambda ()
               (let* ((before (read-bytes p)) (v (check-db p first-only)))
                 (list (verdict-kind v) (bytevector=? before (read-bytes p))))))))

(let ((p (path "k-current.db")))
  (clean! p)
  (migrate! p first-only)
  (test-equal "check-db on a current file in WAL: serve"
    'serve
    (attempt (lambda () (check-db p first-only))))
  (test-equal "check-db on a file that is not a database: refused as cannot-open"
    'cannot-open
    (attempt (lambda ()
               (let ((q (path "k-junk.db")))
                 (clean! q)
                 (write-bytes! q (make-bytevector 5000 120))
                 (verdict-kind (check-db q first-only)))))))

;;; A hot rollback journal: a file in rollback mode whose writer stopped
;;; mid-transaction after its cache spilled. Made without a kill: the main
;;; file and its journal are copied aside while the writer is mid-transaction
;;; and put back once it has rolled back.

(define hot-reason
  "an interrupted write is still in the database: open it once with `sqlite3`, then run `techo migrate` again")

;; make-hot! : String -> Boolean     #t when a journal is beside the file
(define (make-hot! p)
  (clean! p)
  (make-file! p (list "PRAGMA application_id = 1952801640"
                      "PRAGMA user_version = 1"
                      "create table junk (x)"
                      "insert into junk values (randomblob(500))"))
  (with-db (plain p)
    (lambda (db)
      (execute! db "PRAGMA cache_size = 2")
      (execute! db "begin immediate")
      (do ((i 0 (+ i 1))) ((= i 400))
        (execute! db "insert into junk values (randomblob(500))"))
      (copy-bytes! p (string-append p ".hot"))
      (copy-bytes! (string-append p "-journal") (string-append p ".hot-journal"))
      (execute! db "rollback")))
  (copy-bytes! (string-append p ".hot") p)
  (copy-bytes! (string-append p ".hot-journal") (string-append p "-journal"))
  (file-exists? (string-append p "-journal")))

(let ((p (path "hot.db")))
  (test-equal "a hot journal: the read-only open fails and names the case, and the file is unchanged"
    (list #t (list 'failed hot-reason #f) #t)
    (attempt (lambda ()
               (let* ((made (make-hot! p))
                      (before (read-bytes p))
                      (o (perform! (make-shell p 0) '(open-read-only))))
                 (list made o (equal? before (read-bytes p)))))))
  (test-equal "a hot journal: migrate! ends cannot-open with the named reason"
    (list 'cannot-open hot-reason)
    (attempt (lambda ()
               (make-hot! p)
               (let ((r (migrate! p first-only)))
                 (list (car r) (cadddr r))))))
  (test-equal "a hot journal: check-db refuses with the named reason"
    (list 'refuse 'cannot-open (string-append "cannot open the database: " hot-reason))
    (attempt (lambda () (make-hot! p) (check-db p first-only))))
  (test-equal "a hot journal: after one read-write open, migrate! converts the file"
    '(nothing #t)
    (attempt (lambda ()
               (make-hot! p)
               (with-db (plain p) (lambda (db) (row db "select count(*) from junk")))
               (let ((r (migrate! p first-only)))
                 (list (car r) (caddr r)))))))

;;; Migration 2: accounts and api_keys

(define (bv n fill) (make-bytevector n fill))
(define id-a (bv 16 1))
(define id-b (bv 16 2))

;; refused-kind : Database String Any ... -> Symbol
;; 'constraint when SQLite refuses the statement's constraint, 'ok when it
;; runs, and 'other for any other raise.
(define (refused-kind db sql . params)
  (guard (e ((sqlite-constraint? e) 'constraint) (#t 'other))
    (apply execute! db sql params)
    'ok))

(define insert-account-sql
  "INSERT INTO accounts(id, username, email, password_hash, created) VALUES (?, ?, ?, 'h', 1)")
(define insert-key-sql
  "INSERT INTO api_keys(id, account, name, key_hash, created) VALUES (?, ?, 'k', ?, 1)")

(let ((p (path "m-accounts.db")))
  (clean! p)
  (migrate! p migrations)
  (test-equal "migration 2: both tables and the index exist"
    '(("accounts" "table") ("api_keys" "table") ("api_keys_account" "index"))
    (attempt
     (lambda ()
       (with-db (plain p)
         (lambda (db)
           (rows db "select name, type from sqlite_schema where name in ('accounts', 'api_keys', 'api_keys_account') order by name"))))))
  (test-equal "migration 2: a non-lowercase email is refused, a lowercase one is not"
    '(constraint ok)
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db)
           (list (refused-kind db insert-account-sql id-a "a" "A@Example.com")
                 (refused-kind db insert-account-sql id-a "a" "a@example.com")))))))
  ;; The rule is ASCII's alone, by GLOB's range, which no SQLite build folds
  ;; differently: lower() folds more under ICU, and a CHECK made of it
  ;; would then refuse what (techo accounts) hands it.
  (test-equal "migration 2: the email rule is ASCII's: a capital outside it is kept"
    'ok
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db)
           (refused-kind db insert-account-sql (bv 16 7) "nonascii"
                         (string (integer->char #xC9) #\@ #\x)))))))
  (test-equal "migration 2: a username with a capital, a space, nothing or 33 characters is refused; 32 good ones are not"
    '(constraint constraint constraint constraint ok)
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db)
           (let* ((r1 (refused-kind db insert-account-sql (bv 16 8) "Ada" "u1@x"))
                  (r2 (refused-kind db insert-account-sql (bv 16 8) "a b" "u2@x"))
                  (r3 (refused-kind db insert-account-sql (bv 16 8) "" "u3@x"))
                  (r4 (refused-kind db insert-account-sql (bv 16 8) (make-string 33 #\a) "u4@x"))
                  (r5 (refused-kind db insert-account-sql (bv 16 8)
                                    (string-append "a-b_9" (make-string 27 #\z)) "u5@x")))
             (list r1 r2 r3 r4 r5)))))))
  (test-equal "migration 2: a key's name of nothing or 65 characters is refused; 64 are not"
    '(constraint constraint ok)
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db)
           (let* ((sql "INSERT INTO api_keys(id, account, name, key_hash, created) VALUES (?, ?, ?, ?, 1)")
                  (r1 (refused-kind db sql (bv 16 31) (bv 16 8) "" (bv 32 31)))
                  (r2 (refused-kind db sql (bv 16 32) (bv 16 8) (make-string 65 #\n) (bv 32 32)))
                  (r3 (refused-kind db sql (bv 16 33) (bv 16 8) (make-string 64 #\n) (bv 32 33))))
             (list r1 r2 r3)))))))
  (test-equal "migration 2: an account id that is not 16 bytes is refused"
    'constraint
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db) (refused-kind db insert-account-sql (bv 15 9) "z" "z@example.com"))))))
  (test-equal "migration 2: a key naming a missing account is refused; naming a real one is not"
    '(constraint ok)
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db)
           (list (refused-kind db insert-key-sql (bv 16 5) id-b (bv 32 7))
                 (refused-kind db insert-key-sql (bv 16 5) id-a (bv 32 7))))))))
  (test-equal "migration 2: a key hash that is not 32 bytes, and a key id that is not 16, are refused"
    '(constraint constraint)
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db)
           (list (refused-kind db insert-key-sql (bv 16 6) id-a (bv 31 8))
                 (refused-kind db insert-key-sql (bv 17 6) id-a (bv 32 8))))))))
  (test-equal "migration 2: two keys with one hash are refused"
    'constraint
    (attempt
     (lambda ()
       (with-db (open-techo-db p 'read-write 0)
         (lambda (db) (refused-kind db insert-key-sql (bv 16 9) id-a (bv 32 7))))))))

;;; migration 4

(let ((p (path "m-v3.db")))
  (clean! p)
  (test-equal "migration 4: a file at version 3 holding nodes with snapshots migrates to 4; every node is active and still reads its body"
    (list '(applied (4 5) #f 5)
          '((1 "active" "first v2") (2 "active" "second v1"))
          '(constraint ok))
    (attempt
     (lambda ()
       (migrate! p (list (car migrations) (cadr migrations) (caddr migrations)))
       (with-db (plain p)
         (lambda (db)
           (execute! db "PRAGMA foreign_keys = off")
           (execute! db "INSERT INTO accounts(id, username, email, password_hash, created) VALUES (x'01010101010101010101010101010101', 'a', 'a@x', 'h', 1)")
           (for-each
            (lambda (sql) (execute! db sql))
            (list
             "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated) VALUES (x'0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a', x'01010101010101010101010101010101', x'01010101010101010101010101010101', 'note', 't1', 'text/plain', '{}', 2, 1, 2)"
             "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated) VALUES (x'0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b', x'01010101010101010101010101010101', x'01010101010101010101010101010101', 'task', 't2', 'text/plain', '{}', 1, 1, 1)"
             "INSERT INTO revisions(node, revision, author, title, content_type, props, created, body) VALUES (x'0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a', 1, x'01010101010101010101010101010101', 't1', 'text/plain', '{}', 1, 'first v1')"
             "INSERT INTO revisions(node, revision, author, title, content_type, props, created, body) VALUES (x'0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a', 2, x'01010101010101010101010101010101', 't1', 'text/plain', '{}', 2, 'first v2')"
             "INSERT INTO revisions(node, revision, author, title, content_type, props, created, body) VALUES (x'0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b', 1, x'01010101010101010101010101010101', 't2', 'text/plain', '{}', 1, 'second v1')"))))
       (let* ((r (migrate! p migrations))
              (got (with-db (open-techo-db p 'read-only)
                     (lambda (db)
                       (rows db "SELECT n.num, n.state, r.body FROM nodes n JOIN revisions r ON r.node = n.id AND r.revision = n.revision ORDER BY n.num"))))
              (bad (with-db (open-techo-db p 'read-write 0)
                     (lambda (db)
                       (list (refused-kind db "UPDATE nodes SET state = 'gone' WHERE num = 1")
                             (refused-kind db "UPDATE nodes SET state = 'trashed' WHERE num = 1"))))))
         (list (list (car r) (cadr r) (caddr r) (cadddr r)) got bad))))))

;;; migration 5

(let ((p (path "m-v4.db")))
  (clean! p)
  (test-equal "migration 5: a file at version 4 holding nodes with snapshots migrates to 5; every parent is NULL and every node still reads its body"
    (list '(applied (5) #f 5)
          '((1 1 "first v2") (2 1 "second v1"))
          '(constraint constraint ok))
    (attempt
     (lambda ()
       (migrate! p (list (car migrations) (cadr migrations) (caddr migrations) (cadddr migrations)))
       (with-db (plain p)
         (lambda (db)
           (execute! db "PRAGMA foreign_keys = off")
           (execute! db "INSERT INTO accounts(id, username, email, password_hash, created) VALUES (x'01010101010101010101010101010101', 'a', 'a@x', 'h', 1)")
           (for-each
            (lambda (sql) (execute! db sql))
            (list
             "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated) VALUES (x'0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a', x'01010101010101010101010101010101', x'01010101010101010101010101010101', 'note', 't1', 'text/plain', '{}', 2, 1, 2)"
             "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated) VALUES (x'0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b', x'01010101010101010101010101010101', x'01010101010101010101010101010101', 'task', 't2', 'text/plain', '{}', 1, 1, 1)"
             "INSERT INTO revisions(node, revision, author, title, content_type, props, created, body) VALUES (x'0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a', 1, x'01010101010101010101010101010101', 't1', 'text/plain', '{}', 1, 'first v1')"
             "INSERT INTO revisions(node, revision, author, title, content_type, props, created, body) VALUES (x'0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a', 2, x'01010101010101010101010101010101', 't1', 'text/plain', '{}', 2, 'first v2')"
             "INSERT INTO revisions(node, revision, author, title, content_type, props, created, body) VALUES (x'0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b', 1, x'01010101010101010101010101010101', 't2', 'text/plain', '{}', 1, 'second v1')"))))
       (let* ((r (migrate! p migrations))
              (got (with-db (open-techo-db p 'read-only)
                     (lambda (db)
                       (rows db "SELECT n.num, n.parent IS NULL, r.body FROM nodes n JOIN revisions r ON r.node = n.id AND r.revision = n.revision ORDER BY n.num"))))
              (bad (with-db (open-techo-db p 'read-write 0)
                     (lambda (db)
                       (list (refused-kind db "UPDATE nodes SET parent = x'0101' WHERE num = 1")
                             (refused-kind db "UPDATE nodes SET parent = x'0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c' WHERE num = 1")
                             (refused-kind db "UPDATE nodes SET parent = x'0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b' WHERE num = 1"))))))
         (list (list (car r) (cadr r) (caddr r) (cadddr r)) got bad))))))

;;; wal-size-limit

(let ((p (path "m-jsl.db")))
  (clean! p)
  (migrate! p migrations)
  (test-equal "wal-size-limit: 16 MiB"
    16777216 wal-size-limit)
  (test-equal "wal-size-limit: read-write and migrate connections have journal_size_limit set; a read-only one has not"
    (list wal-size-limit wal-size-limit -1)
    (attempt
     (lambda ()
       (let ((get (lambda (mode)
                    (with-db (open-techo-db p mode)
                      (lambda (db) (vector-ref (query-row db "PRAGMA journal_size_limit") 0))))))
         (list (get 'read-write) (get 'migrate) (get 'read-only))))))
  ;; A purge is "gone for good" only if freed pages are written as zeros.
  ;; This SQLite is built that way; open-techo-db says so itself, so a build
  ;; that is not still does it.
  (test-equal "secure_delete: on for the connections that write"
    (list 1 1)
    (attempt
     (lambda ()
       (let ((get (lambda (mode)
                    (with-db (open-techo-db p mode)
                      (lambda (db) (vector-ref (query-row db "PRAGMA secure_delete") 0))))))
         (list (get 'read-write) (get 'migrate)))))))

(test-end "db")

(exit (suite-exit-status runner))
