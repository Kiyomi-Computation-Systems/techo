#!r6rs
;;; The migrations suite: layers 1, 2 and 6 of the slice 2 plan.
;;;   1  static checks on both tables
;;;   2  every row driven through the stepper; every can't-happen pair seen
;;;      to raise; the classifier and event-kind over their whole domains;
;;;      check-migrations; results
;;;   6  the diagrams, the shipped list against its recorded copy
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo machine)
        (techo migrations))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-info : (-> Any) -> (U 'no-raise (List Symbol Any))
;; What an assertion violation was raised about: its who and irritants.
(define (raised-info thunk)
  (guard (e ((and (who-condition? e) (irritants-condition? e))
             (list (condition-who e) (condition-irritants e)))
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

;; raised-who : (-> Any) -> (U 'no-raise Symbol)
(define (raised-who thunk)
  (let ((r (raised-info thunk))) (if (pair? r) (car r) r)))

(define T techo-application-id)

;; Three migrations, so there is a behind at 1 and 2, current at 3, ahead at 4.
(define tm
  (list (list 1 "one" '("S1a" "S1b"))
        (list 2 "two" '("S2"))
        (list 3 "three" '("S3a" "S3b" "S3c"))))

;; facts : Integer Integer Natural Symbol -> DbFacts
(define (facts id ver objs mode) (list id ver objs mode))
;; ok : Any -> RawOutcome   (the transaction is open after)
(define (ok-open v) (list 'ok v #t))
(define (ok-ended v) (list 'ok v #f))
;; d : the run machine's state data
(define (d k i committed converted tries pending)
  (list k i committed converted tries pending))
(define D0 (d 0 0 '() #f 3 #f))
(define (st kind data) (cons kind data))

;; sorted-pairs-diff : (Listof (Pair A B)) (Listof (Pair A B)) -> (Listof (Pair A B))
;; The pairs of XS not in YS.
(define (pairs-diff xs ys) (filter (lambda (p) (not (member p ys))) xs))

;; row-pairs : (Listof Row) -> (Listof (Pair StateKind EventKind))
(define (row-pairs rows) (map (lambda (r) (cons (car r) (cadr r))) rows))

(test-begin "migrations")

;;; Layer 1: static checks

(test-equal "layer 1: the run table has no problems"
  '()
  (attempt
   (lambda ()
     (machine-problems (make-machine run-rows) '(peek-opening) '(ended)
                       run-cant-happen))))

(test-equal "layer 1: the check table has no problems"
  '()
  (attempt
   (lambda ()
     (machine-problems (make-machine check-rows) '(peek-opening) '(ended)
                       check-cant-happen))))

;; R1 to R40 are 40 rows; R8, R39, R40 each take a second (+3), R35 and R36
;; are four rows each (+6), R20b adds the pause's failed row, and R26b the
;; relook's failure that ended the transaction: 51.
(test-equal "layer 1: the run table has the plan's rows, as data"
  51
  (length run-rows))

(test-equal "layer 1: every can't-happen pair carries a reason"
  '()
  (filter (lambda (c) (not (and (= (length c) 3) (string? (caddr c))
                                (> (string-length (caddr c)) 0))))
          (append run-cant-happen check-cant-happen)))

;; A start that fails its own table is found: drop one row and see the problem.
(test-equal "layer 1: dropping a row is found (the check on the table can fail)"
  '((unlisted-gap peek-opening failed))
  (attempt
   (lambda ()
     (filter (lambda (p) (eq? (car p) 'unlisted-gap))
             (machine-problems
              (make-machine (filter (lambda (r)
                                      (not (and (eq? (car r) 'peek-opening)
                                                (eq? (cadr r) 'failed))))
                                    run-rows))
              '(peek-opening) '(ended) run-cant-happen)))))

;;; Layer 2: every row driven

;; A case: label, state, raw outcome, expected event kind, expected next
;; state, expected command.
(define (c label state raw kind next cmd) (list label state raw kind next cmd))
(define (case-state x) (cadr x))
(define (case-raw x) (caddr x))
(define (case-kind x) (cadddr x))
(define (case-next x) (list-ref x 4))
(define (case-cmd x) (list-ref x 5))

(define run-cases
  (list
   (c "R1" (st 'peek-opening D0) '(ok #t #f) 'opened
      (st 'peeking D0) '(read-facts))
   (c "R2" (st 'peek-opening D0) '(missing "no such file" #f) 'missing
      (st 'opening D0) '(open-read-write))
   (c "R3" (st 'peek-opening D0) '(failed "unable to open database file" #f)
      'failed
      (st 'ended '(cannot-open () #f "unable to open database file"))
      '(end cannot-open () #f "unable to open database file"))
   (c "R4" (st 'peeking D0) (ok-ended (facts T 3 5 'wal)) 'current
      (st 'closing (d 0 0 '() #f 3 '(nothing . 3))) '(close))
   (c "R5 ahead" (st 'peeking D0) (ok-ended (facts T 4 0 'wal)) 'refused
      (st 'closing (d 0 0 '() #f 3 '(refused ahead 4))) '(close))
   (c "R5 foreign" (st 'peeking D0) (ok-ended (facts 7 1 1 'wal)) 'refused
      (st 'closing (d 0 0 '() #f 3 '(refused . foreign))) '(close))
   (c "R6 fresh" (st 'peeking D0) (ok-ended (facts 0 0 0 'wal)) 'work
      (st 'reopening D0) '(close))
   (c "R6 unconverted current" (st 'peeking D0) (ok-ended (facts T 3 0 'delete))
      'work (st 'reopening D0) '(close))
   (c "R6 behind" (st 'peeking D0) (ok-ended (facts T 2 0 'wal)) 'work
      (st 'reopening D0) '(close))
   (c "R7" (st 'peeking D0) '(failed "disk I/O error" #f) 'failed
      (st 'closing (d 0 0 '() #f 3 '(failed #f "disk I/O error" #f))) '(close))
   (c "R8 done" (st 'reopening D0) '(ok #t #f) 'done
      (st 'opening D0) '(open-read-write))
   (c "R8 failed" (st 'reopening D0) '(failed "close failed" #f) 'failed
      (st 'opening D0) '(open-read-write))
   (c "R9" (st 'opening D0) '(ok #t #f) 'opened
      (st 'looking D0) '(read-facts))
   (c "R10" (st 'opening D0) '(failed "unable to open database file" #f) 'failed
      (st 'ended '(cannot-open () #f "unable to open database file"))
      '(end cannot-open () #f "unable to open database file"))
   (c "R11" (st 'looking D0) (ok-ended (facts 0 0 0 'delete)) 'unconverted
      (st 'converting D0) '(set-wal))
   (c "R12 fresh" (st 'looking D0) (ok-ended (facts 0 0 0 'wal)) 'pending
      (st 'locking (d 1 1 '() #f 3 #f)) '(begin-immediate))
   (c "R12 behind" (st 'looking D0) (ok-ended (facts T 2 0 'wal)) 'pending
      (st 'locking (d 3 1 '() #f 3 #f)) '(begin-immediate))
   (c "R12 after a commit" (st 'looking (d 2 1 '(1) #t 2 #f))
      (ok-ended (facts T 2 0 'wal)) 'pending
      (st 'locking (d 3 1 '(1) #t 2 #f)) '(begin-immediate))
   (c "R13 nothing" (st 'looking D0) (ok-ended (facts T 3 0 'wal)) 'current
      (st 'closing (d 0 0 '() #f 3 '(nothing . 3))) '(close))
   (c "R13 applied" (st 'looking (d 2 1 '(1 2) #t 3 #f))
      (ok-ended (facts T 3 0 'wal)) 'current
      (st 'closing (d 2 1 '(1 2) #t 3 '(applied . 3))) '(close))
   (c "R14 ahead" (st 'looking D0) (ok-ended (facts T 5 0 'wal)) 'refused
      (st 'closing (d 0 0 '() #f 3 '(refused ahead 5))) '(close))
   (c "R14 foreign" (st 'looking D0) (ok-ended (facts T 0 0 'wal)) 'refused
      (st 'closing (d 0 0 '() #f 3 '(refused . foreign))) '(close))
   (c "R15" (st 'looking D0) '(failed "disk I/O error" #f) 'failed
      (st 'closing (d 0 0 '() #f 3 '(failed #f "disk I/O error" #f))) '(close))
   (c "R16" (st 'converting D0) '(ok #t #f) 'converted
      (st 'looking (d 0 0 '() #t 3 #f)) '(read-facts))
   (c "R17 first" (st 'converting D0) '(busy "database is locked" #f) 'busy-retry
      (st 'pausing (d 0 0 '() #f 2 #f)) '(pause . 100))
   (c "R17 last try" (st 'converting (d 0 0 '() #f 1 #f))
      '(busy "database is locked" #f) 'busy-retry
      (st 'pausing (d 0 0 '() #f 0 #f)) '(pause . 100))
   (c "R18" (st 'converting (d 0 0 '() #f 0 #f)) '(busy "database is locked" #f)
      'busy-none
      (st 'closing (d 0 0 '() #f 0 '(busy . "database is locked"))) '(close))
   (c "R19" (st 'converting D0) '(failed "attempt to write a readonly database" #f)
      'failed
      (st 'closing
          (d 0 0 '() #f 3 '(failed #f "attempt to write a readonly database" #f)))
      '(close))
   (c "R20 done" (st 'pausing (d 0 0 '() #f 2 #f)) '(ok #t #f) 'done
      (st 'looking (d 0 0 '() #f 2 #f)) '(read-facts))
   (c "R20b failed" (st 'pausing D0) '(failed "interrupted" #f) 'failed
      (st 'closing (d 0 0 '() #f 3 '(failed #f "interrupted" #f))) '(close))
   (c "R21" (st 'locking (d 1 1 '() #f 3 #f)) '(ok #t #t) 'locked
      (st 'relooking (d 1 1 '() #f 3 #f)) '(read-facts))
   (c "R22" (st 'locking (d 1 1 '() #f 3 #f)) '(busy "database is locked" #f)
      'busy
      (st 'closing (d 1 1 '() #f 3 '(busy . "database is locked"))) '(close))
   (c "R23" (st 'locking (d 1 1 '() #f 3 #f)) '(failed "disk I/O error" #f)
      'failed
      (st 'closing (d 1 1 '() #f 3 '(failed #f "disk I/O error" #f))) '(close))
   (c "R24 first migration" (st 'relooking (d 1 1 '() #t 3 #f))
      (ok-open (facts 0 0 0 'wal)) 'pending
      (st 'applying (d 1 1 '() #t 3 #f)) '(run-statement . "S1a"))
   (c "R24 second migration" (st 'relooking (d 2 1 '(1) #f 3 #f))
      (ok-open (facts T 1 0 'wal)) 'pending
      (st 'applying (d 2 1 '(1) #f 3 #f)) '(run-statement . "S2"))
   (c "R25 moved on" (st 'relooking (d 2 1 '(1) #f 3 #f))
      (ok-open (facts T 2 0 'wal)) 'changed
      (st 'undoing-to-look (d 2 1 '(1) #f 3 #f)) '(rollback))
   (c "R25 not in WAL" (st 'relooking (d 2 1 '(1) #f 3 #f))
      (ok-open (facts T 1 0 'delete)) 'changed
      (st 'undoing-to-look (d 2 1 '(1) #f 3 #f)) '(rollback))
   (c "R26" (st 'relooking (d 2 1 '(1) #f 3 #f)) '(failed "io" #t) 'failed
      (st 'undoing-to-fail (d 2 1 '(1) #f 3 '(failed 2 "io" #f))) '(rollback))
   ;; the transaction is gone, so there is nothing to roll back
   (c "R26b" (st 'relooking (d 2 1 '(1) #f 3 #f)) '(failed "io" #f) 'failed-ended
      (st 'closing (d 2 1 '(1) #f 3 '(failed 2 "io" #f))) '(close))
   (c "R26b, ok but ended" (st 'relooking (d 2 1 '(1) #f 3 #f))
      (ok-ended (facts T 1 0 'wal)) 'failed-ended
      (st 'closing (d 2 1 '(1) #f 3 '(failed 2 "the transaction ended early" #f)))
      '(close))
   (c "R27" (st 'applying (d 1 1 '() #f 3 #f)) (ok-open #t) 'more
      (st 'applying (d 1 2 '() #f 3 #f)) '(run-statement . "S1b"))
   (c "R27 third of three" (st 'applying (d 3 2 '(1 2) #f 3 #f)) (ok-open #t) 'more
      (st 'applying (d 3 3 '(1 2) #f 3 #f)) '(run-statement . "S3c"))
   (c "R28" (st 'applying (d 1 2 '() #f 3 #f)) (ok-open #t) 'last
      (st 'checking (d 1 2 '() #f 3 #f)) '(foreign-key-check))
   (c "R29" (st 'applying (d 1 1 '() #f 3 #f)) (ok-ended #t) 'txn-ended
      (st 'closing
          (d 1 1 '() #f 3 '(failed 1 "a statement ended the transaction" #f)))
      '(close))
   (c "R35 applying" (st 'applying (d 1 1 '() #f 3 #f))
      '(failed "constraint failed" #t) 'failed
      (st 'undoing-to-fail (d 1 1 '() #f 3 '(failed 1 "constraint failed" #f)))
      '(rollback))
   (c "R36 applying" (st 'applying (d 1 1 '() #f 3 #f))
      '(failed "disk full" #f) 'failed-ended
      (st 'closing (d 1 1 '() #f 3 '(failed 1 "disk full" #f))) '(close))
   (c "R30" (st 'checking (d 1 2 '() #f 3 #f)) (ok-open '()) 'clean
      (st 'stamping (d 1 2 '() #f 3 #f)) '(stamp . 1))
   (c "R31" (st 'checking (d 1 2 '() #f 3 #f)) (ok-open '((t 1 p 0))) 'violations
      (st 'undoing-to-fail
          (d 1 2 '() #f 3 '(failed 1 "foreign key check found violations" #f)))
      '(rollback))
   (c "R35 checking" (st 'checking (d 1 2 '() #f 3 #f)) '(failed "io" #t) 'failed
      (st 'undoing-to-fail (d 1 2 '() #f 3 '(failed 1 "io" #f))) '(rollback))
   (c "R36 checking" (st 'checking (d 1 2 '() #f 3 #f)) '(failed "io" #f)
      'failed-ended
      (st 'closing (d 1 2 '() #f 3 '(failed 1 "io" #f))) '(close))
   (c "R36 checking, ok but ended" (st 'checking (d 1 2 '() #f 3 #f))
      (ok-ended '()) 'failed-ended
      (st 'closing (d 1 2 '() #f 3 '(failed 1 "the transaction ended early" #f)))
      '(close))
   (c "R32" (st 'stamping (d 1 2 '() #f 3 #f)) (ok-open #t) 'stamped
      (st 'committing (d 1 2 '() #f 3 #f)) '(commit))
   (c "R35 stamping" (st 'stamping (d 1 2 '() #f 3 #f)) '(failed "io" #t) 'failed
      (st 'undoing-to-fail (d 1 2 '() #f 3 '(failed 1 "io" #f))) '(rollback))
   (c "R36 stamping" (st 'stamping (d 1 2 '() #f 3 #f)) '(failed "io" #f)
      'failed-ended
      (st 'closing (d 1 2 '() #f 3 '(failed 1 "io" #f))) '(close))
   (c "R36 stamping, ok but ended" (st 'stamping (d 1 2 '() #f 3 #f))
      (ok-ended #t) 'failed-ended
      (st 'closing (d 1 2 '() #f 3 '(failed 1 "the transaction ended early" #f)))
      '(close))
   (c "R33" (st 'committing (d 1 2 '() #t 3 #f)) (ok-ended #t) 'below
      (st 'locking (d 2 1 '(1) #t 3 #f)) '(begin-immediate))
   (c "R34" (st 'committing (d 3 3 '(1 2) #f 3 #f)) (ok-ended #t) 'latest
      (st 'closing (d 3 3 '(1 2 3) #f 3 '(applied . 3))) '(close))
   (c "R35 committing" (st 'committing (d 2 1 '(1) #f 3 #f))
      '(failed "disk full" #t) 'failed
      (st 'undoing-to-fail (d 2 1 '(1) #f 3 '(failed 2 "disk full" #t)))
      '(rollback))
   (c "R36 committing" (st 'committing (d 2 1 '(1) #f 3 #f))
      '(failed "disk full" #f) 'failed-ended
      (st 'closing (d 2 1 '(1) #f 3 '(failed 2 "disk full" #t))) '(close))
   (c "R37" (st 'undoing-to-look (d 2 1 '(1) #f 3 #f)) '(ok #t #f) 'done
      (st 'looking (d 2 1 '(1) #f 3 #f)) '(read-facts))
   (c "R38" (st 'undoing-to-look (d 2 1 '(1) #f 3 #f)) '(failed "io" #f) 'failed
      (st 'closing (d 2 1 '(1) #f 3 '(failed 2 "io" #f))) '(close))
   (c "R39 done" (st 'undoing-to-fail (d 2 1 '(1) #f 3 '(failed 2 "io" #f)))
      '(ok #t #f) 'done
      (st 'closing (d 2 1 '(1) #f 3 '(failed 2 "io" #f))) '(close))
   (c "R39 failed" (st 'undoing-to-fail (d 2 1 '(1) #f 3 '(failed 2 "io" #f)))
      '(failed "cannot rollback" #f) 'failed
      (st 'closing (d 2 1 '(1) #f 3 '(failed 2 "io" #f))) '(close))
   (c "R40 done" (st 'closing (d 3 3 '(1 2 3) #t 3 '(applied . 3)))
      '(ok #t #f) 'done
      (st 'ended '(applied (1 2 3) #t 3)) '(end applied (1 2 3) #t 3))
   (c "R40 failed" (st 'closing (d 3 3 '(1 2 3) #t 3 '(applied . 3)))
      '(failed "close failed" #f) 'failed
      (st 'ended '(applied (1 2 3) #t 3)) '(end applied (1 2 3) #t 3))
   (c "R40 a failure" (st 'closing (d 2 1 '(1) #f 3 '(failed 2 "x" #t)))
      '(ok #t #f) 'done
      (st 'ended '(failed (1) #f (2 "x" #t))) '(end failed (1) #f (2 "x" #t)))))

(define check-cases
  (list
   (c "C opened" (st 'peek-opening '()) '(ok #t #f) 'opened
      (st 'peeking '()) '(read-facts))
   (c "C missing" (st 'peek-opening '()) '(missing "no such file" #f) 'missing
      (st 'ended
          '(refuse missing "the database file is missing: run `techo migrate`"))
      '(end refuse missing "the database file is missing: run `techo migrate`"))
   (c "C cannot open" (st 'peek-opening '())
      '(failed "unable to open database file" #f) 'failed
      (st 'ended
          '(refuse cannot-open
                   "cannot open the database: unable to open database file"))
      '(end refuse cannot-open
            "cannot open the database: unable to open database file"))
   (c "C serve" (st 'peeking '()) (ok-ended (facts T 3 0 'wal)) 'serve
      (st 'closing 'serve) '(close))
   (c "C fresh" (st 'peeking '()) (ok-ended (facts 0 0 0 'delete)) 'fresh
      (st 'closing '(refuse fresh "the database is empty: run `techo migrate`"))
      '(close))
   (c "C behind" (st 'peeking '()) (ok-ended (facts T 2 0 'wal)) 'behind
      (st 'closing
          '(refuse behind
                   "the database is behind this binary: run `techo migrate`"))
      '(close))
   (c "C unconverted" (st 'peeking '()) (ok-ended (facts T 3 0 'delete))
      'unconverted
      (st 'closing
          '(refuse unconverted
                   "the database is not in WAL mode: run `techo migrate`"))
      '(close))
   (c "C ahead" (st 'peeking '()) (ok-ended (facts T 5 0 'wal)) 'ahead
      (st 'closing
          '(refuse ahead "this binary is older than the database (version 5)"))
      '(close))
   (c "C foreign" (st 'peeking '()) (ok-ended (facts 9 1 1 'wal)) 'foreign
      (st 'closing '(refuse foreign "not Techo's database")) '(close))
   (c "C failed" (st 'peeking '()) '(failed "disk I/O error" #f) 'failed
      (st 'closing
          '(refuse failed "cannot read the database: disk I/O error"))
      '(close))
   (c "C close done" (st 'closing 'serve) '(ok #t #f) 'done
      (st 'ended 'serve) '(end . serve))
   (c "C close failed" (st 'closing '(refuse fresh "x")) '(failed "x" #f) 'failed
      (st 'ended '(refuse fresh "x")) '(end refuse fresh "x"))))

;; drive : (Listof Migration) Stepper (State RawOutcome -> EventKind) Case
;;         -> (U (List EventKind State Command) (List 'raised String))
(define (drive step kind-of x)
  (attempt
   (lambda ()
     (let-values (((next cmd) (step tm (case-state x) (case-raw x))))
       (list (kind-of tm (case-state x) (case-raw x)) next cmd)))))

(for-each
 (lambda (x)
   (test-equal (string-append "layer 2 run row " (car x))
     (list (case-kind x) (case-next x) (case-cmd x))
     (drive run-step event-kind x)))
 run-cases)

(for-each
 (lambda (x)
   (test-equal (string-append "layer 2 check row " (car x))
     (list (case-kind x) (case-next x) (case-cmd x))
     (drive check-step check-event-kind x)))
 check-cases)

;; Every row is driven: the pairs the cases declare, and the rows' pairs.
(define (case-pairs cases)
  (map (lambda (x) (cons (state-kind (case-state x)) (case-kind x))) cases))

(test-equal "layer 2: a run row no case drives"
  '()
  (pairs-diff (row-pairs run-rows) (case-pairs run-cases)))
(test-equal "layer 2: a run case that drives no row"
  '()
  (pairs-diff (case-pairs run-cases) (row-pairs run-rows)))
(test-equal "layer 2: a check row no case drives"
  '()
  (pairs-diff (row-pairs check-rows) (case-pairs check-cases)))
(test-equal "layer 2: a check case that drives no row"
  '()
  (pairs-diff (case-pairs check-cases) (row-pairs check-rows)))

;; The command is the row's command kind.
(define (command-kind-mismatches rows cases)
  (filter
   (lambda (x)
     (let ((row (find (lambda (r) (and (eq? (car r) (state-kind (case-state x)))
                                       (eq? (cadr r) (case-kind x))))
                      rows)))
       (not (and row (eq? (cadddr row) (car (case-cmd x)))))))
   cases))
(test-equal "layer 2: each case's command is its row's command kind (run)"
  '()
  (map car (command-kind-mismatches run-rows run-cases)))
(test-equal "layer 2: each case's command is its row's command kind (check)"
  '()
  (map car (command-kind-mismatches check-rows check-cases)))

;; Every can't-happen pair raises, naming the pair.
(define (cant-results machine-rows cants)
  (let ((m (make-machine machine-rows)))
    (map (lambda (c)
           (list c
                 (raised-info
                  (lambda ()
                    (machine-step m (cons (car c) '()) (cons (cadr c) '()))))))
         cants)))
(define (cant-mismatches machine-rows cants)
  (filter (lambda (r)
            (not (equal? (cadr r)
                         (list 'machine-step (list (car (car r)) (cadr (car r)))))))
          (cant-results machine-rows cants)))

(test-equal "layer 2: every run can't-happen pair raises, naming it"
  '()
  (cant-mismatches run-rows run-cant-happen))
(test-equal "layer 2: every check can't-happen pair raises, naming it"
  '()
  (cant-mismatches check-rows check-cant-happen))
(test-assert "layer 2: the run can't-happen list is not empty"
  (> (length run-cant-happen) 100))
(test-assert "layer 2: the check can't-happen list is not empty"
  (> (length check-cant-happen) 10))

;; make-stepper takes the rows and the classifier it is given.
(test-equal "layer 2: make-stepper uses the classifier it is given"
  '((ended cannot-open () #f "unknown failure")
    (end cannot-open () #f "unknown failure"))
  (attempt
   (lambda ()
     (let-values (((s cmd)
                   ((make-stepper run-rows (lambda (ms state raw) 'failed))
                    tm (st 'peek-opening D0) '(failed #f #f))))
       (list s cmd)))))

(test-equal "layer 2: run-start and check-start"
  '(((peek-opening 0 0 () #f 3 #f) (open-read-only))
    ((peek-opening) (open-read-only)))
  (attempt
   (lambda ()
     (let-values (((s1 c1) (run-start)) ((s2 c2) (check-start)))
       (list (list s1 c1) (list s2 c2))))))

;;; event-kind over every state kind and raw outcome shape

(define fail-open '(failed "x" #t))
(define fail-ended '(failed "x" #f))
(define busy-raw '(busy "database is locked" #f))
(define missing-raw '(missing "no such file" #f))

;; An entry: state, raw, expected event kind.
(define (e state raw kind) (list state raw kind))

(define (simple state ok-kind other-kind)
  (list (e state (ok-open #t) ok-kind) (e state (ok-ended #t) ok-kind)
        (e state busy-raw other-kind) (e state missing-raw other-kind)
        (e state fail-open other-kind) (e state fail-ended other-kind)))

(define (look-entries state-kind data expectations)
  ;; expectations: (facts kind)
  (map (lambda (x) (e (st state-kind data) (ok-ended (car x)) (cadr x)))
       expectations))

;; look-entries-open: the same, the transaction still open after the read,
;; as it is for a look under the lock.
(define (look-entries-open state-kind data expectations)
  (map (lambda (x) (e (st state-kind data) (ok-open (car x)) (cadr x)))
       expectations))

(define (non-ok-failed state)
  (list (e state busy-raw 'failed) (e state missing-raw 'failed)
        (e state fail-open 'failed) (e state fail-ended 'failed)))

(define event-kind-table
  (append
   ;; peek-opening: opened, missing, failed
   (list (e (st 'peek-opening D0) (ok-ended #t) 'opened)
         (e (st 'peek-opening D0) (ok-open #t) 'opened)
         (e (st 'peek-opening D0) busy-raw 'failed)
         (e (st 'peek-opening D0) missing-raw 'missing)
         (e (st 'peek-opening D0) fail-open 'failed)
         (e (st 'peek-opening D0) fail-ended 'failed))
   ;; peeking
   (look-entries
    'peeking D0
    (list (list (facts T 3 0 'wal) 'current)
          (list (facts T 3 0 'delete) 'work)
          (list (facts 0 0 0 'wal) 'work)
          (list (facts 0 0 0 'delete) 'work)
          (list (facts T 1 0 'wal) 'work)
          (list (facts T 2 0 'delete) 'work)
          (list (facts T 4 0 'wal) 'refused)
          (list (facts T 4 0 'delete) 'refused)
          (list (facts 7 3 0 'wal) 'refused)
          (list (facts T 0 0 'wal) 'refused)
          (list (facts 0 0 1 'wal) 'refused)))
   (non-ok-failed (st 'peeking D0))
   ;; reopening, opening
   (simple (st 'reopening D0) 'done 'failed)
   (simple (st 'opening D0) 'opened 'failed)
   ;; looking
   (look-entries
    'looking D0
    (list (list (facts 0 0 0 'wal) 'pending)
          (list (facts 0 0 0 'delete) 'unconverted)
          (list (facts T 1 0 'wal) 'pending)
          (list (facts T 2 9 'wal) 'pending)
          (list (facts T 2 0 'delete) 'unconverted)
          (list (facts T 3 0 'wal) 'current)
          (list (facts T 3 0 'delete) 'unconverted)
          (list (facts T 4 0 'wal) 'refused)
          (list (facts T 4 0 'delete) 'refused)
          (list (facts 99 0 0 'delete) 'refused)
          (list (facts 0 0 1 'wal) 'refused)
          (list (facts T -1 0 'wal) 'refused)))
   (non-ok-failed (st 'looking D0))
   ;; converting, with tries left and none
   (list (e (st 'converting D0) (ok-ended #t) 'converted)
         (e (st 'converting D0) busy-raw 'busy-retry)
         (e (st 'converting (d 0 0 '() #f 1 #f)) busy-raw 'busy-retry)
         (e (st 'converting (d 0 0 '() #f 0 #f)) busy-raw 'busy-none)
         (e (st 'converting D0) missing-raw 'failed)
         (e (st 'converting D0) fail-open 'failed)
         (e (st 'converting D0) fail-ended 'failed)
         (e (st 'converting (d 0 0 '() #f 0 #f)) fail-ended 'failed))
   (simple (st 'pausing D0) 'done 'failed)
   ;; locking
   (list (e (st 'locking (d 1 1 '() #f 3 #f)) (ok-open #t) 'locked)
         (e (st 'locking (d 1 1 '() #f 3 #f)) busy-raw 'busy)
         (e (st 'locking (d 1 1 '() #f 3 #f)) missing-raw 'failed)
         (e (st 'locking (d 1 1 '() #f 3 #f)) fail-open 'failed)
         (e (st 'locking (d 1 1 '() #f 3 #f)) fail-ended 'failed))
   ;; relooking: pending exactly when fresh at k = 1 or behind at k - 1, in WAL
   (look-entries-open
    'relooking (d 1 1 '() #f 3 #f)
    (list (list (facts 0 0 0 'wal) 'pending)
          (list (facts 0 0 0 'delete) 'changed)
          (list (facts T 1 0 'wal) 'changed)
          (list (facts T 3 0 'wal) 'changed)
          (list (facts T 4 0 'wal) 'changed)
          (list (facts 99 1 1 'wal) 'changed)))
   (look-entries-open
    'relooking (d 2 1 '(1) #f 3 #f)
    (list (list (facts T 1 0 'wal) 'pending)
          (list (facts T 1 0 'delete) 'changed)
          (list (facts 0 0 0 'wal) 'changed)
          (list (facts T 2 0 'wal) 'changed)
          (list (facts T 3 0 'wal) 'changed)
          (list (facts 0 0 1 'wal) 'changed)))
   (look-entries-open
    'relooking (d 3 1 '(1 2) #f 3 #f)
    (list (list (facts T 2 0 'wal) 'pending)
          (list (facts T 3 0 'wal) 'changed)
          (list (facts T 1 0 'wal) 'changed)))
   ;; relooking: a failure, or an ok, that ended the transaction is
   ;; failed-ended, whatever the facts
   (let ((s (st 'relooking (d 2 1 '(1) #f 3 #f))))
     (list (e s fail-open 'failed) (e s fail-ended 'failed-ended)
           (e s '(busy "b" #t) 'failed) (e s busy-raw 'failed-ended)
           (e s '(missing "m" #t) 'failed) (e s missing-raw 'failed-ended)
           (e s (ok-ended (facts T 1 0 'wal)) 'failed-ended)
           (e s (ok-ended (facts T 2 0 'wal)) 'failed-ended)
           (e s (ok-ended (facts 0 0 0 'delete)) 'failed-ended)))
   ;; applying: migration 1 has two statements
   (list (e (st 'applying (d 1 1 '() #f 3 #f)) (ok-open #t) 'more)
         (e (st 'applying (d 1 2 '() #f 3 #f)) (ok-open #t) 'last)
         (e (st 'applying (d 2 1 '(1) #f 3 #f)) (ok-open #t) 'last)
         (e (st 'applying (d 3 2 '(1 2) #f 3 #f)) (ok-open #t) 'more)
         (e (st 'applying (d 3 3 '(1 2) #f 3 #f)) (ok-open #t) 'last)
         (e (st 'applying (d 1 1 '() #f 3 #f)) (ok-ended #t) 'txn-ended)
         (e (st 'applying (d 1 2 '() #f 3 #f)) (ok-ended #t) 'txn-ended)
         (e (st 'applying (d 1 1 '() #f 3 #f)) fail-open 'failed)
         (e (st 'applying (d 1 1 '() #f 3 #f)) fail-ended 'failed-ended)
         (e (st 'applying (d 1 1 '() #f 3 #f)) '(busy "b" #t) 'failed)
         (e (st 'applying (d 1 1 '() #f 3 #f)) '(busy "b" #f) 'failed-ended)
         (e (st 'applying (d 1 1 '() #f 3 #f)) '(missing "m" #t) 'failed)
         (e (st 'applying (d 1 1 '() #f 3 #f)) '(missing "m" #f) 'failed-ended))
   ;; checking
   (let ((s (st 'checking (d 1 2 '() #f 3 #f))))
     (list (e s (ok-open '()) 'clean)
           (e s (ok-open '((t 1 p 0))) 'violations)
           (e s (ok-open '((t 1 p 0) (t 2 p 0))) 'violations)
           (e s (ok-ended '()) 'failed-ended)
           (e s (ok-ended '((t 1 p 0))) 'failed-ended)
           (e s fail-open 'failed) (e s fail-ended 'failed-ended)
           (e s '(busy "b" #t) 'failed) (e s '(busy "b" #f) 'failed-ended)
           (e s '(missing "m" #t) 'failed) (e s '(missing "m" #f) 'failed-ended)))
   ;; stamping
   (let ((s (st 'stamping (d 1 2 '() #f 3 #f))))
     (list (e s (ok-open #t) 'stamped) (e s (ok-ended #t) 'failed-ended)
           (e s fail-open 'failed) (e s fail-ended 'failed-ended)
           (e s '(busy "b" #t) 'failed) (e s '(busy "b" #f) 'failed-ended)))
   ;; committing: k below latest, and k is latest
   (list (e (st 'committing (d 1 2 '() #f 3 #f)) (ok-ended #t) 'below)
         (e (st 'committing (d 2 1 '(1) #f 3 #f)) (ok-ended #t) 'below)
         (e (st 'committing (d 3 3 '(1 2) #f 3 #f)) (ok-ended #t) 'latest)
         (e (st 'committing (d 3 3 '(1 2) #f 3 #f)) (ok-open #t) 'failed)
         (e (st 'committing (d 3 3 '(1 2) #f 3 #f)) fail-open 'failed)
         (e (st 'committing (d 3 3 '(1 2) #f 3 #f)) fail-ended 'failed-ended)
         (e (st 'committing (d 3 3 '(1 2) #f 3 #f)) '(busy "b" #t) 'failed)
         (e (st 'committing (d 3 3 '(1 2) #f 3 #f)) '(busy "b" #f) 'failed-ended))
   (simple (st 'undoing-to-look D0) 'done 'failed)
   (simple (st 'undoing-to-fail D0) 'done 'failed)
   (simple (st 'closing D0) 'done 'failed)))

(for-each
 (lambda (x)
   (test-equal (string-append "event-kind: " (symbol->string (car (car x))) " "
                              (describe (cadr x)))
     (caddr x)
     (attempt (lambda () (event-kind tm (car x) (cadr x))))))
 event-kind-table)

;; Every non-terminal state kind of the table is in the event-kind table.
(test-equal "event-kind: every non-terminal state kind is covered"
  '()
  (filter (lambda (k)
            (and (not (eq? k 'ended))
                 (not (exists (lambda (x) (eq? (car (car x)) k)) event-kind-table))))
          (map car run-rows)))

;; Every answer has a row: event-kind never lands on a can't-happen pair.
(test-equal "event-kind: every answer in the table has a row"
  '()
  (filter (lambda (x)
            (not (member (cons (car (car x)) (caddr x)) (row-pairs run-rows))))
          event-kind-table))

(test-equal "event-kind: ended takes no event"
  'event-kind
  (raised-who (lambda () (event-kind tm (st 'ended '(nothing () #f 1)) '(ok #t #f)))))

(test-equal "event-kind: a malformed outcome is refused, by who"
  '(event-kind event-kind)
  (list (raised-who (lambda () (event-kind tm (st 'opening D0) '(ok #t))))
        (raised-who (lambda () (event-kind tm (st 'opening D0) '(weird #t #f))))))

(test-equal "event-kind: facts that are not facts are refused, by who"
  'event-kind
  (raised-who (lambda () (event-kind tm (st 'looking D0) (ok-ended '(1 2))))))

;;; check-event-kind

(define check-event-table
  (append
   (list (e (st 'peek-opening '()) (ok-ended #t) 'opened)
         (e (st 'peek-opening '()) busy-raw 'failed)
         (e (st 'peek-opening '()) missing-raw 'missing)
         (e (st 'peek-opening '()) fail-ended 'failed))
   (look-entries
    'peeking '()
    (list (list (facts T 3 0 'wal) 'serve)
          (list (facts T 3 7 'wal) 'serve)
          (list (facts T 3 0 'delete) 'unconverted)
          (list (facts 0 0 0 'wal) 'fresh)
          (list (facts 0 0 0 'delete) 'fresh)
          (list (facts T 1 0 'wal) 'behind)
          (list (facts T 2 0 'delete) 'behind)
          (list (facts T 4 0 'wal) 'ahead)
          (list (facts T 4 0 'delete) 'ahead)
          (list (facts 99 3 0 'wal) 'foreign)
          (list (facts 0 0 2 'wal) 'foreign)
          (list (facts T 0 0 'wal) 'foreign)
          (list (facts T -2 0 'delete) 'foreign)))
   (non-ok-failed (st 'peeking '()))
   (simple (st 'closing 'serve) 'done 'failed)))

(for-each
 (lambda (x)
   (test-equal (string-append "check-event-kind: " (symbol->string (car (car x)))
                              " " (describe (cadr x)))
     (caddr x)
     (attempt (lambda () (check-event-kind tm (car x) (cadr x))))))
 check-event-table)

(test-equal "check-event-kind: every answer has a row"
  '()
  (filter (lambda (x)
            (not (member (cons (car (car x)) (caddr x)) (row-pairs check-rows))))
          check-event-table))

(test-equal "check-event-kind: a state the check machine lacks is refused"
  'check-event-kind
  (raised-who (lambda () (check-event-kind tm (st 'looking D0) '(ok #t #f)))))

;;; classify, over id x version x schema x journal mode

;; The expected table, by hand, for latest = 3. A row: id, version, objects,
;; answer. The journal mode never matters, so each row is tried in both.
(define classify-table
  (list
   ;; id 0
   (list 0 -1 0 'foreign) (list 0 -1 1 'foreign)
   (list 0 0 0 'fresh)    (list 0 0 1 'foreign)
   (list 0 1 0 'foreign)  (list 0 1 1 'foreign)
   (list 0 2 0 'foreign)  (list 0 2 1 'foreign)
   (list 0 3 0 'foreign)  (list 0 3 1 'foreign)
   (list 0 4 0 'foreign)  (list 0 4 1 'foreign)
   ;; Techo's id
   (list T -1 0 'foreign) (list T -1 1 'foreign)
   (list T 0 0 'foreign)  (list T 0 1 'foreign)
   (list T 1 0 '(behind 1)) (list T 1 1 '(behind 1))
   (list T 2 0 '(behind 2)) (list T 2 1 '(behind 2))
   (list T 3 0 'current)  (list T 3 1 'current)
   (list T 4 0 '(ahead 4)) (list T 4 1 '(ahead 4))
   ;; another program's id
   (list 99 -1 0 'foreign) (list 99 -1 1 'foreign)
   (list 99 0 0 'foreign)  (list 99 0 1 'foreign)
   (list 99 1 0 'foreign)  (list 99 1 1 'foreign)
   (list 99 2 0 'foreign)  (list 99 2 1 'foreign)
   (list 99 3 0 'foreign)  (list 99 3 1 'foreign)
   (list 99 4 0 'foreign)  (list 99 4 1 'foreign)))

(test-equal "classify: the table is the whole space (3 ids x 6 versions x 2 counts)"
  36
  (length classify-table))

(for-each
 (lambda (row)
   (for-each
    (lambda (mode)
      (test-equal (string-append "classify: id " (number->string (car row))
                                 " version " (number->string (cadr row))
                                 " objects " (number->string (caddr row))
                                 " " (symbol->string mode))
        (cadddr row)
        (attempt (lambda ()
                   (classify (facts (car row) (cadr row) (caddr row) mode) tm)))))
    '(wal delete)))
 classify-table)

(test-equal "classify: a negative id is foreign"
  'foreign
  (attempt (lambda () (classify (facts -5 3 0 'wal) tm))))
(test-equal "classify: the latest comes from the list it is given"
  '((ahead 2) current)
  (attempt (lambda ()
             (list (classify (facts T 2 0 'wal) (list (car tm)))
                   (classify (facts T 1 0 'wal) (list (car tm)))))))
(test-equal "classify: facts that are not facts raise, by who"
  'classify
  (raised-who (lambda () (classify '(1 2 3) tm))))

(test-equal "facts-wal?: wal is wal, the rest are not"
  '(#t #f #f #f)
  (attempt (lambda ()
             (map (lambda (m) (facts-wal? (facts T 1 0 m)))
                  '(wal delete memory truncate)))))

;;; check-migrations

(define m1 (if (pair? migrations) (car migrations) (list 1 "x" (list "x"))))
(define (with-m1 . more) (cons m1 more))

(test-equal "check-migrations: the shipped list is clean"
  '()
  (attempt (lambda () (check-migrations migrations))))
(test-equal "check-migrations: a clean second migration"
  '()
  (attempt (lambda ()
             (check-migrations
              (with-m1 (list 2 "t" '("CREATE TABLE a (x INTEGER) STRICT"
                                      "CREATE INDEX a_x ON a (x)")))))))
(test-equal "check-migrations: a trigger's BEGIN ... END is accepted"
  '()
  (attempt
   (lambda ()
     (check-migrations
      (with-m1 (list 2 "t"
                     '("CREATE TRIGGER t1 AFTER INSERT ON a BEGIN SELECT 1; END")))))))
(test-equal "check-migrations: the empty list"
  '((no-migrations))
  (attempt (lambda () (check-migrations '()))))
(test-equal "check-migrations: a gap"
  '((bad-version 1 3))
  (attempt (lambda () (check-migrations (with-m1 (list 3 "t" '("CREATE TABLE a (x)")))))))
(test-equal "check-migrations: a repeat"
  '((bad-version 1 1))
  (attempt (lambda () (check-migrations (with-m1 (list 1 "t" '("CREATE TABLE a (x)")))))))
(test-equal "check-migrations: the first is not 1"
  '((bad-version 0 2))
  (attempt (lambda () (check-migrations (list (list 2 "two" (caddr m1)))))))
(test-equal "check-migrations: an empty name, and a blank one"
  '((empty-name 2) (empty-name 3))
  (attempt (lambda ()
             (check-migrations
              (with-m1 (list 2 "" '("CREATE TABLE a (x)"))
                       (list 3 "  " '("CREATE TABLE b (x)")))))))
(test-equal "check-migrations: an empty statement, and a blank one"
  '((empty-statement 2 1) (empty-statement 2 2))
  (attempt (lambda ()
             (check-migrations
              (with-m1 (list 2 "t" '("" " \n "
                                      )))))))
(test-equal "check-migrations: a migration with no statements is clean"
  '()
  (attempt (lambda () (check-migrations (with-m1 (list 2 "t" '()))))))
(test-equal "check-migrations: migration 1 must be exactly the id statement"
  '((first-migration-not-the-id) (first-migration-not-the-id)
    (first-migration-not-the-id))
  (attempt
   (lambda ()
     (list
      (car (check-migrations
            (list (list 1 "x" '("PRAGMA application_id = 5")))))
      (car (check-migrations
            (list (list 1 "x" (list (car (caddr m1)) "CREATE TABLE a (x)")))))
      (car (check-migrations
            (list (list 1 "x" '("CREATE TABLE a (x)")))))))))
(test-equal "check-migrations: a malformed migration"
  '((malformed-migration 1) (malformed-migration 1))
  (attempt
   (lambda ()
     (list (car (check-migrations (with-m1 '(2 "t"))))
           (car (check-migrations (with-m1 '(2 "t" ("a" 3)))))))))

(for-each
 (lambda (word)
   (test-equal (string-append "check-migrations: " word " is refused")
     (list (list 'forbidden-statement 2 1 word))
     (attempt
      (lambda ()
        (check-migrations
         (with-m1 (list 2 "t" (list (string-append "  " word " x"))))))))
   (test-equal (string-append "check-migrations: " word " is refused in lower case")
     (list (list 'forbidden-statement 2 2 word))
     (attempt
      (lambda ()
        (check-migrations
         (with-m1 (list 2 "t" (list "CREATE TABLE a (x)"
                                    (string-append "\n\t"
                                                   (list->string
                                                    (map char-downcase
                                                         (string->list word)))
                                                   ";")))))))))
 '("BEGIN" "COMMIT" "END" "ROLLBACK" "SAVEPOINT" "RELEASE" "ATTACH" "DETACH"
   "VACUUM" "PRAGMA" "EXPLAIN"))

(test-equal "check-migrations: a comment in front does not hide the word"
  '((forbidden-statement 2 1 "COMMIT") (forbidden-statement 2 2 "BEGIN"))
  (attempt
   (lambda ()
     (check-migrations
      (with-m1 (list 2 "t" '("-- hello\nCOMMIT" "/* x */ begin")))))))
(test-equal "check-migrations: a leading ; or a byte order mark does not hide the word"
  '((forbidden-statement 2 1 "COMMIT") (forbidden-statement 2 2 "COMMIT")
    (forbidden-statement 2 3 "COMMIT") (forbidden-statement 2 4 "END")
    (forbidden-statement 2 5 "COMMIT"))
  (attempt
   (lambda ()
     (check-migrations
      (with-m1 (list 2 "t" (list ";COMMIT" " ; ; COMMIT" "-- x\n;COMMIT" "/*x*/;END"
                                 (string-append (string (integer->char #xFEFF))
                                                "COMMIT"))))))))
(test-equal "check-migrations: the first migration's PRAGMA is no excuse for the others"
  '((forbidden-statement 2 1 "PRAGMA"))
  (attempt
   (lambda ()
     (check-migrations (with-m1 (list 2 "t" (list (car (caddr m1)))))))))

;;; The shipped list

(define (read-datum path)
  (attempt (lambda () (call-with-input-file path read))))

(test-equal "shipped list: the list equals its recorded copy"
  (read-datum "tests/shipped-migrations.scm")
  migrations)
(test-equal "shipped list: the copy is one datum, a list of seven migrations, versions 1 to 7"
  '(1 2 3 4 5 6 7)
  (let ((r (read-datum "tests/shipped-migrations.scm")))
    (if (and (list? r) (= (length r) 7)) (map car r) r)))
(test-equal "shipped list: migration 1 is the one that sets the id"
  '(1 "techo's database" ("PRAGMA application_id = 1952801640"))
  (car migrations))
(test-equal "shipped list: migration 2 is three statements, creating accounts, api_keys and the index"
  '(#t #t #t)
  (let ((ss (caddr (cadr migrations))))
    (map (lambda (s prefix)
           (and (>= (string-length s) (string-length prefix))
                (string=? prefix (substring s 0 (string-length prefix)))))
         ss
         '("CREATE TABLE accounts" "CREATE TABLE api_keys" "CREATE INDEX api_keys_account"))))
(test-equal "shipped list: migration 3 is four statements, creating nodes, its index, revisions and changes"
  '(#t #t #t #t)
  (let ((ss (caddr (caddr migrations))))
    (map (lambda (s prefix)
           (and (>= (string-length s) (string-length prefix))
                (string=? prefix (substring s 0 (string-length prefix)))))
         ss
         '("CREATE TABLE nodes" "CREATE INDEX nodes_owner" "CREATE TABLE revisions" "CREATE TABLE changes"))))
(test-equal "shipped list: migration 4 is one statement, named for a node's state, adding the state column with its CHECK"
  (list "a node's state"
        (list "ALTER TABLE nodes ADD COLUMN state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','archived','trashed','purged'))"))
  (let ((m (list-ref migrations 3))) (list (cadr m) (caddr m))))
(test-equal "shipped list: migration 5 is two statements, named for a node's parent, adding the column and its index"
  (list "a node's parent"
        (list "ALTER TABLE nodes ADD COLUMN parent BLOB REFERENCES nodes(id) CHECK (parent IS NULL OR length(parent) = 16)"
              "CREATE INDEX nodes_parent ON nodes(owner, parent, id)"))
  (let ((m (list-ref migrations 4))) (list (cadr m) (caddr m))))
(test-equal "shipped list: migration 6 is two statements, named for links, creating the table and its target index"
  (list "links"
        (list "CREATE TABLE links (
  owner   BLOB    NOT NULL REFERENCES accounts(id),
  source  BLOB    NOT NULL REFERENCES nodes(id),
  target  BLOB    NOT NULL REFERENCES nodes(id),
  type    TEXT    NOT NULL,
  created INTEGER NOT NULL,
  PRIMARY KEY (owner, source, type, target)
) STRICT, WITHOUT ROWID"
              "CREATE INDEX links_target ON links(owner, target, type, source)"))
  (let ((m (list-ref migrations 5))) (list (cadr m) (caddr m))))
;; ADR-0012's rule, one statement an entry: the table, its index by node
;; (beginning with the owner), and the snapshot's column, behind the body,
;; whose CHECK holds a JSON array.
(test-equal "shipped list: migration 7 is three statements, named for tags, creating node_tags, its index by owner and node, and the snapshot's tags column"
  (list "tags"
        (list "CREATE TABLE node_tags (
  owner BLOB NOT NULL REFERENCES accounts(id),
  tag   TEXT NOT NULL CHECK (length(tag) BETWEEN 1 AND 64),
  node  BLOB NOT NULL REFERENCES nodes(id),
  PRIMARY KEY (owner, tag, node)
) STRICT, WITHOUT ROWID"
              "CREATE INDEX node_tags_node ON node_tags(owner, node)"
              "ALTER TABLE revisions ADD COLUMN tags TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags) AND json_type(tags) = 'array')"))
  (let ((m (if (> (length migrations) 6) (list-ref migrations 6) '(7 "none" ())))) (list (cadr m) (caddr m))))
(test-equal "shipped list: the id is `tech`"
  #x74656368
  techo-application-id)
(test-equal "shipped list: latest-version"
  (list (length migrations) 3 0)
  (attempt (lambda () (list (latest-version migrations) (latest-version tm)
                            (latest-version '())))))

;;; facts-sql

(test-assert "facts-sql: no semicolon, so it is one statement"
  (not (exists (lambda (ch) (char=? ch #\;)) (string->list facts-sql))))

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(test-assert "facts-sql: the four columns, in order"
  (let ((ixs (map (lambda (s) (string-index-of facts-sql s))
                  '("pragma_application_id" "pragma_user_version"
                    "sqlite_schema" "pragma_journal_mode"))))
    (and (for-all (lambda (x) x) ixs)
         (apply < ixs)
         (= 0 (string-index-of facts-sql "SELECT (SELECT")))))

;;; Results

(define commit-failed
  '(failed (1) #f (2 "disk full" #t)))

(define results-table
  ;; result, exit status, progress lines, ending lines
  (list
   (list '(applied (1 2) #t 2) 0
         '("converted the database to WAL" "applied migration 1"
           "applied migration 2")
         '("the database is at version 2"))
   (list '(applied (3) #f 3) 0
         '("applied migration 3")
         '("the database is at version 3"))
   (list '(nothing () #f 3) 0
         '()
         '("nothing to do: the database is at version 3"))
   (list '(nothing () #t 3) 0
         '("converted the database to WAL")
         '("nothing to do: the database is at version 3"))
   (list '(refused () #f (ahead 5)) 1
         '()
         '("refused: this binary is older than the database (version 5)"))
   (list '(refused () #f foreign) 1 '() '("refused: not Techo's database"))
   (list '(failed (1) #t (2 "constraint failed" #f)) 1
         '("converted the database to WAL" "applied migration 1")
         '("failed: migration 2: constraint failed"))
   (list '(failed () #f (#f "disk I/O error" #f)) 1
         '()
         '("failed: disk I/O error"))
   (list commit-failed 1
         '("applied migration 1")
         '("failed: migration 2: disk full"
           "the database's version is unknown: run `techo migrate` again"))
   (list '(busy () #f "database is locked") 1 '() '("busy: database is locked"))
   (list '(busy (1) #t "database is locked") 1
         '("converted the database to WAL" "applied migration 1")
         '("busy: database is locked"))
   (list '(cannot-open () #f "unable to open database file") 1
         '()
         '("cannot open the database: unable to open database file"))))

(for-each
 (lambda (row)
   (test-equal (string-append "result->exit-status: " (describe (car row)))
     (cadr row)
     (attempt (lambda () (result->exit-status (car row)))))
   (test-equal (string-append "result->progress-lines: " (describe (car row)))
     (caddr row)
     (attempt (lambda () (result->progress-lines (car row)))))
   (test-equal (string-append "result->ending-lines: " (describe (car row)))
     (cadddr row)
     (attempt (lambda () (result->ending-lines (car row)))))
   (test-equal (string-append "result->lines: " (describe (car row)))
     (append (caddr row) (cadddr row))
     (attempt (lambda () (result->lines (car row))))))
 results-table)

(test-equal "results: all six kinds are covered"
  '(applied busy cannot-open failed nothing refused)
  (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
             (let loop ((rs (map car results-table)) (seen '()))
               (cond ((null? rs) seen)
                     ((memq (car (car rs)) seen) (loop (cdr rs) seen))
                     (else (loop (cdr rs) (cons (car (car rs)) seen)))))))

(test-equal "results: not a Result is refused"
  '(result->exit-status result->lines result->progress-lines result->ending-lines)
  (list (raised-who (lambda () (result->exit-status '(weird () #f 0))))
        (raised-who (lambda () (result->lines '(weird () #f 0))))
        (raised-who (lambda () (result->progress-lines '(weird () #f 0))))
        (raised-who (lambda () (result->ending-lines '(weird () #f 0))))))

;;; Layer 6: the diagrams

(define (read-file path)
  (attempt (lambda () (call-with-input-file path get-string-all))))

(test-equal ".plans/machines/migrate.md is what the tables render"
  (attempt (lambda () (machines-document)))
  (read-file ".plans/machines/migrate.md"))

(test-assert "the document has one block for each machine, and names both"
  (let ((doc (attempt (lambda () (machines-document)))))
    (and (string? doc)
         (string-index-of doc "stateDiagram-v2")
         (string-index-of doc "peek-opening --> peeking: opened")
         (string-index-of doc "committing --> locking: below")
         (string-index-of doc "closing --> ended: done, failed"))))

(test-end "migrations")

(exit (suite-exit-status runner))
