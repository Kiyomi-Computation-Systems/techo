#!r6rs
;;; The tasks suite: slice 6's task machine, (techo tasks). All pure.
;;;
;;;   the lists         task-statuses and task-events, as P7 names them
;;;   the table         the nine cells against the plan's table written out
;;;                     here, each stepped; machine-problems with no end; what
;;;                     is no status or event raises, with nothing of it
;;;   task-command      every combination of what was found, the state, the
;;;                     kind, the status and the event, against a table
;;;                     written out here; what it raises (the review's
;;;                     blocker 3)
;;;   the diagram       .plans/machines/task.md is what the table renders
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo machine)
        (techo tasks))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-as : (-> Any) -> (U (List Symbol String (Listof Any)) 'no-raise (List 'other String))
;; An assertion violation as its who, its message and its irritants;
;; 'no-raise when nothing was raised; any other raise as (other text).
(define (raised-as thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (message-condition? e))
             (list (condition-who e) (condition-message e)
                   (if (irritants-condition? e) (condition-irritants e) '())))
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

(define (read-file path)
  (attempt (lambda () (call-with-input-file path get-string-all))))

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

(test-begin "tasks")

;;; The lists (P7)

(test-equal "statuses: TODO, DONE and WONTDO, upper case, as strings"
  '("TODO" "DONE" "WONTDO")
  (attempt (lambda () task-statuses)))

(test-equal "events: done, wontdo and reopen, each its own command"
  '(done wontdo reopen)
  (attempt (lambda () task-events)))

;;; The table, written out from the plan's "The task machine"

(define statuses '(TODO DONE WONTDO))
(define events '(done wontdo reopen))

(define task-table
  '((TODO done DONE close)
    (TODO wontdo WONTDO close)
    (TODO reopen TODO refuse-wrong-status)
    (DONE done DONE refuse-wrong-status)
    (DONE wontdo WONTDO keep)
    (DONE reopen TODO open)
    (WONTDO done DONE keep)
    (WONTDO wontdo WONTDO refuse-wrong-status)
    (WONTDO reopen TODO open)))

(define (task-problems rows)
  (attempt (lambda () (machine-problems (make-machine rows) '(TODO) #f '()))))

(test-equal "table: the rows are exactly the plan's, in its order"
  task-table
  (attempt (lambda () (map (lambda (r) (list (car r) (cadr r) (caddr r) (cadddr r))) task-rows))))

(test-equal "table: nine rows, and machine-problems, start TODO, no end, no cell that cannot happen, answers ()"
  '(9 ())
  (list (attempt (lambda () (length task-rows))) (task-problems task-rows)))

(test-equal "table: with an empty list of ends, every status is a dead end: #f is what says no end"
  '((dead-end TODO) (dead-end DONE) (dead-end WONTDO))
  (attempt (lambda () (machine-problems (make-machine task-rows) '(TODO) '() '()))))

(test-equal "table: dropping DONE + reopen is reported"
  '((unlisted-gap DONE reopen))
  (task-problems (filter (lambda (r) (not (and (eq? (car r) 'DONE) (eq? (cadr r) 'reopen))))
                         task-rows)))

(test-equal "table: a second row for TODO + done is reported"
  '((double-row TODO done))
  (task-problems (append task-rows (list (list 'TODO 'done 'WONTDO 'close (lambda (d e) d))))))

(test-equal "table: pointing TODO's two closes back at TODO leaves DONE and WONTDO unreachable"
  '((unreachable DONE) (unreachable WONTDO))
  (task-problems (map (lambda (r)
                        (if (and (eq? (car r) 'TODO) (memq (cadr r) '(done wontdo)))
                            (list 'TODO (cadr r) 'TODO (cadddr r) (car (cddddr r)))
                            r))
                      task-rows)))

(test-equal "table: every move between two different statuses is allowed (P7)"
  '((TODO DONE #t) (TODO WONTDO #t) (DONE TODO #t) (DONE WONTDO #t) (WONTDO TODO #t) (WONTDO DONE #t))
  (attempt
   (lambda ()
     (apply append
            (map (lambda (s)
                   (map (lambda (t)
                          (list s t (and (exists (lambda (r) (and (eq? (car r) s) (eq? (caddr r) t)
                                                                  (not (eq? (cadddr r) 'refuse-wrong-status))))
                                                 task-rows)
                                         #t)))
                        (filter (lambda (t) (not (eq? t s))) statuses)))
                 statuses)))))

(test-equal "table: three refusals leave the status; two closes leave TODO, two opens land on it, two keeps are between DONE and WONTDO"
  '((refuse-wrong-status 3 #t) (close 2 #t) (open 2 #t) (keep 2 #t))
  (attempt
   (lambda ()
     (let ((rows-of (lambda (c) (filter (lambda (r) (eq? (cadddr r) c)) task-rows))))
       (list (list 'refuse-wrong-status (length (rows-of 'refuse-wrong-status))
                   (for-all (lambda (r) (eq? (car r) (caddr r))) (rows-of 'refuse-wrong-status)))
             (list 'close (length (rows-of 'close)) (for-all (lambda (r) (and (eq? (car r) 'TODO) (not (eq? (caddr r) 'TODO))))
                                   (rows-of 'close)))
             (list 'open (length (rows-of 'open)) (for-all (lambda (r) (and (not (eq? (car r) 'TODO)) (eq? (caddr r) 'TODO)))
                                  (rows-of 'open)))
             (list 'keep (length (rows-of 'keep)) (for-all (lambda (r) (and (memq (car r) '(DONE WONTDO))
                                                   (memq (caddr r) '(DONE WONTDO))
                                                   (not (eq? (car r) (caddr r)))))
                                  (rows-of 'keep))))))))

;; Every one of the nine cells, by construction from the table above.
(for-each
 (lambda (s)
   (for-each
    (lambda (e)
      (test-equal (string-append "step: " (symbol->string s) " + " (symbol->string e))
        (let ((row (find (lambda (r) (and (eq? (car r) s) (eq? (cadr r) e))) task-table)))
          (if row (list (caddr row) (cadddr row)) 'missing-from-the-suites-table))
        (attempt (lambda () (call-with-values (lambda () (task-step s e)) list)))))
    events))
 statuses)

(test-equal "step: what is no status or no event raises, who task-step, with no irritant"
  (map (lambda (x) (list 'task-step "not a task's status and event" '())) '(1 2 3 4 5 6 7))
  (map (lambda (args) (raised-as (lambda () (apply task-step args))))
       (list (list 'todo 'done) (list "TODO" 'done) (list #f 'done) (list 'TODO 'archive)
             (list 'TODO "done") (list 'TODO 'write) (list 'active 'reopen))))

;;; task-command (the review's blocker 3)

(define found-kinds '(none match differ))
(define states '(#f active archived trashed))
(define kinds '(#f "task" "project" "journal" "note" "contact"))
(define task-statuses* '(#f TODO DONE WONTDO))

;; What task-command answers, written out by hand, not computed. none and
;; differ answer one thing in every cell, whatever the state, the kind and
;; the status: node-command's 404 and 412, before anything else is asked.
;; For match: under each event, a row per state and kind, an entry per
;; status in task-statuses*' order (#f TODO DONE WONTDO). ! is a raise,
;; who task-command, no irritant: a match with no state, no kind, a Task
;; with no status, or another kind with one. ws is refuse-wrong-state, nt
;; refuse-not-a-task, wst refuse-wrong-status; (c S) the command c and the
;; next status S.
(define by-found '((none refuse-404 #f) (differ refuse-412 #f)))

(define match-table
  '((done
     (#f       #f        ! ! ! !)
     (#f       "task"    ! ! ! !)
     (#f       "project" ! ! ! !)
     (#f       "journal" ! ! ! !)
     (#f       "note"    ! ! ! !)
     (#f       "contact" ! ! ! !)
     (active   #f        ! ! ! !)
     (active   "task"    ! (close DONE) wst (keep DONE))
     (active   "project" nt ! ! !)
     (active   "journal" nt ! ! !)
     (active   "note"    nt ! ! !)
     (active   "contact" nt ! ! !)
     (archived #f        ! ! ! !)
     (archived "task"    ! (close DONE) wst (keep DONE))
     (archived "project" nt ! ! !)
     (archived "journal" nt ! ! !)
     (archived "note"    nt ! ! !)
     (archived "contact" nt ! ! !)
     (trashed  #f        ! ! ! !)
     (trashed  "task"    ! ws ws ws)
     (trashed  "project" ws ! ! !)
     (trashed  "journal" ws ! ! !)
     (trashed  "note"    ws ! ! !)
     (trashed  "contact" ws ! ! !))
    (wontdo
     (#f       #f        ! ! ! !)
     (#f       "task"    ! ! ! !)
     (#f       "project" ! ! ! !)
     (#f       "journal" ! ! ! !)
     (#f       "note"    ! ! ! !)
     (#f       "contact" ! ! ! !)
     (active   #f        ! ! ! !)
     (active   "task"    ! (close WONTDO) (keep WONTDO) wst)
     (active   "project" nt ! ! !)
     (active   "journal" nt ! ! !)
     (active   "note"    nt ! ! !)
     (active   "contact" nt ! ! !)
     (archived #f        ! ! ! !)
     (archived "task"    ! (close WONTDO) (keep WONTDO) wst)
     (archived "project" nt ! ! !)
     (archived "journal" nt ! ! !)
     (archived "note"    nt ! ! !)
     (archived "contact" nt ! ! !)
     (trashed  #f        ! ! ! !)
     (trashed  "task"    ! ws ws ws)
     (trashed  "project" ws ! ! !)
     (trashed  "journal" ws ! ! !)
     (trashed  "note"    ws ! ! !)
     (trashed  "contact" ws ! ! !))
    (reopen
     (#f       #f        ! ! ! !)
     (#f       "task"    ! ! ! !)
     (#f       "project" ! ! ! !)
     (#f       "journal" ! ! ! !)
     (#f       "note"    ! ! ! !)
     (#f       "contact" ! ! ! !)
     (active   #f        ! ! ! !)
     (active   "task"    ! wst (open TODO) (open TODO))
     (active   "project" nt ! ! !)
     (active   "journal" nt ! ! !)
     (active   "note"    nt ! ! !)
     (active   "contact" nt ! ! !)
     (archived #f        ! ! ! !)
     (archived "task"    ! wst (open TODO) (open TODO))
     (archived "project" nt ! ! !)
     (archived "journal" nt ! ! !)
     (archived "note"    nt ! ! !)
     (archived "contact" nt ! ! !)
     (trashed  #f        ! ! ! !)
     (trashed  "task"    ! ws ws ws)
     (trashed  "project" ws ! ! !)
     (trashed  "journal" ws ! ! !)
     (trashed  "note"    ws ! ! !)
     (trashed  "contact" ws ! ! !))))

;; entry->answer : Any -> Any     the table's short form as task-command's answer
(define (entry->answer x)
  (case x
    ((ws) '(refuse-wrong-state #f))
    ((nt) '(refuse-not-a-task #f))
    ((wst) '(refuse-wrong-status #f))
    ((!) '!)
    (else x)))

;; expected-command : Symbol (U Symbol #f) (U String #f) (U Symbol #f) Symbol -> Any
;; The tables' entry for the cell; a cell they lack expects what
;; task-command never answers.
(define (expected-command found state kind status event)
  (cond ((assq found by-found) => cdr)
        ((eq? found 'match)
         (let* ((rows (cond ((assq event match-table) => cdr) (else '())))
                (row (find (lambda (r) (and (eq? (car r) state) (equal? (cadr r) kind))) rows))
                (tail (memq status task-statuses*)))
           (if (and row tail (= (length (cddr row)) (length task-statuses*)))
               (entry->answer (list-ref (cddr row) (- (length task-statuses*) (length tail))))
               'missing-from-the-suites-table)))
        (else 'missing-from-the-suites-table)))

;; commanded : Symbol Any Any Any Any -> Any
;; task-command's two answers as a list; ! for an assertion violation, who
;; task-command, with no irritant; any other raise as itself.
(define (commanded found state kind status event)
  (guard (e ((and (assertion-violation? e) (who-condition? e)
                  (eq? (condition-who e) 'task-command)
                  (or (not (irritants-condition? e)) (null? (condition-irritants e))))
             '!)
            (#t (list 'raised (describe e))))
    (call-with-values (lambda () (task-command found state kind status event)) list)))

(define (for-each-cell f)
  (for-each
   (lambda (found)
     (for-each
      (lambda (event)
        (for-each
         (lambda (state)
           (for-each
            (lambda (kind) (for-each (lambda (status) (f found state kind status event)) task-statuses*))
            kinds))
         states))
      events))
   found-kinds))

;; Every one of the 864 cells, by construction: 3 Founds, 4 states, 6
;; kinds, 4 statuses, 3 events.
(for-each-cell
 (lambda (found state kind status event)
   (test-equal (string-append "command: " (written found) ", " (written state) ", " (written kind)
                              ", " (written status) ", " (written event))
     (expected-command found state kind status event)
     (commanded found state kind status event))))

(test-equal "command: the grid expects every answer task-command has, and a raise"
  '(#t #t #t #t #t #t #t #t #t #t)
  (let ((seen '()))
    (for-each-cell (lambda (f s k st e) (set! seen (cons (expected-command f s k st e) seen))))
    (map (lambda (a) (and (member a seen) #t))
         '((refuse-404 #f) (refuse-412 #f) (refuse-wrong-state #f) (refuse-not-a-task #f)
           (refuse-wrong-status #f) (close DONE) (close WONTDO) (keep DONE) (keep WONTDO) !))))

(test-equal "command: the order: stale before the state, the state before the kind, the kind before the status"
  '((refuse-412 #f) (refuse-wrong-state #f) (refuse-not-a-task #f) (refuse-wrong-status #f))
  (list (commanded 'differ 'trashed "note" #f 'done)
        (commanded 'match 'trashed "task" 'DONE 'done)
        (commanded 'match 'active "note" #f 'reopen)
        (commanded 'match 'archived "task" 'TODO 'reopen)))

(test-equal "command: an event not of task-events raises, with nothing of the request, whatever was found"
  (map (lambda (e) '(task-command "not a task's event" ())) '(1 2 3 4 5 6 7 8))
  (map (lambda (args) (raised-as (lambda () (apply task-command args))))
       (list (list 'match 'active "task" 'TODO 'archive) (list 'match 'active "task" 'TODO 'replace)
             (list 'match 'active "task" 'TODO 'write) (list 'none #f #f #f "done")
             (list 'differ 'active "task" 'DONE 'DONE) (list 'match 'active "task" 'TODO #f)
             (list 'none #f #f #f 'close) (list 'match 'active "task" 'TODO 'Done))))

(test-equal "command: a Found, a kind or a status of no known value raises, with no irritant"
  (map (lambda (e) (list 'task-command e '()))
       '("not what a job finds" "a kind is one of the five or #f" "a kind is one of the five or #f"
         "a status is TODO, DONE, WONTDO or #f" "a status is TODO, DONE, WONTDO or #f"
         "a status is TODO, DONE, WONTDO or #f"))
  (map (lambda (args) (raised-as (lambda () (apply task-command args))))
       (list (list 'gone 'active "task" 'TODO 'done) (list 'match 'active "folder" #f 'done)
             (list 'none #f 'task #f 'done) (list 'match 'active "task" "TODO" 'done)
             (list 'match 'active "task" 'todo 'done) (list 'differ 'active "task" 'archived 'done))))

(test-equal "command: a match's state that is no live state raises, with no irritant"
  (map (lambda (e) '(task-command "a node found is active, archived or trashed" ())) '(1 2 3))
  (map (lambda (s) (raised-as (lambda () (task-command 'match s "task" 'TODO 'done))))
       (list 'purged "active" #f)))

(test-equal "command: none and differ look at no state, kind or status: any known value answers the same"
  '((refuse-404 #f) (refuse-404 #f) (refuse-412 #f) (refuse-412 #f))
  (list (commanded 'none 'trashed "task" 'DONE 'reopen) (commanded 'none 'purged #f #f 'done)
        (commanded 'differ #f #f #f 'wontdo) (commanded 'differ 'purged "note" 'TODO 'done)))

;;; The diagram, held to its file

(test-equal ".plans/machines/task.md is what the table renders"
  (attempt (lambda () (task-document)))
  (read-file ".plans/machines/task.md"))

(test-equal "the task document shows the diagram, every cell's answer and task-command's order"
  '(#t #t #t #t #t #t #t #t #t #t)
  (let ((doc (attempt (lambda () (task-document)))))
    (map (lambda (needle) (and (string? doc) (string-index-of doc needle) #t))
         (list "Generated from the table in `src/techo/tasks.sls`. Do not edit.\n"
               "stateDiagram-v2\n"
               "    TODO --> DONE: done\n"
               "    DONE --> TODO: reopen\n"
               "    WONTDO --> WONTDO: wontdo\n"
               "| Status | done | wontdo | reopen |\n"
               "| TODO | -> DONE, close | -> WONTDO, close | refuse-wrong-status |\n"
               "| DONE | refuse-wrong-status | -> WONTDO, keep | -> TODO, open |\n"
               "| WONTDO | -> DONE, keep | refuse-wrong-status | -> TODO, open |\n"
               "`task-command`"))))

(test-end "tasks")

(exit (suite-exit-status runner))
