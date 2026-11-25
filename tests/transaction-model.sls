#!r6rs
;;; (transaction-model): a pure model of the database file, its write lock,
;;; the doorway's write thread and one read thread with their connections,
;;; and another process beside them. Layer 3 of the slice 2b plan explores
;;; the real tables of (techo transaction) against it; layer 4 (task 4)
;;; replays its traces on real SQLite through job-perform!.
;;;
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path. Pure: no clock, no file, no SQLite, no thread. The one side effect
;;; is the observer a caller may pass to model-next.
;;;
;;; The shapes
;;; ----------
;;; Token   one write: job j's i-th write, j from 0 and i from 1, the integer
;;;         10j + i (write-token, token-job, token-write). A job has 1 to 9.
;;; File    #(writes version hash): the committed writes, oldest first, and
;;;         user_version. Interned: an equal file made again is the first.
;;; Thread  #(job state command box? conn txn? lock? unc snap commit-ok?
;;;           answered start-answered past? ran? hash)
;;;   job             the running job's place on its thread, from 0; the
;;;                   thread's job count once every job is done
;;;   state, command  the table's State and the Command it asked for, or #f
;;;                   for both once every job is done
;;;   box?            the thread's box holds its connection
;;;   conn            open (in the box), kept (a failed close left it open,
;;;                   the box empty all the same), none (closed)
;;;   txn?            a transaction is open on that connection
;;;   lock?           that transaction holds the write lock (the writer's)
;;;   unc             the transaction's uncommitted writes, in order
;;;   snap            #f, or the File the transaction reads: its snapshot
;;;   commit-ok?      ghost: the running job's COMMIT answered ok (T5)
;;;   answered        ghost: the thread's jobs that ended (answer), in order
;;;   start-answered  ghost, reader: how many write jobs had been answered
;;;                   when the running read job left start (T2)
;;;   past?           ghost, writer: the running job stepped out of
;;;                   beginning, and has not come back to start or
;;;                   beginning, nor ended (T1)
;;;   ran?            ghost: the running job's body returned with its
;;;                   transaction open, the one way to an answer (T2, T5)
;;; World   #(hash file writer reader olock budget bad)
;;;   olock   the other process holds the write lock
;;;   budget  how many more times it may take it
;;;   bad     the problems the step that made this world found: T2, T6
;;;           and T10 are read at a step (what a job's body saw, what ran on
;;;           an empty box), each (Symbol . String)
;;;
;;; A thread whose job reached `ended` keeps it for the one world in which
;;; it ended, where the invariant reads it; the next step, by anyone, first
;;; sweeps it on to its next job's start (or to done), keeping its box and
;;; connection: what a job leaves on the connection, the next job meets.
;;;
;;; What each command does
;;; ----------------------
;;; Every modelling decision is stated where it is made, in model-choices
;;; and perform, with what it rests on: the plan's clauses (`cl. N`, "What
;;; the model assumes"), the probes under build/probe-2b-sqlite/ (p1 to p8)
;;; and build/review-2b-plan/ (pa, pc) and build/review-2b-plan-2/ (h1 to
;;; h4), chez-sqlite3's close (its private/connection.sls), and circuit's
;;; properties as the plan lists them (S5, S14). In short:
;;; - busy only at BEGIN IMMEDIATE, and only while another holds the write
;;;   lock (cl. 1);
;;; - every statement may fail leaving its transaction open or ended, but
;;;   BEGIN fails with one open only when one was left open;
;;; - a COMMIT that fails may have taken effect, or not, or leave the
;;;   transaction open (cl. 3);
;;; - a job returns or raises with its transaction open, or ended by SQLite,
;;;   which then drops its uncommitted writes;
;;; - a close that fails may leave the connection open, holding what it
;;;   held; the box is empty either way;
;;; - a read transaction's snapshot is taken at its first read, the version
;;;   read (cl. 5);
;;; - the other process takes and frees the lock, and while holding it may
;;;   commit one version change (a migrate), between any two steps.
;;;
;;; Traces, for the replay (task 4)
;;; -------------------------------
;;; model-traces gives, for each row a configuration fires, keyed by the
;;; row's entry in write-row-names or read-row-names, (Name StateKind
;;; EventKind), a shortest trace to a step that fires it, carried on to a
;;; quiet world (nothing left to run) by always taking the first next step.
;;; A trace is a list of Steps from model-start. A Step:
;;;   step-who      writer, reader or other
;;;   step-job      the job's place on its thread, from 0; #f for other
;;;   step-choice   how the call went (below); for other: take, free, migrate
;;;   step-command  the Command carried out; for other: (take-lock),
;;;                 (free-lock), (migrate . v), v the version it commits
;;;   step-raw      the RawOutcome fed to the table, (status value open?)
;;;                 as the plan's RawOutcome; #f for other
;;;   step-row      the row's name, such as W11; #f for other
;;;   step-state    the thread's State after; #f for other
;;;   step-action   for (run-job), what the job did: (Tokens Ending Txn)
;;;                 with Tokens the writes it made, in order; Ending
;;;                 returned or raised; Txn open (the transaction still
;;;                 open), ended (SQLite ended it after those writes, with
;;;                 its next write: the writes are gone), or none (no
;;;                 transaction: each write committed at once). For other:
;;;                 its choice. Else #f.
;;;   step-file     the File after the step: file-writes, file-version. The
;;;                 replay compares it with what another connection reads.
;;;   step-saw      for (run-job), the File the job's body read: its
;;;                 snapshot inside a transaction, the file as it was
;;;                 without one. For a read job, what it saw; for a write
;;;                 job, what its writes went on top of. Else #f (and for a
;;;                 job with an empty box).
;;; The choices, by command (the replay stages each, or injects it):
;;;   (look)                 present absent
;;;   (begin-immediate)      ok busy failed-open failed-closed
;;;   (begin)                ok failed-open failed-closed
;;;   (read-version . v)     ok failed-open failed-closed
;;;   (run-job)              (Kind . k), Kind returned-open raised-open
;;;                          returned-closed raised-closed, k the writes
;;;                          made before (step-action spells it out)
;;;   (commit)               ok failed-open failed-closed (no effect)
;;;                          took-effect (failed, and committed)
;;;   (rollback)             ok failed-open failed-closed
;;;   (close)                ok failed-gone (closed, then raised)
;;;                          failed-kept (left open) failed-closed (no box)
;;; model-apply replays a step from its who and choice.
;;;
;;; The serve machine (machine 3) is explored by itself: serve-explore. Its
;;; world has the write worker, the hasher (slice 3b) and the read worker.
(library (transaction-model)
  (export
   ;; configurations
   make-config config-name config-writes config-reads config-takes
   config-migrate? config-latest config-model-mutant config-unchecked
   config-with-model-mutant config-with-unchecked config-with-cap
   ;; tokens and files
   write-token token-job token-write job-tokens file-writes file-version
   ;; machines
   make-job-machine real-machine table-machine machine-name
   named-rows model-job-command model-job-start make-model-job-stepper
   ;; worlds and threads
   model-start world-file world-thread world-olock world-budget world-bad
   thread-job thread-state thread-command thread-box? thread-conn thread-txn?
   thread-lock? thread-unc thread-snap thread-answered
   ;; semantics
   model-choices other-choices model-apply
   ;; exploration
   model-next model-invariant model-final model-explore
   ;; traces
   model-traces step-who step-job step-choice step-command step-raw
   step-row step-state step-action step-file step-saw
   ;; machine 3
   make-serve-machine serve-real-machine model-serve-command
   model-serve-start make-model-serve-stepper serve-explore)
  (import (rnrs)
          (techo machine)
          (techo transaction)
          (explore))

  ;;; Hashing: over the whole value, as Chez's equal-hash is not (traps.md)

  (define (mix h x) (mod (+ (* h 31) x) 536870909))
  (define (atom-code x)
    (cond ((eq? x #t) 1) ((eq? x #f) 2) ((null? x) 3)
          ((symbol? x) (mod (symbol-hash x) 16777213))
          ((string? x) (mod (string-hash x) 16777213))
          ((and (integer? x) (exact? x)) (mod x 16777213))
          (else (mod (equal-hash x) 16777213))))
  ;; deep-hash : Any Integer -> Integer
  (define (deep-hash x h)
    (cond ((pair? x) (deep-hash (cdr x) (deep-hash (car x) (mix h 5))))
          ((vector? x)
           (let loop ((i 0) (h (mix h 7)))
             (if (= i (vector-length x)) h (loop (+ i 1) (deep-hash (vector-ref x i) h)))))
          (else (mix h (atom-code x)))))

  (define (show x) (call-with-string-output-port (lambda (p) (write x p))))
  (define (join strs sep)
    (if (null? strs)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))
  ;; from-to : Integer Integer -> (Listof Integer)   A to B inclusive
  (define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))
  (define (take xs n) (if (or (= n 0) (null? xs)) '() (cons (car xs) (take (cdr xs) (- n 1)))))

  ;; Files and threads are interned: equal? on worlds, which tries eq? first
  ;; at each node, then mostly stops at once. A cache only: model-explore
  ;; and model-traces empty it.
  (define file-table (make-hashtable (lambda (f) (vector-ref f 2)) equal?))
  (define thread-table (make-hashtable (lambda (t) (vector-ref t 14)) equal?))
  (define (intern table x)
    (or (hashtable-ref table x #f)
        (begin (hashtable-set! table x x) x)))
  (define (forget!)
    (hashtable-clear! file-table)
    (hashtable-clear! thread-table))

  ;;; Tokens and files

  ;; write-token : Natural Positive-Integer -> Token
  (define (write-token j i)
    (unless (and (integer? i) (exact? i) (<= 1 i 9))
      (assertion-violation 'write-token "a job has 1 to 9 writes" i))
    (+ (* 10 j) i))
  ;; token-job : Token -> Natural
  (define (token-job t) (div t 10))
  ;; token-write : Token -> Positive-Integer
  (define (token-write t) (mod t 10))
  (define (show-token t)
    (string-append (number->string (token-job t)) "." (number->string (token-write t))))
  (define (show-tokens ts) (string-append "(" (join (map show-token ts) " ") ")"))

  (define (make-file writes version)
    (intern file-table (vector writes version (deep-hash version (deep-hash writes 11)))))
  ;; file-writes : File -> (Listof Token)    committed, oldest first
  (define (file-writes f) (vector-ref f 0))
  ;; file-version : File -> Integer          user_version
  (define (file-version f) (vector-ref f 1))
  (define (file-hash f) (vector-ref f 2))
  (define (file-add f toks)
    (if (null? toks) f (make-file (append (file-writes f) toks) (file-version f))))
  (define (show-file f)
    (string-append (show-tokens (file-writes f)) " at version "
                   (number->string (file-version f))))

  ;;; Configurations

  ;; Config is #(name writes reads takes migrate? latest mutant unchecked cap)
  ;;   writes    each write job's number of writes, in call order
  ;;   reads     how many read jobs the one read thread runs
  ;;   takes     how many times the other process may take the write lock
  ;;   migrate?  whether, holding it, it may commit a version change
  ;;   latest    this binary's latest version, 1: the shipped list's
  ;;   mutant    #f, or a model mutant, for the suite's own checks:
  ;;     no-snapshot     a read transaction never takes a snapshot: every
  ;;                     read sees the file as it is then
  ;;     busy-is-ok      BEGIN IMMEDIATE answers ok where busy would be
  ;;                     the answer, taking the lock beside its holder
  ;;     no-busy         BEGIN IMMEDIATE is never told busy: it can only
  ;;                     fail while another holds the lock
  ;;     live-handle     a job's handle lives on after SQLite ended its
  ;;                     transaction: its later writes commit one by one
  ;;     commit-drops    a COMMIT that answers ok writes nothing
  ;;     commit-doubles  a COMMIT that answers ok writes everything twice
  ;;     failed-commit-took-effect
  ;;                     a COMMIT that fails and ends its transaction has
  ;;                     always taken effect
  ;;   unchecked the properties not to check, as symbols (T1 ...): to see
  ;;             which others a mutant breaks. () by default.
  ;;   cap       #f, or the most worlds model-next may expand before it
  ;;             raises, so that a mutant whose graph is too big fails

  ;; make-config : Any (Listof Positive-Integer) Natural Natural Boolean -> Config
  (define (make-config name writes reads takes migrate?)
    (unless (and (list? writes)
                 (for-all (lambda (n) (and (integer? n) (exact? n) (<= 1 n 9))) writes))
      (assertion-violation 'make-config "each write job has 1 to 9 writes" writes))
    (unless (and (integer? reads) (exact? reads) (>= reads 0))
      (assertion-violation 'make-config "reads must be a Natural" reads))
    (unless (and (integer? takes) (exact? takes) (>= takes 0))
      (assertion-violation 'make-config "takes must be a Natural" takes))
    (vector name writes reads takes (and migrate? #t) 1 #f '() #f))

  ;; config-name : Config -> Any
  ;; config-writes : Config -> (Listof Positive-Integer)
  ;; config-reads : Config -> Natural
  ;; config-takes : Config -> Natural
  ;; config-migrate? : Config -> Boolean
  ;; config-latest : Config -> Natural
  ;; config-model-mutant : Config -> (U #f Symbol)
  ;; config-unchecked : Config -> (Listof Symbol)
  (define (config-name c) (vector-ref c 0))
  (define (config-writes c) (vector-ref c 1))
  (define (config-reads c) (vector-ref c 2))
  (define (config-takes c) (vector-ref c 3))
  (define (config-migrate? c) (vector-ref c 4))
  (define (config-latest c) (vector-ref c 5))
  (define (config-model-mutant c) (vector-ref c 6))
  (define (config-unchecked c) (vector-ref c 7))
  (define (config-cap c) (vector-ref c 8))
  (define (config-set c i x)
    (let ((v (vector-map (lambda (y) y) c))) (vector-set! v i x) v))
  ;; config-with-model-mutant : Config (U #f Symbol) -> Config
  (define (config-with-model-mutant c m) (config-set c 6 m))
  ;; config-with-unchecked : Config (Listof Symbol) -> Config
  (define (config-with-unchecked c ns) (config-set c 7 ns))
  ;; config-with-cap : Config (U #f Natural) -> Config
  (define (config-with-cap c n) (config-set c 8 n))

  (define (thread-count c who)
    (if (eq? who 'writer) (length (config-writes c)) (config-reads c)))
  ;; job-size : Config Who Natural -> Natural   a read job writes nothing
  (define (job-size c who j)
    (if (eq? who 'writer) (list-ref (config-writes c) j) 0))
  ;; job-tokens : Config Natural -> (Listof Token)   write job J's writes
  (define (job-tokens c j)
    (map (lambda (i) (write-token j i)) (from-to 1 (list-ref (config-writes c) j))))

  ;;; Machines

  ;; Machine is #(name wstart wstep wkind wnames rstart rstep rkind rnames)
  ;;   wstart, rstart : Natural -> (values State Command)
  ;;   wstep, rstep : State Event -> (values State Command)
  ;;   wkind, rkind : Command RawOutcome -> EventKind
  ;;   wnames, rnames : a table from (StateKind . EventKind) to the row's name
  (define (name-table names)
    (let ((h (make-hashtable equal-hash equal?)))
      (for-each (lambda (n) (hashtable-set! h (cons (cadr n) (caddr n)) (car n))) names)
      h))

  ;; make-job-machine : Any (Natural -> (values State Command)) Stepper Kind
  ;;                    (Listof (List Symbol StateKind EventKind))
  ;;                    (Natural -> (values State Command)) Stepper Kind
  ;;                    (Listof (List Symbol StateKind EventKind)) -> Machine
  ;; The write machine's start, step, event kind and row names, then the
  ;; read machine's.
  (define (make-job-machine name wstart wstep wkind wnames rstart rstep rkind rnames)
    (vector name wstart wstep wkind (name-table wnames)
            rstart rstep rkind (name-table rnames)))
  ;; machine-name : Machine -> Any
  (define (machine-name m) (vector-ref m 0))
  (define (machine-start m who) (vector-ref m (if (eq? who 'writer) 1 5)))
  (define (machine-step-of m who) (vector-ref m (if (eq? who 'writer) 2 6)))
  (define (machine-kind m who) (vector-ref m (if (eq? who 'writer) 3 7)))
  (define (row-name m who s e)
    (hashtable-ref (vector-ref m (if (eq? who 'writer) 4 8)) (cons s e) #f))

  ;; real-machine : Machine
  ;; (techo transaction)'s own tables, steppers and event kind, unmutated.
  (define real-machine
    (make-job-machine 'real write-start write-step job-event-kind write-row-names
                      read-start read-step job-event-kind read-row-names))

  ;; model-job-command : Symbol -> (State -> Command)
  ;; The command a job's state asks for, BEGIN-KIND being what the table
  ;; begins with. A copy of (techo transaction)'s job-command, which it does
  ;; not export; the suite holds the copy to the library's steppers.
  (define (model-job-command begin-kind)
    (lambda (s)
      (case (car s)
        ((start) (list 'look))
        ((beginning) (list begin-kind))
        ((versioning) (cons 'read-version (car (cdr s))))
        ((running) (list 'run-job))
        ((committing) (list 'commit))
        ((rolling-back ending) (list 'rollback))
        ((closing) (list 'close))
        ((ended) (cons 'end (cdr s)))
        (else (assertion-violation 'model-job-command "not a state" s)))))

  ;; model-job-start : (State -> Command) -> (Natural -> (values State Command))
  ;; As write-start and read-start: `start`, carrying latest and nothing
  ;; pending.
  (define (model-job-start command-of)
    (lambda (latest)
      (let ((s (cons 'start (list latest #f))))
        (values s (command-of s)))))

  ;; make-model-job-stepper : (Listof Row) (State -> Command)
  ;;                          -> (State Event -> (values State Command))
  ;; A step function over ROWS, made as (techo transaction) makes its own:
  ;; the command is COMMAND-OF the next state, and must be of the row's
  ;; command kind.
  (define (make-model-job-stepper rows command-of)
    (let ((m (make-machine rows)))
      (lambda (state event)
        (let-values (((next row-command) (machine-step m state event)))
          (let ((cmd (command-of next)))
            (unless (eq? (car cmd) (car row-command))
              (assertion-violation 'model-job-stepper
                "the row's command kind is not the next state's"
                (car state) (car event) (car row-command) (car cmd)))
            (values next cmd))))))

  ;; named-rows : (Listof Row) (Listof (List Symbol StateKind EventKind))
  ;;              -> (Listof NamedRow)
  ;; NamedRow is (Name StateKind EventKind StateKind CommandKind Update):
  ;; each row with its name in front, from the library's two lists.
  (define (named-rows rows names)
    (map (lambda (r n)
           (unless (and (eq? (car r) (cadr n)) (eq? (cadr r) (caddr n)))
             (assertion-violation 'named-rows "the names are not the rows'" r n))
           (cons (car n) r))
         rows names))

  ;; table-machine : Any (Listof NamedRow) (Listof NamedRow)
  ;;                 (State -> Command) (State -> Command) Kind Kind -> Machine
  ;; A machine from two named tables, each stepped by make-model-job-stepper
  ;; with its command function, and sorted by its event kind function.
  (define (table-machine name wtable rtable wcommand rcommand wkind rkind)
    (define (names t) (map (lambda (r) (list (car r) (cadr r) (caddr r))) t))
    (make-job-machine name (model-job-start wcommand)
                      (make-model-job-stepper (map cdr wtable) wcommand) wkind
                      (names wtable)
                      (model-job-start rcommand)
                      (make-model-job-stepper (map cdr rtable) rcommand) rkind
                      (names rtable)))

  ;;; Threads

  (define f-job 0) (define f-state 1) (define f-cmd 2) (define f-box 3)
  (define f-conn 4) (define f-txn 5) (define f-lock 6) (define f-unc 7)
  (define f-snap 8) (define f-ok 9) (define f-answered 10) (define f-start 11)
  (define f-past 12) (define f-ran 13) (define f-hash 14)

  (define (thread-hash-of v)
    (let loop ((i 0) (h 13))
      (cond ((= i f-hash) h)
            ((= i f-snap)
             (loop (+ i 1) (mix h (let ((s (vector-ref v i))) (if s (file-hash s) 0)))))
            (else (loop (+ i 1) (deep-hash (vector-ref v i) h))))))
  (define (seal! v)
    (vector-set! v f-hash (thread-hash-of v))
    (intern thread-table v))
  (define (new-thread job state cmd)
    (seal! (vector job state cmd #t 'open #f #f '() #f #f '() #f #f #f 0)))
  ;; thread-update : Thread Index Any ... -> Thread
  (define (thread-update t . kvs)
    (let ((v (vector-map (lambda (x) x) t)))
      (let loop ((kvs kvs))
        (unless (null? kvs)
          (vector-set! v (car kvs) (cadr kvs))
          (loop (cddr kvs))))
      (seal! v)))
  (define (thread-hash t) (vector-ref t f-hash))

  ;; thread-job : Thread -> Natural
  ;; thread-state : Thread -> (U State #f)
  ;; thread-command : Thread -> (U Command #f)
  ;; thread-box? : Thread -> Boolean
  ;; thread-conn : Thread -> (U 'open 'kept 'none)
  ;; thread-txn? : Thread -> Boolean
  ;; thread-lock? : Thread -> Boolean
  ;; thread-unc : Thread -> (Listof Token)
  ;; thread-snap : Thread -> (U File #f)
  ;; thread-answered : Thread -> (Listof Natural)
  (define (thread-job t) (vector-ref t f-job))
  (define (thread-state t) (vector-ref t f-state))
  (define (thread-command t) (vector-ref t f-cmd))
  (define (thread-box? t) (vector-ref t f-box))
  (define (thread-conn t) (vector-ref t f-conn))
  (define (thread-txn? t) (vector-ref t f-txn))
  (define (thread-lock? t) (vector-ref t f-lock))
  (define (thread-unc t) (vector-ref t f-unc))
  (define (thread-snap t) (vector-ref t f-snap))
  (define (thread-commit-ok? t) (vector-ref t f-ok))
  (define (thread-answered t) (vector-ref t f-answered))
  (define (thread-start-answered t) (vector-ref t f-start))
  (define (thread-past? t) (vector-ref t f-past))
  (define (thread-ran? t) (vector-ref t f-ran))
  (define (thread-kind t) (let ((s (thread-state t))) (and s (car s))))

  ;; the transaction gone: its writes, lock and snapshot with it
  (define (txn-ended t)
    (thread-update t f-txn #f f-lock #f f-unc '() f-snap #f))
  ;; the connection closed: it drops its transaction (cl. 4)
  (define (conn-closed t)
    (thread-update t f-box #f f-conn 'none f-txn #f f-lock #f f-unc '() f-snap #f))

  ;;; Worlds

  (define (make-world f wr rd olock budget bad)
    (vector (mix (mix (mix (mix (mix (mix 19 (file-hash f)) (thread-hash wr))
                                (thread-hash rd))
                           (atom-code olock))
                      budget)
                 (deep-hash bad 0))
            f wr rd olock budget bad))
  (define (world-hash w) (vector-ref w 0))
  ;; world-file : World -> File
  ;; world-thread : World (U 'writer 'reader) -> Thread
  ;; world-olock : World -> Boolean
  ;; world-budget : World -> Natural
  ;; world-bad : World -> (Listof (Pairof Symbol String))
  (define (world-file w) (vector-ref w 1))
  (define (world-thread w who) (vector-ref w (if (eq? who 'writer) 2 3)))
  (define (world-olock w) (vector-ref w 4))
  (define (world-budget w) (vector-ref w 5))
  (define (world-bad w) (vector-ref w 6))
  (define (world-with w f who t bad)
    (make-world f
                (if (eq? who 'writer) t (world-thread w 'writer))
                (if (eq? who 'reader) t (world-thread w 'reader))
                (world-olock w) (world-budget w) bad))

  ;; first-thread : Config Machine Who -> Thread
  (define (first-thread c m who)
    (if (= (thread-count c who) 0)
        (new-thread 0 #f #f)
        (let-values (((s cmd) ((machine-start m who) (config-latest c))))
          (new-thread 0 s cmd))))

  ;; model-start : Config Machine -> World
  ;; The file holds nothing, at this binary's latest version: serve's check
  ;; and the set-up's let nothing else start (S2, the set-up's verdict).
  ;; Each thread's box holds an open connection, and no transaction.
  (define (model-start c m)
    (make-world (make-file '() (config-latest c))
                (first-thread c m 'writer) (first-thread c m 'reader)
                #f (config-takes c) '()))

  ;;; The commands

  (define statement-kinds
    '(begin-immediate begin read-version run-job commit rollback close))

  ;; model-choices : Config World (U 'writer 'reader) -> (Listof Choice)
  ;; The ways the thread's command can go in W, nominal first. None once the
  ;; thread is done, or at (end . _), which is not a call.
  (define (model-choices c w who)
    (let* ((t (world-thread w who)) (cmd (thread-command t)))
      (if (not cmd)
          '()
          (let ((k (car cmd)) (box (thread-box? t)) (txn (thread-txn? t))
                (mutant (config-model-mutant c)))
            (case k
              ;; The box is the thread's own state, handed unchanged to each
              ;; job (circuit, as the plan lists it): looking cannot fail.
              ((look) (if box '(present) '(absent)))
              ((begin-immediate begin)
               (cond
                ;; No connection to run it on: the shell's call raises.
                ((not box) '(failed-closed))
                ;; "cannot start a transaction within a transaction", the
                ;; one open left as it was (h1 4). Only then can BEGIN fail
                ;; with a transaction open: none is opened by a failure.
                (txn '(failed-open))
                ;; Busy only at BEGIN IMMEDIATE on the read-write
                ;; connection, while another holds the write lock (cl. 1;
                ;; pa 3: no transaction is open after it). A plain BEGIN
                ;; takes no lock, and on a read-only connection neither
                ;; does BEGIN IMMEDIATE (pa 2), so neither is ever busy.
                ;; Busy that waited and then got the lock is the other
                ;; process freeing it first: an interleaving of its own.
                ((and (eq? k 'begin-immediate) (eq? who 'writer) (world-olock w))
                 (case mutant
                   ((busy-is-ok) '(ok failed-closed))
                   ((no-busy) '(failed-closed))
                   (else '(busy failed-closed))))
                ;; A BEGIN may still fail, with nothing begun: an I/O error
                ;; at the lock, or a broken connection.
                (else '(ok failed-closed))))
              ((read-version)
               (cond ((not box) '(failed-closed))
                     ;; A read fails leaving its transaction open (an
                     ;; interrupted read, p6) or ended (an I/O error SQLite
                     ;; rolls back). Never busy: a read in WAL waits for no
                     ;; lock (cl. 6), and the writer's snapshot is held
                     ;; from its BEGIN IMMEDIATE on.
                     (txn '(ok failed-open failed-closed))
                     (else '(ok failed-closed))))
              ((run-job) (job-choices c w who t))
              ((commit)
               (cond ((not box) '(failed-closed))
                     ;; ok; refused by a deferred foreign key, the
                     ;; transaction still open (cl. 3, pa 4); failed and
                     ;; ended with nothing committed (SQLite rolls back on a
                     ;; full disk); failed, ended, and committed (the plan:
                     ;; a failed COMMIT is a "maybe", W17 either way).
                     ;; Never busy: in WAL that means a statement of the
                     ;; connection's own is unfinished (pc), which the
                     ;; handle rules out (cl. 10).
                     (txn (if (eq? mutant 'failed-commit-took-effect)
                              '(ok failed-open took-effect)
                              '(ok failed-open failed-closed took-effect)))
                     ;; "cannot commit - no transaction is active" (h1 2)
                     (else '(failed-closed))))
              ((rollback)
               (cond ((not box) '(failed-closed))
                     ;; A ROLLBACK that fails may leave the transaction open
                     ;; or end it. Not staged by any probe: offered, as
                     ;; slice 2's model does, so that W19, W20, R15 and R16
                     ;; are explored. Never busy, for COMMIT's reason.
                     (txn '(ok failed-open failed-closed))
                     ;; "cannot rollback - no transaction is active" (h1 2)
                     (else '(failed-closed))))
              ((close)
               ;; chez-sqlite3's close (private/connection.sls): it
               ;; finalizes what it tracks, then sqlite3_close. On
               ;; SQLITE_OK the connection is closed, and a finalize's
               ;; failure is raised after (failed-gone); on any other
               ;; answer the connection stays open, holding what it held,
               ;; and the close raises (failed-kept). The box is emptied
               ;; either way (the plan's RawOutcome for (close)).
               (if box '(ok failed-gone failed-kept) '(failed-closed)))
              ((end) '())
              (else (assertion-violation 'model-choices "not a command" cmd)))))))

  ;; can-take-lock? : World Thread -> Boolean
  ;; A deferred transaction's first write takes the write lock, unless
  ;; another holds it (busy) or the file changed since its snapshot
  ;; (busy-snapshot): pa 6, each leaving the transaction open.
  (define (can-take-lock? w t)
    (and (not (world-olock w))
         (let ((s (thread-snap t))) (or (not s) (eq? s (world-file w))))))

  ;; job-choices : Config World Who Thread -> (Listof Choice)
  ;; How (run-job) can go. A write job of n writes either makes them all and
  ;; returns, or raises after k of them, k from 0 to n, its transaction
  ;; open; or SQLite ends its transaction with a write after k of them, and
  ;; the job raises, or catches that raise and returns (an interrupt, a full
  ;; disk, INSERT OR ROLLBACK: p6, h1 2). The handle refuses every later
  ;; call (D11), so nothing it writes after lands; and it refuses COMMIT and
  ;; ROLLBACK (D11's forbidden words), so a job's transaction never ends by
  ;; the job's hand. A job that swallows its own failed write and returns is,
  ;; to the doorway, a job of fewer writes: no other configuration is needed
  ;; for it. A read job writes nothing.
  (define (job-choices c w who t)
    (let ((n (job-size c who (thread-job t))) (txn (thread-txn? t)))
      (define (each kind lo hi) (map (lambda (k) (cons kind k)) (from-to lo hi)))
      (cond
       ((not (thread-box? t)) (list (cons 'raised-closed 0)))
       ((eq? who 'reader)
        (if txn
            (list '(returned-open . 0) '(raised-open . 0)
                  '(returned-closed . 0) '(raised-closed . 0))
            (list '(returned-closed . 0) '(raised-closed . 0))))
       ((and txn (or (thread-lock? t) (can-take-lock? w t)))
        (append (list (cons 'returned-open n)) (each 'raised-open 0 n)
                (each 'returned-closed 0 n) (each 'raised-closed 0 n)))
       ;; a deferred transaction that cannot take the lock: its first write
       ;; is busy, and the job raises with the transaction open (pa 6)
       (txn (list (cons 'raised-open 0)))
       ;; no transaction: each write commits at once (autocommit), busy
       ;; while another holds the lock
       ((world-olock w) (list (cons 'raised-closed 0)))
       (else (cons (cons 'returned-closed n) (each 'raised-closed 0 (- n 1)))))))

  ;; perform : Config World Who Choice
  ;;           -> (values File Thread RawOutcome Action Saw Problems)
  ;; The file and the thread after the call, the outcome, what a job did
  ;; and saw (for the trace), and what it broke that only a step shows: T2,
  ;; T6 and T10. The thread's state and command are left as they were: the
  ;; caller steps the table.
  (define (perform c w who choice)
    (let* ((t (world-thread w who)) (cmd (thread-command t)) (k (car cmd))
           (f (world-file w)) (box (thread-box? t)) (txn (thread-txn? t))
           (j (thread-job t)) (L (config-latest c)) (mutant (config-model-mutant c))
           (t10 (if (and (not box) (memq k statement-kinds))
                    (list (cons 'T10 (string-append "T10: the " (symbol->string who)
                                                    " ran " (show cmd) " in job "
                                                    (number->string j)
                                                    " with its box empty")))
                    '())))
      (define (out f2 t2 raw action saw problems)
        (values f2 t2 raw action saw (append t10 problems)))
      (define (bad) (assertion-violation 'model-perform "not a choice here" cmd choice))
      (define (no-conn-or why) (if box why "no connection"))
      ;; the snapshot a read takes, if it is the transaction's first (cl. 5)
      (define snap
        (or (thread-snap t)
            (and txn (not (eq? mutant 'no-snapshot)) f)))
      (case k
        ((look)
         (case choice
           ((present absent) (out f t (list choice #f #f) #f #f '()))
           (else (bad))))
        ((begin-immediate begin)
         (case choice
           ;; BEGIN IMMEDIATE on the read-write connection takes the lock
           ;; and reads from then on one snapshot: the file as it is, which
           ;; no one else can commit to while the lock is held (cl. 1). On
           ;; the read-only connection it takes no lock, and its snapshot is
           ;; the BEGIN's (pa 2: a commit after it is not seen). A plain
           ;; BEGIN takes neither: the snapshot waits for the first read.
           ((ok) (out f (thread-update t f-txn #t
                                      f-lock (and (eq? k 'begin-immediate) (eq? who 'writer))
                                      f-unc '()
                                      f-snap (and (eq? k 'begin-immediate) f))
                      '(ok #t #t) #f #f '()))
           ((busy) (out f t '(busy "database is locked" #f) #f #f '()))
           ((failed-open)
            (out f t '(failed "cannot start a transaction within a transaction" #t)
                 #f #f '()))
           ((failed-closed) (out f t (list 'failed (no-conn-or "disk I/O error") #f)
                                 #f #f '()))
           (else (bad))))
        ((read-version)
         (let ((view (if txn (or snap f) f)))
           (case choice
             ;; The version read is the transaction's first read, so the
             ;; snapshot is taken here (cl. 5, pa 1). Outside a transaction
             ;; it reads the file as it is, and open? is #f.
             ((ok) (out f (if txn (thread-update t f-snap snap) t)
                        (list 'ok (file-version view) txn) #f #f '()))
             ((failed-open) (out f t '(failed "disk I/O error" #t) #f #f '()))
             ((failed-closed)
              (out f (if txn (txn-ended t) t)
                   (list 'failed (no-conn-or "disk I/O error") #f) #f #f '()))
             (else (bad)))))
        ((run-job) (perform-job c w who choice t f snap out bad))
        ((commit)
         (case choice
           ;; A commit is whole (cl. 2): the transaction's writes are
           ;; appended to the file, in order, and the lock is free.
           ((ok)
            (let ((f2 (case mutant
                        ((commit-drops) f)
                        ((commit-doubles) (file-add (file-add f (thread-unc t))
                                                    (thread-unc t)))
                        (else (file-add f (thread-unc t))))))
              (out f2 (thread-update (txn-ended t) f-ok #t) '(ok #t #f) #f #f '())))
           ((failed-open)
            (out f t '(failed "FOREIGN KEY constraint failed" #t) #f #f '()))
           ((failed-closed)
            (out f (if txn (txn-ended t) t)
                 (list 'failed (no-conn-or (if txn "disk I/O error"
                                               "cannot commit - no transaction is active"))
                       #f)
                 #f #f '()))
           ((took-effect)
            (out (file-add f (thread-unc t)) (txn-ended t)
                 '(failed "disk I/O error" #f) #f #f '()))
           (else (bad))))
        ((rollback)
         (case choice
           ;; A rollback leaves nothing (cl. 2).
           ((ok) (out f (txn-ended t) '(ok #t #f) #f #f '()))
           ((failed-open) (out f t '(failed "disk I/O error" #t) #f #f '()))
           ((failed-closed)
            (out f (if txn (txn-ended t) t)
                 (list 'failed (no-conn-or (if txn "disk I/O error"
                                               "cannot rollback - no transaction is active"))
                       #f)
                 #f #f '()))
           (else (bad))))
        ((close)
         (case choice
           ((ok) (out f (conn-closed t) '(ok #t #f) #f #f '()))
           ((failed-gone)
            (out f (conn-closed t) '(failed "a statement's finalize failed" #f) #f #f '()))
           ((failed-kept)
            (out f (thread-update t f-box #f f-conn 'kept)
                 '(failed "unable to close due to unfinalized statements" #f) #f #f '()))
           ((failed-closed) (out f t '(failed "no connection" #f) #f #f '()))
           (else (bad))))
        (else (assertion-violation 'model-perform "not a shell call" cmd)))))

  ;; perform-job : the (run-job) case of perform.
  (define (perform-job c w who choice t f snap out bad)
    (unless (and (pair? choice) (memq (car choice) '(returned-open raised-open
                                                     returned-closed raised-closed)))
      (bad))
    (let* ((kind (car choice)) (k (cdr choice)) (j (thread-job t))
           (n (job-size c who j)) (L (config-latest c)) (txn (thread-txn? t))
           (box (thread-box? t))
           (returned? (and (memq kind '(returned-open returned-closed)) #t))
           (open? (and (memq kind '(returned-open raised-open)) #t))
           (made (if (eq? who 'writer) (map (lambda (i) (write-token j i)) (from-to 1 k)) '()))
           (raw (list (if returned? 'returned 'raised)
                      (if returned? (list who j) "the job raised")
                      open?))
           (action (list made (if returned? 'returned 'raised)
                         (cond (open? 'open) (txn 'ended) (else 'none))))
           (view (if txn (or snap f) f))
           (label (string-append (if (eq? who 'writer) "write" "read") " job "
                                 (number->string j))))
      ;; T6: the body runs inside a transaction, at this binary's version.
      (define t6
        (cond ((not box) '())
              ((not txn)
               (list (cons 'T6 (string-append "T6: " label
                                              "'s body runs with no transaction open"))))
              ((not (= (file-version view) L))
               (list (cons 'T6 (string-append "T6: " label "'s body runs at version "
                                              (number->string (file-version view))
                                              ", not " (number->string L)))))
              (else '())))
      ;; T2: a read job sees every write answered before it left start. The
      ;; answer exists only once its job's table reached `ended` (circuit's
      ;; S14), which is when the writer's ghost records it.
      (define t2
        (if (and box (eq? who 'reader))
            (let* ((answered (take (thread-answered (world-thread w 'writer))
                                   (or (thread-start-answered t) 0)))
                   (missed (filter (lambda (aj)
                                     (not (for-all (lambda (tok) (memv tok (file-writes view)))
                                                   (job-tokens c aj))))
                                   answered)))
              (if (null? missed)
                  '()
                  (list (cons 'T2 (string-append "T2: " label " left start after write job "
                                                 (number->string (car missed))
                                                 " was answered, and saw "
                                                 (show-file view))))))
            '()))
      (cond
       ((not box) (out f t raw (list '() 'raised 'none) #f '()))
       ((eq? who 'reader)
        (cond ((and open? (not txn)) (bad))
              (else (out f (if open? (thread-update t f-snap snap f-ran returned?) (txn-ended t))
                         raw action view (append t6 t2)))))
       (txn
        (let ((t1 (if (thread-lock? t)
                      t
                      ;; a deferred transaction's first write takes the lock
                      (if (can-take-lock? w t)
                          (thread-update t f-lock #t f-snap snap)
                          t))))
          (cond
           ((and (not (thread-lock? t1)) (not (and (eq? kind 'raised-open) (= k 0))))
            (bad))
           ((> k n) (bad))
           (open?
            (out f (thread-update t1 f-unc (append (thread-unc t1) made) f-ran returned?)
                 raw action view t6))
           (else
            ;; SQLite ended the transaction with the job's write k + 1: its
            ;; writes are gone. With a live handle, the job's writes after
            ;; that one commit at once, one by one.
            (let ((after (if (eq? (config-model-mutant c) 'live-handle)
                             (map (lambda (i) (write-token j i)) (from-to (+ k 2) n))
                             '())))
              (out (file-add f after) (txn-ended t1) raw action view t6))))))
       (else
        ;; no transaction: each write the job made has committed
        (cond ((or open? (> k n)) (bad))
              (else (out (file-add f made) t raw action view t6)))))))

  ;;; The other process

  ;; other-choices : Config World -> (Listof Symbol)
  ;; What the other process may do: take the write lock, if no one holds it
  ;; and its budget allows; free it; or, holding it, commit one version
  ;; change, latest + 1, which frees it (a migrate beside the server, D6:
  ;; probed to commit with the server's connections open, p7). Readers never
  ;; wait for it (cl. 6), and it waits for no reader.
  (define (other-choices c w)
    (let ((olock (world-olock w))
          (wlock (thread-lock? (world-thread w 'writer))))
      (append (if (and (not olock) (not wlock) (> (world-budget w) 0)) '(take) '())
              (if olock '(free) '())
              (if (and olock (config-migrate? c)
                       (= (file-version (world-file w)) (config-latest c)))
                  '(migrate)
                  '()))))

  (define (other-move c w choice)
    (unless (memq choice (other-choices c w))
      (assertion-violation 'model-apply "not a step of the other process here" choice))
    (let* ((f (world-file w))
           (f2 (if (eq? choice 'migrate) (make-file (file-writes f) (+ (file-version f) 1)) f))
           (w2 (make-world f2 (world-thread w 'writer) (world-thread w 'reader)
                           (eq? choice 'take)
                           (if (eq? choice 'take) (- (world-budget w) 1) (world-budget w))
                           '()))
           (cmd (case choice
                  ((take) '(take-lock))
                  ((free) '(free-lock))
                  (else (cons 'migrate (file-version f2))))))
      (cons (make-step 'other #f choice cmd #f #f #f choice f2 #f) w2)))

  ;;; Steps

  ;; Step is (List Who Job Choice Command Raw Row State Action File Saw)
  ;; step-who : Step -> (U 'writer 'reader 'other)
  ;; step-job : Step -> (U Natural #f)
  ;; step-choice : Step -> Choice
  ;; step-command : Step -> Command
  ;; step-raw : Step -> (U RawOutcome #f)
  ;; step-row : Step -> (U Symbol #f)
  ;; step-state : Step -> (U State #f)
  ;; step-action : Step -> Any
  ;; step-file : Step -> File
  ;; step-saw : Step -> (U File #f)
  (define (make-step who job choice cmd raw row state action file saw)
    (list who job choice cmd raw row state action file saw))
  (define (step-who s) (list-ref s 0))
  (define (step-job s) (list-ref s 1))
  (define (step-choice s) (list-ref s 2))
  (define (step-command s) (list-ref s 3))
  (define (step-raw s) (list-ref s 4))
  (define (step-row s) (list-ref s 5))
  (define (step-state s) (list-ref s 6))
  (define (step-action s) (list-ref s 7))
  (define (step-file s) (list-ref s 8))
  (define (step-saw s) (list-ref s 9))

  (define (filter-unchecked c problems)
    (filter (lambda (p) (not (memq (car p) (config-unchecked c)))) problems))

  ;; move : Config Machine (U #f Observer) World Who Choice -> (Pairof Step World)
  ;; The thread's call carried out the way CHOICE says, and its table
  ;; stepped on the event job-event-kind (or the machine's kind) sorts.
  (define (move c m observe w who choice)
    (let* ((t (world-thread w who)) (cmd (thread-command t)) (state (thread-state t)))
      (let-values (((f2 t2 raw action saw problems) (perform c w who choice)))
        (let ((kind ((machine-kind m who) cmd raw)))
          (let-values (((s2 cmd2) ((machine-step-of m who) state (cons kind raw))))
            (let* ((name (row-name m who (car state) kind))
                   (ended-answer (and (eq? (car s2) 'ended) (equal? (cdr s2) '(answer))))
                   (t3 (thread-update
                        t2 f-state s2 f-cmd cmd2
                        f-start (if (and (eq? who 'reader) (eq? (car state) 'start))
                                    (length (thread-answered (world-thread w 'writer)))
                                    (thread-start-answered t2))
                        f-past (and (not (memq (car s2) '(start beginning ended)))
                                    (or (thread-past? t2) (eq? (car state) 'beginning)))
                        f-answered (if ended-answer
                                       (append (thread-answered t2) (list (thread-job t2)))
                                       (thread-answered t2))))
                   (w2 (world-with w f2 who t3 (filter-unchecked c problems))))
              (when observe (observe (list name (car state) kind)))
              (cons (make-step who (thread-job t) choice cmd raw name s2 action f2 saw)
                    w2)))))))

  ;; sweep : Config Machine World -> World
  ;; Each thread whose job ended moves to its next job's start, or to done,
  ;; keeping its box and connection, and leaving the job's ghosts behind but
  ;; the answers. Jobs on one thread run in call order (circuit's S5), and
  ;; a thread takes its next job as soon as it is free.
  (define (sweep c m w)
    (define (next t who)
      (if (eq? (thread-kind t) 'ended)
          (let ((j2 (+ (thread-job t) 1)))
            (if (< j2 (thread-count c who))
                (let-values (((s cmd) ((machine-start m who) (config-latest c))))
                  (thread-update t f-job j2 f-state s f-cmd cmd f-ok #f f-start #f f-past #f
                                 f-ran #f))
                (thread-update t f-job j2 f-state #f f-cmd #f f-ok #f f-start #f f-past #f
                               f-ran #f)))
          t))
    (let* ((wr (world-thread w 'writer)) (rd (world-thread w 'reader))
           (wr2 (next wr 'writer)) (rd2 (next rd 'reader)))
      (if (and (eq? wr wr2) (eq? rd rd2))
          w
          (make-world (world-file w) wr2 rd2 (world-olock w) (world-budget w)
                      (world-bad w)))))

  (define (nominal-choice? ch)
    (or (and (memq ch '(present ok)) #t)
        (and (pair? ch) (eq? (car ch) 'returned-open))))
  ;; nominal-choices : (Listof Choice) -> (Listof Choice)
  ;; The nominal ways, or with none, the first: a failure the call cannot
  ;; escape, the machine's own doing and not an injected one.
  (define (nominal-choices cs)
    (let ((ns (filter nominal-choice? cs)))
      (if (pair? ns) ns (if (pair? cs) (list (car cs)) '()))))

  ;; model-next : Config Machine (U #f Observer) Boolean
  ;;              -> (World -> (Listof (Pairof Step World)))
  ;; Observer is ((List Symbol StateKind EventKind) -> Any): told the row
  ;; each step fires, as write-row-names and read-row-names list it.
  ;; The explorer's next worlds: the writer's call, every way it can go;
  ;; the reader's; the other process's moves. With NOMINAL, every call goes
  ;; its nominal way and the other process does nothing. None once both
  ;; threads are done: the other process's moves then change nothing a
  ;; property reads.
  ;; One reduction: while the writer asks (look), its steps are the only
  ;; next steps. The look reads the writer's own box, which only the writer
  ;; changes, and moves it from start to beginning or ended, which nothing
  ;; but the writer reads; so it commutes with every other step, and every
  ;; other step still lands before and after each of the writer's.
  ;; (The reader's look is not reduced: T2's ghost is read when the reader
  ;; leaves start.)
  (define (model-next c m observe nominal)
    (define expanded 0)
    (lambda (w0)
      (when (config-cap c)
        (set! expanded (+ expanded 1))
        (when (> expanded (config-cap c))
          (assertion-violation 'model-next "more worlds than the cap" (config-cap c))))
      (let* ((w (sweep c m w0)) (wr (world-thread w 'writer)) (rd (world-thread w 'reader)))
        (define (moves who)
          (let ((cs (model-choices c w who)))
            (map (lambda (ch) (move c m observe w who ch))
                 (if nominal (nominal-choices cs) cs))))
        (cond
         ((and (not (thread-command wr)) (not (thread-command rd))) '())
         ((and (thread-command wr) (eq? (car (thread-command wr)) 'look)) (moves 'writer))
         (else
          (append (moves 'writer) (moves 'reader)
                  (if nominal
                      '()
                      (map (lambda (ch) (other-move c w ch)) (other-choices c w)))))))))

  ;; model-apply : Config Machine World (U 'writer 'reader 'other) Choice
  ;;               -> (Pairof Step World)
  ;; One step, as model-next takes it, after the sweep. Replaying a trace is
  ;; applying each step's who and choice in turn from model-start; each
  ;; answer's Step is then equal? to the trace's. Raises on a step that is
  ;; not one here.
  (define (model-apply c m w0 who choice)
    (let ((w (sweep c m w0)))
      (if (eq? who 'other)
          (other-move c w choice)
          (begin
            (unless (member choice (model-choices c w who))
              (assertion-violation 'model-apply "not a step here" who choice))
            (move c m #f w who choice)))))

  ;;; The properties

  (define property-order '(model T1 T2 T4 T5 T6 T9 T10 N1 stuck))
  (define (rank p) (let loop ((ps property-order) (i 0))
                     (cond ((null? ps) i) ((eq? (car ps) p) i) (else (loop (cdr ps) (+ i 1))))))
  ;; report : Config (Listof (Pairof Symbol String)) -> (U #f String)
  ;; The problems not unchecked, in the order of property-order, joined by
  ;; " | ", each message beginning with its property's name.
  (define (report c problems)
    (let ((ps (filter-unchecked c problems)))
      (if (null? ps)
          #f
          (join (map cdr (list-sort (lambda (a b) (< (rank (car a)) (rank (car b)))) ps))
                " | "))))

  (define past-beginning '(versioning running committing rolling-back closing))

  ;; file-problems : Config File -> (Listof (Pairof Symbol String))
  ;; T4: every write job's writes are in the file all or none, each once.
  (define (file-problems c f)
    (let ((ws (file-writes f)) (out '()))
      (let loop ((l ws))
        (unless (null? l)
          (when (memv (car l) (cdr l))
            (set! out (cons (cons 'T4 (string-append "T4: write " (show-token (car l))
                                                     " is in the file twice: "
                                                     (show-file f)))
                            out)))
          (loop (cdr l))))
      (let loop ((j 0) (ns (config-writes c)))
        (unless (null? ns)
          (let ((have (length (filter (lambda (tok) (memv tok ws)) (job-tokens c j)))))
            (when (< 0 have (car ns))
              (set! out (cons (cons 'T4 (string-append "T4: write job " (number->string j)
                                                       " has " (number->string have) " of its "
                                                       (number->string (car ns))
                                                       " writes in the file: " (show-file f)))
                              out))))
          (loop (+ j 1) (cdr ns))))
      out))

  ;; world-problems : Config World -> (Listof (Pairof Symbol String))
  ;; T1, T5 and T9 in one world, and the model's own sanity.
  (define (world-problems c w)
    (let* ((wr (world-thread w 'writer)) (rd (world-thread w 'reader))
           (f (world-file w)) (out '()))
      (define (bad! p msg) (set! out (cons (cons p msg) out)))
      (define (job-of t) (number->string (thread-job t)))
      ;; the model's own: a lock only with a transaction; the reader never
      ;; holds one; a connection in the box is open.
      (for-each
       (lambda (who t)
         (when (and (thread-lock? t) (not (thread-txn? t)))
           (bad! 'model (string-append "model: the " who " holds the lock with no transaction")))
         (unless (eq? (thread-box? t) (eq? (thread-conn t) 'open))
           (bad! 'model (string-append "model: the " who "'s box and connection disagree"))))
       '("writer" "reader") (list wr rd))
      (when (thread-lock? rd) (bad! 'model "model: the reader holds the write lock"))
      ;; T1: at most one write transaction
      (when (and (thread-lock? wr) (world-olock w))
        (bad! 'T1 "T1: the writer and another process both hold the write lock"))
      ;; T1, as restated: past beginning only while holding the lock
      (when (and (thread-past? wr) (not (thread-lock? wr)))
        (bad! 'T1 (string-append "T1: write job " (job-of wr) " is in "
                                 (symbol->string (thread-kind wr))
                                 " without the write lock")))
      ;; T1: no transaction open on the writer at ended, or between jobs,
      ;; unless its close failed and kept the connection (W20)
      (when (and (memq (thread-kind wr) '(#f start ended)) (thread-txn? wr)
                 (not (eq? (thread-conn wr) 'kept)))
        (bad! 'T1 (string-append "T1: the writer is "
                                 (if (thread-kind wr)
                                     (string-append "in " (symbol->string (thread-kind wr))
                                                    " of job " (job-of wr))
                                     "done")
                                 " with a transaction open, and no close failed")))
      ;; T9: the same on the read thread (R16)
      (when (and (memq (thread-kind rd) '(#f start ended)) (thread-txn? rd)
                 (not (eq? (thread-conn rd) 'kept)))
        (bad! 'T9 (string-append "T9: the reader is "
                                 (if (thread-kind rd)
                                     (string-append "in " (symbol->string (thread-kind rd))
                                                    " of job " (job-of rd))
                                     "done")
                                 " with a transaction open, and no close failed")))
      ;; T5: an answer only after COMMIT said ok
      (when (and (eq? (thread-kind wr) 'ended) (equal? (cdr (thread-state wr)) '(answer))
                 (not (thread-commit-ok? wr)))
        (bad! 'T5 (string-append "T5: write job " (job-of wr)
                                 " is answered, and no COMMIT of it answered ok")))
      ;; T5, T2: an answer only for a job whose body returned with its
      ;; transaction open: for a read, what it answers is what its body
      ;; read in its snapshot
      (for-each
       (lambda (t p what)
         (when (and (eq? (thread-kind t) 'ended) (equal? (cdr (thread-state t)) '(answer))
                    (not (thread-ran? t)))
           (bad! p (string-append (symbol->string p) ": " what " job " (job-of t)
                                  " is answered, and its body did not return"
                                  " in its transaction"))))
       (list wr rd) '(T5 T2) '("write" "read"))
      ;; T5: an answered write's effects are in the file exactly once, whole
      (for-each
       (lambda (aj)
         (let ((counts (map (lambda (tok) (length (filter (lambda (x) (= x tok)) (file-writes f))))
                            (job-tokens c aj))))
           (unless (for-all (lambda (n) (= n 1)) counts)
             (bad! 'T5 (string-append "T5: write job " (number->string aj)
                                      " was answered, and the file holds "
                                      (show-file f))))))
       (thread-answered wr))
      out))

  ;; model-invariant : Config -> (World -> (U #f String))
  ;; T1, T2, T4, T5, T6, T9 and T10 in one world, and the model's own
  ;; sanity: #f, or every broken one in order, each named ("T1: ..."),
  ;; joined by " | ". T2, T6 and T10 are found by the step that made the
  ;; world. T3 and T7 are not here: in the model a reader never waits for
  ;; the writer, and a job's body is one step.
  (define (model-invariant c)
    (let ((cache (make-eq-hashtable)))
      (lambda (w)
        (let* ((f (world-file w))
               (fp (or (hashtable-ref cache f #f)
                       (let ((p (file-problems c f))) (hashtable-set! cache f p) p))))
          (report c (append (world-bad w) fp (world-problems c w)))))))

  ;; model-final : Config Machine Boolean -> (World -> (U #f String))
  ;; At a world with nothing left to run:
  ;;   stuck  every job of both threads has ended
  ;;   N1     with NOMINAL (no failure, no other process): every write job
  ;;          and every read job answered, and the file holds every write,
  ;;          in call order, at this binary's version. This suite's own: with
  ;;          it, a table that refuses every job cannot pass for one that
  ;;          works.
  (define (model-final c m nominal)
    (lambda (w0)
      (let* ((w (sweep c m w0)) (wr (world-thread w 'writer)) (rd (world-thread w 'reader))
             (out '()))
        (define (bad! p msg) (set! out (cons (cons p msg) out)))
        (for-each
         (lambda (who t)
           (when (thread-command t)
             (bad! 'stuck (string-append "stuck: the " who " is in "
                                         (show (thread-kind t)) " asking "
                                         (show (thread-command t))))))
         '("writer" "reader") (list wr rd))
        (when nominal
          (let ((nw (length (config-writes c))))
            (unless (equal? (thread-answered wr) (from-to 0 (- nw 1)))
              (bad! 'N1 (string-append "N1: with no failure, the write jobs answered are "
                                       (show (thread-answered wr)))))
            (unless (equal? (thread-answered rd) (from-to 0 (- (config-reads c) 1)))
              (bad! 'N1 (string-append "N1: with no failure, the read jobs answered are "
                                       (show (thread-answered rd)))))
            (unless (equal? (world-file w)
                            (make-file (apply append (map (lambda (j) (job-tokens c j))
                                                          (from-to 0 (- nw 1))))
                                       (config-latest c)))
              (bad! 'N1 (string-append "N1: with no failure, the file ends "
                                       (show-file (world-file w)))))))
        (report c out))))

  ;; model-explore : Config Machine (U #f Observer)
  ;;                 -> (U (List 'ok Natural) (List 'violated String Trace)
  ;;                       (List 'cycle Trace))
  ;; (explore)'s answer, explored twice: the nominal graph first, for N1,
  ;; then, if that answers ok, the whole graph. The whole graph's answer,
  ;; or the nominal one's when it is not ok.
  (define (model-explore c m observe)
    (forget!)
    (let ((r (explore (model-start c m) (model-next c m observe #t)
                      (model-invariant c) (model-final c m #t) world-hash)))
      (if (eq? (car r) 'ok)
          (explore (model-start c m) (model-next c m observe #f)
                   (model-invariant c) (model-final c m #f) world-hash)
          r)))

  ;;; Traces for the replay

  ;; model-traces : Config Machine
  ;;                -> (Listof (Pairof (List Symbol StateKind EventKind) Trace))
  ;; For each row the configuration fires, keyed as write-row-names and
  ;; read-row-names list it, a shortest trace to a step that fires it,
  ;; carried on to a quiet world by always taking the first next step (the
  ;; writer's nominal call first). Breadth-first over the whole graph.
  (define (model-traces c m)
    (forget!)
    (let ((next (model-next c m #f #f))
          (seen (make-hashtable world-hash equal?))
          (firsts '()))
      (define (path w)
        (let loop ((w w) (acc '()))
          (let ((link (hashtable-ref seen w #f)))
            (if link (loop (car link) (cons (cdr link) acc)) acc))))
      (define (tail w)
        (let loop ((w w) (acc '()))
          (let ((moves (next w)))
            (if (null? moves)
                (reverse acc)
                (loop (cdar moves) (cons (caar moves) acc))))))
      (let ((start (model-start c m)))
        (hashtable-set! seen start #f)
        (let loop ((front (list start)) (back '()))
          (cond
           ((and (null? front) (null? back)) #f)
           ((null? front) (loop (reverse back) '()))
           (else
            (let add ((moves (next (car front))) (back back))
              (if (null? moves)
                  (loop (cdr front) back)
                  (let* ((step (caar moves)) (w2 (cdar moves))
                         (key (and (step-row step) (step-key c m (car front) step))))
                    (when (and key (not (assoc key firsts)))
                      (set! firsts (cons (list key (car front) step w2) firsts)))
                    (if (hashtable-contains? seen w2)
                        (add (cdr moves) back)
                        (begin (hashtable-set! seen w2 (cons (car front) step))
                               (add (cdr moves) (cons w2 back))))))))))
        (map (lambda (entry)
               (cons (car entry)
                     (append (path (cadr entry)) (list (caddr entry)) (tail (cadddr entry)))))
             (reverse firsts)))))

  ;; step-key : Config Machine World Step -> (List Symbol StateKind EventKind)
  ;; The row a thread's step fired, as the names list it: the state it left
  ;; (read from the world before, swept) and the event the raw sorts to.
  (define (step-key c m w step)
    (let* ((who (step-who step))
           (t (world-thread (sweep c m w) who))
           (kind ((machine-kind m who) (step-command step) (step-raw step))))
      (list (step-row step) (car (thread-state t)) kind)))

  ;;; Machine 3: serve, explored by itself

  ;; ServeMachine is #(name start step kind names)
  ;;   start : -> (values State Command)
  ;;   step : State Event -> (values State Command)
  ;;   kind : Command RawOutcome -> EventKind
  ;; make-serve-machine : Any (-> (values State Command)) Stepper Kind
  ;;                      (Listof (List Symbol StateKind EventKind)) -> ServeMachine
  (define (make-serve-machine name start step kind names)
    (vector name start step kind (name-table names)))
  (define (smachine-start m) (vector-ref m 1))
  (define (smachine-step m) (vector-ref m 2))
  (define (smachine-kind m) (vector-ref m 3))
  (define (smachine-name m s e) (hashtable-ref (vector-ref m 4) (cons s e) #f))

  ;; serve-real-machine : ServeMachine
  (define serve-real-machine
    (make-serve-machine 'real serve-start serve-step serve-event-kind serve-row-names))

  ;; model-serve-command : State -> Command
  ;; A copy of (techo transaction)'s serve-command, which it does not
  ;; export; the suite holds it to serve-step.
  (define (model-serve-command s)
    (case (car s)
      ((checking) (list 'check))
      ((opening-writer) (list 'open-writer))
      ((opening-hasher) (list 'open-hasher))
      ((opening-readers) (list 'open-readers))
      ((serving) (list 'serve))
      ((stopping-readers) (list 'stop-readers))
      ((stopping-hasher) (list 'stop-hasher))
      ((stopping-writer) (list 'stop-writer))
      ((ended) (cons 'end (car (cdr s))))
      (else (assertion-violation 'model-serve-command "not a state" s))))

  ;; model-serve-start : (State -> Command) -> (-> (values State Command))
  (define (model-serve-start command-of)
    (lambda ()
      (let ((s (cons 'checking (list #f '()))))
        (values s (command-of s)))))

  ;; make-model-serve-stepper : (Listof Row) (State -> Command)
  ;;                            -> (State Event -> (values State Command))
  (define (make-model-serve-stepper rows command-of)
    (let ((m (make-machine rows)))
      (lambda (state event)
        (let-values (((next row-command) (machine-step m state event)))
          (let ((cmd (command-of next)))
            (unless (eq? (car cmd) (car row-command))
              (assertion-violation 'model-serve-stepper
                "the row's command kind is not the next state's"
                (car state) (car event) (car row-command) (car cmd)))
            (values next cmd))))))

  ;; ServeWorld is (List State Command Writer Hasher Readers First Expected Bad)
  ;;   Writer, Hasher, Readers   none, running or stopped: each worker
  ;;   First             #f, or the exit status of the first thing that
  ;;                     raised or was refused
  ;;   Expected          what the shell must print at the end, in order
  ;;   Bad               what the step that made it broke
  ;; Of circuit's worker, as the plan lists it: a set-up's raise leaves
  ;; make-worker after every thread is joined (a raised open made nothing
  ;; that runs); a tear-down's raise leaves worker-stop! after every thread
  ;; is joined (a raised stop stopped it). The hasher's open stops its own
  ;; worker when the stand-in's hash raises, so a raised open of the hasher
  ;; made nothing that runs either (slice 3b, L5).
  (define (sw-state w) (list-ref w 0))
  (define (sw-command w) (list-ref w 1))
  (define (sw-writer w) (list-ref w 2))
  (define (sw-hasher w) (list-ref w 3))
  (define (sw-readers w) (list-ref w 4))
  (define (sw-first w) (list-ref w 5))
  (define (sw-expected w) (list-ref w 6))
  (define (sw-bad w) (list-ref w 7))

  ;; serve-outcomes : Command -> (Listof (List Choice RawOutcome (U #f Integer)
  ;;                                           (U #f (Pairof Symbol Any))))
  ;; Every way each command can go: the raw outcome, the exit status it
  ;; asks for if it is a failure, and the line the shell must print for it.
  (define refusal '(refuse foreign "techo serve: the file is not techo's"))
  (define (serve-outcomes cmd)
    (define (raised what) (string-append what " raised"))
    (case (car cmd)
      ((check) (list (list 'serve '(ok serve #f) #f #f)
                     (list 'refused (list 'ok refusal #f) 1 (cons 'line (caddr refusal)))))
      ((open-writer open-hasher open-readers stop-readers stop-hasher stop-writer)
       (let ((obj (raised (symbol->string (car cmd)))))
         (list (list 'ok '(ok #t #f) #f #f)
               (list 'raised (list 'raised obj #f) 1 (cons 'raised obj)))))
      ((serve) (list (list 'returned '(returned #t #f) #f #f)
                     (list 'refused '(refused "CHEZ_HTTP_PORT" #f) 2
                           (cons 'refused "CHEZ_HTTP_PORT"))
                     (list 'raised '(raised "serve raised" #f) 1 (cons 'raised "serve raised"))))
      ((end) '())
      (else (assertion-violation 'serve-outcomes "not a command of serve" cmd))))

  ;; serve-move : ServeMachine (U #f Observer) ServeWorld (List ...) -> (Pairof Step ServeWorld)
  (define (serve-move m observe w outcome)
    (let* ((state (sw-state w)) (cmd (sw-command w))
           (choice (car outcome)) (raw (cadr outcome)) (status (caddr outcome))
           (print (cadddr outcome)) (ok? (not status))
           (wr (sw-writer w)) (hs (sw-hasher w)) (rd (sw-readers w)) (bad '()))
      (define (bad! msg) (set! bad (cons (cons 'T8 msg) bad)))
      (case (car cmd)
        ((open-writer) (when ok? (set! wr 'running)))
        ((open-hasher) (when ok? (set! hs 'running)))
        ((open-readers) (when ok? (set! rd 'running)))
        ((stop-readers)
         (unless (eq? rd 'running) (bad! "T8: stops the readers, which are not running"))
         (set! rd 'stopped))
        ((stop-hasher)
         (unless (eq? hs 'running) (bad! "T8: stops the hasher, which is not running"))
         (when (eq? rd 'running) (bad! "T8: stops the hasher while the readers run"))
         (set! hs 'stopped))
        ((stop-writer)
         (unless (eq? wr 'running) (bad! "T8: stops the writer, which is not running"))
         (when (eq? rd 'running) (bad! "T8: stops the writer while the readers run"))
         (when (eq? hs 'running) (bad! "T8: stops the writer while the hasher runs"))
         (set! wr 'stopped))
        (else #f))
      (let ((kind ((smachine-kind m) cmd raw)))
        (let-values (((s2 cmd2) ((smachine-step m) state (cons kind raw))))
          (let ((name (smachine-name m (car state) kind)))
            (when observe (observe (list name (car state) kind)))
            (cons (make-step 'serve #f choice cmd raw name s2 #f #f #f)
                  (list s2 cmd2 wr hs rd (or (sw-first w) status)
                        (if print (append (sw-expected w) (list print)) (sw-expected w))
                        bad)))))))

  ;; serve-invariant : ServeWorld -> (U #f String)
  ;; T8: never ends with a worker it made still running, the hasher too;
  ;; the readers stopped before the hasher, and both before the writer
  ;; (read at each stop); exit 0 only if nothing raised or was refused; the
  ;; first status carried wins; and every failure's line printed, in order.
  (define (serve-invariant w)
    (let ((out (map cdr (sw-bad w))) (s (sw-state w)))
      (define (bad! msg) (set! out (cons msg out)))
      (when (eq? (car s) 'ended)
        (when (eq? (sw-writer w) 'running) (bad! "T8: ends with the writer still running"))
        (when (eq? (sw-hasher w) 'running) (bad! "T8: ends with the hasher still running"))
        (when (eq? (sw-readers w) 'running) (bad! "T8: ends with the readers still running"))
        (let ((status (serve-carried s)) (first (sw-first w)))
          (when (and (eqv? status 0) first)
            (bad! "T8: exits 0 after something raised or was refused"))
          (unless (eqv? status (or first 0))
            (bad! (string-append "T8: exits " (show status) ", and the first status carried is "
                                 (show (or first 0))))))
        (unless (equal? (serve-prints s) (sw-expected w))
          (bad! (string-append "T8: prints " (show (serve-prints s)) ", and the failures were "
                               (show (sw-expected w))))))
      (if (null? out) #f (join (reverse out) " | "))))

  ;; serve-explore : ServeMachine (U #f Observer)
  ;;                 -> (U (List 'ok Natural) (List 'violated String Trace)
  ;;                       (List 'cycle Trace))
  ;; Machine 3 from serve-start, every outcome at every command, T8 in every
  ;; world; at a world with nothing left, the table must have ended.
  (define (serve-explore m observe)
    (let-values (((s cmd) ((smachine-start m))))
      (explore (list s cmd 'none 'none 'none #f '() '())
               (lambda (w)
                 (map (lambda (o) (serve-move m observe w o))
                      (serve-outcomes (sw-command w))))
               serve-invariant
               (lambda (w)
                 (if (eq? (car (sw-state w)) 'ended)
                     #f
                     (string-append "stuck: serve is in " (show (car (sw-state w))))))
               (lambda (w) (deep-hash w 17)))))
)
