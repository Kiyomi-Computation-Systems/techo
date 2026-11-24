#!r6rs
;;; (transaction-replay-support): the machinery of layer 4 of the slice 2b
;;; plan, the replay of (transaction-model)'s traces on real SQLite through
;;; (techo doorway)'s job-perform!, the procedure the doorway's worker
;;; threads call. The suite, tests/test-transaction-replay.sps, holds the
;;; table of how each choice is made real, the configurations and the
;;; tests; this library holds what they run.
;;;
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path. It is the imperative side of the comparison: it opens files and
;;; calls SQLite, and (transaction-model) is the pure side it is held to.
;;;
;;; One replay
;;; ----------
;;; A replay copies a template file (techo's migrations applied: version 1,
;;; in WAL; and two tables of the replay's own, below) to a new path, and
;;; opens, all in this one thread, each with a busy timeout of 0:
;;;   writer   doorway-set-up's read-write box, as the write thread's;
;;;   reader   doorway-set-up's read-only box, as a read thread's;
;;;   other    a plain read-write connection: another process, which takes
;;;            the write lock with BEGIN IMMEDIATE, frees it with ROLLBACK,
;;;            and migrates by PRAGMA user_version and COMMIT under it.
;;; Each of the writer and the reader gets a temp table, trap, holding one
;;; row, so that INSERT OR ROLLBACK can end its transaction for real.
;;; Then it takes the trace's steps in order. At each step it
;;;   - applies the step to the model again (model-apply), for the model's
;;;     world after it, and holds the result equal to the trace's step;
;;;   - for a thread, starts the actor's next job when the model has
;;;     (a new JobShell on the same box, and the table's start),
;;;     and holds the command the REAL side's own stepping asks for (the
;;;     replay machine's step function, fed the REAL outcomes so far) to
;;;     the model step's command;
;;;   - makes the model's choice real when SQLite can give it: stages it,
;;;     then calls the options' exec (job-perform!) once; or injects it when
;;;     it cannot, calling no exec, and makes plain calls that bring the
;;;     connection's true state to the outcome reported (a real ROLLBACK
;;;     for a failure that ended the transaction, a real COMMIT for one
;;;     that took effect), counting it with its reason;
;;;   - compares the outcome with the model's: status, open?, the value of
;;;     a version read or of a job's return, the event kind job-event-kind
;;;     sorts each into, and the next state (the last two, and the command,
;;;     follow from the first three through the same pure functions, so
;;;     they are never the first difference: they guard the replay's own
;;;     bookkeeping of each actor's job); for (run-job), what the job's
;;;     body really read (the tokens and the version) with step-saw; for
;;;     the writer's BEGIN IMMEDIATE, whether the model offers busy with
;;;     whether the write lock is really held (the lock as the observer
;;;     found it after the step before);
;;;   - opens a fresh observer connection (read-write, timeout 0), reads
;;;     the tokens in commit order and user_version, probes the write lock
;;;     with BEGIN IMMEDIATE (busy: held; ok: rolled back at once), closes
;;;     it, and compares with step-file and the model's lock;
;;;   - compares each actor's connection (in the box, kept open by a failed
;;;     close, or none), every connection it saw closed being closed, and
;;;     its transaction flag (in-transaction? on every connection of its
;;;     still open), with the model's world after the step.
;;; The first difference is the verdict.
;;;
;;; The file
;;; --------
;;;   tokens (n INTEGER PRIMARY KEY, tok INTEGER NOT NULL)
;;;     one row per write a job makes: tok is the model's Token. n orders
;;;     them, and only the writer writes, so n's order is commit order.
;;;   dangle (id INTEGER PRIMARY KEY, up INTEGER REFERENCES dangle(id)
;;;           DEFERRABLE INITIALLY DEFERRED)
;;;     a row whose up is -1 dangles: a COMMIT with it in the transaction
;;;     is refused, the transaction left open (cl. 3).
;;;
;;; A job, from step-action (Tokens Ending Txn)
;;; -------------------------------------------
;;;   open    reads the tokens and the version (pragma_user_version: a job
;;;           may not run PRAGMA); writes each token; then
;;;           returns (values who job) or raises. A writer whose
;;;           transaction does not hold the lock (a plain BEGIN, a mutant
;;;           table) attempts its first write, which SQLite refuses.
;;;   ended   the same reads and writes; then INSERT OR ROLLBACK into
;;;           temp.trap, whose conflict makes SQLite roll the transaction
;;;           back and raise; then attempts the job's later writes (those
;;;           after the one that ended it), which the handle must refuse;
;;;           then returns, or raises what the trap raised.
;;;   none    no transaction (mutant tables only): no reads, since the
;;;           handle dies at its first call outside a transaction; each
;;;           write attempted, a failure swallowed; then returns or raises.
(library (transaction-replay-support)
  (export
   ;; machines
   make-replay-machine replay-machine-model real-replay-machine
   replay-table-machine
   ;; options
   make-replay-options default-replay-options shell-exec
   ;; the template
   make-template! remove-db-files!
   ;; traces
   trace-of-moves trace-by-chooser walk-trace choice-tag
   ;; the replay
   replay-trace report-verdict report-steps report-keys report-hows
   report-reasons report-offers
   ;; what the realization claims
   realization-claims)
  (import (rnrs)
          (only (chezscheme) box unbox set-box!)
          (chez-sqlite3)
          (techo-testing)
          (techo migrations)
          (techo db)
          (techo transaction)
          (techo doorway)
          (transaction-model))

  ;;; Helpers

  (define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))

  ;; attempt : (-> A) -> (U A (List 'raised String))
  (define (attempt thunk)
    (guard (e (#t (list 'raised (describe e))))
      (thunk)))
  (define (raised? x) (and (pair? x) (eq? (car x) 'raised)))

  ;; choice-tag : Choice -> Symbol
  ;; A choice as the counts key it: a job's (Kind . k) by its Kind.
  (define (choice-tag ch) (if (pair? ch) (car ch) ch))

  ;; txn? : Database -> Boolean     #f when the connection is closed
  (define (txn? db) (guard (e (#t #f)) (in-transaction? db)))
  ;; closed? : Database -> Boolean
  (define (closed? db) (guard (e ((sqlite-closed? e) #t) (#t #f)) (in-transaction? db) #f))

  (define io "disk I/O error")

  ;;; Machines

  ;; ReplayMachine is #(Machine wstart wstep wkind rstart rstep rkind): the
  ;; model's Machine and the procedures it was made from, which the real
  ;; side runs. (transaction-model) exports no accessors for a Machine's
  ;; procedures, so this keeps them.
  (define (wrap-machine m wstart wstep wkind rstart rstep rkind)
    (vector m wstart wstep wkind rstart rstep rkind))

  ;; make-replay-machine : Any (Natural -> (values State Command)) Stepper Kind
  ;;                       (Listof (List Symbol StateKind EventKind))
  ;;                       (Natural -> (values State Command)) Stepper Kind
  ;;                       (Listof (List Symbol StateKind EventKind)) -> ReplayMachine
  ;; As make-job-machine: the write machine's start, step, kind and row
  ;; names, then the read machine's.
  (define (make-replay-machine name wstart wstep wkind wnames rstart rstep rkind rnames)
    (wrap-machine (make-job-machine name wstart wstep wkind wnames rstart rstep rkind rnames)
                  wstart wstep wkind rstart rstep rkind))

  ;; replay-machine-model : ReplayMachine -> Machine
  (define (replay-machine-model rm) (vector-ref rm 0))
  (define (rm-start rm who) (vector-ref rm (if (eq? who 'writer) 1 4)))
  (define (rm-step rm who) (vector-ref rm (if (eq? who 'writer) 2 5)))
  (define (rm-kind rm who) (vector-ref rm (if (eq? who 'writer) 3 6)))

  ;; real-replay-machine : ReplayMachine
  ;; (techo transaction)'s own tables, around the model's real-machine.
  (define real-replay-machine
    (wrap-machine real-machine write-start write-step job-event-kind
                  read-start read-step job-event-kind))

  ;; replay-table-machine : Any (Listof NamedRow) (Listof NamedRow)
  ;;                        (State -> Command) (State -> Command) Kind Kind
  ;;                        -> ReplayMachine
  ;; As the model's table-machine: two named tables, each stepped by
  ;; make-model-job-stepper with its command function.
  (define (replay-table-machine name wtable rtable wcommand rcommand wkind rkind)
    (define (names t) (map (lambda (r) (list (car r) (cadr r) (caddr r))) t))
    (make-replay-machine name (model-job-start wcommand)
                         (make-model-job-stepper (map cdr wtable) wcommand) wkind
                         (names wtable)
                         (model-job-start rcommand)
                         (make-model-job-stepper (map cdr rtable) rcommand) rkind
                         (names rtable)))

  ;;; Options

  ;; ReplayOptions is #(Exec ShellCommand)
  ;;   exec           Who (Boxof (U Database #f)) JobShell Command (Tx -> Any)
  ;;                  -> RawOutcome: the one call for a command, given the
  ;;                  actor and its box too, so that a mutant of the shell
  ;;                  can be written around job-perform!
  ;;   shell-command  Who Command -> Command: the command the shell is handed
  ;;                  for the model's (the identity, but for a mutant that
  ;;                  makes the model believe one thing and the shell do
  ;;                  another)

  ;; make-replay-options : Exec (Who Command -> Command) -> ReplayOptions
  (define (make-replay-options exec shell-command) (vector exec shell-command))
  (define (options-exec o) (vector-ref o 0))
  (define (options-shell-command o) (vector-ref o 1))

  ;; shell-exec : Exec     job-perform!, the actor and the box unused
  (define (shell-exec who b sh cmd job) (job-perform! sh cmd job))

  ;; default-replay-options : ReplayOptions
  (define default-replay-options
    (make-replay-options shell-exec (lambda (who cmd) cmd)))

  ;;; The template file

  ;; remove-db-files! : String -> Void     the file, its -wal and its -shm
  (define (remove-db-files! path)
    (for-each (lambda (s)
                (let ((p (string-append path s)))
                  (when (file-exists? p) (delete-file p))))
              '("" "-wal" "-shm")))

  ;; make-template! : String -> Void
  ;; At PATH: techo's shipped migrations applied (version 1, in WAL), then
  ;; the replay's two tables, made by a plain connection and closed cleanly,
  ;; so that no -wal is left and the file can be copied. Raises if one is.
  (define (make-template! path)
    (remove-db-files! path)
    (migrate! path migrations)
    (let ((db (open-database path 'read-write '((busy-timeout . 0)))))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (execute! db "CREATE TABLE tokens (n INTEGER PRIMARY KEY, tok INTEGER NOT NULL)")
          (execute! db (string-append "CREATE TABLE dangle (id INTEGER PRIMARY KEY, up INTEGER"
                                      " REFERENCES dangle(id) DEFERRABLE INITIALLY DEFERRED)")))
        (lambda () (close-database! db))))
    (when (file-exists? (string-append path "-wal"))
      (assertion-violation 'make-template! "the template kept its -wal" path)))

  ;; copy-file! : String String -> Void
  (define (copy-file! from to)
    (let ((bv (call-with-port (open-file-input-port from) get-bytevector-all)))
      (remove-db-files! to)
      (call-with-port (open-file-output-port to)
        (lambda (p) (put-bytevector p bv)))))

  ;;; Traces

  ;; default-choice : Config World Who -> Choice
  ;; The thread's nominal (first) choice. A thread whose job has ended is
  ;; swept to its next job's look by model-apply first: its box decides.
  (define (default-choice c w who)
    (let* ((t (world-thread w who)) (st (thread-state t)))
      (if (and st (eq? (car st) 'ended))
          (if (thread-box? t) 'present 'absent)
          (let ((cs (model-choices c w who)))
            (if (null? cs)
                (assertion-violation 'trace-of-moves "the thread has no call" who)
                (car cs))))))

  ;; trace-of-moves : Config ReplayMachine (Listof (Pairof Who (U Choice #f))) -> Trace
  ;; The model's steps for MOVES, each (who . choice) applied in turn from
  ;; the start; #f is the thread's nominal choice. The other process's
  ;; choice is always given. Raises on a move that is not a step there.
  (define (trace-of-moves c rm moves)
    (let ((m (replay-machine-model rm)))
      (let loop ((w (model-start c m)) (moves moves) (acc '()))
        (if (null? moves)
            (reverse acc)
            (let* ((who (caar moves))
                   (choice (or (cdar moves) (default-choice c w who)))
                   (r (model-apply c m w who choice)))
              (loop (cdr r) (cdr moves) (cons (car r) acc)))))))

  ;; trace-by-chooser : Config ReplayMachine ((Listof Step) -> Natural) Natural -> Trace
  ;; From the start, at each world the next steps of the model's graph
  ;; (model-next, every call every way, the other process's moves), CHOOSE
  ;; picking one by its index, until none is left or LIMIT steps.
  (define (trace-by-chooser c rm choose limit)
    (let* ((m (replay-machine-model rm)) (next (model-next c m #f #f)))
      (let loop ((w (model-start c m)) (n 0) (acc '()))
        (let ((moves (next w)))
          (if (or (null? moves) (= n limit))
              (reverse acc)
              (let ((mv (list-ref moves (choose (map car moves)))))
                (loop (cdr mv) (+ n 1) (cons (car mv) acc))))))))

  ;; lcg : Natural -> Natural     a 31-bit linear congruential step
  (define (lcg x) (mod (+ (* x 1103515245) 12345) 2147483648))
  (define (pick x n) (mod (div x 65536) n))

  ;; walk-trace : Config ReplayMachine Natural Natural -> Trace
  ;; A seeded random walk over the model's graph, at most LIMIT steps: at
  ;; each world an actor with a next step, each alike; then its nominal
  ;; step three times in four, else any of its steps, each alike.
  (define (walk-trace c rm seed limit)
    (let* ((m (replay-machine-model rm)) (next (model-next c m #f #f)))
      (let loop ((w (model-start c m)) (x (lcg (+ seed 7919))) (n 0) (acc '()))
        (let ((moves (next w)))
          (if (or (null? moves) (= n limit))
              (reverse acc)
              (let* ((whos (fold-left (lambda (acc mv)
                                        (let ((who (step-who (car mv))))
                                          (if (memq who acc) acc (append acc (list who)))))
                                      '() moves))
                     (x1 (lcg x)) (x2 (lcg x1)) (x3 (lcg x2))
                     (who (list-ref whos (pick x1 (length whos))))
                     (mine (filter (lambda (mv) (eq? (step-who (car mv)) who)) moves))
                     (mv (if (< (pick x2 4) 3) (car mine) (list-ref mine (pick x3 (length mine))))))
                (loop (cdr mv) x3 (+ n 1) (cons (car mv) acc))))))))

  ;;; What the realization claims

  ;; realization-claims : (Listof (List CommandKind ChoiceTag Claim String))
  ;; Claim is real (always a call of the exec), injected (never), or either
  ;; (real in the situations named, injected in the others). The suite's
  ;; header has the same table; the suite holds the run to it both ways.
  (define realization-claims
    '((look present real "the box holds its connection")
      (look absent real "a close emptied the box")
      (begin-immediate ok real "no one else holds the write lock")
      (begin-immediate busy real "the other process really holds BEGIN IMMEDIATE; timeout 0")
      (begin-immediate failed-open real "a transaction was left open (a mutant table)")
      (begin-immediate failed-closed either
       "real on the read-write connection: PRAGMA query_only = 1 first (SQLite: readonly, nothing begun), reset after; injected on the read-only one, where BEGIN IMMEDIATE opens a read transaction whatever query_only says")
      (begin ok real "a plain BEGIN")
      (begin failed-open real "a transaction was left open (a mutant table)")
      (begin failed-closed injected
       "a plain BEGIN with none open does nothing that can fail: nothing is called")
      (read-version ok real "PRAGMA user_version")
      (read-version failed-open injected
       "a read fails only by an interrupt from another thread or a broken file: nothing is called; the transaction stays")
      (read-version failed-closed injected
       "the same, ended: a real ROLLBACK, reported failed")
      (run-job returned-open real "the job reads, writes its tokens, returns")
      (run-job raised-open real "the job reads, writes its tokens, raises")
      (run-job returned-closed real
       "after its tokens, INSERT OR ROLLBACK into temp.trap conflicts: SQLite ends the transaction and raises; the job catches it, tries its later writes (refused), returns")
      (run-job raised-closed real "the same, and the job raises what the trap raised")
      (commit ok real "COMMIT")
      (commit failed-open real
       "a dangling row put in dangle first: the deferred foreign key refuses the COMMIT, the transaction left open")
      (commit failed-closed either
       "real with no transaction (cannot commit); injected in one: a real ROLLBACK, reported failed")
      (commit took-effect injected "a real COMMIT, reported failed")
      (rollback ok real "ROLLBACK")
      (rollback failed-open injected
       "SQLite's ROLLBACK of an open transaction does not fail: nothing is called; the transaction stays")
      (rollback failed-closed either
       "real with no transaction (cannot rollback); injected in one: a real ROLLBACK, reported failed")
      (close ok real "close-database!")
      (close failed-gone injected "a close that raises cannot be staged: the box emptied, the connection closed")
      (close failed-kept injected
       "the box emptied, the connection kept open, holding its transaction and lock")
      (other take real "BEGIN IMMEDIATE on the other connection")
      (other free real "ROLLBACK on the other connection")
      (other migrate real "PRAGMA user_version = v, then COMMIT, on the other connection")))

  ;;; The run

  ;; Actor: the real side of one thread
  ;;   box      its Box, as doorway-set-up made it
  ;;   kept     #f, or the connection a failed close kept open
  ;;   gone     the connections a close took, each of which must be closed
  ;;   job      the job's place on its thread (#f before the first)
  ;;   state, command   the real side's own State and Command
  ;;   shell    the JobShell of the job
  (define-record-type actor
    (fields who box (mutable kept) (mutable gone) (mutable job) (mutable state)
            (mutable command) (mutable shell)))

  ;; Run: the replay's state
  (define-record-type run
    (fields config rm opts path writer reader other
            (mutable steps) (mutable keys) hows reasons offers (mutable lock)))

  (define (run-actor r who) (if (eq? who 'writer) (run-writer r) (run-reader r)))

  ;; open-run : Config ReplayMachine ReplayOptions String -> Run
  ;; The three connections on PATH (the writer's first: the read-only open
  ;; needs the -shm it makes), and the temp traps.
  (define (open-run c rm opts path)
    (let* ((wb (doorway-set-up path 'read-write migrations 0))
           (rb (guard (e (#t (doorway-tear-down wb) (raise e)))
                 (doorway-set-up path 'read-only migrations 0)))
           (other (guard (e (#t (doorway-tear-down rb) (doorway-tear-down wb) (raise e)))
                    (open-database path 'read-write '((busy-timeout . 0))))))
      (for-each (lambda (b)
                  (execute! (unbox b) "CREATE TEMP TABLE trap (k INTEGER PRIMARY KEY)")
                  (execute! (unbox b) "INSERT INTO temp.trap VALUES (0)"))
                (list wb rb))
      (make-run c rm opts path
                (make-actor 'writer wb #f '() #f #f #f #f)
                (make-actor 'reader rb #f '() #f #f #f #f)
                other 0 '() (make-hashtable equal-hash equal?)
                (make-hashtable equal-hash equal?) (make-hashtable equal-hash equal?) #f)))

  ;; close-all! : Run -> Void     every connection the run still has open
  (define (close-all! r)
    (define (quietly db) (when db (guard (e (#t #f)) (close-database! db))))
    (for-each (lambda (a)
                (quietly (unbox (actor-box a)))
                (set-box! (actor-box a) #f)
                (quietly (actor-kept a))
                (for-each quietly (actor-gone a)))
              (list (run-reader r) (run-writer r)))
    (quietly (run-other r)))

  ;;; Observing

  ;; observe : String -> (U (List (Listof Token) Integer Boolean) (List 'raised String))
  ;; The file as a fresh connection sees it, outside any transaction: the
  ;; tokens in commit order, user_version, and whether the write lock is
  ;; held (BEGIN IMMEDIATE at timeout 0 told busy; an ok one is rolled
  ;; back at once). Opened read-write, since a read-only BEGIN IMMEDIATE
  ;; takes no lock (pa 2), and closed.
  (define (observe path)
    (attempt
     (lambda ()
       (let ((db (open-database path 'read-write '((busy-timeout . 0)))))
         (dynamic-wind
           (lambda () #f)
           (lambda ()
             (let* ((toks (map (lambda (row) (vector-ref row 0))
                               (query db "SELECT tok FROM tokens ORDER BY n")))
                    (v (vector-ref (query-row db "PRAGMA user_version") 0))
                    (held (guard (e ((sqlite-busy? e) #t))
                            (execute! db "BEGIN IMMEDIATE")
                            (execute! db "ROLLBACK")
                            #f)))
               (list toks v held)))
           (lambda () (guard (e (#t #f)) (close-database! db))))))))

  ;; Check is (List Symbol Any Any): a comparison's name, the model's side,
  ;; the real side.

  ;; world-checks : Run World -> (Listof Check)
  ;; The file, the lock, and each actor, after a step (or at the start).
  (define (world-checks r w)
    (let* ((o (observe (run-path r))) (f (world-file w))
           (wr (world-thread w 'writer)) (rd (world-thread w 'reader))
           (otx (txn? (run-other r))))
      (run-lock-set! r (and (not (raised? o)) (caddr o)))
      (append
       (if (raised? o)
           (list (list 'observed 'a-view o))
           (list (list 'file-writes (file-writes f) (car o))
                 (list 'file-version (file-version f) (cadr o))
                 (list 'write-lock (list (thread-lock? wr) (world-olock w))
                       (list (and (caddr o) (not otx)) otx))))
       (actor-checks (run-writer r) wr)
       (actor-checks (run-reader r) rd)
       (list (list 'other-transaction (world-olock w) otx)))))

  ;; actor-checks : Actor Thread -> (Listof Check)
  (define (actor-checks a t)
    (let* ((who (symbol->string (actor-who a)))
           (bdb (unbox (actor-box a))) (kept (actor-kept a))
           (unclosed (filter (lambda (db) (not (closed? db))) (actor-gone a)))
           (live (append (if bdb (list bdb) '()) (if kept (list kept) '()) unclosed)))
      (define (name s) (string->symbol (string-append who "-" s)))
      (list (list (name "closes-closed") 0 (length unclosed))
            (list (name "connection") (thread-conn t)
                  (cond (bdb 'open) (kept 'kept) (else 'none)))
            (list (name "transaction") (thread-txn? t) (exists txn? live)))))

  ;;; Jobs

  ;; make-job : Symbol Natural Natural Action Boolean -> (values (Tx -> Any) (-> Saw))
  ;; The job of step-action ACTION (the header's "A job"), of N writes in
  ;; all, and a thunk for what its body read: #f, or (List Tokens Version).
  ;; DEFERRED? says the writer's transaction holds no lock.
  (define (make-job who j n action deferred?)
    (let* ((made (car action)) (ending (cadr action)) (mode (caddr action))
           (k (length made)) (saw #f))
      (define (rows->toks rows) (map (lambda (row) (vector-ref row 0)) rows))
      (define (read! tx)
        (let* ((toks (rows->toks (tx-query tx "SELECT tok FROM tokens ORDER BY n")))
               (v (vector-ref (tx-query-row tx "SELECT user_version FROM pragma_user_version") 0)))
          (set! saw (list toks v))))
      (define (write! tx tok) (tx-execute! tx "INSERT INTO tokens (tok) VALUES (?)" tok))
      (define (quietly thunk) (guard (e (#t #f)) (thunk)))
      (define (done e)
        (if (eq? ending 'returned) (values who j) (raise (or e 'replay-job-raised))))
      (values
       (lambda (tx)
         (case mode
           ((open)
            (read! tx)
            (when (and deferred? (null? made) (> n 0))
              (write! tx (write-token j 1)))
            (for-each (lambda (tok) (write! tx tok)) made)
            (done #f))
           ((ended)
            (read! tx)
            (for-each (lambda (tok) (write! tx tok)) made)
            (let ((e (guard (e (#t e))
                       (tx-execute! tx "INSERT OR ROLLBACK INTO temp.trap VALUES (0)")
                       #f)))
              (for-each (lambda (i) (quietly (lambda () (write! tx (write-token j i)))))
                        (from-to (+ k 2) n))
              (done e)))
           (else
            (for-each (lambda (tok) (quietly (lambda () (write! tx tok)))) made)
            (done #f))))
       (lambda () saw))))

  (define (no-job tx) (assertion-violation 'replay "a job run where none was asked"))

  ;;; Realizing a step

  ;; realize : Run Actor World Step -> (List RawOutcome How String (U #f Saw))
  ;; Carries out the step's command on the actor's connection the way its
  ;; choice says (realization-claims): the raw outcome, real or injected,
  ;; the reason when injected, and what a job's body read.
  (define (realize r a w s)
    (let* ((who (actor-who a)) (cmd (step-command s)) (choice (step-choice s))
           (scmd ((options-shell-command (run-opts r)) who cmd))
           (b (actor-box a)) (db (unbox b)) (txn (and db (txn? db)))
           (exec (options-exec (run-opts r))))
      (define (call job)
        (list (guard (e (#t (list 'shell-raised (describe e) #f)))
                (exec who b (actor-shell a) scmd job))
              'real "" #f))
      (define (inject status why)
        (list (list status (if (eq? status 'failed) io #t) (and db (txn? db))) 'injected why #f))
      (define (bad)
        (assertion-violation 'realize "no way to make this real" cmd choice))
      (case (car cmd)
        ((look) (call no-job))
        ((begin-immediate begin)
         (case choice
           ((ok busy failed-open) (call no-job))
           ((failed-closed)
            (cond ((not db) (call no-job))
                  ((and (eq? who 'writer) (eq? (car scmd) 'begin-immediate))
                   (execute! db "PRAGMA query_only = 1")
                   (dynamic-wind
                     (lambda () #f)
                     (lambda () (call no-job))
                     (lambda () (execute! db "PRAGMA query_only = 0"))))
                  (else (inject 'failed "begin failed-closed: nothing is called"))))
           (else (bad))))
        ((read-version)
         (case choice
           ((ok) (call no-job))
           ((failed-open)
            (if db (inject 'failed "read-version failed-open: nothing is called") (call no-job)))
           ((failed-closed)
            (cond ((not db) (call no-job))
                  (txn (execute! db "ROLLBACK")
                       (inject 'failed "read-version failed-closed: a real ROLLBACK"))
                  (else (inject 'failed "read-version failed-closed: nothing is called"))))
           (else (bad))))
        ((run-job)
         (let* ((c (run-config r)) (j (step-job s))
                (n (if (eq? who 'writer) (list-ref (config-writes c) j) 0))
                (t (world-thread w who))
                (deferred? (and (eq? who 'writer) (thread-txn? t) (not (thread-lock? t)))))
           (let-values (((job saw) (make-job who j n (step-action s) deferred?)))
             (let ((out (call job)))
               (list (car out) (cadr out) (caddr out) (saw))))))
        ((commit)
         (case choice
           ((ok) (call no-job))
           ((failed-open)
            (when txn (execute! db "INSERT INTO dangle (up) VALUES (-1)"))
            (call no-job))
           ((failed-closed)
            (if txn
                (begin (execute! db "ROLLBACK")
                       (inject 'failed "commit failed-closed in a transaction: a real ROLLBACK"))
                (call no-job)))
           ((took-effect)
            (if txn
                (begin (execute! db "COMMIT")
                       (inject 'failed "commit took-effect: a real COMMIT"))
                (bad)))
           (else (bad))))
        ((rollback)
         (case choice
           ((ok) (call no-job))
           ((failed-open)
            (if txn (inject 'failed "rollback failed-open: nothing is called") (call no-job)))
           ((failed-closed)
            (if txn
                (begin (execute! db "ROLLBACK")
                       (inject 'failed "rollback failed-closed in a transaction: a real ROLLBACK"))
                (call no-job)))
           (else (bad))))
        ((close)
         (case choice
           ((ok failed-closed)
            (when db (actor-gone-set! a (cons db (actor-gone a))))
            (call no-job))
           ((failed-gone)
            (if db
                (begin (set-box! b #f)
                       (close-database! db)
                       (actor-gone-set! a (cons db (actor-gone a)))
                       (list (list 'failed "a statement's finalize failed" #f) 'injected
                             "close failed-gone: closed, the box emptied" #f))
                (call no-job)))
           ((failed-kept)
            (if db
                (begin (set-box! b #f)
                       (actor-kept-set! a db)
                       (list (list 'failed "unable to close due to unfinalized statements" #f)
                             'injected "close failed-kept: the box emptied, the connection kept" #f))
                (call no-job)))
           (else (bad))))
        (else (bad)))))

  ;;; One step

  (define (add-how! r key)
    (hashtable-update! (run-hows r) key (lambda (n) (+ n 1)) 0))

  ;; start-job! : Run Actor Natural -> (U #f Check)
  ;; The actor's next job, J: its shell and the table's start. A difference
  ;; when its last job had not ended.
  (define (start-job! r a j)
    (if (and (actor-job a) (not (eq? (car (actor-state a)) 'ended)))
        (list 'job-ended 'ended (car (actor-state a)))
        (let-values (((s cmd) ((rm-start (run-rm r) (actor-who a))
                               (config-latest (run-config r)))))
          (actor-job-set! a j)
          (actor-state-set! a s)
          (actor-command-set! a cmd)
          (actor-shell-set! a (make-job-shell (actor-box a)))
          #f)))

  ;; thread-step : Run World Step -> (Pairof How (Listof Check))
  (define (thread-step r w s)
    (let* ((c (run-config r)) (rm (run-rm r)) (who (step-who s)) (a (run-actor r who))
           (cmd (step-command s)) (mraw (step-raw s))
           (late (and (not (eqv? (actor-job a) (step-job s))) (start-job! r a (step-job s)))))
      (cond
       (late (cons 'none (list late)))
       ((not (equal? (actor-command a) cmd))
        (cons 'none (list (list 'command cmd (actor-command a)))))
       (else
        ;; The writer's BEGIN IMMEDIATE on its connection with no
        ;; transaction is told busy exactly while another holds the lock
        ;; (cl. 1): the model must offer busy then, and only then. The lock
        ;; as the observer found it after the last step.
        (let* ((bdb (unbox (actor-box a)))
               (busy-check? (and (eq? who 'writer) (eq? (car cmd) 'begin-immediate)
                                 bdb (not (txn? bdb)) #t))
               (busy-offered (and busy-check? (memq 'busy (model-choices c w who)) #t))
               (lock-before (and (run-lock r) #t))
               (out (realize r a w s))
               (raw (car out)) (how (cadr out))
               (kind (attempt (lambda () ((rm-kind rm who) cmd raw))))
               (mkind (attempt (lambda () ((rm-kind rm who) cmd mraw))))
               (next (attempt (lambda ()
                                (let-values (((s2 c2) ((rm-step rm who) (actor-state a)
                                                       (cons kind raw))))
                                  (cons s2 c2)))))
               (tag (choice-tag (step-choice s))))
          (add-how! r (list (car cmd) tag how))
          (when (eq? how 'injected)
            (hashtable-set! (run-reasons r) (list (car cmd) tag) (caddr out)))
          (run-keys-set! r (cons (list who (car (actor-state a)) kind how) (run-keys r)))
          (unless (raised? next)
            (actor-state-set! a (car next))
            (actor-command-set! a (cdr next)))
          (cons how
                (append
                 (list (list 'status (car mraw) (car raw))
                       (list 'open (caddr mraw) (caddr raw)))
                 (if (or (and (eq? (car cmd) 'read-version) (eq? (car mraw) 'ok))
                         (and (eq? (car cmd) 'run-job) (eq? (car mraw) 'returned)))
                     (list (list 'value (cadr mraw) (cadr raw)))
                     '())
                 (list (list 'event mkind kind))
                 (if (and (eq? (car cmd) 'run-job) (step-saw s)
                          (not (eq? (caddr (step-action s)) 'none)))
                     (let ((f (step-saw s)))
                       (list (list 'saw (list (file-writes f) (file-version f)) (cadddr out))))
                     '())
                 (if busy-check?
                     (list (list 'busy-offered-while-locked busy-offered lock-before))
                     '())
                 (list (list 'state (step-state s) (if (raised? next) next (car next)))))))))))

  ;; other-step : Run Step -> (Pairof How (Listof Check))
  (define (other-step r s)
    (let* ((db (run-other r)) (choice (step-choice s))
           (out (attempt
                 (lambda ()
                   (case choice
                     ((take) (execute! db "BEGIN IMMEDIATE"))
                     ((free) (execute! db "ROLLBACK"))
                     ((migrate)
                      (execute! db (string-append "PRAGMA user_version = "
                                                  (number->string (cdr (step-command s)))))
                      (execute! db "COMMIT"))
                     (else (assertion-violation 'other-step "not a move" choice)))
                   'ok))))
      (add-how! r (list 'other choice 'real))
      (cons 'real (list (list 'other-outcome 'ok out)))))

  ;; first-difference : (Listof Check) -> (U Check #f)
  (define (first-difference checks)
    (find (lambda (k) (not (equal? (cadr k) (caddr k)))) checks))

  ;; replay-step : Run World Natural Step -> (U (Pairof 'next World) Verdict)
  (define (replay-step r w n s)
    (let* ((c (run-config r)) (m (replay-machine-model (run-rm r)))
           (who (step-who s)) (choice (step-choice s))
           (again (attempt (lambda () (model-apply c m w who choice)))))
      (define (verdict how d)
        (list n who (step-job s) (step-command s) choice how (car d) (cadr d) (caddr d)))
      (cond
       ((or (raised? again) (not (equal? (car again) s)))
        (verdict 'none (list 'model-trace s again)))
       (else
        (for-each (lambda (ch) (hashtable-set! (run-offers r)
                                               (list (if (eq? who 'other) 'other (car (step-command s)))
                                                     (choice-tag ch))
                                               #t))
                  (cond ((eq? who 'other) (other-choices c w))
                        ((equal? (step-command s) '(look)) (list choice))
                        (else (model-choices c w who))))
        ;; In this order: the call first, then the file and the actors.
        (let* ((call (if (eq? who 'other) (other-step r s) (thread-step r w s)))
               (d1 (first-difference (cdr call)))
               (d (or d1 (first-difference (world-checks r (cdr again))))))
          (run-steps-set! r (+ 1 (run-steps r)))
          (if d (verdict (car call) d) (cons 'next (cdr again))))))))

  ;;; The replay

  ;; Report is #(Verdict Natural Keys Hows Reasons Offers)
  ;;   verdict  'agree; or (List Natural Who Job Command Choice How Symbol
  ;;            Any Any): the step at which the sides first differ (1-based;
  ;;            0 is the start), its actor, job, command and choice, whether
  ;;            it was real or injected, the comparison, the model's side and
  ;;            the real side; or (List 'raised String) when the replay
  ;;            itself could not go on
  ;;   steps    how many steps were replayed
  ;;   keys     (Who StateKind EventKind How) for each thread step, the
  ;;            event kind as the REAL outcome sorts it
  ;;   hows     ((CommandKind ChoiceTag How) . Natural)
  ;;   reasons  ((CommandKind ChoiceTag) . String) for each injection
  ;;   offers   (CommandKind ChoiceTag) for every way the model offered a
  ;;            replayed call to go, taken or not
  ;; report-verdict : Report -> Verdict
  ;; report-steps : Report -> Natural
  ;; report-keys : Report -> (Listof (List Symbol Symbol Any Symbol))
  ;; report-hows : Report -> (Listof (Pairof (List Symbol Symbol Symbol) Natural))
  ;; report-reasons : Report -> (Listof (Pairof (List Symbol Symbol) String))
  ;; report-offers : Report -> (Listof (List Symbol Symbol))
  (define (report-verdict x) (vector-ref x 0))
  (define (report-steps x) (vector-ref x 1))
  (define (report-keys x) (vector-ref x 2))
  (define (report-hows x) (vector-ref x 3))
  (define (report-reasons x) (vector-ref x 4))
  (define (report-offers x) (vector-ref x 5))

  (define (entries h)
    (let-values (((ks vs) (hashtable-entries h)))
      (map cons (vector->list ks) (vector->list vs))))

  ;; replay-trace : Config ReplayMachine Trace ReplayOptions String String -> Report
  ;; TRACE replayed on a copy of the template file TEMPLATE at PATH (any
  ;; file there removed first), against the model under RM's machine,
  ;; whose procedures the real side runs too. Every connection is closed on
  ;; the way out; the files are left for the caller.
  (define (replay-trace c rm trace opts template path)
    (let ((r (attempt (lambda () (copy-file! template path) (open-run c rm opts path)))))
      (if (raised? r)
          (vector r 0 '() '() '() '())
          (dynamic-wind
            (lambda () #f)
            (lambda ()
              (let ((v (attempt (lambda () (run-replay r trace)))))
                (vector v (run-steps r) (reverse (run-keys r)) (entries (run-hows r))
                        (entries (run-reasons r))
                        (map car (entries (run-offers r))))))
            (lambda () (close-all! r))))))

  ;; run-replay : Run Trace -> Verdict
  (define (run-replay r trace)
    (let* ((c (run-config r)) (m (replay-machine-model (run-rm r)))
           (w0 (model-start c m))
           (d (first-difference (world-checks r w0))))
      (if d
          (list 0 #f #f #f #f 'none (car d) (cadr d) (caddr d))
          (let loop ((w w0) (t trace) (n 1))
            (if (null? t)
                'agree
                (let ((out (replay-step r w n (car t))))
                  (if (and (pair? out) (eq? (car out) 'next))
                      (loop (cdr out) (cdr t) (+ n 1))
                      out)))))))
)
