#!r6rs
;;; The replay suite: layer 4 of the slice 2 plan. The model's traces, from
;;; (migrations-model), replayed on real SQLite through (techo db)'s
;;; perform!, so that the pure model the exploration trusts is held to what
;;; SQLite really does. The machinery is (replay-support); its header says
;;; what one replay compares.
;;;
;;;   - every graph trace (model-traces) of configurations chosen so that,
;;;     between them, every row the model fires is replayed, and the
;;;     coverage held as a test;
;;;   - seeded random walks (model-walk) of two runs over migrations of two
;;;     or more statements;
;;;   - the layer 4 mutants, each with the comparison that catches it;
;;;   - the modelling decisions the brief names, each held to SQLite.
;;;
;;; How each choice is made
;;; -----------------------
;;; Real: SQLite gives the outcome; the replay calls perform! once, after
;;; any set-up named. Injected: SQLite cannot be made to give it from one
;;; thread on a good file, so no perform! is made; plain calls bring the
;;; connection's true state to the outcome reported (a real ROLLBACK when
;;; the transaction is to have ended, a real COMMIT when it took effect).
;;;
;;; | Command           | Choice      | How                                                        |
;;; |-------------------|-------------|------------------------------------------------------------|
;;; | open-read-only    | ok, missing | real: the file as the trace left it                        |
;;; | open-read-write   | ok          | real: a missing file is made, fresh, in delete mode        |
;;; | either open       | fail        | injected: a good file opens, and the file must stay as the |
;;; |                   |             | model has it. Nothing is opened                            |
;;; | read-facts        | ok          | real                                                       |
;;; | read-facts        | fail        | injected (real with no connection): a good file reads; an  |
;;; |                   |             | interrupt between two statements is lost                   |
;;; | close             | ok          | real                                                       |
;;; | close             | fail        | injected: the connection really closed                     |
;;; | set-wal           | ok          | real: converts, or in WAL a no-op                          |
;;; | set-wal           | busy        | real while another really holds BEGIN IMMEDIATE (a file   |
;;; |                   |             | not in WAL); injected while another is converting: one     |
;;; |                   |             | thread is never in the middle of another's call            |
;;; | set-wal           | fail        | real read-only or in a transaction on a file not in WAL,   |
;;; |                   |             | or with no connection; injected otherwise                  |
;;; | pause             | ok          | real: it sleeps 100 ms                                     |
;;; | pause             | fail        | injected: a sleep does not fail                            |
;;; | begin-immediate   | ok, busy    | real: busy when another really holds the lock, timeout 0   |
;;; | begin-immediate   | fail        | real in a transaction, or with no connection; injected     |
;;; |                   |             | otherwise. On a read-only connection SQLite answers ok:    |
;;; |                   |             | the model is wrong there (below), migrate never asks it    |
;;; | run-statement     | ok, busy    | real: effect-sql's CREATE TABLE, or the id statement; busy |
;;; |                   |             | is an autocommit write while another holds the lock        |
;;; | run-statement     | ok-ended    | real: ROLLBACK as the statement, which answers ok and ends |
;;; |                   |             | the transaction by rolling it back, as the model means     |
;;; | run-statement     | fail        | real: a NOT NULL failure on a temp table, which main's     |
;;; |                   |             | schema does not count (read-only: the CREATE TABLE itself) |
;;; | run-statement     | fail-ended  | real: INSERT OR ROLLBACK failing the same constraint       |
;;; | foreign-key-check | ok          | real                                                       |
;;; | foreign-key-check | violations  | real: a dangling row put first in the newest effect table  |
;;; |                   |             | the transaction sees (migrate's keys are off); injected    |
;;; |                   |             | with none. A temp table's rows are not checked (probed)    |
;;; | foreign-key-check | fail        | injected (real with no connection): a good check does not  |
;;; |                   |             | fail                                                       |
;;; | stamp             | ok, busy    | real                                                       |
;;; | stamp             | fail        | real read-only or with no connection; injected otherwise   |
;;; | commit            | ok          | real                                                       |
;;; | commit            | fail        | real: a deferred key left dangling, on a connection the    |
;;; |                   |             | replay opened with keys on; SQLite keeps the transaction   |
;;; |                   |             | open, as the model says. Real with no transaction.         |
;;; |                   |             | Injected with no effect table to dangle a row in           |
;;; | commit            | took-effect | injected: a real COMMIT, reported failed                   |
;;; | rollback          | ok          | real                                                       |
;;; | rollback          | fail        | real with no transaction; injected in one: SQLite's        |
;;; |                   |             | ROLLBACK there does not fail                               |
;;; | any but opens,    | fail-ended  | injected: a real ROLLBACK, reported failed                 |
;;; | close, pause      |             |                                                            |
;;; | (a death)         | die         | real: the connection closed with no COMMIT; one thread     |
;;; |                   |             | kills no process, and a close rolls back as a death does   |
;;;
;;; Every file is under build/test-migrations-replay/<unique>/, emptied at
;;; the start; a file whose replay agreed is removed. Everything that can
;;; raise is computed under `attempt`, and a raise comes out as a value the
;;; expectation never is.
(import (rnrs)
        (only (chezscheme) mkdir directory-list delete-directory file-directory?
                           current-time time-second time-nanosecond)
        (srfi :64)
        (chez-sqlite3)
        (techo-testing)
        (techo migrations)
        (techo db)
        (migrations-model)
        (replay-support))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;;; The directory

(define (rm-tree! p)
  (cond ((file-directory? p)
         (for-each (lambda (n) (rm-tree! (string-append p "/" n))) (directory-list p))
         (delete-directory p))
        ((file-exists? p) (delete-file p))))

(define (make-dir! p) (unless (file-directory? p) (mkdir p #o755)))

(define test-dir
  (let ((t (current-time)))
    (guard (e (#t #f))
      (make-dir! "build")
      (rm-tree! "build/test-migrations-replay")
      (make-dir! "build/test-migrations-replay")
      (let ((d (string-append "build/test-migrations-replay/"
                              (number->string (time-second t)) "-"
                              (number->string (time-nanosecond t)))))
        (make-dir! d)
        d))))

(define file-count 0)

;; fresh-path : -> String    a name no replay has used
(define (fresh-path)
  (set! file-count (+ file-count 1))
  (string-append test-dir "/r" (number->string file-count) ".db"))

(define (remove-files! p)
  (for-each (lambda (s) (when (file-exists? (string-append p s)) (delete-file (string-append p s))))
            '("" "-wal" "-shm")))

;;; Lists and configurations, as the model's suite makes them

;; iota-from : Integer Integer -> (Listof Integer)
(define (iota-from a b) (if (> a b) '() (cons a (iota-from (+ a 1) b))))

;; shape : Positive-Integer ... -> (Listof Migration)
;; Migration k has the k-th count of statements; migration 1's first is the
;; id statement, every other an effect token.
(define (shape . counts)
  (let loop ((k 1) (cs counts) (acc '()))
    (if (null? cs)
        (reverse acc)
        (loop (+ k 1) (cdr cs)
              (cons (list k (string-append "m" (number->string k))
                          (if (= k 1)
                              (cons model-id-statement
                                    (map (lambda (i) (effect-statement 1 i)) (iota-from 2 (car cs))))
                              (map (lambda (i) (effect-statement k i)) (iota-from 1 (car cs)))))
                    acc)))))

;; cfg : (Listof Migration) StartName (U 1 2) Boolean -> Config
(define (cfg ms start runs serve?)
  (config-with-cap
   (make-config (list (map (lambda (m) (length (caddr m))) ms) start runs serve?)
                ms (start-file ms start) runs serve?)
   2000000))

;;; Replaying, and what the replays saw

;; Keys, hows and offers of every replay of the real machine, for the
;; coverage.
(define seen-keys (make-hashtable equal-hash equal?))
(define seen-hows (make-hashtable equal-hash equal?))
(define seen-offers (make-hashtable equal-hash equal?))
(define replayed (vector 0 0))          ; traces, steps

;; replay : Config ReplayMachine Trace ReplayOptions -> Report
;; On a new file, removed once the replay agrees.
(define (replay c rm trace opts)
  (let* ((p (fresh-path)) (r (replay-trace c rm trace opts p)))
    (when (eq? (report-verdict r) 'agree) (remove-files! p))
    r))

;; replay-real : Config Trace -> Verdict
;; The real machine's replay, its keys and hows recorded.
(define (replay-real c trace)
  (let ((r (replay c real-replay-machine trace default-replay-options)))
    (for-each (lambda (k) (hashtable-set! seen-keys k #t)) (report-keys r))
    (for-each (lambda (h) (hashtable-update! seen-hows (car h) (lambda (n) (+ n (cdr h))) 0))
              (report-hows r))
    (for-each (lambda (o) (hashtable-set! seen-offers o #t)) (report-offers r))
    (vector-set! replayed 0 (+ 1 (vector-ref replayed 0)))
    (vector-set! replayed 1 (+ (report-steps r) (vector-ref replayed 1)))
    (report-verdict r)))

(test-begin "migrations-replay")

;;; Every graph trace

;; Between them these fire every row the whole space fires (layer 3: every
;; run row but R14, every check row): two runs and serve on a fresh file
;; either way; a missing file; a file behind; a current file not in WAL;
;; and every refused start, in both modes, with serve.
(define graph-configs
  (append
   (list (cfg (shape 2) '(fresh delete) 2 #t)
         (cfg (shape 2) '(fresh wal) 2 #t)
         (cfg (shape 1 2) 'missing 1 #t)
         (cfg (shape 1 2) 'missing 2 #f)
         (cfg (shape 1 2) '((behind 1) delete) 2 #t)
         (cfg (shape 2) '(current delete) 2 #t))
   (apply append
          (map (lambda (kind)
                 (list (cfg (shape 2) (list kind 'wal) 1 #t)
                       (cfg (shape 2) (list kind 'delete) 1 #t)))
               '(ahead other-id schema-no-id version-no-id techo-v0 negative)))))

(for-each
 (lambda (c)
   (test-equal (string-append "replay: every graph trace of " (call-with-string-output-port
                                                                (lambda (p) (write (config-name c) p)))
                              " agrees with SQLite")
     '()
     (attempt
      (lambda ()
        (let loop ((kts (model-traces c real-machine)) (bad '()))
          (if (null? kts)
              (reverse bad)
              (let ((v (replay-real c (cdar kts))))
                (loop (cdr kts) (if (eq? v 'agree) bad (cons (list (caar kts) v) bad))))))))))
 graph-configs)

;;; Random walks

;; Two runs, migrations of two or more statements, fixed seeds. A failing
;; walk is named by its seed, and its verdict by the step's index.
(define walk-configs
  (list (cfg (shape 2 2) '(fresh delete) 2 #t)
        (cfg (shape 1 3) 'missing 2 #t)
        (cfg (shape 2 2) '((behind 1) wal) 2 #t)
        (cfg (shape 3 2) '(fresh wal) 2 #f)))

(define walk-seeds (iota-from 1 100))

(for-each
 (lambda (c)
   (test-equal (string-append "replay: walks 1 to 100 (400 steps at most) of "
                              (call-with-string-output-port (lambda (p) (write (config-name c) p)))
                              " agree with SQLite; a failure lists (seed verdict)")
     '()
     (attempt
      (lambda ()
        (let loop ((seeds walk-seeds) (bad '()))
          (if (null? seeds)
              (reverse bad)
              (let ((v (replay-real c (model-walk c real-machine (car seeds) 400))))
                (loop (cdr seeds) (if (eq? v 'agree) bad (cons (list (car seeds) v) bad))))))))))
 walk-configs)

;;; A choice no shortest trace takes

;; A COMMIT that answers failed but took effect sorts as one that failed
;; and ended the transaction (R36), so the graph's one trace for that row
;; takes the other; and the walks seldom live to a COMMIT. Here it is
;; taken: the run says failed, and the file holds the migration.
(test-equal "replay: a COMMIT that took effect: agrees, the run fails, the file is at version 2"
  '(agree failed 2)
  (attempt (lambda ()
             (let* ((c (cfg (shape 1 2) '((behind 1) wal) 1 #t))
                    (trace (trace-by-choice c real-replay-machine
                                            (lambda (who cmd choices)
                                              (if (equal? cmd '(commit)) 'took-effect (car choices))))))
               (list (replay-real c trace)
                     (let ((s (find (lambda (s) (eq? (car (step-state s)) 'ended)) trace)))
                       (and s (cadr (step-state s))))
                     (model-file-version (step-file (list-ref trace (- (length trace) 1)))))))))

;;; Coverage

;; (run? state . event) for every row of both tables, but R14: looking,
;; refused fires nowhere in the model. A run looks read-write only after its
;; read-only peek accepted the file, and only another program writing in
;; between could make it ahead or foreign.
(define expected-keys
  (append
   (filter (lambda (k) (not (equal? k '(#t looking . refused))))
           (map (lambda (r) (cons #t (cons (car r) (cadr r)))) run-rows))
   (map (lambda (r) (cons #f (cons (car r) (cadr r)))) check-rows)))

(test-equal "coverage: every row the model fires was replayed, sorted from the REAL outcome, but R14"
  '()
  (filter (lambda (k) (not (hashtable-ref seen-keys k #f))) expected-keys))

(test-equal "coverage: the replay fired no row the tables lack"
  '()
  (filter (lambda (k) (not (member k (cons '(#t looking . refused) expected-keys))))
          (vector->list (hashtable-keys seen-keys))))

;; Measured at 818 traces and 8,656 steps; the floors sit a little below.
(test-assert "coverage: at least 800 traces and 8,500 steps were replayed"
  (and (>= (vector-ref replayed 0) 800) (>= (vector-ref replayed 1) 8500)))

;; Each choice the header's table makes real was made real somewhere in
;; the replays above, so no realization has quietly become an injection.
;; Not set-wal busy: migrate locks only a file in WAL, so no run converts
;; while another holds the lock; a decision script below makes it real.
(define real-choices
  '((open-read-only ok) (open-read-only missing) (open-read-write ok) (read-facts ok)
    (close ok) (set-wal ok) (pause ok) (begin-immediate ok)
    (begin-immediate busy) (run-statement ok) (run-statement ok-ended)
    (run-statement fail) (run-statement fail-ended) (foreign-key-check ok)
    (foreign-key-check violations) (stamp ok) (commit ok) (commit fail) (rollback ok)))

(test-equal "coverage: every choice the table calls real was made real"
  '()
  (filter (lambda (cc) (not (hashtable-ref seen-hows (append cc '(real)) #f))) real-choices))

;; Every way the model offered a call to go, at any step of any trace
;; above, was taken by some replay, real or injected. (What migrate never
;; asks, such as set-wal inside a transaction, is never offered here.)
(test-equal "coverage: every way the model offered a replayed call to go was replayed"
  '()
  (filter (lambda (o) (not (or (hashtable-ref seen-hows (append o '(real)) #f)
                               (hashtable-ref seen-hows (append o '(injected)) #f))))
          (vector->list (hashtable-keys seen-offers))))

;;; The layer 4 mutants
;;;
;;; A mutant of the step function runs on both sides: the model's trace is
;;; made with it, and the real side steps with it, so the replay asks only
;;; whether the model predicts SQLite under that machine. A mutant of the
;;; shell is a wrapped perform!. Each is held to the comparison that first
;;; differs, and the unmutated machine to agreement beside it.

;; row-replace : Rows Symbol Symbol (U Symbol #f) (U Symbol #f) (U Update #f) -> Rows
(define (row-replace rows s e next cmd update)
  (map (lambda (r)
         (if (and (eq? (car r) s) (eq? (cadr r) e))
             (list s e (or next (caddr r)) (or cmd (cadddr r)) (or update (list-ref r 4)))
             r))
       rows))

;; first-but : Command Choice -> Chooser
;; Every call goes its first way (its nominal one), but TARGET goes CHOICE.
(define (first-but target choice)
  (lambda (who cmd choices) (if (equal? cmd target) choice (car choices))))

;; index-of : Trace Command -> (U Natural #f)
;; The 1-based index of the first step that carries out CMD.
(define (index-of trace cmd)
  (let loop ((t trace) (n 1))
    (cond ((null? t) #f)
          ((equal? (step-command (car t)) cmd) n)
          (else (loop (cdr t) (+ n 1))))))

;; head : Verdict -> Any     (step who comparison), or the verdict as it is
(define (head v)
  (if (and (pair? v) (integer? (car v)) (>= (length v) 3)) (list (car v) (cadr v) (caddr v)) v))

;; txn-of : Shell -> Boolean
(define (txn-of sh)
  (let ((db (shell-database sh))) (and db (in-transaction? db))))

;; result-kind : Trace -> Any     the kind of the Result its last step ended in
(define (result-kind trace)
  (let ((s (step-state (list-ref trace (- (length trace) 1)))))
    (and (eq? (car s) 'ended) (cadr s))))

(define one-run (cfg (shape 1 2) '((behind 1) wal) 1 #f))
(define three-statements (cfg (shape 1 3) '((behind 1) wal) 1 #f))

;; R29 missing: a statement that answered ok with the transaction gone is
;; taken as more or last. Made with make-stepper over run-rows, with the
;; classifier sorting txn-ended as the same answer with the transaction
;; open would be: a row alone cannot tell more from last.
(define (kind-no-r29 ms state raw)
  (let ((k (event-kind ms state raw)))
    (if (eq? k 'txn-ended) (event-kind ms state (list (car raw) (cadr raw) #t)) k)))
(define no-r29
  (make-replay-machine 'no-r29 run-start (make-stepper run-rows kind-no-r29) kind-no-r29
                       check-start check-step check-event-kind))

(define commit-options (make-replay-options "COMMIT" #f perform!))
(define stmt-2.2 (cons 'run-statement (effect-statement 2 2)))

;; r29 : ReplayMachine ReplayOptions -> (List (U Natural #f) Verdict)
(define (r29 rm opts)
  (let ((trace (trace-by-choice three-statements rm (first-but stmt-2.2 'ok-ended))))
    (list (index-of trace stmt-2.2)
          (report-verdict (replay three-statements rm trace opts)))))

;; The plan's trace: COMMIT as statement 2. It commits statement 1, which
;; the model's ok-ended (a rollback) does not, so the file's facts differ at
;; once.
(test-equal "mutant: R29 missing, COMMIT as statement 2: the replay differs there, by the file's facts"
  '(#t 0 file-facts)
  (attempt (lambda ()
             (let ((r (r29 no-r29 commit-options)))
               (let ((h (head (cadr r))))
                 (if (and (pair? h) (eqv? (car h) (car r))) (cons #t (cdr h)) r))))))

;; Found: the unmutated machine differs on that trace too, at the same step
;; and by the same comparison. A COMMIT statement leaves half a migration
;; committed, R29 or no R29; the model's ok-ended is a rollback, and it is
;; check-migrations' refusal of COMMIT in a migration that keeps it true.
;; So this trace cannot tell R29 from its absence.
(test-equal "R29's COMMIT trace, the unmutated machine: the replay differs there too, by the file's facts"
  '(#t 0 file-facts)
  (attempt (lambda ()
             (let ((r (r29 real-replay-machine commit-options)))
               (let ((h (head (cadr r))))
                 (if (and (pair? h) (eqv? (car h) (car r))) (cons #t (cdr h)) r))))))

(test-equal "R29's trace, the unmutated machine, statement 2 a ROLLBACK (what ok-ended means): agrees, and ends failed"
  '(agree failed)
  (attempt (lambda ()
             (let ((trace (trace-by-choice three-statements real-replay-machine
                                           (first-but stmt-2.2 'ok-ended))))
               (list (report-verdict (replay three-statements real-replay-machine trace
                                             default-replay-options))
                     (result-kind trace))))))

;; With R29 gone and statement 2 a ROLLBACK, statement 3 and the foreign
;; key check run outside any transaction. The model has them autocommit,
;; and SQLite agrees: so at layer 4 only a statement that commits shows
;; R29's absence, and layer 3's M10 is what catches it.
(test-equal "the model's commands outside a transaction agree with SQLite: R29 missing, statement 2 a ROLLBACK, statement 3 autocommitted"
  '(agree (ok #t #f))
  (attempt (lambda ()
             (let* ((trace (trace-by-choice three-statements no-r29 (first-but stmt-2.2 'ok-ended)))
                    (s3 (find (lambda (s) (equal? (step-command s)
                                                  (cons 'run-statement (effect-statement 2 3))))
                              trace)))
               (list (report-verdict (replay three-statements no-r29 trace default-replay-options))
                     (and s3 (step-raw s3)))))))

;; R30 skipped: the last statement goes on to the stamp. The trace's
;; migration leaves a dangling row, as a table rebuild with foreign keys off
;; can; the model's files never hold one, so the third connection's
;; foreign_key_check is what differs, once the COMMIT lands.
(define no-r30
  (make-replay-machine 'no-r30 run-start
                       (make-stepper (row-replace run-rows 'applying 'last 'stamping 'stamp #f)
                                     event-kind)
                       event-kind check-start check-step check-event-kind))
(define dangle-options (make-replay-options "ROLLBACK" (effect-statement 2 2) perform!))

(test-equal "mutant: R30 skipped, a dangling row: the replay differs at the COMMIT, by foreign_key_check (0 then 1)"
  '(#t 0 file-foreign-keys 0 1)
  (attempt (lambda ()
             (let* ((trace (trace-by-choice one-run no-r30 (lambda (who cmd choices) (car choices))))
                    (n (index-of trace '(commit)))
                    (v (report-verdict (replay one-run no-r30 trace dangle-options))))
               (if (and (pair? v) (eqv? (car v) n)) (cons #t (cdr v)) (list n v))))))

(test-equal "R30's trace, the unmutated machine: its check finds the row for real; agrees, and ends failed"
  '(agree failed)
  (attempt (lambda ()
             (let ((trace (trace-by-choice one-run real-replay-machine
                                           (first-but '(foreign-key-check) 'violations))))
               (list (report-verdict (replay one-run real-replay-machine trace dangle-options))
                     (result-kind trace))))))

;; The shell runs a statement outside the transaction. The brief's version
;; runs it on a second autocommit connection, which SQLite tells busy at
;; once: the run's own connection holds the write lock. So the outcome's
;; status is what differs, at statement 1.
(define stmt-2.1 (cons 'run-statement (effect-statement 2 1)))
(define fail-2.2 (first-but stmt-2.2 'fail))

(test-equal "mutant: statements on a second autocommit connection: busy at statement 1, the status differs"
  '(#t 0 status ok busy)
  (attempt (lambda ()
             (let* ((trace (trace-by-choice one-run real-replay-machine fail-2.2))
                    (n (index-of trace stmt-2.1))
                    (p (fresh-path))
                    (other (make-shell p 0))
                    (exec (lambda (sh cmd)
                            (if (eq? (car cmd) 'run-statement)
                                (begin
                                  (unless (shell-database other) (perform! other '(open-read-write)))
                                  (let ((o (perform! other cmd))) (list (car o) (cadr o) (txn-of sh))))
                                (perform! sh cmd))))
                    (v (dynamic-wind
                         (lambda () #f)
                         (lambda () (report-verdict (replay-trace one-run real-replay-machine trace
                                                                  (make-replay-options "ROLLBACK" #f exec) p)))
                         (lambda () (perform! other '(close))))))
               (if (and (pair? v) (eqv? (car v) n)) (cons #t (cdr v)) (list n v))))))

;; The same mutant on the run's own connection: COMMIT, the statement in
;; autocommit, BEGIN IMMEDIATE again. Statement 1's table is then in the
;; file before any COMMIT of the migration, and statement 2's failure can
;; no longer take it back: the file's facts differ at statement 1.
(define (outside-own sh cmd)
  (if (and (eq? (car cmd) 'run-statement) (txn-of sh))
      (let ((db (shell-database sh)))
        (execute! db "COMMIT")
        (let ((o (perform! sh cmd)))
          (execute! db "BEGIN IMMEDIATE")
          (list (car o) (cadr o) (txn-of sh))))
      (perform! sh cmd)))

(test-equal "mutant: statements outside the transaction on the run's own connection: the file's facts differ at statement 1"
  '(#t 0 file-facts)
  (attempt (lambda ()
             (let* ((trace (trace-by-choice one-run real-replay-machine fail-2.2))
                    (n (index-of trace stmt-2.1))
                    (v (report-verdict (replay one-run real-replay-machine trace
                                               (make-replay-options "ROLLBACK" #f outside-own)))))
               (let ((h (head v))) (if (and (pair? h) (eqv? (car h) n)) (cons #t (cdr h)) (list n v)))))))

(test-equal "the statement-2-fails trace, the unmutated shell: agrees, and ends failed"
  '(agree failed)
  (attempt (lambda ()
             (let ((trace (trace-by-choice one-run real-replay-machine fail-2.2)))
               (list (report-verdict (replay one-run real-replay-machine trace default-replay-options))
                     (result-kind trace))))))

;; The shell ignores a failed COMMIT: it answers ok. The COMMIT fails for
;; real, on a deferred foreign key. The event kind does not differ: ok with
;; the transaction still open is sorted as failed, so the run rolls back as
;; the model's does. The outcome's status is what differs.
(define (commit-ignored sh cmd)
  (let ((o (perform! sh cmd)))
    (if (and (eq? (car cmd) 'commit) (not (eq? (car o) 'ok)))
        (list 'ok #t (txn-of sh))
        o)))
(define fail-commit (first-but '(commit) 'fail))

(test-equal "mutant: the shell ignores a failed COMMIT: the deferred-key trace's status differs at the COMMIT"
  '(#t 0 status failed ok)
  (attempt (lambda ()
             (let* ((trace (trace-by-choice one-run real-replay-machine fail-commit))
                    (n (index-of trace '(commit)))
                    (v (report-verdict (replay one-run real-replay-machine trace
                                               (make-replay-options "ROLLBACK" #f commit-ignored)))))
               (if (and (pair? v) (eqv? (car v) n)) (cons #t (cdr v)) (list n v))))))

(test-equal "the deferred-key trace, the unmutated shell: its COMMIT failed for real; agrees, and ends failed"
  '(agree 1 failed)
  (attempt (lambda ()
             (let* ((trace (trace-by-choice one-run real-replay-machine fail-commit))
                    (r (replay one-run real-replay-machine trace default-replay-options)))
               (list (report-verdict r)
                     (let ((h (assoc '(commit fail real) (report-hows r)))) (and h (cdr h)))
                     (result-kind trace))))))

;;; The modelling decisions, held to SQLite
;;;
;;; migrate reaches few of these, so a script machine asks for the commands
;;; in each situation, and the replay compares the model's outcome, file and
;;; flags with SQLite's as it does for migrate's traces.

;; script : StartName (List Command) (List Command) (Listof (Pairof Index #f))
;;          -> Report
;; The runs carry out RUN, serve's check CHECK; MOVES says who steps when,
;; each call going its first way.
(define (script start run check moves)
  (let* ((c (cfg (shape 1 2) start 1 #t))
         (rm (script-replay-machine 'script run check))
         (trace (trace-of-moves c rm moves)))
    (replay c rm trace default-replay-options)))

(define (moves . whos) (map (lambda (w) (cons w #f)) whos))

(test-equal "decision: set-wal on a file in WAL is a no-op ok: read-write, inside a transaction, and read-only"
  'agree
  (attempt (lambda ()
             (report-verdict
              (script '(current wal)
                      '((open-read-write) (set-wal) (begin-immediate) (set-wal) (rollback) (close))
                      '((open-read-only) (set-wal) (close))
                      (moves 0 0 0 0 0 0 2 2 2))))))

(test-equal "decision: set-wal on a read-only connection of a file not in WAL fails, and changes nothing"
  '(agree (set-wal fail real))
  (attempt (lambda ()
             (let ((r (script '(current delete) '()
                              '((open-read-only) (set-wal) (read-facts) (close))
                              (moves 2 2 2 2))))
               (list (report-verdict r)
                     (let ((h (assoc '(set-wal fail real) (report-hows r)))) (and h (car h))))))))

(test-equal "decision: a read-write open of a missing file makes it, fresh, in delete mode"
  'agree
  (attempt (lambda ()
             (report-verdict
              (script 'missing '((open-read-write) (read-facts) (close)) '() (moves 0 0 0))))))

(test-equal "decision: outside a transaction a statement and a stamp autocommit; COMMIT and ROLLBACK fail, flag #f"
  'agree
  (attempt (lambda ()
             (report-verdict
              (script '(fresh delete)
                      (list '(open-read-write) stmt-2.1 '(stamp . 1) '(commit) '(rollback)
                            '(read-facts) '(close))
                      '()
                      (moves 0 0 0 0 0 0 0))))))

;; while run 0 holds BEGIN IMMEDIATE with a table made, serve's actor,
;; read-write, is told busy at an autocommit statement, a stamp, BEGIN
;; IMMEDIATE and (not in WAL) set-wal; in WAL set-wal is a no-op ok. Once
;; run 0 commits, the statement autocommits.
(define (busy-script mode)
  (script (list 'fresh mode)
          (list '(open-read-write) '(begin-immediate) stmt-2.1 '(commit) '(close))
          (list '(open-read-write) stmt-2.2 '(stamp . 5) '(begin-immediate) '(set-wal) stmt-2.2
                '(close))
          (moves 0 0 0 2 2 2 2 2 0 2 2 0)))

(test-equal "decision: busy at once while another holds the lock, in delete mode: a statement, a stamp, BEGIN, set-wal"
  '(agree 1 1 1 1)
  (attempt (lambda ()
             (let* ((r (busy-script 'delete)) (h (report-hows r)))
               (cons (report-verdict r)
                     (map (lambda (k) (let ((x (assoc (list k 'busy 'real) h))) (and x (cdr x))))
                          '(run-statement stamp begin-immediate set-wal)))))))

(test-equal "decision: busy at once while another holds the lock, in WAL: a statement, a stamp, BEGIN; set-wal ok"
  '(agree 1 1 1 1)
  (attempt (lambda ()
             (let* ((r (busy-script 'wal)) (h (report-hows r)))
               (cons (report-verdict r)
                     (append
                      (map (lambda (k) (let ((x (assoc (list k 'busy 'real) h))) (and x (cdr x))))
                           '(run-statement stamp begin-immediate))
                      (list (let ((x (assoc '(set-wal ok real) h))) (and x (cdr x))))))))))

;; serve's actor reads while run 0 holds BEGIN IMMEDIATE with a table made
;; and the version stamped, uncommitted: it sees the last commit. Then run 0
;; commits, and the next read sees it.
(define (reader-script mode)
  (script (list '(behind 1) mode)
          (list '(open-read-write) '(begin-immediate) stmt-2.1 '(stamp . 2) '(commit) '(close))
          '((open-read-only) (read-facts) (read-facts) (close))
          (moves 0 0 0 0 2 2 0 2 2 0)))

(test-equal "decision: a read-only read beside another's uncommitted transaction sees the last commit, in delete mode"
  'agree
  (attempt (lambda () (report-verdict (reader-script 'delete)))))

(test-equal "decision: a read-only read beside another's uncommitted transaction sees the last commit, in WAL"
  'agree
  (attempt (lambda () (report-verdict (reader-script 'wal)))))

;; plain-file! : String Symbol -> Void   a table in it, in MODE, closed
(define (plain-file! p mode)
  (remove-files! p)
  (let ((db (open-database p '((busy-timeout . 0)))))
    (execute! db (string-append "PRAGMA journal_mode = " (symbol->string mode)))
    (execute! db "CREATE TABLE t (x)")
    (close-database! db)))

;; Not in the model: in delete mode a writer whose cache has spilled holds
;; the file's exclusive lock before its COMMIT, and a read is then told
;; busy. migrate's migrations are too small to spill here, and in one
;; thread no read lands inside a COMMIT, so no replay meets it. The model's
;; read-facts has no busy; its fail is sorted the same at every look, so
;; the machines take the same row either way, at migrate's two unlocked
;; looks and at serve's. With the real timeout of 5000 ms the read waits
;; instead.
(test-equal "decision: in delete mode a read beside a spilled transaction is busy (WAL: ok); busy sorts as the model's fail does"
  '(busy ok (failed failed failed))
  (attempt
   (lambda ()
     (let ((statuses
            (map (lambda (mode)
                   (let ((p (fresh-path)))
                     (plain-file! p mode)
                     (let ((w (make-shell p 0)) (r (make-shell p 0)))
                       (dynamic-wind
                         (lambda () #f)
                         (lambda ()
                           (perform! w '(open-read-write))
                           (perform! r '(open-read-only))
                           (execute! (shell-database w) "PRAGMA cache_size = 2")
                           (perform! w '(begin-immediate))
                           (let loop ((i 0))
                             (when (< i 400)
                               (execute! (shell-database w) "INSERT INTO t VALUES (randomblob(500))")
                               (loop (+ i 1))))
                           (car (perform! r '(read-facts))))
                         (lambda () (perform! w '(close)) (perform! r '(close)))))))
                 '(delete wal)))
           (data '(0 0 () #f 3 #f)) (busy '(busy "database is locked" #f))
           (fail '(failed "disk I/O error" #f)))
       (list (car statuses) (cadr statuses)
             (map (lambda (k)
                    (if (equal? (k busy) (k fail)) (k busy) (list 'differ (k busy) (k fail))))
                  (list (lambda (raw) (event-kind migrations (cons 'peeking data) raw))
                        (lambda (raw) (event-kind migrations (cons 'looking data) raw))
                        (lambda (raw) (check-event-kind migrations '(peeking) raw)))))))))

;; Refuted, outside migrate's reach: the model says BEGIN IMMEDIATE fails on
;; a read-only connection, as the other writes do. SQLite answers ok and
;; opens a read transaction (it begins one, not a write, on a database it
;; cannot write). migrate begins only on its read-write connection, so no
;; trace of it meets this, and the replay injects the model's failure
;; there; a machine that began on its read-only connection would see a
;; transaction the model does not have. Expected to fail until the model
;; gives that choice: when it passes, the suite says so.
(test-expect-fail 1)
(test-equal "decision refuted: BEGIN IMMEDIATE on a read-only connection; model (failed #f), SQLite (ok #t)"
  (attempt (lambda ()
             (let* ((c (cfg (shape 1 2) '(current wal) 1 #t))
                    (rm (script-replay-machine 'ro-begin '() '((open-read-only) (begin-immediate) (close))))
                    (s (cadr (trace-of-moves c rm (moves 2 2)))))
               (list (car (step-raw s)) (caddr (step-raw s))))))
  (attempt (lambda ()
             (let ((p (fresh-path)) (sh #f))
               (plain-file! p 'wal)
               (set! sh (make-shell p 0))
               (dynamic-wind
                 (lambda () #f)
                 (lambda ()
                   (perform! sh '(open-read-only))
                   (let ((o (perform! sh '(begin-immediate)))) (list (car o) (caddr o))))
                 (lambda () (perform! sh '(close))))))))

(test-end "migrations-replay")

(exit (suite-exit-status runner))
