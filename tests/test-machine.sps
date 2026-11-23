#!r6rs
;;; The machine suite: (techo machine) on small tables of its own, and the
;;; explorer (explore) on small worlds.
;;;
;;; Everything that can raise is computed under a guard, and a raise comes
;;; out as a sentinel the expected value never is, so a failure names what
;;; was raised, never #f.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo machine)
        (explore))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; row : StateKind EventKind StateKind CommandKind -> Row
;; A row whose update counts how many steps the data has seen.
(define (row s e n c)
  (list s e n c (lambda (data ev) (+ data 1))))

;; problems : Machine (Listof StateKind) (Listof StateKind)
;;            (Listof (List StateKind EventKind String))
;;            -> (U (Listof Problem) (List 'raised String))
(define (problems rows starts terminals cants)
  (attempt
   (lambda ()
     (machine-problems (make-machine rows) starts terminals cants))))

;; A clean table: a -> b -> c (terminal); each non-terminal answers both
;; events, and c has no row.
(define clean-rows
  (list (row 'a 'go 'b 'cmd-ab)
        (row 'a 'stop 'c 'cmd-ac)
        (row 'b 'go 'c 'cmd-bc)
        (row 'b 'stop 'c 'cmd-bc)))

(test-begin "machine")

;;; make-machine, machine-rows

(test-equal "machine-rows: the rows as given, in order"
  '(a b)
  (attempt
   (lambda ()
     (map car (machine-rows (make-machine (list (row 'a 'go 'b 'x)
                                                (row 'b 'go 'a 'y))))))))

;;; machine-problems

(test-equal "problems: a clean table answers ()"
  '()
  (problems clean-rows '(a) '(c) '()))

(test-equal "problems: a double row is named once"
  '((double-row a go))
  (problems (append clean-rows (list (row 'a 'go 'c 'other)))
            '(a) '(c) '()))

(test-equal "problems: an unlisted gap is named"
  '((unlisted-gap b stop))
  (problems (list (row 'a 'go 'b 'x) (row 'a 'stop 'c 'x) (row 'b 'go 'c 'x))
            '(a) '(c) '()))

(test-equal "problems: a listed can't-happen pair silences the gap"
  '()
  (problems (list (row 'a 'go 'b 'x) (row 'a 'stop 'c 'x) (row 'b 'go 'c 'x))
            '(a) '(c) '((b stop "b never sees stop"))))

(test-equal "problems: a terminal state's gaps are not gaps"
  '()
  (problems clean-rows '(a) '(c) '()))

(test-equal "problems: a listed pair that has a row is named"
  '((listed-but-has-row a go))
  (problems clean-rows '(a) '(c) '((a go "claimed impossible"))))

(test-equal "problems: an unreachable state is named"
  '((unreachable z))
  (problems (append clean-rows
                    (list (row 'z 'go 'c 'x) (row 'z 'stop 'c 'x)))
            '(a) '(c) '()))

(test-equal "problems: a dead end is named"
  '((dead-end d))
  (problems (list (row 'a 'go 'd 'x) (row 'a 'stop 'c 'x)
                  (row 'd 'go 'd 'x) (row 'd 'stop 'd 'x))
            '(a) '(c) '()))

(test-equal "problems: a terminal with a row is named"
  '((terminal-has-row c))
  (problems (append clean-rows (list (row 'c 'go 'a 'x)))
            '(a) '(c) '((c stop "c stops here"))))

(test-equal "problems: problems come in table order"
  '((double-row a go) (double-row b stop))
  (problems (append clean-rows
                    (list (row 'b 'stop 'c 'x) (row 'a 'go 'c 'x)))
            '(a) '(c) '()))

;;; machine-step

;; stepped : Machine State Event -> (U (List State Command) (List 'raised String))
(define (stepped m state event)
  (attempt (lambda ()
             (call-with-values (lambda () (machine-step (if (procedure? m) (m) m) state event))
               list))))

;; stepped-clean : State Event -> (U (List State Command) (List 'raised String))
(define (stepped-clean state event) (stepped step-machine state event))

;; step-machine : -> Machine
;; A thunk: make-machine can raise, and a raise in a top-level definition
;; kills the suite before any test is named.
(define (step-machine) (make-machine clean-rows))

(test-equal "step: the next state is the row's, its data updated"
  '((b . 11) (cmd-ab . 11))
  (stepped-clean '(a . 10) '(go . payload)))

(test-equal "step: the update sees the data and the event's data"
  '((c . (1 . seen)) (cmd-ac . (1 . seen)))
  (stepped (lambda ()
            (make-machine
             (list (list 'a 'stop 'c 'cmd-ac
                         (lambda (d ev) (cons d ev))))))
           '(a . 1) '(stop . seen)))

(test-equal "step: the command carries the new data"
  '(cmd-bc . 6)
  (let ((r (stepped-clean '(b . 5) '(stop . #f))))
    (and (pair? r) (not (eq? (car r) 'raised)) (cadr r))))

;; raised-with : thunk -> (U (List 'assertion who message irritants) (List 'other String))
(define (raised-with thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e))
             (list 'assertion (condition-who e)
                   (if (irritants-condition? e) (condition-irritants e) '())))
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

(test-equal "step: a pair with no row raises, naming the state and event kinds"
  '(assertion machine-step (c go))
  (raised-with (lambda () (machine-step (step-machine) '(c . #f) '(go . #f)))))

(test-equal "step: a missing event kind raises too"
  '(assertion machine-step (a nope))
  (raised-with (lambda () (machine-step (step-machine) '(a . #f) '(nope . #f)))))

;;; machine->mermaid

(test-equal "mermaid: one line per state pair, events joined"
  (string-append "stateDiagram-v2\n"
                 "    a --> b: go\n"
                 "    a --> c: stop\n"
                 "    b --> c: go, stop\n")
  (attempt (lambda () (machine->mermaid (step-machine)))))

(test-equal "mermaid: a pair first seen earlier keeps its place"
  (string-append "stateDiagram-v2\n"
                 "    a --> b: x, z\n"
                 "    b --> a: y\n")
  (attempt
   (lambda ()
     (machine->mermaid (make-machine (list (row 'a 'x 'b 'c) (row 'b 'y 'a 'c)
                                           (row 'a 'z 'b 'c)))))))

;;; explore

;; A world is a number; a graph is an alist of (world (label . world) ...).
;; graph-next : alist -> (World -> (Listof (Pairof Label World)))
(define (graph-next g)
  (lambda (w) (let ((p (assv w g))) (if p (cdr p) '()))))

(define (never w) #f)

(test-equal "explore: ok carries the number of distinct worlds"
  '(ok 4)
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1) (b . 2)) (1 (c . 3)) (2 (d . 3)))) never never))))

(test-equal "explore: a lone start is one world"
  '(ok 1)
  (attempt (lambda () (explore 0 (graph-next '()) never never))))

(test-equal "explore: a violation at the start has the empty trace"
  '(violated "bad start" ())
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1)))) (lambda (w) (and (= w 0) "bad start")) never))))

(test-equal "explore: the trace is a shortest one"
  '(violated "bad 9" (short1 short2))
  (attempt
   (lambda ()
     (explore 0
              (graph-next '((0 (long1 . 1) (short1 . 5))
                            (1 (long2 . 2))
                            (2 (long3 . 3))
                            (3 (long4 . 9))
                            (5 (short2 . 9))))
              (lambda (w) (and (= w 9) "bad 9"))
              never))))

(test-equal "explore: the final check is called at a world with no next worlds"
  '(violated "bad end 2" (a b))
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1)) (1 (b . 2))))
              never
              (lambda (w) (and (= w 2) "bad end 2"))))))

(test-equal "explore: the final check is not called where a world has next worlds"
  '(ok 3)
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1)) (1 (b . 2))))
              never
              (lambda (w) (and (< w 2) "called too early"))))))

(test-equal "explore: a cycle answers the labels that close it"
  '(cycle (a b c))
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1)) (1 (b . 2)) (2 (c . 1)))) never never))))

(test-equal "explore: a diamond is not a cycle"
  '(ok 4)
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1) (b . 2)) (1 (c . 3)) (2 (d . 3)))) never never))))

(test-equal "explore: a self-loop is a cycle"
  '(cycle (a))
  (attempt (lambda () (explore 0 (graph-next '((0 (a . 0)))) never never))))

(test-equal "explore: a violation takes precedence over a cycle"
  '(violated "bad 3" (a b c))
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1)) (1 (b . 2) (z . 0)) (2 (c . 3))))
              (lambda (w) (and (= w 3) "bad 3"))
              never))))

(test-equal "explore: a raise in next-worlds is a violation naming it"
  '(violated "raised: boom" (a))
  (attempt
   (lambda ()
     (explore 0
              (lambda (w)
                (if (= w 1)
                    (assertion-violation 'next "boom")
                    '((a . 1))))
              never never))))

(test-equal "explore: a raise in the invariant is a violation naming it"
  '(violated "raised: inv" (a))
  (attempt
   (lambda ()
     (explore 0 (graph-next '((0 (a . 1))))
              (lambda (w) (if (= w 1) (error 'inv "inv") #f))
              never))))

(test-equal "explore: a raise in the final check is a violation naming it"
  '(violated "raised: fin" ())
  (attempt
   (lambda ()
     (explore 0 (graph-next '())
              never
              (lambda (w) (error 'final "fin"))))))

(test-equal "explore: worlds are compared with equal?"
  '(ok 2)
  (attempt
   (lambda ()
     (explore (list 0 "x")
              (lambda (w) (if (= (car w) 0) (list (cons 'a (list 1 (string #\y)))
                                                  (cons 'b (list 1 (string #\y))))
                              '()))
              never never))))

(test-end "machine")

(exit (suite-exit-status runner))
