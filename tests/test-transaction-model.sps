#!r6rs
;;; The transaction model suite: layer 3 of the slice 2b plan. The real
;;; tables of (techo transaction), explored against the pure model of a
;;; file, its write lock, the doorway's two threads and another process in
;;; (transaction-model):
;;;   - the model's own clauses, call by call;
;;;   - named configurations, each with a floor on its worlds, T1, T2, T4,
;;;     T5, T6, T9 and T10 in every world, no cycle; N1 (this suite's own:
;;;     with no failure, every job answers) on each nominal graph;
;;;   - the rows that fired, against the tables' names;
;;;   - the plan's layer 3 mutants, each on a small configuration with the
;;;     property it names, and mutants of the model, so that the model is
;;;     seen to matter;
;;;   - machine 3, serve, explored by itself, T8;
;;;   - the traces the replay (layer 4) takes.
;;;
;;; T3 and T7 are not here, and no check stands in for them. T3 (a read
;;; completes while the writer is stalled): in the model a reader never
;;; waits for the writer, so nothing here could fail it; layer 5 holds it.
;;; T7 (a read job sees one prefix of the commits for its whole run): in the
;;; model a job's body is one step, so it cannot see two; layer 4 holds it.
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo transaction)
        (transaction-model))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (iota-from a b) (if (> a b) '() (cons a (iota-from (+ a 1) b))))

;; split : String String -> (Listof String)
(define (split s sep)
  (let ((n (string-length s)) (k (string-length sep)))
    (let loop ((i 0) (from 0) (acc '()))
      (cond ((> (+ i k) n) (reverse (cons (substring s from n) acc)))
            ((string=? (substring s i (+ i k)) sep)
             (loop (+ i k) (+ i k) (cons (substring s from i) acc)))
            (else (loop (+ i 1) from acc))))))

;; property-of : String -> String     "T1: ..." -> "T1"
(define (property-of seg)
  (let loop ((i 0))
    (cond ((= i (string-length seg)) seg)
          ((char=? (string-ref seg i) #\:) (substring seg 0 i))
          (else (loop (+ i 1))))))

(define (brief-step s)
  (list (step-who s) (step-choice s) (car (step-command s)) (step-row s)))

;; outcome : Result -> (U 'ok 'cycle (Listof String) Any)
(define (outcome r)
  (cond ((and (pair? r) (eq? (car r) 'ok)) 'ok)
        ((and (pair? r) (eq? (car r) 'cycle)) 'cycle)
        ((and (pair? r) (eq? (car r) 'violated))
         (map property-of (split (cadr r) " | ")))
        (else r)))

;; brief : Result -> Any   evidence for a failure
(define (brief r)
  (cond ((and (pair? r) (eq? (car r) 'violated))
         (list 'violated (cadr r) (map brief-step (caddr r))))
        ((and (pair? r) (eq? (car r) 'cycle))
         (list 'cycle (map brief-step (cadr r))))
        (else r)))

;; cfg : Any (Listof Positive-Integer) Natural Natural Boolean -> Config
;; Capped, so that a mutant whose graph is far bigger fails, not hangs.
(define (cfg name writes reads takes migrate?)
  (config-with-cap (make-config name writes reads takes migrate?) 3000000))

;;; Tables, rows and mutants

(define wtable (named-rows write-rows write-row-names))
(define rtable (named-rows read-rows read-row-names))
(define stable (named-rows serve-rows serve-row-names))

;; row-of : NamedTable StateKind EventKind -> NamedRow
(define (row-of t s e)
  (or (find (lambda (r) (and (eq? (cadr r) s) (eq? (caddr r) e))) t)
      (assertion-violation 'row-of "no such row" s e)))
(define (update-of t s e) (list-ref (row-of t s e) 5))

;; replace : NamedTable StateKind EventKind (U StateKind #f) (U CommandKind #f)
;;           (U Update #f) -> NamedTable
;; The row for (S, E) with its next state, command kind or update replaced,
;; #f keeping the row's own. Raises if there is no such row.
(define (replace t s e next cmd update)
  (row-of t s e)
  (map (lambda (r)
         (if (and (eq? (cadr r) s) (eq? (caddr r) e))
             (list (car r) s e (or next (list-ref r 3)) (or cmd (list-ref r 4))
                   (or update (list-ref r 5)))
             r))
       t))

;; retarget : NamedTable StateKind CommandKind -> NamedTable
;; Every row into NEXT given command kind CMD: for a mutant that changes
;; what NEXT asks.
(define (retarget t next cmd)
  (map (lambda (r) (if (eq? (list-ref r 3) next)
                       (list (car r) (cadr r) (caddr r) next cmd (list-ref r 5))
                       r))
       t))

(define (same d e) d)
(define wcommand (model-job-command 'begin-immediate))
(define rcommand (model-job-command 'begin))

;; mutant-machine : NamedTable NamedTable [Command-of Command-of Kind Kind] -> Machine
(define mutant-machine
  (case-lambda
    ((w r) (mutant-machine w r wcommand rcommand))
    ((w r wc rc) (table-machine 'mutant w r wc rc job-event-kind job-event-kind))
    ((w r wc rc wk rk) (table-machine 'mutant w r wc rc wk rk))))

(define (real) real-machine)

;; kill : (-> Config) (-> Machine) (U String Symbol) -> Any
;; EXPECT when the exploration ends that way (a violation naming the
;; property, among any others it names; ok; cycle), else the evidence.
(define (kill config machine expect)
  (attempt
   (lambda ()
     (let* ((r (model-explore (config) (machine) #f)) (o (outcome r)))
       (cond ((and (string? expect) (list? o) (member expect o)) expect)
             ((and (symbol? expect) (eq? o expect)) expect)
             (else (brief r)))))))

;; kill-length : (-> Config) (-> Machine) -> (U Natural Any)
;; The length of the shortest trace to the violation.
(define (kill-length config machine)
  (attempt
   (lambda ()
     (let ((r (model-explore (config) (machine) #f)))
       (if (eq? (car r) 'violated) (length (caddr r)) (brief r))))))

;; The small configurations the mutants run on
(define (two-two) (cfg "two writes of two, two reads, lock once, migrate" '(2 2) 2 1 #t))
(define (two-one) (cfg "two writes of one, one read, lock once, migrate" '(1 1) 1 1 #t))
(define (one-two) (cfg "one write of two, one read, lock once, migrate" '(2) 1 1 #t))

;; A mutant: name, expected property, configuration, machine, and its
;; trace length when the plan's.
(define (mutant name expect config machine) (list name expect config machine))

(define table-mutants
  (list
   (mutant "W15 answers before COMMIT (W11 answers)" "T5" one-two
           (lambda () (mutant-machine
                       (replace wtable 'running 'returned-open 'ended 'end
                                (update-of wtable 'committing 'ok))
                       rtable)))
   (mutant "W13 ends without a ROLLBACK" "T1" one-two
           (lambda () (mutant-machine
                       (replace wtable 'running 'raised-open 'ended 'end
                                (update-of wtable 'running 'raised-closed))
                       rtable)))
   (mutant "R10 ends without a ROLLBACK" "T9" one-two
           (lambda () (mutant-machine
                       wtable
                       (replace rtable 'running 'returned-open 'ended 'end
                                (lambda (d e) '(answer))))))
   (mutant "W8 runs the job anyway" "T6" one-two
           (lambda () (mutant-machine
                       (replace wtable 'versioning 'moved 'running 'run-job same)
                       rtable)))
   ;; Reading the version before BEGIN, outside a transaction, needs its
   ;; event kind changed too: job-event-kind sorts an ok version read with
   ;; no transaction open as failed-closed, and with it no job ever runs.
   (mutant "the version read moved before BEGIN" "T6" one-two
           (lambda ()
             (mutant-machine
              (replace (replace (replace wtable 'start 'present 'versioning 'read-version #f)
                                'versioning 'same 'beginning 'begin-immediate same)
                       'beginning 'ok 'running 'run-job same)
              rtable wcommand rcommand
              (lambda (cmd raw)
                (if (and (eq? (car cmd) 'read-version) (eq? (car raw) 'ok))
                    (if (= (cadr raw) (cdr cmd)) 'same 'moved)
                    (job-event-kind cmd raw)))
              job-event-kind)))
   (mutant "BEGIN IMMEDIATE made a plain BEGIN in the write table" "T1" one-two
           (lambda () (mutant-machine (replace wtable 'start 'present #f 'begin #f) rtable
                                      (model-job-command 'begin) rcommand)))
   (mutant "W19 ends without closing" "T1" one-two
           (lambda ()
             (let ((finish (update-of wtable 'rolling-back 'ok)))
               (mutant-machine
                (replace (replace wtable 'rolling-back 'busy 'ended 'end finish)
                         'rolling-back 'failed-open 'ended 'end finish)
                rtable))))
   (mutant "W2 begins a transaction on an empty box" "T10" two-one
           (lambda () (mutant-machine
                       (replace wtable 'start 'absent 'beginning 'begin-immediate same)
                       rtable)))
   ;; This suite's own, for what no plan mutant reaches
   ;; The shortest kill is a job that raised before its first write: its
   ;; empty commit is answered, so T5; a test below sees T4 with T5 off.
   (mutant "own: W13 commits what the job wrote before it raised" "T5" one-two
           (lambda () (mutant-machine
                       (replace wtable 'running 'raised-open 'committing 'commit same)
                       rtable)))
   (mutant "own: W7 rolls back and refuses as moved" "N1" one-two
           (lambda () (mutant-machine
                       (replace wtable 'versioning 'same 'rolling-back 'rollback
                                (update-of wtable 'versioning 'moved))
                       rtable)))
   (mutant "own: R6 skips the job and answers" "T2" one-two
           (lambda () (mutant-machine
                       wtable
                       (replace rtable 'versioning 'same 'ending 'rollback
                                (update-of rtable 'running 'returned-open)))))
   ;; A COMMIT that failed may have taken effect: a retry then commits the
   ;; job twice. Without the model's took-effect it would only cycle.
   (mutant "own: W17 retries the job" "T4" one-two
           (lambda () (mutant-machine
                       (replace wtable 'committing 'failed-closed 'beginning 'begin-immediate
                                same)
                       rtable)))))

(define model-mutants
  (list
   (mutant "model: a read transaction's snapshot never taken" "T6"
           (lambda () (config-with-model-mutant (one-two) 'no-snapshot)) real)
   (mutant "model: BEGIN IMMEDIATE answers ok where it would be busy" "T1"
           (lambda () (config-with-model-mutant (one-two) 'busy-is-ok)) real)
   (mutant "model: the handle lives on after SQLite ended the transaction" "T4"
           (lambda () (config-with-model-mutant (one-two) 'live-handle)) real)
   (mutant "model: a COMMIT that answers ok writes nothing" "T5"
           (lambda () (config-with-model-mutant (one-two) 'commit-drops)) real)
   (mutant "model: a COMMIT that answers ok writes everything twice" "T4"
           (lambda () (config-with-model-mutant (one-two) 'commit-doubles)) real)))

(test-begin "transaction-model")

;;; The model's own clauses, call by call

;; drive : Config Machine (Listof (Pairof Who Choice)) -> (Pairof (Listof Step) World)
;; From the start, each step applied in turn; the steps and the last world.
(define (drive c m moves)
  (let loop ((w (model-start c m)) (ms moves) (steps '()))
    (if (null? ms)
        (cons (reverse steps) w)
        (let ((r (model-apply c m w (caar ms) (cdar ms))))
          (loop (cdr r) (cdr ms) (cons (car r) steps))))))
(define (world-after c m moves) (cdr (drive c m moves)))
(define (last-step c m moves) (car (reverse (car (drive c m moves)))))
(define (writer w) (world-thread w 'writer))
(define (reader w) (world-thread w 'reader))

(define c1 (cfg "clauses" '(2 1) 2 2 #t))
(define m1 real-machine)
(define begun '((writer . present) (writer . ok)))
(define running (append begun '((writer . ok))))

(test-equal "model: BEGIN IMMEDIATE is told busy only while another holds the lock"
  '((ok failed-closed) (busy failed-closed))
  (attempt
   (lambda ()
     (list (model-choices c1 (world-after c1 m1 '((writer . present))) 'writer)
           (model-choices c1 (world-after c1 m1 '((writer . present) (other . take)))
                          'writer)))))

(test-equal "model: busy leaves no transaction; ok holds the lock and a transaction"
  '((#f #f) (#t #t))
  (attempt
   (lambda ()
     (let ((busy (writer (world-after c1 m1 '((writer . present) (other . take)
                                              (writer . busy)))))
           (ok (writer (world-after c1 m1 begun))))
       (list (list (thread-txn? busy) (thread-lock? busy))
             (list (thread-txn? ok) (thread-lock? ok)))))))

(test-equal "model: the other process takes the lock only when it is free, within its budget"
  '((take) () (free migrate) (take) ())
  (attempt
   (lambda ()
     (list (other-choices c1 (world-after c1 m1 '((writer . present))))
           (other-choices c1 (world-after c1 m1 begun))
           (other-choices c1 (world-after c1 m1 '((writer . present) (other . take))))
           (other-choices c1 (world-after c1 m1 '((writer . present) (other . take)
                                                  (other . free))))
           (other-choices c1 (world-after c1 m1 '((writer . present) (other . take)
                                                  (other . free) (other . take)
                                                  (other . migrate))))))))

(test-equal "model: a plain BEGIN takes no lock and no snapshot; the version read takes it"
  (list '(#t #f #f) '(#t #f 1) 1)
  (attempt
   (lambda ()
     (let* ((b '((writer . present) (reader . present) (reader . ok)))
            (rb (reader (world-after c1 m1 b)))
            (rv (reader (world-after c1 m1 (append b '((reader . ok))))))
            ;; a migrate after the version read is not seen by the job's body
            (s (last-step c1 m1 (append b '((reader . ok) (other . take) (other . migrate)
                                            (reader . (returned-open . 0)))))))
       (list (list (thread-txn? rb) (thread-lock? rb) (thread-snap rb))
             (list (thread-txn? rv) (thread-lock? rv)
                   (and (thread-snap rv) (file-version (thread-snap rv))))
             (file-version (step-saw s)))))))

(test-equal "model: a migrate before the version read is seen: R7, and the file is at 2"
  '(R7 2)
  (attempt
   (lambda ()
     (let ((s (last-step c1 m1 '((writer . present) (reader . present) (reader . ok)
                                 (other . take) (other . migrate) (reader . ok)))))
       (list (step-row s) (cadr (step-raw s)))))))

(test-equal "model: a read job sees only what was committed when its snapshot was taken"
  (list '() (list (write-token 0 1) (write-token 0 2)))
  (attempt
   (lambda ()
     (let* ((r '((reader . present) (reader . ok) (reader . ok)))
            (w (append begun '((writer . ok) (writer . (returned-open . 2)) (writer . ok))))
            (before (last-step c1 m1 (append r w '((reader . (returned-open . 0))))))
            (after (last-step c1 m1 (append w r '((reader . (returned-open . 0)))))))
       (list (file-writes (step-saw before)) (file-writes (step-saw after)))))))

(test-equal "model: a COMMIT that failed and took effect: the writes in, no transaction, no lock"
  (list (list (write-token 0 1) (write-token 0 2)) #f #f 'W17)
  (attempt
   (lambda ()
     (let* ((d (drive c1 m1 (append running '((writer . (returned-open . 2))
                                              (writer . took-effect)))))
            (t (writer (cdr d))))
       (list (file-writes (world-file (cdr d))) (thread-txn? t) (thread-lock? t)
             (step-row (car (reverse (car d)))))))))

(test-equal "model: a COMMIT that failed and did not: nothing in; refused open: still open"
  '((() #f #f W17) (() #t #t W16))
  (attempt
   (lambda ()
     (map (lambda (choice)
            (let* ((d (drive c1 m1 (append running (list '(writer . (returned-open . 2))
                                                         (cons 'writer choice)))))
                   (t (writer (cdr d))))
              (list (file-writes (world-file (cdr d))) (thread-txn? t) (thread-lock? t)
                    (step-row (car (reverse (car d)))))))
          '(failed-closed failed-open)))))

(test-equal "model: a failed ROLLBACK may leave the transaction and the lock, or end both"
  '((#t #t W19) (#f #f W18))
  (attempt
   (lambda ()
     (map (lambda (choice)
            (let* ((d (drive c1 m1 (append running (list '(writer . (raised-open . 1))
                                                         (cons 'writer choice)))))
                   (t (writer (cdr d))))
              (list (thread-txn? t) (thread-lock? t) (step-row (car (reverse (car d)))))))
          '(failed-open failed-closed)))))

(define to-closing
  (append running '((writer . (raised-open . 1)) (writer . failed-open))))

(test-equal "model: a close that fails may keep the connection, its transaction and the lock"
  '((#f kept #t #t ()) (#f none #f #f (take)) (#f none #f #f (take)))
  (attempt
   (lambda ()
     (map (lambda (choice)
            (let* ((w (world-after c1 m1 (append to-closing (list (cons 'writer choice)))))
                   (t (writer w)))
              (list (thread-box? t) (thread-conn t) (thread-txn? t) (thread-lock? t)
                    (other-choices c1 w))))
          '(failed-kept failed-gone ok)))))

(test-equal "model: a job whose transaction SQLite ended: its writes gone, the lock free"
  '((() #f #f) ((1 2) #t #t))
  (attempt
   (lambda ()
     (map (lambda (choice)
            (let ((t (writer (world-after c1 m1 (append running (list (cons 'writer choice)))))))
              (list (map token-write (thread-unc t)) (thread-txn? t) (thread-lock? t))))
          '((raised-closed . 1) (returned-open . 2))))))

(test-equal "model: a job's choices: every k for a raise or an end, and one return"
  '((returned-open . 2) (raised-open . 0) (raised-open . 1) (raised-open . 2)
    (returned-closed . 0) (returned-closed . 1) (returned-closed . 2)
    (raised-closed . 0) (raised-closed . 1) (raised-closed . 2))
  (attempt (lambda () (model-choices c1 (world-after c1 m1 running) 'writer))))

;; A mutant machine that leaves a transaction open at the end of a job
(define leaves-open
  (mutant-machine (replace wtable 'running 'raised-open 'ended 'end
                           (update-of wtable 'running 'raised-closed))
                  rtable))
(define leaves-open-c (config-with-unchecked c1 '(T1)))

(test-equal "model: BEGIN fails with a transaction open only when one was left open: W6"
  '((ok failed-closed) (failed-open) W6)
  (attempt
   (lambda ()
     (let ((left (append running '((writer . (raised-open . 0)) (writer . present)))))
       (list (model-choices c1 (world-after c1 m1 '((writer . present))) 'writer)
             (model-choices leaves-open-c (world-after leaves-open-c leaves-open left) 'writer)
             (step-row (last-step leaves-open-c leaves-open
                                  (append left '((writer . failed-open))))))))))

;; A mutant machine that runs statements on an empty box
(define empty-box
  (mutant-machine (replace wtable 'start 'absent 'beginning 'begin-immediate same) rtable))
(define empty-box-c (config-with-unchecked c1 '(T10)))

(test-equal "model: on an empty box a statement can only fail, and T10 sees it"
  (list '(failed-closed) '(T10))
  (attempt
   (lambda ()
     (let* ((w (world-after empty-box-c empty-box
                            (append to-closing '((writer . ok) (writer . absent)))))
            (w2 (world-after c1 empty-box
                             (append to-closing '((writer . ok) (writer . absent)
                                                  (writer . failed-closed))))))
       (list (model-choices empty-box-c w 'writer) (map car (world-bad w2)))))))

;; The model's copies of the library's steppers and commands, run beside
;; the library's at every step of a configuration: they must agree.
(define (checked who a b)
  (lambda (s e)
    (let-values (((s1 c1) (a s e)) ((s2 c2) (b s e)))
      (unless (and (equal? s1 s2) (equal? c1 c2))
        (assertion-violation who "the model's copy disagrees" s e s2 c2))
      (values s1 c1))))
(define (checked-start who a b)
  (lambda (latest)
    (let-values (((s1 c1) (a latest)) ((s2 c2) (b latest)))
      (unless (and (equal? s1 s2) (equal? c1 c2))
        (assertion-violation who "the model's start disagrees" s2 c2))
      (values s1 c1))))
(define checked-machine
  (make-job-machine 'checked
                    (checked-start 'write write-start (model-job-start wcommand))
                    (checked 'write write-step (make-model-job-stepper write-rows wcommand))
                    job-event-kind write-row-names
                    (checked-start 'read read-start (model-job-start rcommand))
                    (checked 'read read-step (make-model-job-stepper read-rows rcommand))
                    job-event-kind read-row-names))

(test-equal "model: its copies of the job steppers agree with the library's"
  'ok
  (kill (lambda () (cfg "agree" '(2 1) 2 2 #t)) (lambda () checked-machine) 'ok))

;;; The whole space: named configurations, each with a floor

;; Each: name, writes per job, read jobs, the other's takes, migrate?, and
;; the floor, about 98% of the count measured (2026-11-23; in brackets).
;; All nine took 12 s. Four writes of one, two reads, lock twice and
;; migrate, 821,043 worlds in 8.7 s, passed, and is left out: the plan asks
;; for up to three write jobs.
;;   [208,344] [227,790] [212,466] [325,355] [36,391] [1,397] [5,900]
;;   [2,888] [265]
(define configurations
  (list
   (list "three writes of one, two reads, lock twice, migrate" '(1 1 1) 2 2 #t 205000)
   (list "three writes of two, two reads, lock twice, migrate" '(2 2 2) 2 2 #t 224000)
   (list "writes of one, two and one, two reads, lock twice, migrate" '(1 2 1) 2 2 #t 209000)
   (list "three writes of two, two reads, lock three times, migrate" '(2 2 2) 2 3 #t 320000)
   (list "two writes of two, two reads, lock twice, no migrate" '(2 2) 2 2 #f 35500)
   (list "three writes of two, no reads, lock twice, migrate" '(2 2 2) 0 2 #t 1350)
   (list "one write of two, two reads, lock once, migrate" '(2) 2 1 #t 5800)
   (list "two writes of one, one read, no other process" '(1 1) 1 0 #f 2800)
   (list "no writes, two reads, lock once, migrate" '() 2 1 #t 260)))

(define fired (make-hashtable equal-hash equal?))
(define (observe key) (hashtable-set! fired key #t))

(define (list-head* xs n) (if (= n 0) '() (cons (car xs) (list-head* (cdr xs) (- n 1)))))

;; space : (Listof (List String Result))
(define space
  (map (lambda (k)
         (list (car k)
               (attempt (lambda ()
                          (model-explore (apply cfg (list-head* k 5)) real-machine observe)))
               (list-ref k 5)))
       configurations))

(for-each
 (lambda (entry)
   (let ((name (car entry)) (r (cadr entry)) (floor (caddr entry)))
     (test-equal (string-append "layer 3: " name ": explores ok")
       'ok
       (if (eq? (outcome r) 'ok) 'ok (brief r)))
     (test-assert (string-append "layer 3: " name ": at least "
                                 (number->string floor) " worlds")
       (and (pair? r) (eq? (car r) 'ok) (>= (cadr r) floor)))))
 space)

;; Rows never fired, each with its reason. Every other row of both tables
;; fires.
;;   W6, R5   BEGIN fails with a transaction open only when one was left
;;            open, and no correct row leaves one: defensive, as slice 2's
;;            R14 is (the plan, "W6 never fires in the model").
;;   W9, R8 busy at the version read; W16 busy at COMMIT; W19 and R15 busy
;;            at ROLLBACK; R4 busy at a plain BEGIN: the model offers busy
;;            only at BEGIN IMMEDIATE while another holds the lock (cl. 1).
;;            A read in WAL waits for no lock (cl. 6), a plain BEGIN takes
;;            none, and busy at COMMIT or ROLLBACK means an unfinished
;;            statement (pc), which the handle rules out (cl. 10). Each
;;            shares its row with an event that does fire, with the same
;;            next state and update, so no path is left out.
(define never-fired
  '((W6 beginning failed-open) (W9 versioning busy) (W16 committing busy)
    (W19 rolling-back busy) (R4 beginning busy) (R5 beginning failed-open)
    (R8 versioning busy) (R15 ending busy)))

(test-equal "layer 3: every row fires but the eight listed, W6 and R5 among them"
  never-fired
  (filter (lambda (n) (not (hashtable-ref fired n #f)))
          (append write-row-names read-row-names)))

(test-equal "layer 3: nothing fires that is not a row"
  '()
  (filter (lambda (k) (not (member k (append write-row-names read-row-names))))
          (vector->list (hashtable-keys fired))))

;;; Mutants

(for-each
 (lambda (mu)
   (test-equal (string-append "mutant: " (car mu) ": " (cadr mu))
     (cadr mu)
     (kill (caddr mu) (cadddr mu) (cadr mu)))
   (test-equal (string-append "mutant: " (car mu) ": the real tables pass there")
     'ok
     (kill (lambda () (config-with-model-mutant ((caddr mu)) #f)) real 'ok)))
 (append table-mutants model-mutants))

;; T2 is implied in the model by T5 and clause 5: a snapshot is taken after
;; its job left start, and an answer comes only after its COMMIT. So no
;; table breaks T2 without breaking T5 first. With T1 and T5 unchecked, the
;; W15 mutant is seen by T2: the reader that left start after the answer
;; does not see the write.
(test-equal "mutant: W15 answers before COMMIT, T1 and T5 unchecked: T2"
  "T2"
  (kill (lambda () (config-with-unchecked (one-two) '(T1 T5)))
        (cadddr (car table-mutants)) "T2"))

(test-equal "mutant: own: W13 commits what the job wrote before it raised, T5 unchecked: T4"
  "T4"
  (kill (lambda () (config-with-unchecked (one-two) '(T5)))
        (lambda () (mutant-machine
                    (replace wtable 'running 'raised-open 'committing 'commit same)
                    rtable))
        "T4"))

;; Found: the plan gives this mutant T4 as well as T1. In the model it
;; breaks only T1: the next job's BEGIN IMMEDIATE fails with the
;; transaction open, and W6 rolls the leftovers back, so no COMMIT ever
;; takes them. With W6 going on instead, they are committed with the next
;; job's writes, and T4 sees it.
(test-equal "mutant: W13 ends without a ROLLBACK, T1 unchecked (found: survives, W6 saves it)"
  'ok
  (kill (lambda () (config-with-unchecked (two-two) '(T1)))
        (cadddr (cadr table-mutants)) 'ok))

(test-equal "mutant: W13 ends without a ROLLBACK and W6 goes on, T1 unchecked: T4"
  "T4"
  (kill (lambda () (config-with-unchecked (two-two) '(T1)))
        (lambda ()
          (mutant-machine
           (replace (replace wtable 'running 'raised-open 'ended 'end
                             (update-of wtable 'running 'raised-closed))
                    'beginning 'failed-open 'versioning 'read-version same)
           rtable))
        "T4"))

;; T5's "an answer only after COMMIT said ok" is never needed by the
;; mutants above: the events cannot tell a failed COMMIT that took effect
;; from one that did not, so a table that answers after one answers after
;; the other too, and T5's "an answered write is in the file" sees that.
;; With every failed COMMIT taking effect, only the first can see it.
(test-equal "mutant: W17 answers, every failed COMMIT having taken effect: T5"
  "T5"
  (kill (lambda () (config-with-model-mutant (one-two) 'failed-commit-took-effect))
        (lambda () (mutant-machine
                    (replace wtable 'committing 'failed-closed 'ended 'end
                             (update-of wtable 'committing 'ok))
                    rtable))
        "T5"))

(test-equal "mutant: model: BEGIN IMMEDIATE never busy: W4 no longer fires"
  '(#t #f)
  (attempt
   (lambda ()
     (map (lambda (mutant)
            (let ((seen (make-hashtable equal-hash equal?)))
              (model-explore (config-with-model-mutant (one-two) mutant) real-machine
                             (lambda (k) (hashtable-set! seen k #t)))
              (hashtable-ref seen '(W4 beginning busy) #f)))
          '(#f no-busy)))))

;; Equivalent, and so not mutants: each survives, as the plan says.
(test-equal "equivalent: a read job that ends by COMMIT survives"
  'ok
  (kill one-two
        (lambda ()
          (mutant-machine wtable (retarget rtable 'ending 'commit) wcommand
                          (lambda (s) (if (eq? (car s) 'ending) '(commit) (rcommand s)))))
        'ok))

(test-equal "equivalent: a read table that begins with BEGIN IMMEDIATE survives"
  'ok
  (kill one-two
        (lambda ()
          (mutant-machine wtable (replace rtable 'start 'present #f 'begin-immediate #f)
                          wcommand (model-job-command 'begin-immediate)))
        'ok))

;;; Machine 3: serve, by itself

(define serve-fired (make-hashtable equal-hash equal?))
(define serve-result
  (attempt (lambda () (serve-explore serve-real-machine
                                     (lambda (k) (hashtable-set! serve-fired k #t))))))

(test-equal "serve: explores ok" 'ok (if (eq? (outcome serve-result) 'ok) 'ok (brief serve-result)))

;; Measured at 30: every outcome at every command of a table of six commands.
(test-assert "serve: at least 30 worlds"
  (and (pair? serve-result) (eq? (car serve-result) 'ok) (>= (cadr serve-result) 30)))

(test-equal "serve: every row fires"
  '()
  (filter (lambda (n) (not (hashtable-ref serve-fired n #f))) serve-row-names))

(define (serve-mutant table command-of)
  (make-serve-machine 'mutant (model-serve-start command-of)
                      (make-model-serve-stepper (map cdr table) command-of)
                      serve-event-kind
                      (map (lambda (r) (list (car r) (cadr r) (caddr r))) table)))

(define (serve-kill machine expect)
  (attempt
   (lambda ()
     (let* ((r (serve-explore (machine) #f)) (o (outcome r)))
       (cond ((and (string? expect) (list? o) (member expect o)) expect)
             ((and (symbol? expect) (eq? o expect)) expect)
             (else (brief r)))))))

(test-equal "serve: the model's copy of the serve stepper agrees with the library's"
  'ok
  (serve-kill
   (lambda ()
     (make-serve-machine
      'checked serve-start
      (let ((copy (make-model-serve-stepper serve-rows model-serve-command)))
        (lambda (s e)
          (let-values (((s1 c1) (serve-step s e)) ((s2 c2) (copy s e)))
            (unless (and (equal? s1 s2) (equal? c1 c2))
              (assertion-violation 'serve "the model's copy disagrees" s e))
            (values s1 c1))))
      serve-event-kind serve-row-names))
   'ok))

(define serve-mutants
  (list
   (list "S7 ends without stopping the writer" "T8"
         (lambda ()
           (serve-mutant
            (replace stable 'opening-readers 'raised 'ended 'end
                     (lambda (d e) (list (or (car d) 1)
                                         (append (cadr d) (list (cons 'raised (cadr e)))))))
            model-serve-command)))
   (list "S8 and S11 swapped: the writer stopped first" "T8"
         (lambda ()
           (serve-mutant
            (retarget (retarget stable 'stopping-readers 'stop-writer)
                      'stopping-writer 'stop-readers)
            (lambda (s)
              (case (car s)
                ((stopping-readers) '(stop-writer))
                ((stopping-writer) '(stop-readers))
                (else (model-serve-command s)))))))
   ;; Stopped the other way round only after serving, so that no other
   ;; part of T8 sees it: the order is read at the writer's stop.
   (list "the writer stopped before the readers, after serving" "T8"
         (lambda ()
           (serve-mutant
            (append
             (map (lambda (r) (if (eq? (list-ref r 3) 'stopping-readers)
                                  (list (car r) (cadr r) (caddr r) 'writer-first 'stop-writer
                                        (list-ref r 5))
                                  r))
                  stable)
             (list (list 'S11x 'writer-first 'ok 'readers-last 'stop-readers same)
                   (list 'S12x 'writer-first 'raised 'readers-last 'stop-readers
                         (update-of stable 'stopping-readers 'raised))
                   (list 'S13x 'readers-last 'ok 'ended 'end
                         (update-of stable 'stopping-writer 'ok))
                   (list 'S14x 'readers-last 'raised 'ended 'end
                         (update-of stable 'stopping-writer 'raised))))
            (lambda (s)
              (case (car s)
                ((writer-first) '(stop-writer))
                ((readers-last) '(stop-readers))
                (else (model-serve-command s)))))))
   (list "own: S13 exits 0 whatever was carried" "T8"
         (lambda ()
           (serve-mutant (replace stable 'stopping-writer 'ok #f #f
                                  (lambda (d e) (list 0 (cadr d))))
                         model-serve-command)))
   (list "own: S12 replaces the status carried" "T8"
         (lambda ()
           (serve-mutant (replace stable 'stopping-readers 'raised #f #f
                                  (lambda (d e) (list 1 (append (cadr d)
                                                                (list (cons 'raised (cadr e)))))))
                         model-serve-command)))
   (list "own: S12 prints nothing" "T8"
         (lambda ()
           (serve-mutant (replace stable 'stopping-readers 'raised #f #f
                                  (lambda (d e) (list (or (car d) 1) (cadr d))))
                         model-serve-command)))))

(for-each
 (lambda (mu)
   (test-equal (string-append "serve mutant: " (car mu) ": " (cadr mu))
     (cadr mu)
     (serve-kill (caddr mu) (cadr mu))))
 serve-mutants)

;;; The traces the replay takes

(define (traces-config) (cfg "traces" '(1 2) 2 1 #t))
(define traces (attempt (lambda () (model-traces (traces-config) real-machine))))

;; replay : Config Trace -> (U 'same List)
;; Each step's who and choice applied in turn from the start: 'same when
;; every Step is equal? to the trace's, and the last world is quiet.
(define (replay c trace)
  (let loop ((w (model-start c real-machine)) (steps trace) (n 0))
    (if (null? steps)
        (if (null? ((model-next c real-machine #f #f) w)) 'same (list n 'not-quiet))
        (let ((r (attempt (lambda () (model-apply c real-machine w (step-who (car steps))
                                                  (step-choice (car steps)))))))
          (if (and (pair? r) (not (eq? (car r) 'raised)) (equal? (car r) (car steps)))
              (loop (cdr r) (cdr steps) (+ n 1))
              (list n (brief-step (car steps)) r))))))

(test-equal "traces: the trace configuration fires every row the whole space fires"
  '()
  (attempt
   (lambda ()
     (let ((keys (map car traces)))
       (filter (lambda (k) (not (member k keys))) (vector->list (hashtable-keys fired)))))))

(test-equal "traces: every trace replays step for step, to a quiet world"
  '()
  (attempt
   (lambda ()
     (filter (lambda (x) (not (eq? (cdr x) 'same)))
             (map (lambda (kt) (cons (car kt) (replay (traces-config) (cdr kt)))) traces)))))

(test-equal "traces: each trace's key is the row a step of it fires"
  '()
  (attempt
   (lambda ()
     (filter (lambda (kt) (not (exists (lambda (s) (eq? (step-row s) (car (car kt))))
                                       (cdr kt))))
             traces))))

(test-equal "traces: a step carries what the replay stages and compares"
  (list 'writer 0 '(returned-open . 1) '(run-job) '(returned (writer 0) #t) 'W11
        (list (list (write-token 0 1)) 'returned 'open) '() 1
        'reader 1 (list (write-token 0 1)))
  (attempt
   (lambda ()
     (let* ((c (traces-config))
            (d (drive c real-machine
                      '((writer . present) (writer . ok) (writer . ok)
                        (writer . (returned-open . 1)) (writer . ok)
                        (reader . present) (reader . ok) (reader . ok)
                        (reader . (returned-open . 0)) (reader . ok)
                        (reader . present) (reader . ok) (reader . ok)
                        (reader . (returned-open . 0)))))
            (s (list-ref (car d) 3)) (r (car (reverse (car d)))))
       (list (step-who s) (step-job s) (step-choice s) (step-command s) (step-raw s)
             (step-row s) (step-action s) (file-writes (step-file s))
             (file-version (step-file s))
             (step-who r) (step-job r) (file-writes (step-saw r)))))))

(test-end "transaction-model")

(exit (suite-exit-status runner))
