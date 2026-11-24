#!r6rs
;;; (techo doorway): the imperative shell of slice 2b's database doorway.
;;; It carries out the commands of (techo transaction)'s pure step function,
;;; one SQLite call for each, and feeds each outcome back: a job is one
;;; transaction, begun and ended by the table, never by the job. Nothing here
;;; decides what to do next (ADR-0007, ADR-0013). The plan is
;;; .plans/2026-11-23-slice-2b-doorway.md.
;;;
;;; A job gets a handle (Tx), never the connection (D11).
;;;
;;; A thread's connection sits in a BOX that belongs to that thread: a
;;; (Boxof (U Database #f)), made by `doorway-set-up`, emptied by a `(close)`
;;; command and by `doorway-tear-down`. Boxes are Chez's (portable R6RS has
;;; none).
;;;
;;; Every connection is made by `open-techo-db`, where the settings live.
(library (techo doorway)
  (export tx-execute! tx-query tx-query-row
          make-doorway doorway-open-writer! doorway-open-readers!
          doorway-stop-readers! doorway-stop-writer!
          make-test-doorway doorway-set-up doorway-tear-down
          db-write db-read
          &db-unavailable db-unavailable? db-unavailable-reason
          db-unavailable-expected db-unavailable-found
          &db-refused db-refused? db-refused-line
          &db-transaction-ended db-transaction-ended?
          db-retry-after wrap-db
          make-job-shell job-perform! run-job!)
  (import (rnrs)
          (only (chezscheme) box unbox set-box!)
          (chez-sqlite3)
          (circuit response)
          (circuit worker)
          (techo db)
          (techo migrations)
          (techo transaction))

  ;;; Conditions

  ;; &db-unavailable : reason expected found
  ;; reason is busy, moved or unavailable; for moved, expected is this
  ;; binary's latest version and found the file's. Otherwise both are #f.
  (define-condition-type &db-unavailable &error
    %make-db-unavailable db-unavailable?
    (reason db-unavailable-reason)
    (expected db-unavailable-expected)
    (found db-unavailable-found))

  ;; &db-refused : line
  ;; A thread's set-up refused the file; line is the check's own line.
  (define-condition-type &db-refused &error
    %make-db-refused db-refused?
    (line db-refused-line))

  ;; &db-transaction-ended : no fields
  ;; A job ended its own transaction, or kept going after SQLite ended it.
  (define-condition-type &db-transaction-ended &error
    %make-db-transaction-ended db-transaction-ended?)

  ;; db-unavailable?, db-refused?, db-transaction-ended? : Any -> Boolean
  ;; db-unavailable-reason : &db-unavailable -> (U 'busy 'moved 'unavailable)
  ;; db-unavailable-expected, db-unavailable-found : &db-unavailable -> (U Natural #f)
  ;; db-refused-line : &db-refused -> String

  (define (make-db-unavailable reason expected found)
    (condition (%make-db-unavailable reason expected found)
               (make-message-condition
                (string-append "the database is unavailable: "
                               (symbol->string reason)))))

  (define (make-db-refused line)
    (condition (%make-db-refused line) (make-message-condition line)))

  (define (make-db-transaction-ended)
    (condition (%make-db-transaction-ended)
               (make-message-condition
                "the job's transaction has ended: a job never ends its own")))

  ;; db-retry-after : Natural
  ;; Seconds, for a 503's Retry-After.
  (define db-retry-after 5)

  ;;; The handle

  ;; Tx : the connection, and a state: live, ended (SQLite ended the
  ;; transaction under a call) or killed (the job is over).
  (define-record-type (tx %make-tx tx?)
    (fields db (mutable state)))

  ;; A call's failure, as its raise is held until the handle has looked.
  (define-record-type failure (fields e))

  ;; tx-call : Tx Symbol Any (Database -> Any) -> Any
  ;; Before: a dead handle, and SQL a migration may not use, are refused and
  ;; nothing runs. Then the call, and on EVERY way out of it, a raise too, a
  ;; look at in-transaction?: a transaction that ended kills the handle. A
  ;; call that raised raises its own object again; one that returned raises
  ;; &db-transaction-ended.
  (define (tx-call tx who sql proc)
    (case (tx-state tx)
      ((killed)
       (assertion-violation who "the handle is dead: its job has ended"))
      ((ended) (raise (make-db-transaction-ended))))
    (unless (string? sql)
      (assertion-violation who "the SQL is a string" sql))
    (when (forbidden-statement? sql)
      (assertion-violation who
        "a job may not run a statement that begins with BEGIN, COMMIT, END, ROLLBACK, SAVEPOINT, RELEASE, ATTACH, DETACH, VACUUM, PRAGMA or EXPLAIN"
        sql))
    (let* ((db (tx-db tx))
           (r (guard (e (#t (make-failure e)))
                (call-with-values (lambda () (proc db)) list)))
           (open? (guard (e2 (#t #f)) (in-transaction? db))))
      (unless open?
        (when (eq? (tx-state tx) 'live) (tx-state-set! tx 'ended)))
      (cond ((failure? r) (raise (failure-e r)))
            (open? (apply values r))
            (else (raise (make-db-transaction-ended))))))

  ;; tx-execute! : Tx String Any ... -> Void
  (define (tx-execute! tx sql . params)
    (tx-call tx 'tx-execute! sql
             (lambda (db) (apply execute! db sql params) (if #f #f))))

  ;; tx-query : Tx String Any ... -> (Listof (Vectorof Any))
  (define (tx-query tx sql . params)
    (tx-call tx 'tx-query sql (lambda (db) (apply query db sql params))))

  ;; tx-query-row : Tx String Any ... -> (U (Vectorof Any) #f)
  (define (tx-query-row tx sql . params)
    (tx-call tx 'tx-query-row sql (lambda (db) (apply query-row db sql params))))

  ;;; The job shell

  ;; JobShell : the thread's box. Made per job, inside the worker's job.
  (define-record-type (job-shell make-job-shell job-shell?)
    (fields box))

  ;; make-job-shell : (Boxof (U Database #f)) -> JobShell

  ;; open-after : Database -> Boolean
  ;; in-transaction?, #f when that call itself raises.
  (define (open-after db) (guard (e (#t #f)) (in-transaction? db)))

  ;; A job's result, as the catch packs it.
  (define-record-type raised (fields e))

  ;; caught : (-> Any) -> (U (Listof Any) Raised)
  ;; THUNK's values as a list, or its raise as a Raised: two nested handlers,
  ;; each escaping by the continuation for anything but a warning, which each
  ;; passes on continuably, as circuit's worker does for a job. A warning is
  ;; no answer of the job's.
  (define (caught thunk)
    (call/cc
     (lambda (k)
       (let ((pass (lambda (e)
                     (if (warning? e)
                         (raise-continuable e)
                         (k (make-raised e))))))
         (with-exception-handler
          pass
          (lambda ()
            (with-exception-handler
             pass
             (lambda () (call-with-values thunk list)))))))))

  ;; sql-outcome : Database String -> RawOutcome
  ;; One statement through execute!: (ok #t open?), (busy obj open?) or
  ;; (failed obj open?), obj the object raised.
  (define (sql-outcome db sql)
    (guard (e ((sqlite-busy? e) (list 'busy e (open-after db)))
              (#t (list 'failed e (open-after db))))
      (execute! db sql)
      (list 'ok #t (open-after db))))

  ;; version-outcome : Database -> RawOutcome
  (define (version-outcome db)
    (guard (e ((sqlite-busy? e) (list 'busy e (open-after db)))
              (#t (list 'failed e (open-after db))))
      (let ((v (vector-ref (query-row db "PRAGMA user_version") 0)))
        (list 'ok v (open-after db)))))

  ;; job-perform! : JobShell Command (Tx -> Any) -> RawOutcome
  ;; Exactly one thing for the command, and no decision (see (techo
  ;; transaction) for the shapes). (end . _) is an assertion violation, as is
  ;; a command that needs a connection when the box is empty.
  (define (job-perform! sh command job)
    (let* ((b (job-shell-box sh))
           (db (unbox b)))
      (define (need-db)
        (unless db
          (assertion-violation 'job-perform! "no connection: the box is empty"
                               command))
        db)
      (unless (pair? command)
        (assertion-violation 'job-perform! "not a command" command))
      (case (car command)
        ((look) (list (if db 'present 'absent) #f #f))
        ((begin-immediate) (sql-outcome (need-db) "BEGIN IMMEDIATE"))
        ((begin) (sql-outcome (need-db) "BEGIN"))
        ((read-version) (version-outcome (need-db)))
        ((commit) (sql-outcome (need-db) "COMMIT"))
        ((rollback) (sql-outcome (need-db) "ROLLBACK"))
        ((run-job)
         (let* ((db (need-db))
                (h (%make-tx db 'live))
                (r (dynamic-wind
                     (lambda () #f)
                     (lambda () (caught (lambda () (job h))))
                     (lambda () (tx-state-set! h 'killed)))))
           (if (raised? r)
               (list 'raised (raised-e r) (open-after db))
               (list 'returned r (open-after db)))))
        ((close)
         (set-box! b #f)
         (if db
             (guard (e (#t (list 'failed e #f)))
               (close-database! db)
               (list 'ok #t #f))
             (list 'ok #t #f)))
        ((end) (assertion-violation 'job-perform! "`end` is never performed"
                                    command))
        (else (assertion-violation 'job-perform! "not a command" command)))))

  ;; run-job! : (State Event -> (values State Command)) State JobShell (Tx -> Any)
  ;;            [(Command RawOutcome -> Void)] -> Any
  ;; The loop: perform the command, tell the observer, carry, sort the event,
  ;; step; until (end . Ending). The first command is (look), as every job
  ;; machine's start gives. At the end: (answer) returns what the job
  ;; returned, as its values; (raise-carried) raises the first object carried
  ;; (when none was carried, a condition of this shell's, naming the command
  ;; that said ok and left the transaction wrongly); (raise-ended) raises
  ;; &db-transaction-ended; (refuse . kind) raises &db-unavailable.
  ;; If the step function, the event sorting or the observer raises, or the
  ;; loop is left by a continuation, a (rollback) is performed under a guard
  ;; on the way out, so a bug never leaves the writer idle holding the lock.
  (define run-job!
    (case-lambda
      ((step state sh job) (run-job! step state sh job #f))
      ((step state sh job observer)
       (let ((finished? #f))
         (dynamic-wind
           (lambda () #f)
           (lambda ()
             (let loop ((state state) (command (list 'look))
                        (carry empty-carry) (expected #f) (odd #f))
               (if (eq? (car command) 'end)
                   (begin
                     (check-ending (cdr command) carry)
                     (set! finished? #t)
                     (finish (cdr command) carry expected odd))
                   (let ((raw (job-perform! sh command job)))
                     (when observer (observer command raw))
                     (let* ((carry (job-carry carry command raw))
                            (kind (job-event-kind command raw))
                            (expected (if (eq? (car command) 'read-version)
                                          (cdr command)
                                          expected))
                            (odd (or odd
                                     (and (eq? (car raw) 'ok)
                                          (memq kind '(failed-open failed-closed))
                                          command))))
                       (let-values (((state command)
                                     (step state (cons kind raw))))
                         (loop state command carry expected odd)))))))
           (lambda ()
             (unless finished?
               (guard (e (#t #f))
                 (job-perform! sh (list 'rollback) job)))))))))

  ;; check-ending : Ending Carry -> Void
  ;; A table that ends with `answer` when the job returned nothing is a bug,
  ;; and the loop's net is still to roll back.
  (define (check-ending ending carry)
    (when (and (equal? ending '(answer)) (not (carry-values carry)))
      (assertion-violation 'run-job! "the job's values were not carried")))

  ;; finish : Ending Carry (U Natural #f) (U Command #f) -> Any
  (define (finish ending carry expected odd)
    (case (car ending)
      ((answer)
       (let ((vs (carry-values carry)))
         (unless vs
           (assertion-violation 'run-job! "the job's values were not carried"))
         (apply values vs)))
      ((raise-carried)
       (let ((r (carry-raised carry)))
         (if r
             (raise (car r))
             (raise (condition
                     (make-assertion-violation)
                     (make-who-condition 'run-job!)
                     (make-message-condition
                      "a command said ok and left the transaction in the wrong state")
                     (make-irritants-condition (list odd)))))))
      ((raise-ended) (raise (make-db-transaction-ended)))
      ((refuse)
       (let ((kind (cdr ending)))
         (raise (if (eq? kind 'moved)
                    (make-db-unavailable kind expected (carry-version carry))
                    (make-db-unavailable kind #f #f)))))
      (else (assertion-violation 'run-job! "not an ending" ending))))

  ;;; A thread's set-up and tear-down

  ;; doorway-set-up : String Symbol (Listof Migration) [Natural]
  ;;                  -> (Boxof (U Database #f))
  ;; MODE is 'read-write or 'read-only. Opens the connection, reads the file's
  ;; four facts, and raises &db-refused (after closing the connection) unless
  ;; the file is current and in WAL. Any other raise closes it too.
  (define doorway-set-up
    (case-lambda
      ((path mode ms) (doorway-set-up path mode ms busy-timeout-ms))
      ((path mode ms busy-ms)
       (let* ((db (open-techo-db path mode busy-ms))
              (verdict (guard (e (#t (guard (e2 (#t #f)) (close-database! db))
                                     (raise e)))
                         (set-up-verdict (read-db-facts db) ms))))
         (define (refuse! line)
           (guard (e (#t #f)) (close-database! db))
           (raise (make-db-refused line)))
         (cond ((not (eq? verdict 'serve)) (refuse! (caddr verdict)))
               ((eq? mode 'read-write)
                (let ((problem (write-problem db)))
                  (if problem (refuse! problem) (box db))))
               (else (box db)))))))

  ;; write-problem : Database -> (U String #f)
  ;; Why this connection cannot write, or #f when it can. SQLite's read-write
  ;; open of a file the process may only read falls back to read-only without
  ;; a word (probed), and BEGIN IMMEDIATE succeeds on such a connection. So
  ;; this writes the version the file already has, inside a transaction it
  ;; rolls back. Any other raise is raised, the connection closed first.
  (define (write-problem db)
    (guard (e ((sqlite-read-only? e)
               (guard (e2 (#t #f)) (execute! db "ROLLBACK"))
               "cannot write the database file: check its permissions")
              ((sqlite-busy? e)
               (guard (e2 (#t #f)) (execute! db "ROLLBACK"))
               "the database is busy: another program holds it")
              (#t (guard (e2 (#t #f)) (close-database! db))
                  (raise e)))
      (execute! db "BEGIN IMMEDIATE")
      (let ((v (vector-ref (query-row db "PRAGMA user_version") 0)))
        (execute! db (string-append "PRAGMA user_version = " (number->string v))))
      (execute! db "ROLLBACK")
      #f))

  ;; doorway-tear-down : (Boxof (U Database #f)) -> Void
  ;; Closes the connection if the box holds one; on an empty box, nothing.
  (define (doorway-tear-down b)
    (let ((db (unbox b)))
      (when db
        (set-box! b #f)
        (close-database! db))))

  ;;; The doorway

  (define-record-type (doorway %make-doorway doorway?)
    (fields path readers migrations write-cap read-cap busy-ms
            (mutable writer) (mutable reader)))

  ;; make-doorway : String Natural (Listof Migration) [Natural Natural] -> Doorway
  ;; PATH, the read threads, the migrations, and optionally the write and read
  ;; caps (64 each). No thread yet.
  (define make-doorway
    (case-lambda
      ((path readers ms) (make-doorway path readers ms 64 64))
      ((path readers ms wcap rcap)
       (%make-doorway path readers ms wcap rcap busy-timeout-ms #f #f))))

  ;; doorway-open-writer!, doorway-open-readers! : Doorway -> Void
  ;; Each makes its worker. Raises &db-refused, with the line, when a set-up
  ;; refuses the file.
  (define (doorway-open-writer! d)
    (doorway-writer-set! d
      (make-worker (writer-set-up d) (doorway-write-cap d) 1 doorway-tear-down)))

  (define (doorway-open-readers! d)
    (doorway-reader-set! d
      (make-worker (reader-set-up d) (doorway-read-cap d) (doorway-readers d)
                   doorway-tear-down)))

  ;; writer-set-up, reader-set-up : Doorway -> (-> (Boxof (U Database #f)))
  ;; A thread's set-up thunk. The real workers and the doubles both take
  ;; theirs from here, so a test on the doubles holds the real ones' modes.
  (define (writer-set-up d)
    (lambda ()
      (doorway-set-up (doorway-path d) 'read-write (doorway-migrations d)
                      (doorway-busy-ms d))))

  (define (reader-set-up d)
    (lambda ()
      (doorway-set-up (doorway-path d) 'read-only (doorway-migrations d)
                      (doorway-busy-ms d))))

  ;; doorway-stop-readers!, doorway-stop-writer! : Doorway -> Void
  ;; Stops the worker if it was made; a worker not made is nothing to stop.
  (define (doorway-stop-readers! d)
    (let ((w (doorway-reader d)))
      (when w (doorway-reader-set! d #f) (worker-stop! w))))

  (define (doorway-stop-writer! d)
    (let ((w (doorway-writer d)))
      (when w (doorway-writer-set! d #f) (worker-stop! w))))

  ;; make-test-doorway : String (Listof Migration) [Natural] -> Doorway
  ;; On circuit's doubles: one write thread and one read thread, no queue,
  ;; each call waiting for its answer. The optional argument is the busy
  ;; timeout in ms. The doubles are made now; stop them with the two stops.
  (define make-test-doorway
    (case-lambda
      ((path ms) (make-test-doorway path ms busy-timeout-ms))
      ((path ms busy-ms)
       (let ((d (%make-doorway path 1 ms 0 0 busy-ms #f #f)))
         (doorway-writer-set! d
           (make-test-worker (writer-set-up d) doorway-tear-down))
         (guard (e (#t (doorway-stop-writer! d) (raise e)))
           (doorway-reader-set! d
             (make-test-worker (reader-set-up d) doorway-tear-down)))
         d))))

  ;; db-write, db-read : Doorway (Tx -> Any) -> Any
  ;; In a handler; one write (read) transaction, run by the table. The job's
  ;; values come back, its raise is raised here as it was.
  (define (db-write d job)
    (let ((latest (latest-version (doorway-migrations d))))
      (worker-call (doorway-writer d)
        (lambda (b)
          (let-values (((state command) (write-start latest)))
            (run-job! write-step state (make-job-shell b) job))))))

  (define (db-read d job)
    (let ((latest (latest-version (doorway-migrations d))))
      (worker-call (doorway-reader d)
        (lambda (b)
          (let-values (((state command) (read-start latest)))
            (run-job! read-step state (make-job-shell b) job))))))

  ;;; wrap-db

  (define moved-line
    (lambda (found expected)
      (string-append
       "database moved: the file is at version " (number->string found)
       " and this server expects " (number->string expected)
       "; a newer techo migrate ran beside it; database requests get 503 until the newer techo serves")))

  (define unavailable-line
    "database unavailable: a connection was closed after a failed rollback; database requests can get 503 until techo is restarted")

  ;; wrap-db : (String -> Void) -> Middleware
  ;; Answers &db-unavailable with an empty 503 and Retry-After 5. Logs the
  ;; first "moved" and the first "unavailable" it sees, each once for the
  ;; middleware's life, by one call of LOG with the line (no newline). Built as
  ;; circuit's wrap-busy is: call/cc around with-exception-handler, anything
  ;; else passed on by raise-continuable, so a deadline or a closed client
  ;; goes by.
  (define (wrap-db log)
    (unless (procedure? log)
      (assertion-violation 'wrap-db "the log is a procedure of a string" log))
    (let ((headers (list (cons "retry-after" (number->string db-retry-after))))
          (moved-logged? #f)
          (unavailable-logged? #f))
      (define (note! e)
        (case (db-unavailable-reason e)
          ((moved)
           (unless moved-logged?
             (set! moved-logged? #t)
             (log (moved-line (db-unavailable-found e)
                              (db-unavailable-expected e)))))
          ((unavailable)
           (unless unavailable-logged?
             (set! unavailable-logged? #t)
             (log unavailable-line)))))
      (lambda (handler)
        (unless (procedure? handler)
          (assertion-violation 'wrap-db "a handler is a procedure" handler))
        (lambda (req)
          (call/cc
           (lambda (k)
             (with-exception-handler
              (lambda (e)
                (if (db-unavailable? e)
                    (begin (note! e) (k (make-res 503 headers #f)))
                    (raise-continuable e)))
              (lambda () (handler req)))))))))
)
