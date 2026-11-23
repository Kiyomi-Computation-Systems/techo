#!r6rs
;;; The migration model suite: layer 3 of the slice 2 plan. The real
;;; `techo migrate` and `techo serve` step functions, explored against the
;;; pure model of a file and its lock in (migrations-model):
;;;   - the model's own clauses, call by call;
;;;   - the whole space: every list, start, one run or two, with and
;;;     without serve, M1 to M12 in every world, ML1 to ML3 at every end,
;;;     no cycle; every row fires, and the worlds have a floor;
;;;   - the plan's layer 3 mutants, each on one small configuration, each
;;;     ending as the plan says or as found (each finding is named so); and
;;;     a mutant of this suite's own for each property no plan mutant
;;;     reaches;
;;;   - the traces the replay (layer 4) takes.
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo migrations)
        (migrations-model))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;;; Lists, configurations, outcomes

;; iota-from : Integer Integer -> (Listof Integer)
(define (iota-from a b) (if (> a b) '() (cons a (iota-from (+ a 1) b))))

;; shape : Positive-Integer ... -> (Listof Migration)
;; A list whose migration k has the k-th count of statements. Migration 1's
;; first statement is the id statement; every other is an effect token.
(define (shape . counts)
  (let loop ((k 1) (cs counts) (acc '()))
    (if (null? cs)
        (reverse acc)
        (loop (+ k 1) (cdr cs)
              (cons (list k (string-append "m" (number->string k))
                          (if (= k 1)
                              (cons model-id-statement
                                    (map (lambda (i) (effect-statement 1 i))
                                         (iota-from 2 (car cs))))
                              (map (lambda (i) (effect-statement k i))
                                   (iota-from 1 (car cs)))))
                    acc)))))

;; cfg : (Listof Migration) StartName (U 1 2) Boolean -> Config
;; Capped, so that a graph that turned out infinite fails, not hangs.
(define (cfg ms start runs serve?)
  (config-with-cap
   (make-config (list (map (lambda (m) (length (caddr m))) ms) start runs serve?)
                ms (start-file ms start) runs serve?)
   2000000))

;; split : String String -> (Listof String)
(define (split s sep)
  (let ((n (string-length s)) (k (string-length sep)))
    (let loop ((i 0) (from 0) (acc '()))
      (cond ((> (+ i k) n) (reverse (cons (substring s from n) acc)))
            ((string=? (substring s i (+ i k)) sep)
             (loop (+ i k) (+ i k) (cons (substring s from i) acc)))
            (else (loop (+ i 1) from acc))))))

;; property-of : String -> String
;; "M2: ..." -> "M2"; "raised: ..." -> "raised".
(define (property-of seg)
  (let loop ((i 0))
    (cond ((= i (string-length seg)) seg)
          ((char=? (string-ref seg i) #\:) (substring seg 0 i))
          (else (loop (+ i 1))))))

;; brief-step : Step -> List
(define (brief-step s)
  (list (step-who s) (step-choice s) (car (step-command s))
        (and (step-raw s) (car (step-raw s))) (step-row s)))

;; outcome : Result -> (U 'ok 'cycle (Listof String) (List 'raised Any))
;; ok, cycle, or the properties a violation names, in order.
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

;; kill : (-> Config) (-> Machine) (U String 'cycle 'ok) -> Any
;; EXPECT when the exploration ends that way (a violation naming the
;; property, among any others it names), else the evidence.
(define (kill config machine expect)
  (attempt
   (lambda ()
     (let* ((r (model-explore (config) (machine) #f)) (o (outcome r)))
       (cond ((and (string? expect) (list? o) (member expect o)) expect)
             ((and (symbol? expect) (eq? o expect)) expect)
             (else (brief r)))))))

;;; Mutants: rows rewritten, classifiers wrapped, commands rewritten

;; row-at : Rows Symbol Symbol -> Row
(define (row-at rows s e)
  (find (lambda (r) (and (eq? (car r) s) (eq? (cadr r) e))) rows))

(define (same d e) d)

;; row-replace : Rows Symbol Symbol (U Symbol #f) (U Symbol #f)
;;               (U Update #f) -> Rows
;; The row for (S, E) with its next state, command kind or update replaced,
;; #f keeping the row's own.
(define (row-replace rows s e next cmd update)
  (map (lambda (r)
         (if (and (eq? (car r) s) (eq? (cadr r) e))
             (list s e (or next (caddr r)) (or cmd (cadddr r)) (or update (list-ref r 4)))
             r))
       rows))

;; data : the run machine's state data, (k i committed converted tries pending)
(define (data k i committed converted tries pending)
  (list k i committed converted tries pending))
(define (d-k d) (list-ref d 0))
(define (d-i d) (list-ref d 1))
(define (d-committed d) (list-ref d 2))
(define (d-converted d) (list-ref d 3))
(define (d-tries d) (list-ref d 4))
(define (d-pending d) (list-ref d 5))

;; run-machine : Symbol Rows Classifier -> Machine
(define (run-machine name rows kind)
  (make-model-machine name run-start (make-stepper rows kind) kind
                      check-start check-step check-event-kind))

;; check-machine : Symbol Rows -> Machine
(define (check-machine name rows)
  (make-model-machine name run-start run-step event-kind
                      check-start (make-stepper rows check-event-kind)
                      check-event-kind))

;; look-kind : (Symbol DbFacts (Listof Migration) -> DbState) -> Classifier
;; event-kind with its three looks rewritten over CLASSIFY*, which is told
;; the state kind: a copy of (techo migrations)'s, held to it below.
(define (look-kind classify*)
  (lambda (ms state raw)
    (let ((k (car state)))
      (if (and (memq k '(peeking looking relooking)) (eq? (car raw) 'ok))
          (let* ((f (cadr raw)) (st (classify* k f ms)) (wal (eq? (cadddr f) 'wal))
                 (refused (or (eq? st 'foreign) (and (pair? st) (eq? (car st) 'ahead)))))
            (case k
              ((peeking) (cond (refused 'refused)
                               ((and (eq? st 'current) wal) 'current)
                               (else 'work)))
              ((looking) (cond (refused 'refused) ((not wal) 'unconverted)
                               ((eq? st 'current) 'current) (else 'pending)))
              (else (cond ((not (caddr raw)) 'failed-ended)
                          ((and wal (or (and (eq? st 'fresh) (= (d-k (cdr state)) 1))
                                        (and (pair? st) (eq? (car st) 'behind)
                                             (= (cadr st) (- (d-k (cdr state)) 1)))))
                           'pending)
                          (else 'changed)))))
          (event-kind ms state raw)))))

(define (plain-classify k f ms) (classify f ms))

;; with-run-commands : Symbol (State Command -> Command) -> Machine
;; The real run machine with each command it asks for rewritten.
(define (with-run-commands name f)
  (make-model-machine name run-start
                      (lambda (ms s raw)
                        (let-values (((s2 c2) (run-step ms s raw))) (values s2 (f s2 c2))))
                      event-kind check-start check-step check-event-kind))

;; with-run-start, with-check-start : Symbol Command -> Machine
;; The real machines, the run's or the check's first command replaced.
(define (with-run-start name cmd)
  (make-model-machine name (lambda () (let-values (((s c) (run-start))) (values s cmd)))
                      run-step event-kind check-start check-step check-event-kind))
(define (with-check-start name cmd)
  (make-model-machine name run-start run-step event-kind
                      (lambda () (let-values (((s c) (check-start))) (values s cmd)))
                      check-step check-event-kind))

(define (real) real-machine)

;; A mutant: name, expectation, its configuration, its machine, and the
;; configuration the unmutated machine is held to beside it.
(define (mutant name expect config machine . base)
  (list name expect config machine (if (null? base) config (car base))))

(define mutants
  (list
   ;; The plan's table, layer 3
   (mutant "R24 trusts the earlier look (two runs)" "M2"
           (lambda () (cfg (shape 2) '(fresh wal) 2 #f))
           (lambda () (run-machine 'r24 (row-replace run-rows 'locking 'locked 'applying
                                                     'run-statement #f)
                                   event-kind)))
   ;; Found: M10 sees the run in stamping without the lock a step before
   ;; the stamp lands; M1 kills it too (a test below, M10 unchecked).
   (mutant "the stamp is set before the lock is taken (found: M10 first)" "M10"
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f))
           (lambda () (run-machine 'stamp-first
                                   (row-replace
                                    (row-replace run-rows 'looking 'pending 'stamping 'stamp #f)
                                    'stamping 'stamped 'locking 'begin-immediate #f)
                                   event-kind)))
   (mutant "R32 and R33 swapped: commit, then stamp" "M1"
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f))
           (lambda ()
             (run-machine 'swap
                          (row-replace
                           (row-replace
                            (row-replace
                             (row-replace run-rows 'checking 'clean 'committing 'commit #f)
                             'committing 'below 'stamping 'stamp same)
                            'committing 'latest 'stamping 'stamp same)
                           'stamping 'stamped 'locking 'begin-immediate
                           (list-ref (row-at run-rows 'committing 'below) 4))
                          event-kind)))
   (mutant "R35 goes on to the stamp" "M1"
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f))
           (lambda () (run-machine 'r35
                                   (row-replace
                                    (row-replace run-rows 'applying 'failed 'stamping 'stamp same)
                                    'checking 'failed 'stamping 'stamp same)
                                   event-kind)))
   ;; Goes on only while there is a k + 1, as a run would: at latest, a
   ;; k + 1 that never ends makes the graph infinite, not cyclic.
   (mutant "after a failure, the run undoes and locks k + 1 (two runs)" 'cycle
           (lambda () (cfg (shape 1 2) '(fresh wal) 2 #f))
           (lambda ()
             (run-machine 'go-on
                          (cons (list 'undoing-to-fail 'done-next 'locking 'begin-immediate
                                      (lambda (d e)
                                        (data (+ (d-k d) 1) 1 (d-committed d) (d-converted d)
                                              (d-tries d) #f)))
                                run-rows)
                          (lambda (ms state raw)
                            (let ((k (event-kind ms state raw)))
                              (if (and (eq? (car state) 'undoing-to-fail) (eq? k 'done)
                                       (< (d-k (cdr state)) (latest-version ms)))
                                  'done-next
                                  k))))))
   (mutant "the classifier calls an ahead file behind" "M5"
           (lambda () (cfg (shape 2) '(ahead wal) 1 #f))
           (lambda ()
             (run-machine 'ahead-behind run-rows
                          (look-kind (lambda (k f ms)
                                       (let ((st (classify f ms)))
                                         (if (and (pair? st) (eq? (car st) 'ahead))
                                             (list 'behind (cadr st))
                                             st)))))))
   (mutant "R1 opens read-write" "M5"
           (lambda () (cfg (shape 2) '(other-id wal) 1 #f))
           (lambda () (with-run-start 'r1-rw '(open-read-write))))
   ;; Found: with the read-only peek first, "R16 before any look" has two
   ;; readings and M5 sees neither. R1 going to converting converts on the
   ;; read-only connection, which can only fail on a file not in WAL: it
   ;; survives on a foreign file and is killed by ML2 on a file of ours.
   (mutant "R16 before any look, R1 to converting, foreign (found: survives)" 'ok
           (lambda () (cfg (shape 2) '(other-id delete) 1 #f))
           (lambda () (run-machine 'r16-peek
                                   (row-replace run-rows 'peek-opening 'opened 'converting
                                                'set-wal #f)
                                   event-kind)))
   (mutant "R16 before any look, R1 to converting, ours (found: ML2)" "ML2"
           (lambda () (cfg (shape 2) '(fresh delete) 1 #f))
           (lambda () (run-machine 'r16-peek
                                   (row-replace run-rows 'peek-opening 'opened 'converting
                                                'set-wal #f)
                                   event-kind)))
   ;; R9 going to converting is reached only after the peek accepted the
   ;; file: it converts a file of ours, or a WAL file as a no-op.
   (mutant "R16 before any look, R9 to converting (found: survives)" 'ok
           (lambda () (cfg (shape 1 2) '(fresh delete) 2 #f))
           (lambda () (run-machine 'r16-open
                                   (row-replace run-rows 'opening 'opened 'converting
                                                'set-wal #f)
                                   event-kind)))
   (mutant "R16 before any look, R9 to converting, ahead (found: survives)" 'ok
           (lambda () (cfg (shape 2) '(ahead delete) 2 #f))
           (lambda () (run-machine 'r16-open
                                   (row-replace run-rows 'opening 'opened 'converting
                                                'set-wal #f)
                                   event-kind)))
   (mutant "R25 forgets the rollback" "M10"
           (lambda () (cfg (shape 2) '(fresh wal) 2 #f))
           (lambda () (run-machine 'r25 (row-replace run-rows 'relooking 'changed 'looking
                                                     'read-facts #f)
                                   event-kind)))
   (mutant "R17 retries for ever" 'cycle
           (lambda () (cfg (shape 2) '(fresh delete) 2 #f))
           (lambda () (run-machine 'r17 (row-replace run-rows 'converting 'busy-retry #f #f same)
                                   event-kind)))
   (mutant "R22 retries for ever" 'cycle
           (lambda () (cfg (shape 2) '(fresh wal) 2 #f))
           (lambda () (run-machine 'r22 (row-replace run-rows 'locking 'busy 'locking
                                                     'begin-immediate same)
                                   event-kind)))
   (mutant "R13 answers applied on a file it only read" "M11"
           (lambda () (cfg (shape 2) '(current delete) 1 #f))
           (lambda ()
             (run-machine 'r13
                          (row-replace run-rows 'looking 'current #f #f
                                       (lambda (d e)
                                         (data (d-k d) (d-i d) (d-committed d) (d-converted d)
                                               (d-tries d) (cons 'applied (cadr (cadr e))))))
                          event-kind)))
   (mutant "R33 forgets to record k" "M11"
           (lambda () (cfg (shape 1 2) '(fresh wal) 1 #f))
           (lambda ()
             (run-machine 'r33
                          (row-replace run-rows 'committing 'below #f #f
                                       (lambda (d e)
                                         (data (+ (d-k d) 1) 1 (d-committed d) (d-converted d)
                                               (d-tries d) (d-pending d))))
                          event-kind)))
   (mutant "serve accepts a file behind" "M9"
           (lambda () (cfg (shape 1 2) '((behind 1) wal) 1 #t))
           (lambda () (check-machine 'serve-behind
                                     (row-replace check-rows 'peeking 'behind #f #f
                                                  (lambda (d e) 'serve)))))
   (mutant "serve accepts a file not in WAL" "M9"
           (lambda () (cfg (shape 2) '(current delete) 1 #t))
           (lambda () (check-machine 'serve-unconverted
                                     (row-replace check-rows 'peeking 'unconverted #f #f
                                                  (lambda (d e) 'serve)))))
   ;; Found: the plan gives this one to layer 4; layer 3 kills it too.
   (mutant "R29 missing: a statement that ended the transaction goes on" "M10"
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f))
           (lambda () (run-machine 'r29
                                   (row-replace run-rows 'applying 'txn-ended 'applying
                                                'run-statement
                                                (list-ref (row-at run-rows 'applying 'more) 4))
                                   event-kind)))
   ;; R26b's absence: a relook whose failure ended the transaction is taken
   ;; as R26's, and the run reaches undoing-to-fail holding nothing.
   (mutant "R26b missing: the relook's failure that ended the transaction is R26's"
           "M10"
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f))
           (lambda ()
             (run-machine 'no-r26b run-rows
                          (lambda (ms state raw)
                            (let ((k (event-kind ms state raw)))
                              (if (and (eq? (car state) 'relooking) (eq? k 'failed-ended))
                                  'failed
                                  k))))))
   ;; A pair with no row "can't happen": the step raises, and so the
   ;; explorer fails, naming the raise.
   (mutant "own: event-kind answers a kind peeking has no row for" "raised"
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f))
           (lambda () (run-machine 'no-row run-rows
                                   (lambda (ms state raw)
                                     (if (eq? (car state) 'peeking)
                                         'pending
                                         (event-kind ms state raw))))))
   ;; This suite's own, for the properties no plan mutant reaches
   (mutant "own: a COMMIT puts its effects first (M3)" "M3"
           (lambda () (config-with-model-mutant (cfg (shape 1 2) '(fresh wal) 1 #f)
                                                'commit-prepends))
           real
           (lambda () (cfg (shape 1 2) '(fresh wal) 1 #f)))
   (mutant "own: the stamp is k - 2 (M4)" "M4"
           (lambda () (cfg (shape 1 2) '((behind 1) wal) 1 #f))
           (lambda ()
             (with-run-commands 'stamp-down
                                (lambda (s c)
                                  (if (eq? (car c) 'stamp) (cons 'stamp (- (cdr c) 2)) c)))))
   (mutant "own: migration 1 does not set the id (M6)" "M6"
           (lambda ()
             (cfg (list (list 1 "one" (list (effect-statement 1 1) (effect-statement 1 2))))
                  '(fresh wal) 1 #f))
           real
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f)))
   (mutant "own: a death commits the run's transaction (M7)" "M7"
           (lambda ()
             (config-with-model-mutant (cfg (shape 2) '(fresh wal) 1 #f) 'death-commits))
           real
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f)))
   (mutant "own: the classifier calls a file behind current (M8)" "M8"
           (lambda () (cfg (shape 1 2) '((behind 1) wal) 1 #f))
           (lambda ()
             (run-machine 'behind-current run-rows
                          (look-kind (lambda (k f ms)
                                       (let ((st (classify f ms)))
                                         (if (and (pair? st) (eq? (car st) 'behind))
                                             'current
                                             st)))))))
   (mutant "own: serve's check opens read-write (M12)" "M12"
           (lambda () (cfg (shape 2) 'missing 1 #t))
           (lambda () (with-check-start 'serve-rw '(open-read-write))))
   (mutant "own: R23 ends the run at once (ML1)" "ML1"
           (lambda () (cfg (shape 2) '(fresh wal) 1 #f))
           (lambda ()
             (run-machine 'r23-ends (row-replace run-rows 'locking 'failed 'ended 'end same)
                          event-kind)))
   (mutant "own: R33 stops, failed, after committing k (ML2)" "ML2"
           (lambda () (cfg (shape 1 2) '(fresh wal) 1 #f))
           (lambda ()
             (run-machine 'r33-stops
                          (row-replace run-rows 'committing 'below 'closing 'close
                                       (lambda (d e)
                                         (data (d-k d) (d-i d)
                                               (append (d-committed d) (list (d-k d)))
                                               (d-converted d) (d-tries d)
                                               (list 'failed (d-k d) "stopped" #f))))
                          event-kind)))
   (mutant "own: looking refuses a file behind at 1 (ML3)" "ML3"
           (lambda () (cfg (shape 1 2) '(fresh wal) 1 #f))
           (lambda ()
             (run-machine 'looking-refuses run-rows
                          (look-kind (lambda (k f ms)
                                       (let ((st (classify f ms)))
                                         (if (and (eq? k 'looking) (equal? st '(behind 1)))
                                             'foreign
                                             st)))))))))

(test-begin "migrations-model")

;;; The model's own clauses

(define (start-world ms start runs serve?)
  (let ((c (cfg ms start runs serve?))) (cons c (model-start c real-machine))))

;; drive : Config World (Listof (Pairof Index Choice)) -> World
(define (drive c w moves)
  (fold-left (lambda (w mv) (cdr (model-apply c real-machine w (car mv) (cdr mv))))
             w moves))

;; perform : Config World Index Command Choice -> (List RawOutcome World)
(define (perform c w i cmd choice)
  (let-values (((w2 raw) (model-perform c w i cmd choice))) (list raw w2)))

(test-equal "model: the id statement is the shipped migration 1's"
  (list model-id-statement)
  (attempt (lambda () (caddr (car migrations)))))

(test-equal "model: a read-only open of a missing file answers missing and creates nothing"
  '((missing fail) missing #f)
  (attempt
   (lambda ()
     (let* ((cw (start-world (shape 2) 'missing 1 #f)) (c (car cw)) (w (cdr cw))
            (r (perform c w 0 '(open-read-only) 'missing)))
       (list (model-choices c w 0 '(open-read-only)) (car (car r))
             (model-file-exists? (world-file (cadr r))))))))

(test-equal "model: a read-write open of a missing file creates it fresh, not in WAL"
  '((ok #t #f) (0 0 0 delete) rw)
  (attempt
   (lambda ()
     (let* ((cw (start-world (shape 2) 'missing 1 #f))
            (r (perform (car cw) (cdr cw) 0 '(open-read-write) 'ok)))
       (list (car r) (model-file-facts (world-file (cadr r)))
             (actor-conn (world-actor (cadr r) 0)))))))

;; Run 0 on a fresh file in WAL, driven through migration 1's first
;; statement (the id), and run 1 to its read-write look.
(define (in-migration)
  (let* ((cw (start-world (shape 2) '(fresh wal) 2 #f)) (c (car cw)))
    (cons c (drive c (cdr cw)
                   '((0 . ok) (0 . ok) (0 . ok) (0 . ok) (0 . ok) (0 . ok) (0 . ok) (0 . ok)
                     (1 . ok) (1 . ok) (1 . ok) (1 . ok))))))

(test-equal "model: a run's statement is seen by its own connection only, until COMMIT"
  (list 'applying #t
        (list 'ok (list techo-application-id 0 0 'wal) #t)
        (list 'ok '(0 0 0 wal) #f)
        (list 'ok (list techo-application-id 1 1 'wal) #f))
  (attempt
   (lambda ()
     (let* ((cw (in-migration)) (c (car cw)) (w (cdr cw)) (a (world-actor w 0)))
       (list (car (actor-state a)) (actor-txn? a)
             (car (perform c w 0 '(read-facts) 'ok))
             (car (perform c w 1 '(read-facts) 'ok))
             (let* ((w2 (drive c w '((0 . ok) (0 . ok) (0 . ok) (0 . ok)))))
               (car (perform c w2 1 '(read-facts) 'ok))))))))

(test-equal "model: BEGIN IMMEDIATE can be busy only while another holds the lock"
  '((busy fail) (ok fail))
  (attempt
   (lambda ()
     (let* ((cw (in-migration)) (c (car cw)) (w (cdr cw)))
       (list (model-choices c w 1 '(begin-immediate))
             (let ((w2 (drive c w '((0 . ok) (0 . ok) (0 . ok) (0 . ok) (0 . ok)))))
               (model-choices c w2 1 '(begin-immediate))))))))

(test-equal "model: a failed COMMIT that took effect ends the transaction, its effects in"
  (list '(failed "disk I/O error" #f) #f #f (list techo-application-id 1 1 'wal))
  (attempt
   (lambda ()
     (let* ((cw (in-migration)) (c (car cw))
            (w (drive c (cdr cw) '((0 . ok) (0 . ok) (0 . ok))))
            (r (perform c w 0 '(commit) 'took-effect)))
       (list (car r) (actor-txn? (world-actor (cadr r) 0)) (world-lock (cadr r))
             (model-file-facts (world-file (cadr r))))))))

(test-equal "model: a failed ROLLBACK may leave the transaction open, or end it"
  '((ok fail fail-ended) (failed #t #t 0) (failed #f #f #f))
  (attempt
   (lambda ()
     (let* ((cw (in-migration)) (c (car cw)) (w (cdr cw)))
       (define (after choice)
         (let ((r (perform c w 0 '(rollback) choice)))
           (list (car (car r)) (caddr (car r)) (actor-txn? (world-actor (cadr r) 0))
                 (world-lock (cadr r)))))
       (list (model-choices c w 0 '(rollback)) (after 'fail) (after 'fail-ended))))))

(test-equal "model: setting WAL read-only on a file not in WAL can only fail"
  '((fail) failed delete)
  (attempt
   (lambda ()
     (let* ((cw (start-world (shape 2) '(fresh delete) 1 #f)) (c (car cw))
            (w (drive c (cdr cw) '((0 . ok))))
            (r (perform c w 0 '(set-wal) 'fail)))
       (list (model-choices c w 0 '(set-wal)) (car (car r))
             (model-file-mode (world-file (cadr r))))))))

(test-equal "model: outside a transaction a stamp commits at once; COMMIT can only fail"
  '((ok fail) 7 (fail))
  (attempt
   (lambda ()
     (let* ((cw (start-world (shape 2) '(fresh wal) 1 #f)) (c (car cw))
            (w (drive c (cdr cw) '((0 . ok) (0 . ok) (0 . ok) (0 . ok)))))
       (list (model-choices c w 0 '(stamp . 7))
             (model-file-version (world-file (cadr (perform c w 0 '(stamp . 7) 'ok))))
             (model-choices c w 0 '(commit)))))))

(test-equal "model: a death drops the transaction and the lock, and leaves the file"
  (list #f #f '(0 0 0 wal))
  (attempt
   (lambda ()
     (let* ((cw (in-migration)) (c (car cw))
            (w (drive c (cdr cw) '((0 . ok))))
            (w2 (model-die c w 0)))
       (list (world-actor w2 0) (world-lock w2) (model-file-facts (world-file w2)))))))

(test-equal "model: a call not in the list is refused, by who"
  '(model-choices model-perform)
  (attempt
   (lambda ()
     (let* ((cw (start-world (shape 2) '(fresh wal) 1 #f)) (c (car cw)) (w (cdr cw)))
       (map (lambda (thunk)
              (guard (e ((who-condition? e) (condition-who e)) (#t 'other))
                (thunk)
                'no-raise))
            (list (lambda () (model-choices c w 0 '(vacuum)))
                  ;; busy is a way BEGIN can go, but not with no other actor
                  (lambda () (model-perform c w 0 '(begin-immediate) 'busy))))))))

;; look-kind, unmutated, answers as event-kind over every look state, a
;; k from 1 to 4, facts over three ids, six versions, two object counts
;; and two modes, and the transaction open or not after the read: so each
;; mutant built on it is one change.
(define (facts-grid)
  (let ((T techo-application-id))
    (apply append
           (map (lambda (id)
                  (apply append
                         (map (lambda (v)
                                (list (list id v 0 'wal) (list id v 1 'wal)
                                      (list id v 0 'delete) (list id v 1 'delete)))
                              '(-1 0 1 2 3 4))))
                (list 0 T 7)))))

(test-equal "model: look-kind, unmutated, answers as event-kind"
  '()
  (attempt
   (lambda ()
     (let ((ms (shape 1 2 1)) (copy (look-kind plain-classify)) (out '()))
       (for-each
        (lambda (k)
          (for-each
           (lambda (kk)
             (for-each
              (lambda (facts)
                (for-each
                 (lambda (open?)
                   (let ((state (cons k (data kk 1 '() #f 3 #f)))
                         (raw (list 'ok facts open?)))
                     (unless (eq? (copy ms state raw) (event-kind ms state raw))
                       (set! out (cons (list k kk facts open?) out)))))
                 '(#t #f)))
              (facts-grid)))
           '(1 2 3 4)))
        '(peeking looking relooking))
       out))))

;;; The whole space

;; Six of the fourteen shapes of one to three migrations of one or two
;; statements: the shipped shape, and five with a migration of two
;; statements first, middle or last. These six take about 28 s; all
;; fourteen, 9,723,563 worlds, took 95 s and passed.
(define lists
  (list (shape 1) (shape 2) (shape 1 2) (shape 2 1) (shape 1 2 1) (shape 2 1 2)))

(define fired (make-hashtable equal-hash equal?))
(define (observe run? row) (hashtable-set! fired (cons run? row) #t))

;; space : (List (Listof Failure) Natural Natural)
;; Failure is (List ConfigName Result-brief); then the configurations and
;; the worlds of the whole graphs.
(define (space-configs)
  (apply append
         (map (lambda (ms)
                (apply append
                       (map (lambda (start)
                              (list (cfg ms start 1 #f) (cfg ms start 1 #t)
                                    (cfg ms start 2 #f) (cfg ms start 2 #t)))
                            (start-names ms))))
              lists)))

(define space
  (attempt
   (lambda ()
     (let loop ((cs (space-configs)) (failures '()) (n 0) (worlds 0))
       (if (null? cs)
           (list (reverse failures) n worlds)
           (let ((r (model-explore (car cs) real-machine observe)))
             (loop (cdr cs)
                   (if (eq? (car r) 'ok)
                       failures
                       (cons (list (config-name (car cs)) (brief r)) failures))
                   (+ n 1)
                   (if (eq? (car r) 'ok) (+ worlds (cadr r)) worlds))))))))

(define (space-part i)
  (if (and (list? space) (= (length space) 3)) (list-ref space i) space))

(test-equal "layer 3: every configuration of the whole space explores ok"
  '()
  (space-part 0))

;; 6 lists; per list 1 + 2 x (latest + 7) starts; x 4 for runs and serve.
(test-equal "layer 3: the whole space has every configuration"
  (* 4 (+ (* 2 (+ 1 (* 2 8))) (* 2 (+ 1 (* 2 9))) (* 2 (+ 1 (* 2 10)))))
  (space-part 1))

;; Measured at 2,961,422; the floor sits a little below.
(test-assert "layer 3: the whole space has at least 2,900,000 worlds"
  (let ((n (space-part 2))) (and (integer? n) (>= n 2900000))))

;; R14, looking refused, is the one row no world fires, and it stays: it
;; is defensive. A run looks read-write only after its read-only peek
;; accepted the file, and nothing this binary does makes a file it accepted
;; ahead or foreign; only another program writing between the peek and the
;; look reaches it.
(test-equal "layer 3: every run row fires, but R14 (looking refused)"
  '((looking . refused))
  (attempt
   (lambda ()
     (map (lambda (r) (cons (car r) (cadr r)))
          (filter (lambda (r) (not (hashtable-ref fired (cons #t (cons (car r) (cadr r))) #f)))
                  run-rows)))))

(test-equal "layer 3: every check row fires"
  '()
  (attempt
   (lambda ()
     (map (lambda (r) (cons (car r) (cadr r)))
          (filter (lambda (r) (not (hashtable-ref fired (cons #f (cons (car r) (cadr r))) #f)))
                  check-rows)))))

;;; Mutants

(for-each
 (lambda (mu)
   (test-equal (string-append "mutant: " (car mu) ": "
                              (if (string? (cadr mu)) (cadr mu) (symbol->string (cadr mu))))
     (cadr mu)
     (kill (caddr mu) (cadddr mu) (cadr mu)))
   (test-equal (string-append "mutant: " (car mu) ": the unmutated machine passes there")
     'ok
     (kill (list-ref mu 4) real 'ok)))
 mutants)

(test-equal "mutant: the stamp before the lock, M10 unchecked: M1"
  "M1"
  (kill (lambda () (config-with-unchecked (cfg (shape 2) '(fresh wal) 1 #f) '(10)))
        (lambda () (run-machine 'stamp-first
                                (row-replace
                                 (row-replace run-rows 'looking 'pending 'stamping 'stamp #f)
                                 'stamping 'stamped 'locking 'begin-immediate #f)
                                event-kind))
        "M1"))

;;; The traces the replay takes

;; replay : Config Trace -> (U 'same (List Natural Any Any))
;; Applies each step's who and choice in turn from the start; 'same when
;; every Step comes out equal? to the trace's, and the last world has no
;; next step when ENDS? asks for it.
(define (replay c trace ends?)
  (let loop ((w (model-start c real-machine)) (steps trace) (n 0))
    (if (null? steps)
        (if (or (not ends?) (null? ((model-next c real-machine #f #f) w)))
            'same
            (list n 'not-at-an-end))
        (let ((r (attempt (lambda () (model-apply c real-machine w (step-who (car steps))
                                                  (step-choice (car steps)))))))
          (if (and (pair? r) (not (eq? (car r) 'raised)) (equal? (car r) (car steps)))
              (loop (cdr r) (cdr steps) (+ n 1))
              (list n (brief-step (car steps)) r))))))

(define walk-config (cfg (shape 1 2) '(fresh delete) 2 #t))

(test-equal "traces: a walk is the same for the same seed, and differs across seeds"
  '(#t #t)
  (attempt
   (lambda ()
     (list (equal? (model-walk walk-config real-machine 7 300)
                   (model-walk walk-config real-machine 7 300))
           (not (equal? (model-walk walk-config real-machine 7 300)
                        (model-walk walk-config real-machine 8 300)))))))

(test-equal "traces: twenty walks replay step for step, each to an end"
  '()
  (attempt
   (lambda ()
     (filter (lambda (x) (not (eq? (cdr x) 'same)))
             (map (lambda (seed)
                    (cons seed (replay walk-config
                                       (model-walk walk-config real-machine seed 1000) #t)))
                  (iota-from 1 20))))))

(define traces-config (cfg (shape 2) '(fresh delete) 2 #t))

(test-equal "traces: the graph's traces cover every row the configuration fires"
  '()
  (attempt
   (lambda ()
     (let ((seen (make-hashtable equal-hash equal?)))
       (model-explore traces-config real-machine
                      (lambda (run? row) (hashtable-set! seen (cons run? row) #t)))
       (let ((keys (map car (model-traces traces-config real-machine))))
         (filter (lambda (k) (not (member k keys)))
                 (vector->list (hashtable-keys seen))))))))

(test-equal "traces: every graph trace replays step for step, to an end"
  '()
  (attempt
   (lambda ()
     (filter (lambda (x) (not (eq? (cdr x) 'same)))
             (map (lambda (kt) (cons (car kt) (replay traces-config (cdr kt) #t)))
                  (model-traces traces-config real-machine))))))

(test-equal "traces: a step's file is the facts and effects after it"
  (list (list techo-application-id 1 1 'wal)
        (map string->symbol (list model-id-statement (effect-statement 1 2))))
  (attempt
   (lambda ()
     (let* ((cw (in-migration)) (c (car cw))
            (w (drive c (cdr cw) '((0 . ok) (0 . ok) (0 . ok))))
            (s (car (model-apply c real-machine w 0 'ok))))
       (list (model-file-facts (step-file s)) (model-file-log (step-file s)))))))

(test-end "migrations-model")

(exit (suite-exit-status runner))
