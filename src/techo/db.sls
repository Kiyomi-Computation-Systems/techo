#!r6rs
;;; (techo db): the imperative shell of `techo migrate` and `techo serve`'s
;;; check. It carries out the machines' commands on real SQLite, one SQLite
;;; call for each, and feeds each outcome back to the pure step function in
;;; (techo migrations). Nothing here decides what to do next (ADR-0007,
;;; ADR-0012).
;;;
;;; What chez-sqlite3's `execute!` does with SQL that is not one statement
;;; (probed, v0.1.1): two statements raise an assertion violation
;;; (more-than-one-statement, with the offset), and SQL with no statement,
;;; "" or only a comment, raises one too (no-statement). Nothing runs in
;;; either case. `perform!` turns the violation into a `failed` outcome.
;;;
;;; The connection belongs to the thread that made the shell (chez-sqlite3,
;;; ADR-0010); a shell is made and used in one thread.
(library (techo db)
  (export busy-timeout-ms wal-size-limit open-techo-db read-db-facts
          make-shell shell-database perform!
          migrate! check-db)
  (import (rnrs)
          (only (chezscheme) display-condition sleep make-time)
          (chez-sqlite3)
          (techo migrations))

  ;; busy-timeout-ms : Natural
  ;; How long a connection waits for another's lock before it is told busy.
  (define busy-timeout-ms 5000)

  ;; wal-size-limit : Natural
  ;; The most bytes the write-ahead log keeps after a checkpoint: SQLite
  ;; truncates a bigger one to this (PRAGMA journal_size_limit). A purge of a
  ;; node with much history writes much through the log; this brings the
  ;; file back. 16 MiB, a few of the largest writes.
  (define wal-size-limit 16777216)

  ;; open-techo-db : (case-> (String Symbol -> Database)
  ;;                         (String Symbol Natural -> Database))
  ;; MODE is 'read-write, 'read-only or 'migrate; the optional third argument
  ;; is the busy timeout in ms. Sets the busy timeout, synchronous full and
  ;; foreign keys: on, but off for 'migrate (ADR-0012). On a connection that
  ;; writes ('read-write, 'migrate) it also sets journal_size_limit to
  ;; wal-size-limit, and secure_delete on: a freed page is written as zeros,
  ;; which is what makes a purge final in the file, whatever the SQLite's
  ;; build says. Sets no journal mode.
  ;; 'read-only never creates the file; 'migrate creates it; 'read-write
  ;; does not.
  (define open-techo-db
    (case-lambda
      ((path mode) (open-techo-db path mode busy-timeout-ms))
      ((path mode timeout-ms)
       (let ((flag (case mode
                     ((read-only) 'read-only)
                     ((read-write) 'read-write)
                     ((migrate) 'create)
                     (else (assertion-violation 'open-techo-db
                                                "not a mode" mode)))))
         (let ((db (open-database path flag
                                  (list (cons 'busy-timeout timeout-ms)
                                        (cons 'synchronous 'full)
                                        (cons 'foreign-keys (not (eq? mode 'migrate)))))))
           (unless (eq? mode 'read-only)
             (guard (e (#t (close-database! db) (raise e)))
               (execute! db "PRAGMA secure_delete = ON")
               (execute! db (string-append "PRAGMA journal_size_limit = "
                                           (number->string wal-size-limit)))))
           db)))))

  ;; read-db-facts : Database -> DbFacts
  ;; DbFacts is (List Integer Integer Natural Symbol): application_id,
  ;; user_version, objects in the schema, journal mode. One statement.
  (define (read-db-facts db)
    (let ((row (query-row db facts-sql)))
      (unless (and row (= (vector-length row) 4))
        (assertion-violation 'read-db-facts "facts-sql answered no row" row))
      (list (vector-ref row 0) (vector-ref row 1) (vector-ref row 2)
            (string->symbol (string-downcase (vector-ref row 3))))))

  ;;; The shell

  ;; Shell : the path, the busy timeout, and the connection if one is open.
  (define-record-type (shell %make-shell shell?)
    (fields path timeout (mutable db))
    (protocol (lambda (new) (lambda (path timeout) (new path timeout #f)))))

  ;; make-shell : (case-> (String -> Shell) (String Natural -> Shell))
  ;; No connection yet.
  (define make-shell
    (case-lambda
      ((path) (%make-shell path busy-timeout-ms))
      ((path timeout-ms) (%make-shell path timeout-ms))))

  ;; shell-database : Shell -> (U Database #f)
  (define (shell-database sh) (shell-db sh))

  ;; reason-of : Any -> String
  ;; SQLite's message for its own conditions, Chez's text for any other.
  ;; One case is named in Techo's words: a hot rollback journal, which a
  ;; read-only connection cannot roll back. SQLite's own text for it,
  ;; "attempt to write a readonly database", points at the permissions.
  (define (reason-of e)
    (if (sqlite-error? e)
        (if (eq? (sqlite-error-extended-code e) 'readonly-rollback)
            "an interrupted write is still in the database: open it once with `sqlite3`, then run `techo migrate` again"
            (sqlite-error-message e))
        (guard (e2 (#t "unknown failure"))
          (call-with-string-output-port
           (lambda (p) (if (condition? e) (display-condition e p) (write e p)))))))

  ;; in-txn? : Shell -> Boolean
  ;; Whether a transaction is open: #f with no connection.
  (define (in-txn? sh)
    (let ((db (shell-db sh)))
      (and db (guard (e (#t #f)) (in-transaction? db)))))

  ;; outcome : Shell Symbol Any -> RawOutcome
  (define (outcome sh status value) (list status value (in-txn? sh)))

  ;; attempt-call : Shell (-> Any) -> RawOutcome
  ;; Runs THUNK, the one SQLite call: ok with its value, busy, or failed.
  (define (attempt-call sh thunk)
    (guard (e ((sqlite-busy? e) (outcome sh 'busy (reason-of e)))
              (#t (outcome sh 'failed (reason-of e))))
      (let ((v (thunk))) (outcome sh 'ok v))))

  ;; open! : Shell String Symbol -> RawOutcome
  (define (open! sh path mode)
    (if (shell-db sh)
        (outcome sh 'failed "a connection is already open")
        (attempt-call sh
          (lambda ()
            (shell-db-set! sh (open-techo-db path mode (shell-timeout sh)))
            #t))))

  ;; on-db : Shell (Database -> Any) -> RawOutcome
  ;; attempt-call on the open connection; with none, failed.
  (define (on-db sh proc)
    (let ((db (shell-db sh)))
      (if db
          (attempt-call sh (lambda () (proc db)))
          (list 'failed "no connection is open" #f))))

  ;; close! : Shell -> RawOutcome
  ;; The connection is forgotten whether or not the close raises.
  (define (close! sh)
    (let ((db (shell-db sh)))
      (shell-db-set! sh #f)
      (if db
          (guard (e (#t (list 'failed (reason-of e) #f)))
            (close-database! db)
            (list 'ok #t #f))
          (list 'ok #t #f))))

  ;; pause! : Natural -> Void
  (define (pause! ms)
    (sleep (make-time 'time-duration (* 1000000 (mod ms 1000)) (div ms 1000))))

  ;; perform! : Shell Command -> RawOutcome
  ;; RawOutcome is (List (U 'ok 'busy 'missing 'failed) Any Boolean): the
  ;; status, a value (the facts, the violation rows, #t, or a reason string)
  ;; and whether a transaction is open after the call. One SQLite call. A
  ;; condition from it is an outcome, never a raise; the `end` command is not
  ;; for it, and neither is a command this does not know, nor a stamp that is not
  ;; an exact positive integer: those raise, as bugs. A command that needs a
  ;; connection when none is open, or an open when one is, is `failed`.
  (define (perform! sh command)
    (let ((kind (car command)) (arg (cdr command)))
      (case kind
        ((open-read-only)
         (if (file-exists? (shell-path sh))
             (open! sh (shell-path sh) 'read-only)
             (list 'missing "unable to open database file: no such file" #f)))
        ((open-read-write) (open! sh (shell-path sh) 'migrate))
        ((read-facts)
         (on-db sh read-db-facts))
        ((close) (close! sh))
        ((set-wal)
         (let ((o (on-db sh (lambda (db)
                              (query-row db "PRAGMA journal_mode = wal")))))
           (cond ((not (eq? (car o) 'ok)) o)
                 ((and (cadr o) (equal? (vector-ref (cadr o) 0) "wal"))
                  (list 'ok #t (caddr o)))
                 (else (list 'failed "the journal mode did not become wal"
                             (caddr o))))))
        ((pause) (pause! arg) (outcome sh 'ok #t))
        ((begin-immediate)
         (on-db sh (lambda (db) (execute! db "BEGIN IMMEDIATE") #t)))
        ((run-statement)
         (on-db sh (lambda (db) (execute! db arg) #t)))
        ((foreign-key-check)
         (on-db sh (lambda (db)
                     (map vector->list (query db "PRAGMA foreign_key_check")))))
        ((stamp)
         (unless (and (integer? arg) (exact? arg) (positive? arg))
           (assertion-violation 'perform! "stamp wants an exact positive integer"
                                arg))
         (on-db sh (lambda (db)
                     (execute! db (string-append "PRAGMA user_version = "
                                                 (number->string arg)))
                     #t)))
        ((commit) (on-db sh (lambda (db) (execute! db "COMMIT") #t)))
        ((rollback)
         (on-db sh (lambda (db) (execute! db "ROLLBACK") #t)))
        ((end) (assertion-violation 'perform! "`end` is never performed" command))
        (else (assertion-violation 'perform! "not a command" command)))))

  ;; drive : (-> (values State Command)) (State RawOutcome -> (values State Command))
  ;;         Shell (U #f (Command -> Void)) -> Any
  ;; The loop: observe, perform, step, until `end`, whose payload it returns.
  ;; Whatever connection is open on the way out is closed.
  (define (drive start step sh observer)
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let-values (((state command) (start)))
          (let loop ((state state) (command command))
            (if (eq? (car command) 'end)
                (cdr command)
                (begin
                  (when observer (observer command))
                  (let ((raw (perform! sh command)))
                    (let-values (((state command) (step state raw)))
                      (loop state command))))))))
      (lambda () (close! sh))))

  ;; migrate! : (case-> (String (Listof Migration) -> Result)
  ;;                    (String (Listof Migration) (Command -> Void) -> Result))
  ;; Runs `techo migrate` on PATH. The optional observer is called with each
  ;; command before it is performed (the `end` command excepted); only tests
  ;; pass one.
  (define migrate!
    (case-lambda
      ((path ms) (migrate! path ms #f))
      ((path ms observer)
       (drive run-start (lambda (state raw) (run-step ms state raw))
              (make-shell path) observer))))

  ;; check-db : String (Listof Migration) -> (U 'serve (List 'refuse Symbol String))
  ;; `techo serve`'s check: opens read-only, looks once, closes.
  (define (check-db path ms)
    (drive check-start (lambda (state raw) (check-step ms state raw))
           (make-shell path) #f))
)
