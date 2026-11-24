#!r6rs
;;; The transaction replay suite: layer 4 of the slice 2b plan. The model's
;;; traces, from (transaction-model), replayed on real SQLite through
;;; (techo doorway)'s job-perform!, the procedure the doorway's workers
;;; call, so that the pure model layer 3 explores is held to what SQLite
;;; and the shell really do. The machinery is (transaction-replay-support);
;;; its header says what one replay compares.
;;;
;;;   - every trace (model-traces) of task 2's trace configuration, and of
;;;     a bigger one, whose two-write jobs reach what the first cannot (a
;;;     write after the one that ended a transaction);
;;;   - seeded random walks of the model's graph, which interleave the
;;;     three actors as no shortest trace does;
;;;   - traces aimed at a choice no shortest trace takes;
;;;   - two of the plan's mutant tables, replayed to agreement, for the
;;;     rows (W6, R5) and the deferred locking no real table reaches;
;;;   - coverage, and floors on traces, steps and the share of real steps;
;;;   - the layer 4 mutants of the model and of the shell, each seen to
;;;     differ at a real step;
;;;   - the model's assumptions this layer settles, on real connections;
;;;   - what the replay found: two differences between the model and the
;;;     shell, both off every path the real tables take, pinned.
;;;
;;; How each choice is made
;;; -----------------------
;;; Real: SQLite gives the outcome; the replay calls job-perform! once,
;;; after any staging named. Injected: SQLite cannot be made to give it
;;; from one thread on a good file, so job-perform! is not called; plain
;;; calls bring the connection's true state to the outcome reported. The
;;; same table is realization-claims in the support library, and the tests
;;; under "Coverage" hold every run to it, both ways.
;;;
;;; | Command         | Choice          | How                                                  |
;;; |-----------------|-----------------|------------------------------------------------------|
;;; | look            | present, absent | real                                                 |
;;; | begin-immediate | ok              | real                                                 |
;;; | begin-immediate | busy            | real: the other really holds BEGIN IMMEDIATE, and    |
;;; |                 |                 | every busy timeout is 0                              |
;;; | begin-immediate | failed-open     | real: a transaction left open (a mutant table: W6)   |
;;; | begin-immediate | failed-closed   | real on the writer: PRAGMA query_only = 1 first, so  |
;;; |                 |                 | SQLite answers readonly and begins nothing; reset    |
;;; |                 |                 | after. Injected on a read-only connection (a mutant  |
;;; |                 |                 | table), where it opens a read transaction regardless |
;;; | begin           | ok              | real                                                 |
;;; | begin           | failed-open     | real: a transaction left open (a mutant table: R5)   |
;;; | begin           | failed-closed   | injected: a plain BEGIN with none open does nothing  |
;;; |                 |                 | that can fail                                        |
;;; | read-version    | ok              | real                                                 |
;;; | read-version    | failed-open     | injected: only another thread's interrupt or a       |
;;; |                 |                 | broken file fails it; the transaction stays          |
;;; | read-version    | failed-closed   | injected: the same, ended by a real ROLLBACK         |
;;; | run-job         | returned-open,  | real: the job reads (tokens, version, tokens),       |
;;; |                 | raised-open     | writes its tokens, returns or raises                 |
;;; | run-job         | returned-closed,| real: then INSERT OR ROLLBACK into temp.trap         |
;;; |                 | raised-closed   | conflicts, and SQLite ends the transaction and       |
;;; |                 |                 | raises; the job tries its later writes, which the    |
;;; |                 |                 | handle must refuse, then returns or raises           |
;;; | commit          | ok              | real                                                 |
;;; | commit          | failed-open     | real: a dangling row put in dangle first; the        |
;;; |                 |                 | deferred foreign key refuses the COMMIT and leaves   |
;;; |                 |                 | the transaction open (cl. 3)                         |
;;; | commit          | failed-closed   | real with no transaction; injected in one: a real    |
;;; |                 |                 | ROLLBACK (a full disk is not staged)                 |
;;; | commit          | took-effect     | injected: a real COMMIT, reported failed             |
;;; | rollback        | ok              | real                                                 |
;;; | rollback        | failed-open     | injected: SQLite's ROLLBACK of an open transaction   |
;;; |                 |                 | does not fail; the transaction stays                 |
;;; | rollback        | failed-closed   | real with no transaction; injected in one: a real    |
;;; |                 |                 | ROLLBACK                                             |
;;; | close           | ok              | real                                                 |
;;; | close           | failed-gone     | injected: a close that raises cannot be staged; the  |
;;; |                 |                 | connection closed, the box emptied                   |
;;; | close           | failed-kept     | injected: the box emptied, the connection kept open, |
;;; |                 |                 | holding its transaction and lock                     |
;;; | (other)         | take, free,     | real: BEGIN IMMEDIATE; ROLLBACK; PRAGMA user_version |
;;; |                 | migrate         | then COMMIT, on the other process's connection       |
;;;
;;; Every file is under build/test-transaction-replay/<unique>/, emptied at
;;; the start; a file whose replay agreed is removed. Everything that can
;;; raise is computed under `attempt`, and a raise comes out as a value the
;;; expectation never is.
(import (rnrs)
        (only (chezscheme) mkdir directory-list delete-directory file-directory?
                           current-time time-second time-nanosecond real-time
                           box unbox set-box!)
        (srfi :64)
        (chez-sqlite3)
        (techo-testing)
        (techo migrations)
        (techo transaction)
        (techo doorway)
        (transaction-model)
        (transaction-replay-support))

(define runner (test-runner-simple))
(test-runner-current runner)

(define started (real-time))

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (iota-from a b) (if (> a b) '() (cons a (iota-from (+ a 1) b))))
(define (list-head* xs n) (if (or (null? xs) (= n 0)) '() (cons (car xs) (list-head* (cdr xs) (- n 1)))))

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
      (rm-tree! "build/test-transaction-replay")
      (make-dir! "build/test-transaction-replay")
      (let ((d (string-append "build/test-transaction-replay/"
                              (number->string (time-second t)) "-"
                              (number->string (time-nanosecond t)))))
        (make-dir! d)
        d))))

(define template (string-append (or test-dir "build") "/template.db"))
(define template-made (attempt (lambda () (make-template! template) 'made)))

(define file-count 0)

;; fresh-path : -> String    a name no replay has used
(define (fresh-path)
  (set! file-count (+ file-count 1))
  (string-append test-dir "/r" (number->string file-count) ".db"))

;;; Machines, as the model's suite makes its mutants

(define wtable (named-rows write-rows write-row-names))
(define rtable (named-rows read-rows read-row-names))

;; row-of : NamedTable StateKind EventKind -> NamedRow
(define (row-of t s e)
  (or (find (lambda (r) (and (eq? (cadr r) s) (eq? (caddr r) e))) t)
      (assertion-violation 'row-of "no such row" s e)))
(define (update-of t s e) (list-ref (row-of t s e) 5))

;; replace : NamedTable StateKind EventKind (U StateKind #f) (U CommandKind #f)
;;           (U Update #f) -> NamedTable
(define (replace t s e next cmd update)
  (row-of t s e)
  (map (lambda (r)
         (if (and (eq? (cadr r) s) (eq? (caddr r) e))
             (list (car r) s e (or next (list-ref r 3)) (or cmd (list-ref r 4))
                   (or update (list-ref r 5)))
             r))
       t))

(define wcommand (model-job-command 'begin-immediate))
(define rcommand (model-job-command 'begin))

;; table-replay-machine : Any NamedTable NamedTable (State -> Command) (State -> Command)
;;                        -> ReplayMachine
(define (table-replay-machine name w r wc rc)
  (replay-table-machine name w r wc rc job-event-kind job-event-kind))

;; W13 and R12 end without a ROLLBACK: the transaction left open, so the
;; next job's BEGIN fails with it open (W6, R5).
(define leaves-open
  (attempt
   (lambda ()
     (table-replay-machine
      'leaves-open
      (replace wtable 'running 'raised-open 'ended 'end (update-of wtable 'running 'raised-closed))
      (replace rtable 'running 'raised-open 'ended 'end (update-of rtable 'running 'raised-closed))
      wcommand rcommand))))

;; The write table begins with a plain BEGIN: a deferred transaction, whose
;; first write takes the lock unless another holds it or has committed
;; since its snapshot (the model's can-take-lock?, pa 6).
(define plain-begin
  (attempt (lambda () (table-replay-machine 'plain-begin (replace wtable 'start 'present #f 'begin #f)
                                            rtable (model-job-command 'begin) rcommand))))

;; The read table begins with BEGIN IMMEDIATE, which on a read-only
;; connection takes no lock and opens its read transaction at once: the
;; model's snapshot is then the BEGIN's (pa 2). The plan's equivalent.
(define read-immediate
  (attempt (lambda () (table-replay-machine 'read-immediate wtable
                                            (replace rtable 'start 'present #f 'begin-immediate #f)
                                            wcommand (model-job-command 'begin-immediate)))))

;; A transaction SQLite ended is committed anyway (W12 to committing) or
;; rolled back anyway (W14, R11 to a rollback): so COMMIT and ROLLBACK run
;; with no transaction open, which no real table does.
(define ended-anyway
  (attempt
   (lambda ()
     (table-replay-machine
      'ended-anyway
      (replace (replace wtable 'running 'returned-closed 'committing 'commit #f)
               'running 'raised-closed 'rolling-back 'rollback
               (update-of wtable 'running 'raised-open))
      (replace rtable 'running 'returned-closed 'ending 'rollback
               (lambda (d e) (list (car d) '(raise-ended))))
      wcommand rcommand))))

;;; Replaying, and what the replays saw

;; Keys, hows, reasons and offers of every replay that is not a mutant's,
;; for the coverage.
(define seen-keys (make-hashtable equal-hash equal?))
(define seen-hows (make-hashtable equal-hash equal?))
(define seen-reasons (make-hashtable equal-hash equal?))
(define seen-offers (make-hashtable equal-hash equal?))
(define replayed (vector 0 0))          ; traces, steps

;; replay : Config ReplayMachine Trace ReplayOptions -> Report
;; On a new file, removed once the replay agrees.
(define (replay c rm trace opts)
  (let* ((p (fresh-path)) (r (replay-trace c rm trace opts template p)))
    (when (eq? (report-verdict r) 'agree) (remove-db-files! p))
    r))

;; replay-counted : Config ReplayMachine Trace -> Report
;; An unmutated replay (the shell and the model as they are), recorded.
(define (replay-counted c rm trace)
  (let ((r (replay c rm trace default-replay-options)))
    (for-each (lambda (k) (hashtable-set! seen-keys k #t)) (report-keys r))
    (for-each (lambda (h) (hashtable-update! seen-hows (car h) (lambda (n) (+ n (cdr h))) 0))
              (report-hows r))
    (for-each (lambda (x) (hashtable-set! seen-reasons (car x) (cdr x))) (report-reasons r))
    (for-each (lambda (o) (hashtable-set! seen-offers o #t)) (report-offers r))
    (vector-set! replayed 0 (+ 1 (vector-ref replayed 0)))
    (vector-set! replayed 1 (+ (report-steps r) (vector-ref replayed 1)))
    r))

;; differing : (Listof (Pairof Any Trace)) Config ReplayMachine -> (Listof (List Any Verdict))
;; Each named trace replayed and counted; those that do not agree.
(define (differing named c rm)
  (let loop ((ts named) (bad '()))
    (if (null? ts)
        (reverse bad)
        (let ((v (report-verdict (replay-counted c rm (cdar ts)))))
          (loop (cdr ts) (if (eq? v 'agree) bad (cons (list (caar ts) v) bad)))))))

;; walks : Config ReplayMachine (Listof Natural) -> (Listof (Pairof Natural Trace))
(define (walks c rm seeds)
  (map (lambda (seed) (cons seed (walk-trace c rm seed 400))) seeds))

(define (name-of c) (call-with-string-output-port (lambda (p) (display (config-name c) p))))

(test-begin "transaction-replay")

(test-equal "the template: techo's migrations applied, the replay's tables, no -wal" 'made
  template-made)

;;; Every trace, and the walks

;; Task 2's trace configuration: between them its traces fire every row the
;; whole space fires (the model's suite holds that).
(define trace-config (make-config "writes (1 2), two reads, lock once, migrate" '(1 2) 2 1 #t))
;; Two-write jobs throughout: a write job's transaction ended with a write
;; still to come (the live-handle mutant's ground), and a third job.
(define three-config (make-config "writes (2 2 2), two reads, lock twice, migrate" '(2 2 2) 2 2 #t))
(define mixed-config (make-config "writes (1 2 1), two reads, lock three times, migrate" '(1 2 1) 2 3 #t))
(define calm-config (make-config "writes (2 2), two reads, lock twice, no migrate" '(2 2) 2 2 #f))

(define trace-traces (attempt (lambda () (model-traces trace-config real-machine))))
(define three-traces (attempt (lambda () (model-traces three-config real-machine))))

(test-equal "traces: task 2's configuration gives 38 traces of 700 steps"
  '(38 700)
  (attempt (lambda () (list (length trace-traces) (apply + (map (lambda (kt) (length (cdr kt))) trace-traces))))))

(test-equal (string-append "replay: every trace of " (name-of trace-config) " agrees with SQLite")
  '()
  (attempt (lambda () (differing trace-traces trace-config real-replay-machine))))

(test-equal (string-append "replay: every trace of " (name-of three-config) " agrees with SQLite")
  '()
  (attempt (lambda () (differing three-traces three-config real-replay-machine))))

(for-each
 (lambda (c)
   (test-equal (string-append "replay: walks 1 to 150 (400 steps at most) of " (name-of c)
                              " agree with SQLite; a failure lists (seed verdict)")
     '()
     (attempt (lambda () (differing (walks c real-replay-machine (iota-from 1 150)) c
                                    real-replay-machine)))))
 (list three-config mixed-config calm-config))

;;; Choices no shortest trace takes

;; first-but : (Step -> Boolean) -> ((Listof Step) -> Natural)
;; A chooser: the first next step for which WANT holds, else the first.
(define (first-but want)
  (lambda (steps)
    (let loop ((ss steps) (i 0))
      (cond ((null? ss) 0) ((want (car ss)) i) (else (loop (cdr ss) (+ i 1)))))))

(define (choice? who kind tag)
  (lambda (s) (and (eq? (step-who s) who) (eq? (car (step-command s)) kind)
                   (eq? (choice-tag (step-choice s)) tag))))

;; aimed : Config (Step -> Boolean) -> (List Verdict Natural (U Natural #f))
;; A trace that takes WANT's step whenever it can, replayed and counted:
;; the verdict, and how often WANT's kind of step was taken real and
;; injected.
(define (aimed c want key)
  (let* ((trace (trace-by-chooser c real-replay-machine (first-but want) 400))
         (r (replay-counted c real-replay-machine trace)))
    (list (report-verdict r)
          (let ((h (assoc (append key '(real)) (report-hows r)))) (if h (cdr h) 0))
          (let ((h (assoc (append key '(injected)) (report-hows r)))) (if h (cdr h) 0)))))

(test-equal "replay: COMMIT failed and took effect, whenever offered: agrees (injected: a real COMMIT)"
  '(agree 0 #t)
  (attempt (lambda ()
             (let ((v (aimed three-config (choice? 'writer 'commit 'took-effect)
                             '(commit took-effect))))
               (list (car v) (cadr v) (> (caddr v) 0))))))

(test-equal "replay: a close that fails and keeps its connection, on the writer: agrees"
  '(agree #t)
  (attempt (lambda ()
             (let ((v (aimed three-config
                             (lambda (s) (or ((choice? 'writer 'run-job 'raised-open) s)
                                             ((choice? 'writer 'rollback 'failed-open) s)
                                             ((choice? 'writer 'close 'failed-kept) s)))
                             '(close failed-kept))))
               (list (car v) (> (caddr v) 0))))))

(test-equal "replay: a close that fails and keeps its connection, on the reader: agrees"
  '(agree #t)
  (attempt (lambda ()
             (let ((v (aimed three-config
                             (lambda (s) (or ((choice? 'reader 'rollback 'failed-open) s)
                                             ((choice? 'reader 'close 'failed-kept) s)))
                             '(close failed-kept))))
               (list (car v) (> (caddr v) 0))))))

;;; The mutant tables, replayed to agreement

(for-each
 (lambda (entry)
   (let ((label (car entry)) (c (cadr entry)) (rm (caddr entry)))
     (test-equal (string-append "replay: " label ": every trace and walks 1 to 60 agree with SQLite")
       '()
       (attempt
        (lambda ()
          (append (differing (model-traces c (replay-machine-model rm)) c rm)
                  (differing (walks c rm (iota-from 1 60)) c rm)))))))
 (list (list "W13 and R12 leave the transaction open (W6, R5 fire)" trace-config leaves-open)
       (list "a plain BEGIN in the write table (deferred locking)"
             (make-config "writes (2 2), one read, lock twice, migrate" '(2 2) 1 2 #t) plain-begin)
       (list "BEGIN IMMEDIATE in the read table (the plan's equivalent)" trace-config
             read-immediate)
       (list "COMMIT or ROLLBACK after SQLite ended the transaction" trace-config ended-anyway)))

;;; Coverage

;; Every (who state-kind event-kind) of both tables, as the names list them.
(define all-keys
  (append (map (lambda (n) (list 'writer (cadr n) (caddr n))) write-row-names)
          (map (lambda (n) (list 'reader (cadr n) (caddr n))) read-row-names)))

;; The model never offers busy but at BEGIN IMMEDIATE while another holds
;; the lock (its suite's list of rows never fired, but W6 and R5, which the
;; mutant table above fires).
(define never-offered
  '((writer versioning busy) (writer committing busy) (writer rolling-back busy)
    (reader beginning busy) (reader versioning busy) (reader ending busy)))

(define (seen-key? k how) (hashtable-ref seen-keys (append k (list how)) #f))

(test-equal "coverage: every row the model fires was replayed, sorted from the REAL outcome"
  '()
  (filter (lambda (k) (not (or (seen-key? k 'real) (seen-key? k 'injected))))
          (filter (lambda (k) (not (member k never-offered))) all-keys)))

;; Rows reached only through an injection: each needs a failure SQLite
;; cannot be made to give here (the table's injected rows). W17, W18's and
;; R14's failed-closed are real on the table that commits or rolls back
;; after SQLite ended the transaction.
(test-equal "coverage: the rows replayed only by injection are exactly these"
  '((writer versioning failed-open) (writer versioning failed-closed)
    (writer rolling-back failed-open) (writer closing failed)
    (reader beginning failed-closed) (reader versioning failed-open)
    (reader versioning failed-closed) (reader ending failed-open)
    (reader closing failed))
  (filter (lambda (k) (and (seen-key? k 'injected) (not (seen-key? k 'real)))) all-keys))

(define (claimed claim)
  (map (lambda (c) (list (car c) (cadr c)))
       (filter (lambda (c) (memq (caddr c) claim)) realization-claims)))
(define (seen-how? cc how) (hashtable-ref seen-hows (append cc (list how)) #f))

;; Each choice the table makes real was made real somewhere above, so no
;; realization has quietly become an injection.
(test-equal "coverage: every choice the table calls real (or real in some cases) was made real"
  '()
  (filter (lambda (cc) (not (seen-how? cc 'real))) (claimed '(real either))))

(test-equal "coverage: every choice the table calls injected was injected"
  '()
  (filter (lambda (cc) (not (seen-how? cc 'injected))) (claimed '(injected either))))

(test-equal "coverage: no choice was injected that the table calls real, nor made real that it calls injected"
  '()
  (filter (lambda (h)
            (let* ((cc (list-head* h 2)) (how (caddr h))
                   (c (find (lambda (c) (equal? (list (car c) (cadr c)) cc)) realization-claims)))
              (not (and c (or (eq? (caddr c) 'either) (eq? (caddr c) how))))))
          (vector->list (hashtable-keys seen-hows))))

;; Every way the model offered a replayed call to go, at any step of any
;; replay above, was taken by some replay, real or injected.
(test-equal "coverage: every way the model offered a replayed call to go was replayed"
  '()
  (filter (lambda (o) (not (or (seen-how? o 'real) (seen-how? o 'injected))))
          (vector->list (hashtable-keys seen-offers))))

(define (how-total how)
  (fold-left (lambda (acc k) (if (eq? (caddr k) how) (+ acc (hashtable-ref seen-hows k 0)) acc))
             0 (vector->list (hashtable-keys seen-hows))))

;; Measured (2026-11-23) at 921 traces and 17,876 steps, 94.1% of them
;; real; the floors sit a little below.
(test-assert "coverage: at least 900 traces and 17,500 steps were replayed, 93% of them real"
  (let ((real (how-total 'real)) (inj (how-total 'injected)))
    (and (>= (vector-ref replayed 0) 900) (>= (vector-ref replayed 1) 17500)
         (>= (* 100 real) (* 93 (+ real inj))))))

;;; The layer 4 mutants of the model
;;;
;;; A model mutant makes the traces; the shell and SQLite are as they are.
;;; Each is held to the step and comparison that first differs, a real
;;; step, on a trace aimed at it; the unmutated model's trace of the same
;;; moves agrees beside it; and, for the three that need the actors
;;; interleaved, over the walks every verdict is at a real step. Over
;;; model-traces alone, busy-is-ok and no-busy survive: no shortest trace
;;; begins the writer while the other holds the lock.

;; head : Verdict -> Any     (step how comparison model real), or the verdict
(define (head v)
  (if (and (pair? v) (integer? (car v)) (= (length v) 9))
      (list (list-ref v 0) (list-ref v 5) (list-ref v 6) (list-ref v 7) (list-ref v 8))
      v))

(define (verdict-of c rm moves opts)
  (report-verdict (replay c rm (trace-of-moves c rm moves) opts)))

;; walk-kills : Config ReplayMachine ReplayOptions -> (List Natural Boolean)
;; Of walks 1 to 100, how many differ, and whether each did at a real step.
(define (walk-kills c rm opts)
  (let ((vs (filter (lambda (v) (not (eq? v 'agree)))
                    (map (lambda (seed) (report-verdict (replay c rm (walk-trace c rm seed 400) opts)))
                         (iota-from 1 100)))))
    (list (length vs) (for-all (lambda (v) (and (pair? v) (= (length v) 9) (eq? (list-ref v 5) 'real)))
                               vs))))

(define (mutated c m) (config-with-model-mutant c m))

;; The other takes the lock, then the writer begins.
(define begin-under-lock '((writer . present) (other . take) (writer . #f)))

(test-equal "mutant: model: busy made a success: differs at the writer's BEGIN IMMEDIATE, real, by its status"
  '(3 real status ok busy)
  (attempt (lambda () (head (verdict-of (mutated trace-config 'busy-is-ok) real-replay-machine
                                        '((writer . present) (other . take) (writer . ok))
                                        default-replay-options)))))

(test-equal "mutant: model: busy made a success: the unmutated model's busy there agrees"
  'agree
  (attempt (lambda () (verdict-of trace-config real-replay-machine begin-under-lock
                                  default-replay-options))))

(test-equal "mutant: model: busy made a success: some walks differ, each at a real step"
  '(#t #t)
  (attempt (lambda () (let ((k (walk-kills (mutated three-config 'busy-is-ok) real-replay-machine
                                           default-replay-options)))
                        (list (> (car k) 0) (cadr k))))))

;; The model's snapshot taken at BEGIN, not at the first read: the model is
;; given the read table that begins with BEGIN IMMEDIATE (whose snapshot is
;; the BEGIN's, in the model as in SQLite), and the shell is handed a plain
;; BEGIN for it. So the model believes BEGIN takes the snapshot and the
;; shell does what the real read table does.
(define snapshot-at-begin
  (make-replay-options shell-exec
                       (lambda (who cmd)
                         (if (and (eq? who 'reader) (equal? cmd '(begin-immediate))) '(begin) cmd))))
(define migrate-after-begin
  '((reader . #f) (reader . #f) (other . take) (other . migrate) (reader . #f)))

(test-equal "mutant: model: the snapshot taken at BEGIN: differs at the version read, real, by its value"
  '(5 real value 1 2)
  (attempt (lambda () (head (verdict-of trace-config read-immediate migrate-after-begin
                                        snapshot-at-begin)))))

(test-equal "mutant: model: the snapshot taken at BEGIN: the same moves, unmutated, agree (R7: moved)"
  '(agree R7)
  (attempt (lambda ()
             (let ((t (trace-of-moves trace-config real-replay-machine migrate-after-begin)))
               (list (report-verdict (replay trace-config real-replay-machine t
                                             default-replay-options))
                     (step-row (list-ref t 4)))))))

(test-equal "mutant: model: the snapshot taken at BEGIN: some walks differ, each at a real step"
  '(#t #t)
  (attempt (lambda () (let ((k (walk-kills trace-config read-immediate snapshot-at-begin)))
                        (list (> (car k) 0) (cadr k))))))

;; A read job's version read, then a write job committed, then the read
;; job's body.
(define commit-under-snapshot
  '((reader . present) (reader . ok) (reader . ok)
    (writer . present) (writer . ok) (writer . ok) (writer . (returned-open . 1)) (writer . ok)
    (reader . (returned-open . 0))))

(test-equal "mutant: model: a read never takes its snapshot: differs at the read job's body, real, by what it saw"
  '(9 real saw ((1) 1) (() 1))
  (attempt (lambda () (head (verdict-of (mutated trace-config 'no-snapshot) real-replay-machine
                                        commit-under-snapshot default-replay-options)))))

(test-equal "mutant: model: a read never takes its snapshot: unmutated, the body saw nothing new (T7, cl. 5)"
  'agree
  (attempt (lambda () (verdict-of trace-config real-replay-machine commit-under-snapshot
                                  default-replay-options))))

(test-equal "mutant: model: a read never takes its snapshot: some walks differ, each at a real step"
  '(#t #t)
  (attempt (lambda () (let ((k (walk-kills (mutated three-config 'no-snapshot) real-replay-machine
                                           default-replay-options)))
                        (list (> (car k) 0) (cadr k))))))

;; A job of two writes whose transaction SQLite ends before its first.
(define ended-before-first
  '((writer . present) (writer . ok) (writer . ok) (writer . (returned-closed . 0))))

(test-equal "mutant: model: the handle lives on after SQLite ended the transaction: differs at the job, real, by the file"
  '(4 real file-writes (2) ())
  (attempt (lambda () (head (verdict-of (mutated three-config 'live-handle) real-replay-machine
                                        ended-before-first default-replay-options)))))

(test-equal "mutant: model: the handle lives on: unmutated, the job's later write was refused"
  'agree
  (attempt (lambda () (verdict-of three-config real-replay-machine ended-before-first
                                  default-replay-options))))

(define one-commit '((writer . present) (writer . ok) (writer . ok) (writer . (returned-open . 1))
                     (writer . ok)))

(test-equal "mutant: model: a COMMIT that answers ok writes nothing: differs at the COMMIT, real, by the file"
  '(5 real file-writes () (1))
  (attempt (lambda () (head (verdict-of (mutated trace-config 'commit-drops) real-replay-machine
                                        one-commit default-replay-options)))))

(test-equal "mutant: model: a COMMIT that answers ok writes everything twice: differs at the COMMIT, real, by the file"
  '(5 real file-writes (1 1) (1))
  (attempt (lambda () (head (verdict-of (mutated trace-config 'commit-doubles) real-replay-machine
                                        one-commit default-replay-options)))))

(test-equal "mutant: model: the two COMMIT mutants: unmutated, the COMMIT agrees"
  'agree
  (attempt (lambda () (verdict-of trace-config real-replay-machine one-commit
                                  default-replay-options))))

(test-equal "mutant: model: BEGIN IMMEDIATE never busy: differs at it, real, as busy is not offered with the lock held"
  '(3 real busy-offered-while-locked #f #t)
  (attempt (lambda () (head (verdict-of (mutated trace-config 'no-busy) real-replay-machine
                                        begin-under-lock default-replay-options)))))

;; Survives, as it must: it takes away the failed COMMIT that did not take
;; effect, an injected choice, and the replay sees only what the model
;; says happens, not what it leaves out. Layer 3 holds it (a test there).
(test-equal "mutant: model: every failed COMMIT that ends took effect: survives every trace (injected; an omission)"
  '()
  (attempt (lambda ()
             (let ((c (mutated trace-config 'failed-commit-took-effect)))
               (filter (lambda (kv) (not (eq? (report-verdict (cdr kv)) 'agree)))
                       (map (lambda (kt) (cons (car kt) (replay c real-replay-machine (cdr kt)
                                                                default-replay-options)))
                            (model-traces c real-machine)))))))

;;; The layer 4 mutants of the shell
;;;
;;; Each wraps job-perform!. Every trace of the trace configuration is
;;; replayed with it; held: some differ, and the first that does differs at
;;; a real step, by the comparison named. The first four, and a handle that
;;; lives on after SQLite ended the transaction, were also planted by hand
;;; in copies of src/techo/doorway.sls put first on the library path
;;; (2026-11-23): each turned this suite red.

(define (shell-mutant f) (make-replay-options f (lambda (who cmd) cmd)))

(define rollback-does-nothing
  (shell-mutant (lambda (who b sh cmd job)
                  (if (and (unbox b) (eq? (car cmd) 'rollback))
                      (list 'ok #t (in-transaction? (unbox b)))
                      (job-perform! sh cmd job)))))
(define commit-rolls-back
  (shell-mutant (lambda (who b sh cmd job)
                  (job-perform! sh (if (eq? (car cmd) 'commit) '(rollback) cmd) job))))
(define version-constant
  (shell-mutant (lambda (who b sh cmd job)
                  (if (and (unbox b) (eq? (car cmd) 'read-version))
                      (list 'ok 1 (in-transaction? (unbox b)))
                      (job-perform! sh cmd job)))))
;; The reader's (rollback) does nothing and answers ok, no transaction: a
;; lie no lock shows, since a reader holds none.
(define reader-rollback-lies
  (shell-mutant (lambda (who b sh cmd job)
                  (if (and (eq? who 'reader) (unbox b) (eq? (car cmd) 'rollback))
                      (list 'ok #t #f)
                      (job-perform! sh cmd job)))))
(define close-keeps
  (shell-mutant (lambda (who b sh cmd job)
                  (if (and (unbox b) (eq? (car cmd) 'close))
                      (begin (set-box! b #f) (list 'ok #t #f))
                      (job-perform! sh cmd job)))))

;; first-kill : ReplayOptions -> Any
;; Over the trace configuration's traces: (key step how comparison) of the
;; first that differs, and how many differ.
(define (first-kill opts)
  (let ((vs (filter (lambda (kv) (not (eq? (cdr kv) 'agree)))
                    (map (lambda (kt) (cons (car kt) (report-verdict (replay trace-config real-replay-machine
                                                                             (cdr kt) opts))))
                         trace-traces))))
    (if (null? vs)
        'survives
        (let ((v (cdar vs)))
          (list (car (caar vs)) (list-ref v 0) (list-ref v 3) (list-ref v 5) (list-ref v 6)
                (length vs))))))

(test-equal "mutant: shell: (rollback) does nothing: W1's trace differs at its read job's ROLLBACK, real, by open?"
  '(W1 15 (rollback) real open 34)
  (attempt (lambda () (first-kill rollback-does-nothing))))

(test-equal "mutant: shell: (commit) runs ROLLBACK: W1's trace differs at the COMMIT, real, by the file"
  '(W1 5 (commit) real file-writes 31)
  (attempt (lambda () (first-kill commit-rolls-back))))

;; Caught first not by a value (W8's trace, later, is) but by what a body
;; saw: a version read that does not reach SQLite starts no snapshot, so a
;; read job's body, after a migrate, sees the file as it is then.
(test-equal "mutant: shell: the version read answers 1 always: R6's trace differs at the read job's body, real, by what it saw"
  '(R6 14 (run-job) real saw 3)
  (attempt (lambda () (first-kill version-constant))))

;; Seen at once by the reader's transaction flag (else only at its next
;; BEGIN, which fails with the transaction open).
(test-equal "mutant: shell: the reader's (rollback) does nothing, answers no transaction: W1's trace differs there, real, by the reader's transaction"
  '(W1 15 (rollback) real reader-transaction 34)
  (attempt (lambda () (first-kill reader-rollback-lies))))

;; The connection left open still holds the transaction a failed ROLLBACK
;; left, and so the lock: the observer is told busy.
(test-equal "mutant: shell: (close) empties the box and does not close: W19's trace differs at the close, real, by the lock"
  '(W19 5 (close) real write-lock 6)
  (attempt (lambda () (first-kill close-keeps))))

;;; The model's assumptions, on real connections
;;;
;;; Of task 2's thirteen, those this layer can settle. Where a trace above
;;; already makes one real, the test names the trace; else it is shown here
;;; directly, through job-perform! on boxes as doorway-set-up makes them.

;; with-actors : ((Box Box Database) -> A) -> A
;; A writer's box, a reader's box and a plain read-write connection on a
;; fresh copy of the template, every busy timeout 0; all closed after.
(define (with-actors proc)
  (let* ((p (fresh-path)) (_ (remove-db-files! p)))
    (let ((bv (call-with-port (open-file-input-port template) get-bytevector-all)))
      (call-with-port (open-file-output-port p) (lambda (port) (put-bytevector port bv))))
    (let* ((wb (doorway-set-up p 'read-write (list (car migrations)) 0))
           (rb (doorway-set-up p 'read-only (list (car migrations)) 0))
           (other (open-database p 'read-write '((busy-timeout . 0)))))
      (dynamic-wind
        (lambda () #f)
        (lambda () (proc wb rb other p))
        (lambda ()
          (doorway-tear-down rb) (doorway-tear-down wb)
          (guard (e (#t #f)) (close-database! other)))))))

(define (perform b cmd)
  (let ((raw (job-perform! (make-job-shell b) cmd (lambda (tx) #f))))
    (list (car raw) (caddr raw) (job-event-kind cmd raw))))

(define (version-in p)
  (let ((db (open-database p 'read-only '((busy-timeout . 0)))))
    (dynamic-wind (lambda () #f)
                  (lambda () (vector-ref (query-row db "PRAGMA user_version") 0))
                  (lambda () (close-database! db)))))

(test-equal "assumption: BEGIN with a transaction open fails and leaves it open, on both connections"
  '((ok #t ok) (failed #t failed-open) (ok #t ok) (failed #t failed-open))
  (attempt
   (lambda ()
     (with-actors
      (lambda (wb rb other p)
        (list (perform wb '(begin-immediate)) (perform wb '(begin-immediate))
              (perform rb '(begin)) (perform rb '(begin))))))))

(test-equal "assumption: W6 and R5 were replayed real, on the mutant table that leaves a transaction open"
  '(#t #t)
  (list (and (seen-key? '(writer beginning failed-open) 'real) #t)
        (and (seen-key? '(reader beginning failed-open) 'real) #t)))

(test-equal "assumption: COMMIT and ROLLBACK with no transaction fail, open? false: failed-closed"
  '((failed #f failed-closed) (failed #f failed-closed) (failed #f failed-closed))
  (attempt
   (lambda ()
     (with-actors
      (lambda (wb rb other p)
        (list (perform wb '(commit)) (perform wb '(rollback)) (perform rb '(rollback))))))))

;; The deferred-key trace (W16): the COMMIT made to fail for real; the
;; replay compared, after it, the file (nothing of the job), the writer's
;; transaction (open) and the write lock (held).
(test-equal "assumption: a COMMIT refused by a deferred foreign key: its trace agrees, the COMMIT real"
  '(agree #t)
  (attempt (lambda ()
             (let ((r (replay trace-config real-replay-machine
                              (cdr (assoc '(W16 committing failed-open) trace-traces))
                              default-replay-options)))
               (list (report-verdict r) (and (assoc '(commit failed-open real) (report-hows r)) #t))))))

(test-equal "assumption: INSERT OR ROLLBACK ends the transaction mid-job: W12, W14, R11, R13 replayed real"
  '(#t #t #t #t)
  (map (lambda (k) (and (seen-key? k 'real) #t))
       '((writer running returned-closed) (writer running raised-closed)
         (reader running returned-closed) (reader running raised-closed))))

(test-equal "assumption: another process commits a version change only while it holds the write lock"
  '(busy 1 ok 2 1)
  (attempt
   (lambda ()
     (with-actors
      (lambda (wb rb other p)
        (let* ((wsh (make-job-shell wb)) (rsh (make-job-shell rb)))
          ;; the writer holds the lock: an autocommit change is refused
          (job-perform! wsh '(begin-immediate) #f)
          (let* ((refused (guard (e ((sqlite-busy? e) 'busy))
                            (execute! other "PRAGMA user_version = 2") 'committed))
                 (v1 (version-in p)))
            (job-perform! wsh '(rollback) #f)
            ;; a reader in its snapshot holds nothing: the other's change,
            ;; under its own BEGIN IMMEDIATE, commits
            (job-perform! rsh '(begin) #f)
            (job-perform! rsh '(read-version . 1) #f)
            (let ((ok (guard (e (#t 'refused))
                        (execute! other "BEGIN IMMEDIATE")
                        (execute! other "PRAGMA user_version = 2")
                        (execute! other "COMMIT")
                        'ok)))
              (list refused v1 ok (version-in p)
                    (cadr (job-perform! rsh '(read-version . 1) #f)))))))))))

;; In the trace: the reader BEGINs; the other takes the lock (so the BEGIN
;; holds none) and commits version 2; the reader's version read sees 2 (so
;; its snapshot had not started). The replay compared the lock and the
;; read's value at each step.
(test-equal "assumption: a plain BEGIN on the read-only connection takes no lock; its snapshot starts at the first read"
  '(agree (ok 2 #t))
  (attempt (lambda ()
             (let ((t (trace-of-moves trace-config real-replay-machine migrate-after-begin)))
               (list (report-verdict (replay trace-config real-replay-machine t default-replay-options))
                     (step-raw (list-ref t 4)))))))

;; T7: what a read job sees is a prefix of the commits (each replayed read
;; job's body was held to the model's snapshot, the saw comparison), the
;; same prefix for its whole run. In one thread nothing commits between two
;; reads of a replayed body, so here a commit lands between them, from
;; inside the body, on the writer's connection. The same body with no BEGIN
;; sees the commit: the check is seen to fail without the transaction.
(test-equal "T7: a read job's body reads one snapshot, whatever commits during it; without BEGIN it would not"
  '(((() ()) (5) (5)) ((() (5)) (5) (5)))
  (attempt
   (lambda ()
     (map (lambda (begin?)
            (with-actors
             (lambda (wb rb other p)
               (let* ((rsh (make-job-shell rb)) (w (unbox wb)) (seen #f))
                 (define (rows->toks rows) (map (lambda (r) (vector-ref r 0)) rows))
                 (define sql "SELECT tok FROM tokens ORDER BY n")
                 ;; read, a commit from inside the body, read again
                 (define (twice read)
                   (let* ((a (read))
                          (_ (execute! w "INSERT INTO tokens (tok) VALUES (5)"))
                          (b (read)))
                     (set! seen (list a b))))
                 (if begin?
                     (begin (job-perform! rsh '(begin) #f)
                            (job-perform! rsh '(read-version . 1) #f)
                            (job-perform! rsh '(run-job)
                                          (lambda (tx) (twice (lambda () (rows->toks (tx-query tx sql))))))
                            (job-perform! rsh '(rollback) #f))
                     ;; outside a transaction the handle dies at its first
                     ;; call, so this body reads on the bare connection
                     (twice (lambda () (rows->toks (query (unbox rb) sql)))))
                 (list seen
                       (map (lambda (r) (vector-ref r 0))
                            (query (unbox rb) "SELECT tok FROM tokens ORDER BY n"))
                       (map (lambda (r) (vector-ref r 0))
                            (query other "SELECT tok FROM tokens ORDER BY n")))))))
          '(#t #f)))))

;;; Found: the model and the shell differ, off the real tables' paths
;;;
;;; Neither is reachable from (techo transaction)'s tables, and so no
;;; property layer 3 checks depends on it; each is seen on a mutant table,
;;; and each is pinned until the model changes. When one passes, the suite
;;; says so (an unexpected pass fails it).

;; A job run with no transaction: the model has each write commit at once
;; and the job return having made all n (job-choices, its last clause).
;; The handle commits the first write and dies at that call (in-transaction?
;; is false on its way out), so the job's second write is refused. A
;; table that runs (run-job) from start, W1 to running, shows it: the
;; second job's two writes, model (1 11 12), SQLite (1 11). The model's
;; change: in job-choices's last clause, cap k at 1 for both kinds:
;; (append (each 'returned-closed 0 (min n 1)) (each 'raised-closed 0 (min n 1))).
(define no-begin
  (attempt (lambda () (table-replay-machine 'no-begin
                                            (replace wtable 'start 'present 'running 'run-job #f)
                                            rtable wcommand rcommand))))

(test-expect-fail 1)
(test-equal "found: a job with no transaction: the model commits its every write, the handle only its first"
  'agree
  (attempt (lambda () (verdict-of trace-config no-begin
                                  '((writer . present) (writer . (returned-closed . 1))
                                    (writer . present) (writer . (returned-closed . 2)))
                                  default-replay-options))))

(test-equal "found: a job with no transaction: the difference is the second job's write 1.2, at the job's step"
  '(4 real file-writes (1 11 12) (1 11))
  (attempt (lambda () (head (verdict-of trace-config no-begin
                                        '((writer . present) (writer . (returned-closed . 1))
                                          (writer . present) (writer . (returned-closed . 2)))
                                        default-replay-options)))))

;; (close) on an empty box: the model answers (failed "no connection" #f);
;; job-perform! answers (ok #t #f). W20 and R16 take ok and failed alike,
;; so no row differs. No real table closes an empty box: a close follows
;; only a ROLLBACK that failed with its transaction open, which needs a
;; connection. Shown on a table whose W2 (an empty box) goes to closing.
;; The model's change, in model-choices's (close) case: an empty box
;; answers ok, as the shell does.
(define close-empty
  (attempt (lambda () (table-replay-machine 'close-empty
                                            (replace wtable 'start 'absent 'closing 'close
                                                     (lambda (d e) (list (car d) '(refuse . unavailable))))
                                            rtable wcommand rcommand))))
(define to-empty-close
  '((writer . present) (writer . ok) (writer . ok) (writer . (raised-open . 0))
    (writer . failed-open) (writer . ok) (writer . absent) (writer . #f)))

(test-expect-fail 1)
(test-equal "found: (close) on an empty box: the model says failed, the shell ok"
  'agree
  (attempt (lambda () (verdict-of trace-config close-empty to-empty-close default-replay-options))))

(test-equal "found: (close) on an empty box: the difference is the close's status, failed against ok"
  '(8 real status failed ok)
  (attempt (lambda () (head (verdict-of trace-config close-empty to-empty-close
                                        default-replay-options)))))

;;; The time

(define seconds (/ (- (real-time) started) 1000.0))
(put-string (current-output-port)
            (string-append "transaction-replay: " (number->string (vector-ref replayed 0))
                           " traces, " (number->string (vector-ref replayed 1)) " steps, "
                           (number->string (how-total 'real)) " real, "
                           (number->string (how-total 'injected)) " injected, "
                           (number->string seconds) " s\n"))

;; Measured (2026-11-23) at 11 s on an idle host of 18 cores, and 54 s with
;; 24 busy loops beside it. Half the timeout: room for load, not for growth.
(test-assert "time: the suite ran in under 150 s (its timeout is 300)"
  (< seconds 150))

(test-end "transaction-replay")

(exit (suite-exit-status runner))
