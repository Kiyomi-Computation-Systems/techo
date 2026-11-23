#!r6rs
;;; (replay-support): the machinery of layer 4 of the slice 2 plan, the
;;; replay of the migration model's traces on real SQLite. The suite,
;;; tests/test-migrations-replay.sps, holds the table of how each choice is
;;; made real, the configurations and the tests; this library holds what
;;; they run.
;;;
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path. It is the imperative side of the comparison: it opens files and
;;; calls SQLite, and (migrations-model) is the pure side it is held to.
;;;
;;; One replay
;;; ----------
;;; A trace is a list of the model's Steps from its start world. The replay
;;; builds the real file the trace starts on, makes one Shell per actor,
;;; each with a busy timeout of 0, all in this one thread, and takes the
;;; steps in the trace's order. At each step it
;;;   - applies the step to the model again (model-apply), for the model's
;;;     world after it: the lock, each actor's connection and transaction;
;;;   - takes the actor's pending REAL command, which the real side's own
;;;     step function chose from the REAL outcomes so far, and compares it
;;;     with the model step's command;
;;;   - makes the model's choice real (realize), which calls perform! (or
;;;     the options' exec in its place) once, after any set-up the choice
;;;     needs, or injects the outcome when SQLite cannot be made to give it;
;;;   - compares the real outcome with the model's: status, transaction
;;;     flag, the facts a look read, whether a check found violations, the
;;;     event kind the step function sorts it into, and the next state with
;;;     every reason string masked;
;;;   - reads the file through a third connection, opened read-only for each
;;;     look and closed after, and compares its facts, its table names and
;;;     its foreign key violations with the model's file after the step;
;;;   - compares each live actor's connection (open or not) and transaction
;;;     flag with the model's.
;;; The first difference is the verdict.
(library (replay-support)
  (export
   ;; machines
   make-replay-machine replay-machine-model real-replay-machine
   script-replay-machine
   ;; options
   make-replay-options default-replay-options
   ;; traces
   trace-of-moves trace-by-choice
   ;; the replay
   replay-trace report-verdict report-steps report-keys report-hows report-offers)
  (import (rnrs)
          (chez-sqlite3)
          (techo migrations)
          (techo db)
          (migrations-model))

  ;;; Machines

  ;; ReplayMachine is #(Machine RunStart RunStep RunKind CheckStart CheckStep
  ;;                    CheckKind): the model's Machine, and the six
  ;; procedures it was made from, which the real side runs. (migrations-model)
  ;; exports no accessors for a Machine's procedures, so this keeps them.

  ;; make-replay-machine : Any (-> (values State Command)) Stepper Classifier
  ;;                       (-> (values State Command)) Stepper Classifier
  ;;                       -> ReplayMachine
  (define (make-replay-machine name rs rstep rkind cs cstep ckind)
    (vector (make-model-machine name rs rstep rkind cs cstep ckind)
            rs rstep rkind cs cstep ckind))

  ;; replay-machine-model : ReplayMachine -> Machine
  (define (replay-machine-model rm) (vector-ref rm 0))
  (define (rm-run-start rm) (vector-ref rm 1))
  (define (rm-run-step rm) (vector-ref rm 2))
  (define (rm-run-kind rm) (vector-ref rm 3))
  (define (rm-check-start rm) (vector-ref rm 4))
  (define (rm-check-step rm) (vector-ref rm 5))
  (define (rm-check-kind rm) (vector-ref rm 6))

  ;; real-replay-machine : ReplayMachine
  ;; (techo migrations)'s own machines, unmutated.
  (define real-replay-machine
    (make-replay-machine 'real run-start run-step event-kind
                         check-start check-step check-event-kind))

  ;; script-replay-machine : Any (Listof Command) (Listof Command) -> ReplayMachine
  ;; Not migrate: the runs (actors 0 and 1) carry out RUN-SCRIPT and serve's
  ;; check (actor 2) CHECK-SCRIPT, one command after another, whatever each
  ;; answers. The state is (script . n), every event kind is `done`, and
  ;; after the last command comes (end . (nothing () #f 0)). For holding the
  ;; model's commands to SQLite in situations migrate never reaches.
  (define (script-replay-machine name run-script check-script)
    (define (command-at script n)
      (if (< n (length script))
          (list-ref script n)
          (cons 'end '(nothing () #f 0))))
    (define (start script)
      (lambda () (values (cons 'script 0) (command-at script 0))))
    (define (step script)
      (lambda (ms state raw)
        (let ((n (+ (cdr state) 1)))
          (values (cons 'script n) (command-at script n)))))
    (define (kind ms state raw) 'done)
    (make-replay-machine name (start run-script) (step run-script) kind
                         (start check-script) (step check-script) kind))

  ;;; Options

  ;; ReplayOptions is #(String (U #f String) (Shell Command -> RawOutcome))
  ;;   ended-sql  the SQL of a statement the model says answered ok with its
  ;;              transaction gone (ok-ended): "ROLLBACK", which is what the
  ;;              model means, or "COMMIT", which it does not
  ;;   dangle     #f, or a statement's token: once that statement has
  ;;              answered ok inside a transaction, a dangling row is put in
  ;;              its table, as a table rebuild with foreign keys off can
  ;;              leave one
  ;;   exec       the shell's one-call executor: perform!, or a mutant of it

  ;; make-replay-options : String (U #f String) (Shell Command -> RawOutcome)
  ;;                       -> ReplayOptions
  (define (make-replay-options ended-sql dangle exec)
    (vector ended-sql dangle exec))
  (define (options-ended-sql o) (vector-ref o 0))
  (define (options-dangle o) (vector-ref o 1))
  (define (options-exec o) (vector-ref o 2))

  ;; default-replay-options : ReplayOptions
  (define default-replay-options (make-replay-options "ROLLBACK" #f perform!))

  ;;; SQL

  ;; quoted : String -> String     an SQL identifier
  (define (quoted name) (string-append "\"" name "\""))

  ;; effect-sql : String -> String
  ;; The real statement for the model's token NAME ("effect k.i"): it makes
  ;; exactly one schema object, a table named NAME, with no autoindex (its
  ;; key is INTEGER PRIMARY KEY), and a deferred foreign key to itself, so
  ;; that a dangling row can be put in it.
  (define (effect-sql name)
    (string-append "CREATE TABLE " (quoted name)
                   " (id INTEGER PRIMARY KEY, up INTEGER REFERENCES "
                   (quoted name) "(id) DEFERRABLE INITIALLY DEFERRED)"))

  ;; statement-sql* : String -> String
  ;; The real SQL for a statement the model names: the id statement is real
  ;; SQL already; every other is a token.
  (define (statement-sql* payload)
    (if (string=? payload model-id-statement) payload (effect-sql payload)))

  ;; id-token? : Symbol -> Boolean
  (define (id-token? t) (string=? (symbol->string t) model-id-statement))

  ;; extra-names : Natural -> (Listof String)
  ;; The names of a file's N objects no migration made: "other 1" ...
  (define (extra-names n)
    (let loop ((i n) (acc '()))
      (if (= i 0) acc (loop (- i 1) (cons (string-append "other " (number->string i)) acc)))))

  ;; sorted : (Listof String) -> (Listof String)
  (define (sorted names) (list-sort string<? names))

  ;;; Files

  ;; remove-files! : String -> Void     the file, its -wal and its -shm
  (define (remove-files! path)
    (for-each (lambda (s)
                (let ((p (string-append path s)))
                  (when (file-exists? p) (delete-file p))))
              '("" "-wal" "-shm")))

  ;; with-database : Database (Database -> A) -> A    closes it on the way out
  (define (with-database db proc)
    (dynamic-wind (lambda () #f)
                  (lambda () (proc db))
                  (lambda () (guard (e (#t #f)) (close-database! db)))))

  ;; build-start! : String File -> Void
  ;; The real file at PATH that the model's start FILE describes, made by
  ;; plain calls and closed cleanly, so no -wal is left: none, for a file
  ;; that is not there; otherwise its journal mode, then in one transaction
  ;; a table for each effect in its log (effect-sql), its other program's
  ;; tables, its id and its version. A fresh file in delete mode is a file
  ;; of no bytes. This connection does not wait for the disk (synchronous
  ;; off): it closes before any other opens, and nothing here crashes.
  (define (build-start! path f)
    (remove-files! path)
    (when (model-file-exists? f)
      (with-database (open-database path 'create '((busy-timeout . 0)))
        (lambda (db)
          (execute! db "PRAGMA synchronous = OFF")
          (when (eq? (model-file-mode f) 'wal)
            (execute! db "PRAGMA journal_mode = wal"))
          (execute! db "BEGIN")
          (for-each (lambda (t)
                      (unless (id-token? t) (execute! db (effect-sql (symbol->string t)))))
                    (model-file-log f))
          (for-each (lambda (name)
                      (execute! db (string-append "CREATE TABLE " (quoted name) " (x)")))
                    (extra-names (model-file-extra f)))
          (unless (= (model-file-id f) 0)
            (execute! db (string-append "PRAGMA application_id = "
                                        (number->string (model-file-id f)))))
          (unless (= (model-file-version f) 0)
            (execute! db (string-append "PRAGMA user_version = "
                                        (number->string (model-file-version f)))))
          (execute! db "COMMIT")))))

  ;; View is 'missing, or (List DbFacts (Listof String) Natural): the facts,
  ;; the table names in order, and how many foreign key violations the file
  ;; holds.

  ;; observe : String -> (U View (List 'raised String))
  ;; The file as a third connection sees it: opened read-only (which never
  ;; creates a file), outside any transaction, four plain statements for the
  ;; facts (not facts-sql, so that the shell's own reading is not what it is
  ;; held to), the table names, and PRAGMA foreign_key_check; then closed.
  (define (observe path)
    (guard (e (#t (list 'raised (guard (e2 (#t "?"))
                                  (if (sqlite-error? e) (sqlite-error-message e) "not SQLite's")))))
      (if (not (file-exists? path))
          'missing
          (with-database (open-database path 'read-only '((busy-timeout . 0)))
            (lambda (db)
              (define (one sql) (vector-ref (query-row db sql) 0))
              (list (list (one "PRAGMA application_id") (one "PRAGMA user_version")
                          (one "SELECT count(*) FROM sqlite_schema")
                          (string->symbol (string-downcase (one "PRAGMA journal_mode"))))
                    (sorted (map (lambda (r) (vector-ref r 0))
                                 (query db "SELECT name FROM sqlite_schema WHERE type = 'table'")))
                    (length (query db "PRAGMA foreign_key_check"))))))))

  ;; model-view : File -> View
  ;; The model's file as observe would see it. The model's files hold no
  ;; foreign key violation: a dangling row is only ever in a transaction,
  ;; and R31 rolls it back.
  (define (model-view f)
    (if (not (model-file-exists? f))
        'missing
        (list (model-file-facts f)
              (sorted (append (map symbol->string
                                   (filter (lambda (t) (not (id-token? t))) (model-file-log f)))
                              (extra-names (model-file-extra f))))
              0)))

  ;; file-checks : String File -> (Listof Check)
  ;; Check is (List Symbol Any Any): a comparison's name, the model's side,
  ;; the real side.
  (define (file-checks path f)
    (let ((real (observe path)) (model (model-view f)))
      (cond ((or (eq? real 'missing) (eq? model 'missing))
             (list (list 'file-exists (not (eq? model 'missing)) (not (eq? real 'missing)))))
            ((eq? (car real) 'raised)
             (list (list 'file-observed 'a-view real)))
            (else (list (list 'file-facts (car model) (car real))
                        (list 'file-tables (cadr model) (cadr real))
                        (list 'file-foreign-keys (caddr model) (caddr real)))))))

  ;;; Making a choice real

  ;; shell-txn? : Shell -> Boolean    a transaction open on its connection
  (define (shell-txn? sh)
    (let ((db (shell-database sh)))
      (and db (guard (e (#t #f)) (in-transaction? db)))))

  ;; newest-effect-table : Database -> (U String #f)
  ;; The effect table made last, as this connection sees it.
  (define (newest-effect-table db)
    (let ((r (query-row db (string-append "SELECT name FROM sqlite_schema WHERE type = 'table'"
                                          " AND name LIKE 'effect %' ORDER BY rowid DESC LIMIT 1"))))
      (and r (vector-ref r 0))))

  ;; insert-dangling! : Database String -> Void
  ;; A row of TABLE whose key points at no row: one violation.
  (define (insert-dangling! db table)
    (execute! db (string-append "INSERT INTO " (quoted table) " (up) VALUES (-1)")))

  ;; How is 'real or 'injected.

  ;; realize : Config World Index Command Choice Shell ReplayOptions Boolean
  ;;           -> (Pairof RawOutcome How)
  ;; Carries out actor WHO's command CMD on its shell SH the way CHOICE says,
  ;; W being the model's world before the step. A real outcome comes from
  ;; one call of the options' exec, after any set-up its choice needs; an
  ;; injected one makes no call of it, and makes whatever plain calls bring
  ;; the connection's true state to the outcome it reports: a real ROLLBACK
  ;; for a failure that ended the transaction, a real COMMIT for one that
  ;; took effect. FK? turns foreign keys on at this actor's read-write open,
  ;; so that a deferred key can fail its COMMIT. The suite's header has the
  ;; table of which is which, and why.
  (define (realize c w who cmd choice sh opts fk?)
    (let* ((exec (options-exec opts))
           (a (world-actor w who))
           (conn (actor-conn a))
           (wal? (eq? (model-file-mode (world-file w)) 'wal))
           (db (shell-database sh))
           (txn (shell-txn? sh))
           (lock (world-lock w))
           (other-lock? (and lock (not (= lock who)))))
      (define (real . given)
        (cons (exec sh (if (null? given) cmd (car given))) 'real))
      (define (injected raw) (cons raw 'injected))
      (define (keep why) (injected (list 'failed why (shell-txn? sh))))
      (define (ended why)
        (execute! (shell-database sh) "ROLLBACK")
        (injected (list 'failed why #f)))
      (define (bad) (assertion-violation 'realize "no way to make this real" cmd choice))
      (define io "disk I/O error")
      (case (car cmd)
        ((open-read-only open-read-write)
         (case choice
           ((ok missing)
            (let ((r (real)))
              (when (and fk? (eq? (car cmd) 'open-read-write) (eq? (caar r) 'ok))
                (execute! (shell-database sh) "PRAGMA foreign_keys = ON"))
              r))
           ((fail)
            (when db (exec sh '(close)))
            (injected (list 'failed "unable to open database file" #f)))
           (else (bad))))
        ((read-facts)
         (case choice
           ((ok) (real))
           ((fail) (if db (keep io) (real)))
           ((fail-ended) (ended io))
           (else (bad))))
        ((close)
         (case choice
           ((ok) (real))
           ((fail)
            (exec sh '(close))
            (injected (list 'failed "unable to close due to unfinalized statements" #f)))
           (else (bad))))
        ((set-wal)
         (case choice
           ((ok) (real))
           ((busy) (if other-lock? (real) (injected (list 'busy "database is locked" #f))))
           ((fail) (if (or (not db) (and (not wal?) (or (eq? conn 'ro) txn))) (real) (keep io)))
           ((fail-ended) (ended io))
           (else (bad))))
        ((pause)
         (case choice
           ((ok) (real))
           ((fail) (keep "interrupted"))
           (else (bad))))
        ((begin-immediate)
         (case choice
           ((ok busy) (real))
           ;; On a read-only connection SQLite's BEGIN IMMEDIATE answers ok and
           ;; opens a (read) transaction, where the model says it fails: so
           ;; that failure is injected. migrate never asks it there.
           ((fail) (if (or (not db) txn) (real) (keep io)))
           ((fail-ended) (ended io))
           (else (bad))))
        ((run-statement)
         (let ((payload (cdr cmd)))
           (case choice
             ((ok busy)
              (let ((r (real (cons 'run-statement (statement-sql* payload)))))
                (when (and (eq? choice 'ok) (equal? (options-dangle opts) payload)
                           (eq? (caar r) 'ok) (shell-txn? sh))
                  (insert-dangling! (shell-database sh) payload))
                r))
             ((ok-ended) (real (cons 'run-statement (options-ended-sql opts))))
             ((fail fail-ended)
              (if (and db (eq? conn 'rw))
                  (begin
                    (execute! db "CREATE TEMP TABLE IF NOT EXISTS replay_nn (x NOT NULL)")
                    (real (cons 'run-statement
                                (if (eq? choice 'fail)
                                    "INSERT INTO temp.replay_nn VALUES (NULL)"
                                    "INSERT OR ROLLBACK INTO temp.replay_nn VALUES (NULL)"))))
                  ;; read-only, or no connection: the statement fails by itself
                  (real (cons 'run-statement (statement-sql* payload)))))
             (else (bad)))))
        ((foreign-key-check)
         (case choice
           ((ok) (real))
           ((violations)
            (let ((t (and txn (newest-effect-table db))))
              (if t
                  (begin (insert-dangling! db t) (real))
                  (injected (list 'ok '(("replay" 1 "replay" 0)) (shell-txn? sh))))))
           ((fail) (if db (keep io) (real)))
           ((fail-ended) (ended io))
           (else (bad))))
        ((stamp)
         (case choice
           ((ok busy) (real))
           ((fail) (if (or (not db) (eq? conn 'ro)) (real) (keep io)))
           ((fail-ended) (ended io))
           (else (bad))))
        ((commit)
         (case choice
           ((ok) (real))
           ((fail)
            (let ((t (and txn fk? (newest-effect-table db))))
              (cond ((not txn) (real))
                    (t (insert-dangling! db t) (real))
                    (else (keep io)))))
           ((fail-ended) (ended io))
           ((took-effect)
            (execute! db "COMMIT")
            (injected (list 'failed io #f)))
           (else (bad))))
        ((rollback)
         (case choice
           ((ok) (real))
           ((fail) (if txn (keep "cannot rollback transaction") (real)))
           ((fail-ended) (ended io))
           (else (bad))))
        (else (bad)))))

  ;;; Traces

  ;; trace-of-moves : Config ReplayMachine (Listof (Pairof Index (U Choice #f)))
  ;;                  -> Trace
  ;; The model's steps for MOVES, each (who . choice) applied in turn from
  ;; the start; a choice of #f is the first the command has (its nominal
  ;; one). Raises on a move that is not a step there.
  (define (trace-of-moves c rm moves)
    (let ((m (replay-machine-model rm)))
      (let loop ((w (model-start c m)) (moves moves) (acc '()))
        (if (null? moves)
            (reverse acc)
            (let* ((who (caar moves))
                   (choice (or (cdar moves)
                               (car (model-choices c w who
                                                   (actor-command (world-actor w who))))))
                   (r (model-apply c m w who choice)))
              (loop (cdr r) (cdr moves) (cons (car r) acc)))))))

  ;; trace-by-choice : Config ReplayMachine (Index Command (Listof Choice) -> Choice)
  ;;                   -> Trace
  ;; The model's steps from the start, always stepping the lowest actor that
  ;; has not ended, the way CHOOSE picks from the command's choices, until
  ;; none is left (or 500 steps).
  (define (trace-by-choice c rm choose)
    (let ((m (replay-machine-model rm)))
      (let loop ((w (model-start c m)) (n 0) (acc '()))
        (let ((who (find (lambda (i)
                           (let ((a (world-actor w i)))
                             (and a (not (eq? (car (actor-command a)) 'end)))))
                         '(0 1 2))))
          (if (or (not who) (= n 500))
              (reverse acc)
              (let* ((cmd (actor-command (world-actor w who)))
                     (r (model-apply c m w who (choose who cmd (model-choices c w who cmd)))))
                (loop (cdr r) (+ n 1) (cons (car r) acc))))))))

  ;;; The replay

  ;; mask : Any -> Any     every string replaced by the symbol text
  (define (mask x)
    (cond ((string? x) 'text)
          ((pair? x) (cons (mask (car x)) (mask (cdr x))))
          (else x)))

  ;; mask-command : Command -> Any
  ;; A command as compared: a statement's SQL exactly, an end's Result
  ;; with its reasons masked.
  (define (mask-command cmd) (if (eq? (car cmd) 'end) (mask cmd) cmd))

  ;; attempt : (-> A) -> (U A (List 'raised String))
  (define (attempt thunk)
    (guard (e (#t (list 'raised
                        (guard (e2 (#t "?"))
                          (call-with-string-output-port
                           (lambda (p)
                             (if (condition? e)
                                 (begin
                                   (when (who-condition? e) (write (condition-who e) p) (put-string p ": "))
                                   (when (message-condition? e) (put-string p (condition-message e)))
                                   (when (irritants-condition? e)
                                     (put-string p " ") (write (condition-irritants e) p)))
                                 (write e p))))))))
      (thunk)))

  ;; first-difference : (Listof Check) -> (U Check #f)
  (define (first-difference checks)
    (find (lambda (k) (not (equal? (cadr k) (caddr k)))) checks))

  ;; Report is #(Verdict Natural (Listof Key) (Listof (Pairof HowKey Natural)))
  ;;   verdict  'agree; or (List Natural (U Index #f) Symbol Any Any): the
  ;;            step at which the sides first differ (1-based; 0 is the
  ;;            start file), the actor, the comparison, the model's side and
  ;;            the real side; or (List 'raised String)
  ;;   steps    how many steps were replayed
  ;;   keys     (run? state-kind . event-kind) for each step, the event
  ;;            kind as the REAL outcome sorts it
  ;;   hows     (command-kind choice how) with how many steps took it
  ;;   offers   (command-kind choice) for every way the model offered a
  ;;            call to go at a step of this trace, taken or not
  ;; report-verdict : Report -> Verdict
  ;; report-steps : Report -> Natural
  ;; report-keys : Report -> (Listof (Pairof Boolean (Pairof Symbol Symbol)))
  ;; report-hows : Report -> (Listof (Pairof (List Symbol Symbol How) Natural))
  ;; report-offers : Report -> (Listof (List Symbol Symbol))
  (define (report-verdict r) (vector-ref r 0))
  (define (report-steps r) (vector-ref r 1))
  (define (report-keys r) (vector-ref r 2))
  (define (report-hows r) (vector-ref r 3))
  (define (report-offers r) (vector-ref r 4))

  ;; replay-trace : Config ReplayMachine Trace ReplayOptions String -> Report
  ;; The trace replayed on a real file at PATH (made first, its -wal and
  ;; -shm removed), against the model under RM's machine, whose six
  ;; procedures the real side runs too. Every connection is closed on the
  ;; way out.
  (define (replay-trace c rm trace opts path)
    (let ((r (make-run c rm trace opts path)))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (finish r (attempt (lambda () (run-replay r trace)))))
        (lambda () (close-all! r)))))

  ;; Run is the replay's state:
  ;;   #(config rm opts path shells dead fk actors keys hows steps offers)
  ;; actors: each actor's real (state . pending command)
  (define (make-run c rm trace opts path)
    (vector c rm opts path
            (vector (make-shell path 0) (make-shell path 0) (make-shell path 0))
            (make-vector 3 #f)
            ;; an actor whose COMMIT is to fail with its transaction open gets
            ;; foreign keys on, for a deferred key to fail it
            (map (lambda (i)
                   (and (exists (lambda (s) (and (= (step-who s) i)
                                                 (eq? (car (step-command s)) 'commit)
                                                 (eq? (step-choice s) 'fail)))
                                trace)
                        #t))
                 '(0 1 2))
            #f '() (make-hashtable equal-hash equal?) 0 (make-hashtable equal-hash equal?)))
  (define (run-config r) (vector-ref r 0))
  (define (run-rm r) (vector-ref r 1))
  (define (run-opts r) (vector-ref r 2))
  (define (run-path r) (vector-ref r 3))
  (define (run-shell r i) (vector-ref (vector-ref r 4) i))
  (define (run-dead? r i) (vector-ref (vector-ref r 5) i))
  (define (run-dead! r i) (vector-set! (vector-ref r 5) i #t))
  (define (run-fk? r i) (list-ref (vector-ref r 6) i))
  (define (run-actor r i) (vector-ref (vector-ref r 7) i))
  (define (run-actor-set! r i x) (vector-set! (vector-ref r 7) i x))
  (define (run-keys r) (vector-ref r 8))
  (define (run-hows r) (vector-ref r 9))
  (define (run-steps r) (vector-ref r 10))
  (define (count-step! r) (vector-set! r 10 (+ 1 (vector-ref r 10))))
  (define (add-key! r k) (vector-set! r 8 (cons k (vector-ref r 8))))
  (define (add-offer! r ok) (hashtable-set! (vector-ref r 11) ok #t))
  (define (add-how! r hk)
    (hashtable-set! (run-hows r) hk (+ 1 (hashtable-ref (run-hows r) hk 0))))

  ;; finish : Run Verdict -> Report
  (define (finish r verdict)
    (vector verdict (run-steps r) (reverse (run-keys r))
            (let-values (((ks vs) (hashtable-entries (run-hows r))))
              (map cons (vector->list ks) (vector->list vs)))
            (vector->list (hashtable-keys (vector-ref r 11)))))

  ;; close-all! : Run -> Void
  (define (close-all! r)
    (for-each (lambda (i)
                (unless (run-dead? r i)
                  (guard (e (#t #f)) (perform! (run-shell r i) '(close)))))
              '(0 1 2)))

  ;; actor-checks : Run World -> (Listof Check)
  ;; Each live actor's connection (open or not) and transaction flag.
  (define (actor-checks r w)
    (apply append
           (map (lambda (i)
                  (let ((a (world-actor w i)) (sh (run-shell r i)))
                    (if (or (not a) (run-dead? r i))
                        '()
                        (list (list 'connection (eq? (actor-conn a) 'none)
                                    (not (shell-database sh)))
                              (list 'transaction (actor-txn? a) (shell-txn? sh))))))
                '(0 1 2))))

  ;; run-replay : Run Trace -> Verdict
  (define (run-replay r trace)
    (let* ((c (run-config r)) (rm (run-rm r)) (m (replay-machine-model rm)))
      (build-start! (run-path r) (config-start-file c))
      (let ((d (first-difference (file-checks (run-path r) (config-start-file c)))))
        (if d
            (cons 0 (cons #f d))
            (let-values (((rs rc) ((rm-run-start rm))) ((cs cc) ((rm-check-start rm))))
              (vector-set! r 7 (vector (cons rs rc) (cons rs rc) (cons cs cc)))
              (let loop ((w (model-start c m)) (trace trace) (n 1))
                (if (null? trace)
                    'agree
                    (let ((out (replay-step r w (car trace))))
                      (if (and (pair? out) (eq? (car out) 'next))
                          (loop (cdr out) (cdr trace) (+ n 1))
                          (cons n (cons (step-who (car trace)) out)))))))))))

  ;; replay-step : Run World Step -> (U (Pairof 'next World) Check)
  ;; One step on both sides, from the model's world W before it: the world
  ;; after it, or the first comparison that differs.
  (define (replay-step r w s)
    (let* ((c (run-config r)) (rm (run-rm r)) (m (replay-machine-model rm))
           (who (step-who s)) (choice (step-choice s))
           (again (attempt (lambda () (model-apply c m w who choice))))
           (actor (run-actor r who)))
      (cond
       ((or (not (pair? again)) (eq? (car again) 'raised) (not (equal? (car again) s)))
        (list 'model-trace s again))
       ((not (equal? (mask-command (cdr actor)) (mask-command (step-command s))))
        (list 'command (step-command s) (cdr actor)))
       (else
        ;; In this order: Chez fixes no order for a call's arguments, and the
        ;; file and the actors are read only once the call is made.
        (let* ((calls (if (eq? choice 'die)
                          (begin (die! r who) '())
                          (call-checks r w s)))
               (files (file-checks (run-path r) (step-file s)))
               (actors (actor-checks r (cdr again)))
               (d (first-difference (append calls files actors))))
          (count-step! r)
          (or d (cons 'next (cdr again))))))))

  ;; die! : Run Index -> Void
  ;; One thread cannot kill a process. A death drops the connection with no
  ;; COMMIT, and closing the connection is how this thread drops it: SQLite
  ;; rolls back the open transaction and lets go of the lock, as the next
  ;; opener rolls back a dead process's. The model's death also runs no
  ;; checkpoint; a close may, which changes no content the observer reads.
  (define (die! r who)
    (let ((db (shell-database (run-shell r who))))
      (when db (guard (e (#t #f)) (close-database! db)))
      (run-dead! r who)))

  ;; call-checks : Run World Step -> (Listof Check)
  ;; The step's call made real, the real side stepped on the REAL outcome,
  ;; and the comparisons of outcome, event kind and next state.
  (define (call-checks r w s)
    (let* ((c (run-config r)) (rm (run-rm r)) (ms (config-migrations c))
           (who (step-who s)) (run? (< who 2)) (choice (step-choice s))
           (actor (run-actor r who)) (state (car actor)) (cmd (cdr actor))
           (out (realize c w who cmd choice (run-shell r who) (run-opts r) (run-fk? r who)))
           (raw (car out)) (mraw (step-raw s))
           (kind (attempt (lambda () ((if run? (rm-run-kind rm) (rm-check-kind rm)) ms state raw))))
           (next (attempt (lambda ()
                            (let-values (((s2 c2) ((if run? (rm-run-step rm) (rm-check-step rm))
                                                   ms state raw)))
                              (cons s2 c2))))))
      (for-each (lambda (ch) (add-offer! r (list (car cmd) ch))) (model-choices c w who cmd))
      (add-how! r (list (car cmd) choice (cdr out)))
      (add-key! r (cons run? (cons (car state) kind)))
      (when (and (pair? next) (not (eq? (car next) 'raised)))
        (run-actor-set! r who next))
      (append
       (list (list 'status (car mraw) (car raw))
             (list 'flag (caddr mraw) (caddr raw)))
       (cond ((and (eq? (car cmd) 'read-facts) (eq? (car mraw) 'ok))
              (list (list 'value (cadr mraw) (cadr raw))))
             ((and (eq? (car cmd) 'foreign-key-check) (eq? (car mraw) 'ok))
              (list (list 'value (null? (cadr mraw))
                          (and (list? (cadr raw)) (null? (cadr raw))))))
             (else '()))
       (list (list 'event (cdr (step-row s)) kind)
             (list 'state (mask (step-state s))
                   (if (and (pair? next) (not (eq? (car next) 'raised)))
                       (mask (car next))
                       next))))))
)
