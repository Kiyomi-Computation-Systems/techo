#!r6rs
;;; The transaction suite: layers 1, 2 and 6 of the slice 2b plan.
;;;   1  static checks on the three tables
;;;   2  every row driven by name; every can't-happen pair seen to raise;
;;;      job-event-kind and serve-event-kind over every raw outcome shape;
;;;      job-carry; set-up-verdict; forbidden-statement?; whole runs
;;;   6  the diagram, held to its file
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo machine)
        (techo migrations)
        (techo transaction))

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

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(define T techo-application-id)
(define tm
  (list (list 1 "one" '("S1a" "S1b"))
        (list 2 "two" '("S2"))
        (list 3 "three" '("S3a" "S3b" "S3c"))))
(define (facts id ver objs mode) (list id ver objs mode))

(define L 3)                            ; this binary's latest version
(define boom (list 'a-raised-object))   ; an object a job raised
(define (st kind data) (cons kind data))
(define (jd pending) (list L pending))  ; a job state's data
(define P-RAISE '(raise-carried))
(define P-MOVED '(refuse . moved))

(define (row-pairs rows) (map (lambda (r) (cons (car r) (cadr r))) rows))
(define (pairs-diff xs ys) (filter (lambda (p) (not (member p ys))) xs))
(define (sorted syms)
  (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
             syms))
(define (uniq xs)
  (fold-left (lambda (acc x) (if (memq x acc) acc (append acc (list x)))) '() xs))

(test-begin "transaction")

;;; Layer 1: static checks

(test-equal "layer 1: the write table has no problems"
  '()
  (attempt (lambda ()
             (machine-problems (make-machine write-rows) '(start) '(ended)
                               write-cant-happen))))
(test-equal "layer 1: the read table has no problems"
  '()
  (attempt (lambda ()
             (machine-problems (make-machine read-rows) '(start) '(ended)
                               read-cant-happen))))
(test-equal "layer 1: the serve table has no problems"
  '()
  (attempt (lambda ()
             (machine-problems (make-machine serve-rows) '(checking) '(ended)
                               serve-cant-happen))))

;; W1 to W20 are 20 rows; W9, W16, W18, W19, W20 each take a second row (+5).
(test-equal "layer 1: the write table has the plan's rows" 25 (length write-rows))
;; R1 to R16 are 16; R4, R8, R14, R15, R16 each take a second (+5).
(test-equal "layer 1: the read table has the plan's rows" 21 (length read-rows))
;; S2 to S18: slice 2b's S2 to S14, and slice 3b's hasher rows S15 to S18.
(test-equal "layer 1: the serve table has the plan's rows" 17 (length serve-rows))

;; The names, written out: a row dropped from the table and its name with it
;; is seen here.
(define (names-once names)
  (let loop ((l names) (acc '()))
    (cond ((null? l) (reverse acc))
          ((memq (car l) acc) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))
(test-equal "layer 1: the rows' names are the plan's, in order"
  '((W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12 W13 W14 W15 W16 W17 W18 W19 W20)
    (R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 R14 R15 R16)
    (S2 S3 S4 S5 S15 S16 S6 S7 S8 S9 S10 S11 S12 S17 S18 S13 S14))
  (list (names-once (map car write-row-names))
        (names-once (map car read-row-names))
        (names-once (map car serve-row-names))))
(test-equal "layer 1: each name sits beside its row's state and event"
  (list (map (lambda (r) (cons (car r) (cadr r))) write-rows)
        (map (lambda (r) (cons (car r) (cadr r))) read-rows)
        (map (lambda (r) (cons (car r) (cadr r))) serve-rows))
  (list (map (lambda (n) (cons (cadr n) (caddr n))) write-row-names)
        (map (lambda (n) (cons (cadr n) (caddr n))) read-row-names)
        (map (lambda (n) (cons (cadr n) (caddr n))) serve-row-names)))

(test-equal "layer 1: every can't-happen pair carries a reason"
  '()
  (filter (lambda (c) (not (and (= (length c) 3) (string? (caddr c))
                                (> (string-length (caddr c)) 0))))
          (append write-cant-happen read-cant-happen serve-cant-happen)))

(define (problems rows starts cants)
  (attempt (lambda ()
             (machine-problems (make-machine rows) starts '(ended) cants))))

(test-equal "layer 1: dropping a row is found"
  '((unlisted-gap committing ok))
  (let ((ps (problems (filter (lambda (r) (not (and (eq? (car r) 'committing)
                                                    (eq? (cadr r) 'ok))))
                              write-rows)
                      '(start) write-cant-happen)))
    (filter (lambda (p) (eq? (car p) 'unlisted-gap)) ps)))

(test-equal "layer 1: doubling a row is found"
  '((double-row beginning ok))
  (let ((ps (problems (append write-rows
                              (list (list 'beginning 'ok 'ended 'end
                                          (lambda (d e) '(answer)))))
                      '(start) write-cant-happen)))
    (filter (lambda (p) (eq? (car p) 'double-row)) ps)))

(test-equal "layer 1: giving a can't-happen pair a row is found"
  '((listed-but-has-row running ok))
  (let ((ps (problems (append read-rows
                              (list (list 'running 'ok 'ended 'end
                                          (lambda (d e) '(answer)))))
                      '(start) read-cant-happen)))
    (filter (lambda (p) (eq? (car p) 'listed-but-has-row)) ps)))

;;; Layer 2: every row driven

;; A case: row name, variant, state, command, raw outcome, expected event
;; kind, expected next state, expected next command.
(define (c name variant state cmd raw kind next newcmd)
  (list name variant state cmd raw kind next newcmd))
(define (case-name x) (list-ref x 0))
(define (case-variant x) (list-ref x 1))
(define (case-state x) (list-ref x 2))
(define (case-cmd x) (list-ref x 3))
(define (case-raw x) (list-ref x 4))
(define (case-kind x) (list-ref x 5))
(define (case-next x) (list-ref x 6))
(define (case-newcmd x) (list-ref x 7))
(define (case-label x)
  (string-append (symbol->string (case-name x)) " " (case-variant x)))

(define write-cases
  (list
   (c 'W1 "present" (st 'start (jd #f)) '(look) '(present #f #f) 'present
      (st 'beginning (jd #f)) '(begin-immediate))
   (c 'W2 "absent" (st 'start (jd #f)) '(look) '(absent #f #f) 'absent
      '(ended refuse . unavailable) '(end refuse . unavailable))
   (c 'W3 "ok" (st 'beginning (jd #f)) '(begin-immediate) '(ok #t #t) 'ok
      (st 'versioning (jd #f)) '(read-version . 3))
   (c 'W4 "busy" (st 'beginning (jd #f)) '(begin-immediate) (list 'busy boom #f)
      'busy '(ended refuse . busy) '(end refuse . busy))
   (c 'W5 "failed-closed" (st 'beginning (jd #f)) '(begin-immediate)
      (list 'failed boom #f) 'failed-closed
      '(ended raise-carried) '(end raise-carried))
   (c 'W6 "failed-open" (st 'beginning (jd #f)) '(begin-immediate)
      (list 'failed boom #t) 'failed-open
      (st 'rolling-back (jd P-RAISE)) '(rollback))
   (c 'W7 "same" (st 'versioning (jd #f)) '(read-version . 3) '(ok 3 #t) 'same
      (st 'running (jd #f)) '(run-job))
   (c 'W8 "moved" (st 'versioning (jd #f)) '(read-version . 3) '(ok 4 #t) 'moved
      (st 'rolling-back (jd P-MOVED)) '(rollback))
   (c 'W9 "busy" (st 'versioning (jd #f)) '(read-version . 3)
      (list 'busy boom #t) 'busy (st 'rolling-back (jd P-RAISE)) '(rollback))
   (c 'W9 "failed-open" (st 'versioning (jd #f)) '(read-version . 3)
      (list 'failed boom #t) 'failed-open
      (st 'rolling-back (jd P-RAISE)) '(rollback))
   (c 'W10 "failed-closed" (st 'versioning (jd #f)) '(read-version . 3)
      (list 'failed boom #f) 'failed-closed
      '(ended raise-carried) '(end raise-carried))
   (c 'W10 "ok with no transaction" (st 'versioning (jd #f)) '(read-version . 3)
      '(ok 3 #f) 'failed-closed '(ended raise-carried) '(end raise-carried))
   (c 'W11 "returned-open" (st 'running (jd #f)) '(run-job) '(returned (1) #t)
      'returned-open (st 'committing (jd #f)) '(commit))
   (c 'W12 "returned-closed" (st 'running (jd #f)) '(run-job) '(returned (1) #f)
      'returned-closed '(ended raise-ended) '(end raise-ended))
   (c 'W13 "raised-open" (st 'running (jd #f)) '(run-job) (list 'raised boom #t)
      'raised-open (st 'rolling-back (jd P-RAISE)) '(rollback))
   (c 'W14 "raised-closed" (st 'running (jd #f)) '(run-job) (list 'raised boom #f)
      'raised-closed '(ended raise-carried) '(end raise-carried))
   (c 'W15 "ok" (st 'committing (jd #f)) '(commit) '(ok #t #f) 'ok
      '(ended answer) '(end answer))
   (c 'W16 "busy" (st 'committing (jd #f)) '(commit) (list 'busy boom #t) 'busy
      (st 'rolling-back (jd P-RAISE)) '(rollback))
   (c 'W16 "failed-open" (st 'committing (jd #f)) '(commit)
      (list 'failed boom #t) 'failed-open
      (st 'rolling-back (jd P-RAISE)) '(rollback))
   (c 'W16 "ok with the transaction open" (st 'committing (jd #f)) '(commit)
      '(ok #t #t) 'failed-open (st 'rolling-back (jd P-RAISE)) '(rollback))
   (c 'W17 "failed-closed" (st 'committing (jd #f)) '(commit)
      (list 'failed boom #f) 'failed-closed
      '(ended raise-carried) '(end raise-carried))
   (c 'W18 "ok" (st 'rolling-back (jd P-MOVED)) '(rollback) '(ok #t #f) 'ok
      '(ended refuse . moved) '(end refuse . moved))
   (c 'W18 "failed-closed" (st 'rolling-back (jd P-RAISE)) '(rollback)
      (list 'failed boom #f) 'failed-closed
      '(ended raise-carried) '(end raise-carried))
   (c 'W19 "busy" (st 'rolling-back (jd P-MOVED)) '(rollback)
      (list 'busy boom #t) 'busy (st 'closing (jd P-MOVED)) '(close))
   (c 'W19 "failed-open" (st 'rolling-back (jd P-RAISE)) '(rollback)
      (list 'failed boom #t) 'failed-open (st 'closing (jd P-RAISE)) '(close))
   (c 'W19 "ok with the transaction open" (st 'rolling-back (jd P-RAISE))
      '(rollback) '(ok #t #t) 'failed-open (st 'closing (jd P-RAISE)) '(close))
   (c 'W20 "ok" (st 'closing (jd P-MOVED)) '(close) '(ok #t #f) 'ok
      '(ended refuse . moved) '(end refuse . moved))
   (c 'W20 "failed" (st 'closing (jd P-RAISE)) '(close) (list 'failed boom #f)
      'failed '(ended raise-carried) '(end raise-carried))))

(define read-cases
  (list
   (c 'R1 "present" (st 'start (jd #f)) '(look) '(present #f #f) 'present
      (st 'beginning (jd #f)) '(begin))
   (c 'R2 "absent" (st 'start (jd #f)) '(look) '(absent #f #f) 'absent
      '(ended refuse . unavailable) '(end refuse . unavailable))
   (c 'R3 "ok" (st 'beginning (jd #f)) '(begin) '(ok #t #t) 'ok
      (st 'versioning (jd #f)) '(read-version . 3))
   (c 'R4 "busy" (st 'beginning (jd #f)) '(begin) (list 'busy boom #f) 'busy
      '(ended raise-carried) '(end raise-carried))
   (c 'R4 "failed-closed" (st 'beginning (jd #f)) '(begin) (list 'failed boom #f)
      'failed-closed '(ended raise-carried) '(end raise-carried))
   (c 'R5 "failed-open" (st 'beginning (jd #f)) '(begin) (list 'failed boom #t)
      'failed-open (st 'ending (jd P-RAISE)) '(rollback))
   (c 'R6 "same" (st 'versioning (jd #f)) '(read-version . 3) '(ok 3 #t) 'same
      (st 'running (jd #f)) '(run-job))
   (c 'R7 "moved" (st 'versioning (jd #f)) '(read-version . 3) '(ok 2 #t) 'moved
      (st 'ending (jd P-MOVED)) '(rollback))
   (c 'R8 "busy" (st 'versioning (jd #f)) '(read-version . 3)
      (list 'busy boom #t) 'busy (st 'ending (jd P-RAISE)) '(rollback))
   (c 'R8 "failed-open" (st 'versioning (jd #f)) '(read-version . 3)
      (list 'failed boom #t) 'failed-open (st 'ending (jd P-RAISE)) '(rollback))
   (c 'R9 "failed-closed" (st 'versioning (jd #f)) '(read-version . 3)
      (list 'failed boom #f) 'failed-closed
      '(ended raise-carried) '(end raise-carried))
   (c 'R10 "returned-open" (st 'running (jd #f)) '(run-job) '(returned (1 2) #t)
      'returned-open (st 'ending (jd '(answer))) '(rollback))
   (c 'R11 "returned-closed" (st 'running (jd #f)) '(run-job) '(returned () #f)
      'returned-closed '(ended raise-ended) '(end raise-ended))
   (c 'R12 "raised-open" (st 'running (jd #f)) '(run-job) (list 'raised boom #t)
      'raised-open (st 'ending (jd P-RAISE)) '(rollback))
   (c 'R13 "raised-closed" (st 'running (jd #f)) '(run-job) (list 'raised boom #f)
      'raised-closed '(ended raise-carried) '(end raise-carried))
   (c 'R14 "ok" (st 'ending (jd '(answer))) '(rollback) '(ok #t #f) 'ok
      '(ended answer) '(end answer))
   (c 'R14 "failed-closed" (st 'ending (jd P-RAISE)) '(rollback)
      (list 'failed boom #f) 'failed-closed
      '(ended raise-carried) '(end raise-carried))
   (c 'R15 "busy" (st 'ending (jd '(answer))) '(rollback) (list 'busy boom #t)
      'busy (st 'closing (jd '(answer))) '(close))
   (c 'R15 "failed-open" (st 'ending (jd P-MOVED)) '(rollback)
      (list 'failed boom #t) 'failed-open (st 'closing (jd P-MOVED)) '(close))
   (c 'R16 "ok" (st 'closing (jd '(answer))) '(close) '(ok #t #f) 'ok
      '(ended answer) '(end answer))
   (c 'R16 "failed" (st 'closing (jd P-RAISE)) '(close) (list 'failed boom #f)
      'failed '(ended raise-carried) '(end raise-carried))))

(define (sd carried prints) (list carried prints))
(define S0 (sd #f '()))
(define verdict-refused (list 'refuse 'missing "the database file is missing"))

(define serve-cases
  (list
   (c 'S2 "serve" (st 'checking S0) '(check) '(ok serve #f) 'serve
      (st 'opening-writer S0) '(open-writer))
   (c 'S3 "refused" (st 'checking S0) '(check) (list 'ok verdict-refused #f)
      'refused '(ended 1 ((line . "the database file is missing"))) '(end . 1))
   (c 'S4 "ok" (st 'opening-writer S0) '(open-writer) '(ok #t #f) 'ok
      (st 'opening-hasher S0) '(open-hasher))
   (c 'S5 "raised" (st 'opening-writer S0) '(open-writer) (list 'raised boom #f)
      'raised (list 'ended 1 (list (cons 'raised boom))) '(end . 1))
   (c 'S15 "ok" (st 'opening-hasher S0) '(open-hasher) '(ok #t #f) 'ok
      (st 'opening-readers S0) '(open-readers))
   (c 'S16 "raised" (st 'opening-hasher S0) '(open-hasher) (list 'raised boom #f)
      'raised (st 'stopping-writer (sd 1 (list (cons 'raised boom))))
      '(stop-writer))
   (c 'S6 "ok" (st 'opening-readers S0) '(open-readers) '(ok #t #f) 'ok
      (st 'serving S0) '(serve))
   (c 'S7 "raised" (st 'opening-readers S0) '(open-readers) (list 'raised boom #f)
      'raised (st 'stopping-hasher (sd 1 (list (cons 'raised boom))))
      '(stop-hasher))
   (c 'S8 "returned" (st 'serving S0) '(serve) '(returned #t #f) 'returned
      (st 'stopping-readers S0) '(stop-readers))
   (c 'S9 "refused-settings" (st 'serving S0) '(serve) (list 'refused boom #f)
      'refused-settings
      (st 'stopping-readers (sd 2 (list (cons 'refused boom)))) '(stop-readers))
   (c 'S10 "raised" (st 'serving S0) '(serve) (list 'raised boom #f) 'raised
      (st 'stopping-readers (sd 1 (list (cons 'raised boom)))) '(stop-readers))
   (c 'S11 "ok" (st 'stopping-readers S0) '(stop-readers) '(ok #t #f) 'ok
      (st 'stopping-hasher S0) '(stop-hasher))
   (c 'S12 "raised" (st 'stopping-readers S0) '(stop-readers)
      (list 'raised boom #f) 'raised
      (st 'stopping-hasher (sd 1 (list (cons 'raised boom)))) '(stop-hasher))
   (c 'S12 "raised, 2 carried" (st 'stopping-readers (sd 2 '((refused . x))))
      '(stop-readers) (list 'raised boom #f) 'raised
      (st 'stopping-hasher (sd 2 (list '(refused . x) (cons 'raised boom))))
      '(stop-hasher))
   (c 'S17 "ok, nothing carried" (st 'stopping-hasher S0) '(stop-hasher)
      '(ok #t #f) 'ok (st 'stopping-writer S0) '(stop-writer))
   (c 'S17 "ok, 2 carried" (st 'stopping-hasher (sd 2 '((refused . x))))
      '(stop-hasher) '(ok #t #f) 'ok
      (st 'stopping-writer (sd 2 '((refused . x)))) '(stop-writer))
   (c 'S18 "raised, nothing carried" (st 'stopping-hasher S0) '(stop-hasher)
      (list 'raised boom #f) 'raised
      (st 'stopping-writer (sd 1 (list (cons 'raised boom)))) '(stop-writer))
   (c 'S18 "raised, 2 carried" (st 'stopping-hasher (sd 2 '((refused . x))))
      '(stop-hasher) (list 'raised boom #f) 'raised
      (st 'stopping-writer (sd 2 (list '(refused . x) (cons 'raised boom))))
      '(stop-writer))
   (c 'S13 "ok, nothing carried" (st 'stopping-writer S0) '(stop-writer)
      '(ok #t #f) 'ok '(ended 0 ()) '(end . 0))
   (c 'S13 "ok, 2 carried" (st 'stopping-writer (sd 2 '((refused . x))))
      '(stop-writer) '(ok #t #f) 'ok '(ended 2 ((refused . x))) '(end . 2))
   (c 'S14 "raised, nothing carried" (st 'stopping-writer S0) '(stop-writer)
      (list 'raised boom #f) 'raised
      (list 'ended 1 (list (cons 'raised boom))) '(end . 1))
   (c 'S14 "raised, 2 carried" (st 'stopping-writer (sd 2 '((refused . x))))
      '(stop-writer) (list 'raised boom #f) 'raised
      (list 'ended 2 (list '(refused . x) (cons 'raised boom))) '(end . 2))))

;; drive : (State Event -> (values State Command)) (Command RawOutcome -> EventKind)
;;         Case -> (U (List EventKind State Command) (List 'raised String))
(define (drive step kind-of x)
  (attempt
   (lambda ()
     (let ((kind (kind-of (case-cmd x) (case-raw x))))
       (let-values (((next cmd) (step (case-state x) (cons kind (case-raw x)))))
         (list kind next cmd))))))

(define (test-cases table step kind-of cases)
  (for-each
   (lambda (x)
     (test-equal (string-append "layer 2 " table " row " (case-label x))
       (list (case-kind x) (case-next x) (case-newcmd x))
       (drive step kind-of x)))
   cases))
(test-cases "write" write-step job-event-kind write-cases)
(test-cases "read" read-step job-event-kind read-cases)
(test-cases "serve" serve-step serve-event-kind serve-cases)

;; Every row is driven by name: its name, state and event kind are a case's.
(define (case-triples cases)
  (map (lambda (x) (list (case-name x) (car (case-state x)) (case-kind x)))
       cases))
(define (triples-diff xs ys) (filter (lambda (p) (not (member p ys))) xs))
(define (distinct xs)
  (fold-left (lambda (acc x) (if (member x acc) acc (append acc (list x)))) '() xs))

(test-equal "layer 2: a write row no case drives"
  '()
  (triples-diff write-row-names (case-triples write-cases)))
(test-equal "layer 2: a write case that drives no row"
  '()
  (triples-diff (distinct (case-triples write-cases)) write-row-names))
(test-equal "layer 2: a read row no case drives"
  '()
  (triples-diff read-row-names (case-triples read-cases)))
(test-equal "layer 2: a read case that drives no row"
  '()
  (triples-diff (distinct (case-triples read-cases)) read-row-names))
(test-equal "layer 2: a serve row no case drives"
  '()
  (triples-diff serve-row-names (case-triples serve-cases)))
(test-equal "layer 2: a serve case that drives no row"
  '()
  (triples-diff (distinct (case-triples serve-cases)) serve-row-names))

(define (names-of-rows names) (uniq (map car names)))
(test-equal "layer 2: the plan's row names, in order"
  (list '(W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12 W13 W14 W15 W16 W17 W18 W19 W20)
        '(R1 R2 R3 R4 R5 R6 R7 R8 R9 R10 R11 R12 R13 R14 R15 R16)
        '(S2 S3 S4 S5 S15 S16 S6 S7 S8 S9 S10 S11 S12 S17 S18 S13 S14))
  (list (names-of-rows write-row-names) (names-of-rows read-row-names)
        (names-of-rows serve-row-names)))

;; Every can't-happen pair raises, naming the pair.
(define (cant-mismatches step data cants)
  (filter
   (lambda (c)
     (not (equal? (raised-info
                   (lambda () (step (cons (car c) data) (cons (cadr c) '(ok #t #f)))))
                  (list 'machine-step (list (car c) (cadr c))))))
   cants))
(test-equal "layer 2: every write can't-happen pair raises, naming it"
  '() (cant-mismatches write-step (jd #f) write-cant-happen))
(test-equal "layer 2: every read can't-happen pair raises, naming it"
  '() (cant-mismatches read-step (jd #f) read-cant-happen))
(test-equal "layer 2: every serve can't-happen pair raises, naming it"
  '() (cant-mismatches serve-step S0 serve-cant-happen))
(test-assert "layer 2: the can't-happen lists are not empty"
  (and (> (length write-cant-happen) 50) (> (length read-cant-happen) 40)
       (> (length serve-cant-happen) 15)))
;; Eight states that are not ended, six event kinds, 17 rows.
(test-equal "layer 2: the serve can't-happen list is every pair with no row"
  (- (* 8 6) 17) (length serve-cant-happen))

;; ended takes no event.
(test-equal "layer 2: ended takes no event"
  '(machine-step machine-step machine-step)
  (list (raised-who (lambda () (write-step '(ended answer) '(ok #t #f))))
        (raised-who (lambda () (read-step '(ended answer) '(ok #t #f))))
        (raised-who (lambda () (serve-step '(ended 0 ()) '(ok #t #f))))))

;;; The starts

(test-equal "write-start answers the first state and (look)"
  (list (st 'start (list 7 #f)) '(look))
  (attempt (lambda () (let-values (((s c) (write-start 7))) (list s c)))))
(test-equal "read-start answers the first state and (look)"
  (list (st 'start (list 7 #f)) '(look))
  (attempt (lambda () (let-values (((s c) (read-start 7))) (list s c)))))
(test-equal "serve-start answers checking and (check)"
  (list (st 'checking '(#f ())) '(check))
  (attempt (lambda () (let-values (((s c) (serve-start))) (list s c)))))
(test-equal "a start that is not a Natural is refused"
  '(write-start read-start)
  (list (raised-who (lambda () (write-start 'x)))
        (raised-who (lambda () (read-start -1)))))
(test-equal "the state accessors"
  (list 3 '(answer) #f '())
  (attempt (lambda ()
             (list (job-state-latest (st 'closing (jd '(answer))))
                   (job-state-pending (st 'closing (jd '(answer))))
                   (serve-carried (st 'serving S0))
                   (serve-prints (st 'serving S0))))))

;;; job-event-kind over every raw outcome shape

(define (kinds-of cmd raws)
  (map (lambda (raw) (attempt (lambda () (job-event-kind cmd raw)))) raws))

(define begin-raws
  (list '(ok #t #f) '(ok #t #t) (list 'busy boom #f) (list 'busy boom #t)
        (list 'failed boom #t) (list 'failed boom #f)))
(define begin-kinds '(ok ok busy busy failed-open failed-closed))
(define end-raws begin-raws)
(define end-kinds '(ok failed-open busy busy failed-open failed-closed))
(define version-raws
  (list '(ok 3 #t) '(ok 4 #t) '(ok 0 #t) '(ok 3 #f) '(ok 4 #f)
        (list 'busy boom #f) (list 'busy boom #t)
        (list 'failed boom #t) (list 'failed boom #f)))
(define version-kinds
  '(same moved moved failed-closed failed-closed busy busy failed-open
    failed-closed))
(define job-raws
  (list '(returned (1) #t) '(returned () #f) '(returned (1 2 3) #f)
        (list 'raised boom #t) (list 'raised boom #f)))
(define job-kinds
  '(returned-open returned-closed returned-closed raised-open raised-closed))

(test-equal "job-event-kind (look)"
  '(present absent)
  (kinds-of '(look) '((present #f #f) (absent #f #f))))
(test-equal "job-event-kind (begin-immediate)" begin-kinds
  (kinds-of '(begin-immediate) begin-raws))
(test-equal "job-event-kind (begin)" begin-kinds (kinds-of '(begin) begin-raws))
(test-equal "job-event-kind (read-version . 3)" version-kinds
  (kinds-of '(read-version . 3) version-raws))
(test-equal "job-event-kind (run-job)" job-kinds (kinds-of '(run-job) job-raws))
(test-equal "job-event-kind (commit): ok but still open is failed-open"
  end-kinds (kinds-of '(commit) end-raws))
(test-equal "job-event-kind (rollback): ok but still open is failed-open"
  end-kinds (kinds-of '(rollback) end-raws))
(test-equal "job-event-kind (close)"
  '(ok failed)
  (kinds-of '(close) (list '(ok #t #f) (list 'failed boom #f))))

(define (assert-violation? thunk) (eq? 'assertion (guard (e ((assertion-violation? e) 'assertion)
                                                      (#t 'other))
                                            (thunk) 'no-raise)))
(define (job-violations)
  (map (lambda (cmd+raw) (assert-violation? (lambda () (job-event-kind (car cmd+raw)
                                                                (cadr cmd+raw)))))
       (list (list '(read-version . 3) '(ok "3" #t))
             (list '(read-version . 3) '(ok 3.0 #t))
             (list '(read-version . 3) '(ok 7/2 #t))
             (list '(read-version . 3) '(ok #f #f))
             (list '(read-version . 3) '(present #f #f))
             (list '(look) '(ok #t #f))
             (list '(begin) '(returned (1) #f))
             (list '(run-job) '(ok #t #f))
             (list '(close) '(busy x #f))
             (list '(end answer) '(ok #t #f))
             (list '(frobnicate) '(ok #t #f))
             (list '(begin) '(ok #t))
             (list '(begin) '(ok #t 1)))))
(test-equal "job-event-kind: what it cannot sort is an assertion violation"
  (map (lambda (x) #t) (job-violations))
  (job-violations))

;; The states of the serve table, which has its own kind function.
(define serve-states
  '(checking opening-writer opening-hasher opening-readers serving
    stopping-readers stopping-hasher stopping-writer))
(define (serve-kinds cmd raws)
  (map (lambda (raw) (attempt (lambda () (serve-event-kind cmd raw)))) raws))

;; The kinds a state's command gives are exactly the kinds the state's rows
;; and can't-happen list leave possible.
(define (possible-of rows cants state)
  (let ((universe (uniq (append (map cadr rows) (map cadr cants)))))
    (sorted (filter (lambda (e) (not (exists (lambda (c) (and (eq? (car c) state)
                                                            (eq? (cadr c) e)))
                                            cants)))
                    universe))))
(define (possible-matches rows cants state cmd raws)
  (equal? (possible-of rows cants state)
          (sorted (uniq ((if (memq state serve-states) serve-kinds kinds-of)
                         cmd raws)))))

(test-equal "the write can't-happen list is what job-event-kind leaves out"
  '(#t #t #t #t #t #t #t)
  (list (possible-matches write-rows write-cant-happen 'start '(look)
                          '((present #f #f) (absent #f #f)))
        (possible-matches write-rows write-cant-happen 'beginning
                          '(begin-immediate) begin-raws)
        (possible-matches write-rows write-cant-happen 'versioning
                          '(read-version . 3) version-raws)
        (possible-matches write-rows write-cant-happen 'running '(run-job) job-raws)
        (possible-matches write-rows write-cant-happen 'committing '(commit)
                          end-raws)
        (possible-matches write-rows write-cant-happen 'rolling-back '(rollback)
                          end-raws)
        (possible-matches write-rows write-cant-happen 'closing '(close)
                          (list '(ok #t #f) (list 'failed boom #f)))))
(test-equal "the read can't-happen list is what job-event-kind leaves out"
  '(#t #t #t #t #t #t)
  (list (possible-matches read-rows read-cant-happen 'start '(look)
                          '((present #f #f) (absent #f #f)))
        (possible-matches read-rows read-cant-happen 'beginning '(begin)
                          begin-raws)
        (possible-matches read-rows read-cant-happen 'versioning
                          '(read-version . 3) version-raws)
        (possible-matches read-rows read-cant-happen 'running '(run-job) job-raws)
        (possible-matches read-rows read-cant-happen 'ending '(rollback) end-raws)
        (possible-matches read-rows read-cant-happen 'closing '(close)
                          (list '(ok #t #f) (list 'failed boom #f)))))

;;; serve-event-kind

(test-equal "serve-event-kind (check)"
  '(serve refused)
  (serve-kinds '(check) (list '(ok serve #f) (list 'ok verdict-refused #f))))
(for-each
 (lambda (cmd)
   (test-equal (string-append "serve-event-kind " (symbol->string cmd))
     '(ok raised)
     (serve-kinds (list cmd) (list '(ok #t #f) (list 'raised boom #f)))))
 '(open-writer open-hasher open-readers stop-readers stop-hasher stop-writer))
(test-equal "serve-event-kind (serve)"
  '(returned refused-settings raised)
  (serve-kinds '(serve) (list '(returned #t #f) (list 'refused boom #f)
                              (list 'raised boom #f))))
(define (serve-violations)
  (map (lambda (cmd+raw) (assert-violation? (lambda () (serve-event-kind (car cmd+raw)
                                                                  (cadr cmd+raw)))))
       (list (list '(check) (list 'raised boom #f))
             (list '(check) '(ok bogus #f))
             (list '(check) '(ok (refuse x) #f))
             (list '(open-writer) '(returned #t #f))
             (list '(open-readers) (list 'refused boom #f))
             (list '(open-hasher) '(returned #t #f))
             (list '(stop-hasher) (list 'refused boom #f))
             (list '(stop-hasher) '(returned #t #f))
             (list '(serve) '(ok #t #f))
             (list '(end . 0) '(ok #t #f))
             (list '(look) '(ok #t #f))
             (list '(serve) '(ok #t)))))
(test-equal "serve-event-kind: what it cannot sort is an assertion violation"
  (map (lambda (x) #t) (serve-violations))
  (serve-violations))

(test-equal "the serve can't-happen list is what serve-event-kind leaves out"
  '(#t #t #t #t #t #t #t #t)
  (let ((ok-raised (list '(ok #t #f) (list 'raised boom #f))))
    (list (possible-matches serve-rows serve-cant-happen 'checking '(check)
                            (list '(ok serve #f) (list 'ok verdict-refused #f)))
          (possible-matches serve-rows serve-cant-happen 'opening-writer
                            '(open-writer) ok-raised)
          (possible-matches serve-rows serve-cant-happen 'opening-hasher
                            '(open-hasher) ok-raised)
          (possible-matches serve-rows serve-cant-happen 'opening-readers
                            '(open-readers) ok-raised)
          (possible-matches serve-rows serve-cant-happen 'serving '(serve)
                            (list '(returned #t #f) (list 'refused boom #f)
                                  (list 'raised boom #f)))
          (possible-matches serve-rows serve-cant-happen 'stopping-readers
                            '(stop-readers) ok-raised)
          (possible-matches serve-rows serve-cant-happen 'stopping-hasher
                            '(stop-hasher) ok-raised)
          (possible-matches serve-rows serve-cant-happen 'stopping-writer
                            '(stop-writer) ok-raised))))

;;; Whole runs: the commands the stepper gives are the ones that make the
;;; next raw outcome, until (end . _).

;; run : Step (Command RawOutcome -> EventKind) State Command (Listof RawOutcome)
;;       -> (List (Listof Command) State)
;; The commands asked, ending with the last, and the final state.
(define (run step kind-of state cmd raws)
  (let loop ((state state) (cmd cmd) (raws raws) (asked (list cmd)))
    (if (or (null? raws) (eq? (car cmd) 'end))
        (list (reverse asked) state raws)
        (let-values (((next ncmd) (step state (cons (kind-of cmd (car raws))
                                                    (car raws)))))
          (loop next ncmd (cdr raws) (cons ncmd asked))))))

(define (run-job step start kind-of raws)
  (attempt (lambda ()
             (let-values (((s c) (start L)))
               (let ((r (run step kind-of s c raws)))
                 (list (car r) (null? (caddr r))))))))

(define happy-write
  (list '(present #f #f) '(ok #t #t) '(ok 3 #t) '(returned (1) #t) '(ok #t #f)))
(test-equal "a write job that commits: only W15 answers"
  '(((look) (begin-immediate) (read-version . 3) (run-job) (commit)
     (end answer))
    #t)
  (run-job write-step write-start job-event-kind happy-write))
(test-equal "a write job on a file that moved: rolls back, refuses moved"
  '(((look) (begin-immediate) (read-version . 3) (rollback) (end refuse . moved))
    #t)
  (run-job write-step write-start job-event-kind
           (list '(present #f #f) '(ok #t #t) '(ok 4 #t) '(ok #t #f))))
(test-equal "a write job that raises with its transaction open: rolls back first"
  '(((look) (begin-immediate) (read-version . 3) (run-job) (rollback)
     (end raise-carried))
    #t)
  (run-job write-step write-start job-event-kind
           (list '(present #f #f) '(ok #t #t) '(ok 3 #t) (list 'raised boom #t)
                 '(ok #t #f))))
(test-equal "a write job whose rollback fails: closes, and raises what it carried"
  '(((look) (begin-immediate) (read-version . 3) (run-job) (rollback) (close)
     (end raise-carried))
    #t)
  (run-job write-step write-start job-event-kind
           (list '(present #f #f) '(ok #t #t) '(ok 3 #t) (list 'raised boom #t)
                 (list 'failed boom #t) (list 'failed boom #f))))
(test-equal "a write job refused busy at BEGIN IMMEDIATE"
  '(((look) (begin-immediate) (end refuse . busy)) #t)
  (run-job write-step write-start job-event-kind
           (list '(present #f #f) (list 'busy boom #f))))
(test-equal "a read job that answers: always rolls back"
  '(((look) (begin) (read-version . 3) (run-job) (rollback) (end answer)) #t)
  (run-job read-step read-start job-event-kind
           (list '(present #f #f) '(ok #t #t) '(ok 3 #t) '(returned (1) #t)
                 '(ok #t #f))))
(test-equal "a write job on an empty box is refused unavailable"
  '(((look) (end refuse . unavailable)) #t)
  (run-job write-step write-start job-event-kind (list '(absent #f #f))))

(define (run-serve raws)
  (attempt (lambda ()
             (let-values (((s c) (serve-start)))
               (let* ((r (run serve-step serve-event-kind s c raws))
                      (final (cadr r)))
                 (list (car r) (serve-carried final) (serve-prints final)))))))
(define (ok) '(ok #t #f))
(define (raised o) (list 'raised o #f))
(define o1 (list 'first))
(define o2 (list 'second))

(define o3 (list 'third))

(test-equal "serve: a clean run exits 0, stopping readers, then the hasher, then the writer"
  '(((check) (open-writer) (open-hasher) (open-readers) (serve) (stop-readers)
     (stop-hasher) (stop-writer) (end . 0))
    0 ())
  (run-serve (list '(ok serve #f) (ok) (ok) (ok) '(returned #t #f) (ok) (ok) (ok))))
(test-equal "serve: a refused check exits 1 with its line, no worker made"
  '(((check) (end . 1)) 1 ((line . "the database file is missing")))
  (run-serve (list (list 'ok verdict-refused #f))))
(test-equal "serve: the writer will not open, exit 1"
  (list '((check) (open-writer) (end . 1)) 1 (list (cons 'raised o1)))
  (run-serve (list '(ok serve #f) (raised o1))))
(test-equal "serve: the hasher will not open, the writer is still stopped, exit 1"
  (list '((check) (open-writer) (open-hasher) (stop-writer) (end . 1))
        1 (list (cons 'raised o1)))
  (run-serve (list '(ok serve #f) (ok) (raised o1) (ok))))
(test-equal "serve: the hasher will not open and the writer's stop raises: the first wins"
  (list '((check) (open-writer) (open-hasher) (stop-writer) (end . 1))
        1 (list (cons 'raised o1) (cons 'raised o2)))
  (run-serve (list '(ok serve #f) (ok) (raised o1) (raised o2))))
(test-equal "serve: the readers will not open, the hasher and the writer are still stopped"
  (list '((check) (open-writer) (open-hasher) (open-readers) (stop-hasher)
          (stop-writer) (end . 1))
        1 (list (cons 'raised o1)))
  (run-serve (list '(ok serve #f) (ok) (ok) (raised o1) (ok) (ok))))
(test-equal "serve: a bad setting exits 2, and a later raise does not change it"
  (list '((check) (open-writer) (open-hasher) (open-readers) (serve) (stop-readers)
          (stop-hasher) (stop-writer) (end . 2))
        2 (list (cons 'refused o1) (cons 'raised o2)))
  (run-serve (list '(ok serve #f) (ok) (ok) (ok) (list 'refused o1 #f)
                   (raised o2) (ok) (ok))))
(test-equal "serve: the first raise wins over a later one"
  (list '((check) (open-writer) (open-hasher) (open-readers) (serve) (stop-readers)
          (stop-hasher) (stop-writer) (end . 1))
        1 (list (cons 'raised o1) (cons 'raised o2)))
  (run-serve (list '(ok serve #f) (ok) (ok) (ok) (raised o1) (ok) (ok) (raised o2))))
(test-equal "serve: every stop raises after a refused setting: each is printed in order, and the 2 stays"
  (list '((check) (open-writer) (open-hasher) (open-readers) (serve) (stop-readers)
          (stop-hasher) (stop-writer) (end . 2))
        2 (list (cons 'refused o1) (cons 'raised o2) (cons 'raised o3)
                (cons 'raised boom)))
  (run-serve (list '(ok serve #f) (ok) (ok) (ok) (list 'refused o1 #f)
                   (raised o2) (raised o3) (raised boom))))
(test-equal "serve: a hasher's stop that raises after a clean run exits 1, and the writer still stops"
  (list '((check) (open-writer) (open-hasher) (open-readers) (serve) (stop-readers)
          (stop-hasher) (stop-writer) (end . 1))
        1 (list (cons 'raised o1)))
  (run-serve (list '(ok serve #f) (ok) (ok) (ok) '(returned #t #f) (ok) (raised o1) (ok))))
(test-equal "serve: a writer's tear-down that raises after a clean run exits 1"
  (list '((check) (open-writer) (open-hasher) (open-readers) (serve) (stop-readers)
          (stop-hasher) (stop-writer) (end . 1))
        1 (list (cons 'raised o1)))
  (run-serve (list '(ok serve #f) (ok) (ok) (ok) '(returned #t #f) (ok) (ok) (raised o1))))

;;; job-carry

(define (carry-all steps)
  (fold-left (lambda (c s) (job-carry c (car s) (cadr s))) empty-carry steps))
(define (carry-view c)
  (list (carry-values c) (carry-raised c) (carry-version c)))

(test-equal "job-carry: the empty carry holds nothing"
  '(#f #f #f)
  (carry-view empty-carry))
(test-equal "job-carry: the job's values, and the version read"
  '((1 2) #f 3)
  (attempt
   (lambda ()
     (carry-view (carry-all (list (list '(read-version . 3) '(ok 3 #t))
                                  (list '(run-job) '(returned (1 2) #t))))))))
(test-equal "job-carry: a job that returned no values keeps the empty list"
  '(() #f 3)
  (attempt
   (lambda ()
     (carry-view (carry-all (list (list '(read-version . 3) '(ok 3 #t))
                                  (list '(run-job) '(returned () #t))))))))
(test-equal "job-carry: the first raised object is kept, not the last"
  (list #f (list o1) #f)
  (attempt
   (lambda ()
     (carry-view (carry-all (list (list '(run-job) (list 'raised o1 #t))
                                  (list '(rollback) (list 'failed o2 #t))
                                  (list '(close) (list 'failed boom #f))))))))
(test-equal "job-carry: busy and failed count as raised, whichever is first"
  (list #f (list o1) #f)
  (attempt
   (lambda ()
     (carry-view (carry-all (list (list '(commit) (list 'busy o1 #t))
                                  (list '(rollback) (list 'failed o2 #f))))))))
(test-equal "job-carry: an object that is #f still shows as raised"
  (list #f (list #f) #f)
  (attempt
   (lambda ()
     (carry-view (carry-all (list (list '(run-job) (list 'raised #f #t))
                                  (list '(rollback) (list 'failed o2 #f))))))))
(test-equal "job-carry: ok outcomes carry nothing"
  '(#f #f #f)
  (attempt
   (lambda ()
     (carry-view (carry-all (list (list '(look) '(present #f #f))
                                  (list '(begin) '(ok #t #t))
                                  (list '(commit) '(ok #t #f))
                                  (list '(close) '(ok #t #f))))))))
(test-equal "job-carry: pure, the first carry is not changed"
  '(#f #f #f)
  (attempt (lambda ()
             (job-carry empty-carry '(run-job) (list 'raised o1 #t))
             (carry-view empty-carry))))
(test-equal "job-carry: a malformed outcome and a non-command raise"
  '(job-carry job-carry)
  (list (raised-who (lambda () (job-carry empty-carry '(look) '(ok #t))))
        (raised-who (lambda () (job-carry empty-carry 'look '(ok #t #f))))))

;;; set-up-verdict

(define (verdict f) (attempt (lambda () (set-up-verdict f tm))))

(test-equal "set-up-verdict: current and in WAL serves"
  'serve (verdict (facts T 3 5 'wal)))
(test-equal "set-up-verdict: fresh"
  '(refuse fresh "the database is empty: run `techo migrate`")
  (verdict (facts 0 0 0 'delete)))
(test-equal "set-up-verdict: behind"
  '(refuse behind "the database is behind this binary: run `techo migrate`")
  (verdict (facts T 2 5 'wal)))
(test-equal "set-up-verdict: current but not in WAL"
  '(refuse unconverted "the database is not in WAL mode: run `techo migrate`")
  (verdict (facts T 3 5 'delete)))
(test-equal "set-up-verdict: ahead"
  '(refuse ahead "this binary is older than the database (version 4)")
  (verdict (facts T 4 5 'wal)))
(test-equal "set-up-verdict: foreign"
  '(refuse foreign "not Techo's database")
  (verdict (facts 7 1 1 'wal)))
(test-equal "set-up-verdict: the lines are the check machine's own"
  (let-values (((next cmd) (check-step tm (cons 'peeking '())
                                       (list 'ok (facts T 2 5 'wal) #f))))
    (cdr next))
  (verdict (facts T 2 5 'wal)))
(test-equal "set-up-verdict: facts that are not DbFacts are refused"
  'check-event-kind
  (raised-who (lambda () (set-up-verdict '(1 2) tm))))

;;; forbidden-statement?

(test-equal "forbidden-statement?: each forbidden first word, any case"
  '(#t #t #t #t #t #t #t #t #t #t #t #t)
  (map forbidden-statement?
       '("BEGIN" "commit" "End" "rollBACK" "SAVEPOINT x" "release x"
         "ATTACH 'f' AS g" "detach g" "VACUUM" "pragma user_version = 3"
         ;; SQLite applies a flag pragma while it prepares the statement, so
         ;; EXPLAIN in front does not stop it taking effect.
         "EXPLAIN PRAGMA query_only = 1" "explain query plan pragma query_only=ON")))
(test-equal "forbidden-statement?: after space, semicolons and comments"
  '(#t #t #t #t)
  (map forbidden-statement?
       '("   begin immediate" ";; commit" "-- note\nPRAGMA query_only = 1"
         "/* x */ /* y */ rollback")))
(test-equal "forbidden-statement?: the others are not"
  '(#f #f #f #f #f #f #f)
  (map forbidden-statement?
       '("SELECT 1" "INSERT INTO t VALUES (1)" "" "   " "BEGINNING"
         "-- BEGIN\nSELECT 1" "WITH x AS (SELECT 1) SELECT * FROM x")))
(test-equal "forbidden-statement?: only a word that is first counts"
  '(#f #f)
  (map forbidden-statement?
       '("SELECT 'BEGIN'" "UPDATE t SET commit = 1")))

;;; Layer 6: the diagram

(define (read-file path)
  (attempt (lambda () (call-with-input-file path get-string-all))))

(test-equal ".plans/machines/doorway.md is what the tables render"
  (attempt (lambda () (doorway-document)))
  (read-file ".plans/machines/doorway.md"))

(test-assert "the document has a block for each machine, and names rows of each"
  (let ((doc (attempt (lambda () (doorway-document)))))
    (and (string? doc)
         (string-index-of doc "stateDiagram-v2")
         (string-index-of doc "start --> beginning: present")
         (string-index-of doc "committing --> ended: ok")
         (string-index-of doc "rolling-back --> closing: busy, failed-open")
         (string-index-of doc "ending --> closing: busy, failed-open")
         (string-index-of doc "checking --> opening-writer: serve")
         (string-index-of doc "stopping-writer --> ended: ok, raised"))))

(test-assert "the serve diagram has the hasher's states and the rows that changed"
  (let ((doc (attempt (lambda () (doorway-document)))))
    (and (string? doc)
         (string-index-of doc "opening-writer --> opening-hasher: ok")
         (string-index-of doc "opening-hasher --> opening-readers: ok")
         (string-index-of doc "opening-hasher --> stopping-writer: raised")
         (string-index-of doc "opening-readers --> stopping-hasher: raised")
         (string-index-of doc "stopping-readers --> stopping-hasher: ok, raised")
         (string-index-of doc "stopping-hasher --> stopping-writer: ok, raised")
         (not (string-index-of doc "opening-writer --> opening-readers"))
         (not (string-index-of doc "opening-readers --> stopping-writer"))
         (not (string-index-of doc "stopping-readers --> stopping-writer")))))

(test-equal "the document has three diagrams"
  3
  (let ((doc (attempt (lambda () (doorway-document)))))
    (let loop ((i 0) (n 0))
      (let ((at (and (< i (string-length doc))
                     (string-index-of (substring doc i (string-length doc))
                                      "stateDiagram-v2"))))
        (if at (loop (+ i at 1) (+ n 1)) n)))))

(test-end "transaction")

(exit (suite-exit-status runner))
