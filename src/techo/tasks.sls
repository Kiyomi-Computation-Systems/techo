#!r6rs
;;; (techo tasks): slice 6's task machine (P7; ADR-0007, amended
;;; 2026-11-27). A Task's status, TODO, DONE or WONTDO, as a table over the
;;; three events its commands send, done, wontdo and reopen; task-step, its
;;; pure step; and task-command, the one pure function by which a
;;; transition is answered. It asks node-command, in (techo nodes), as for
;;; a replace (404, 412, wrong_state, in that order), then the kind, then
;;; this table (the plan's review, blocker 3). Pure: no database, no
;;; circuit, no clock.
;;;
;;; A status is a symbol here and a string in props: TODO, DONE and
;;; WONTDO, upper case, as P7 names them. The table has no end (ADR-0007,
;;; amended 2026-11-24): every status takes every event, and a Task may be
;;; closed and reopened for ever. A create may give any status, so every
;;; status is a start; TODO, the default, reaches the others.
;;;
;;; Nothing here raises with a request's text: every raise is an assertion
;;; violation with no irritant.
(library (techo tasks)
  (export task-statuses task-events task-rows task-step task-command task-document)
  (import (rnrs)
          (techo machine)
          (only (techo nodes) node-kinds node-command))

  ;; task-statuses : (Listof String)
  ;; The three, as props hold them: TODO (the default, never stored), DONE
  ;; and WONTDO.
  (define task-statuses '("TODO" "DONE" "WONTDO"))

  ;; The same as the table's symbols.
  (define statuses '(TODO DONE WONTDO))

  ;; task-events : (Listof Symbol)
  ;; The three a transition sends, each its own route: done, wontdo, reopen.
  (define task-events '(done wontdo reopen))

  ;; The commands a row names: close sets closed to the write's time, keep
  ;; leaves it, open removes it.
  (define (same d e) d)

  ;; task-rows : (Listof Row)
  ;; The nine rows, three statuses by three events, by status and then by
  ;; event, as the plan's table reads. Row is (state event next command
  ;; update), as (techo machine) takes it. A refusal leaves the status.
  (define task-rows
    (list
     (list 'TODO 'done 'DONE 'close same)
     (list 'TODO 'wontdo 'WONTDO 'close same)
     (list 'TODO 'reopen 'TODO 'refuse-wrong-status same)
     (list 'DONE 'done 'DONE 'refuse-wrong-status same)
     (list 'DONE 'wontdo 'WONTDO 'keep same)
     (list 'DONE 'reopen 'TODO 'open same)
     (list 'WONTDO 'done 'DONE 'keep same)
     (list 'WONTDO 'wontdo 'WONTDO 'refuse-wrong-status same)
     (list 'WONTDO 'reopen 'TODO 'open same)))

  (define task-machine (make-machine task-rows))

  ;; task-step : Symbol Symbol -> (values Symbol Symbol)
  ;; The status and the event to the next status and the command: close,
  ;; keep, open or refuse-wrong-status. Every pair of the three statuses
  ;; and the three events has a row. An assertion violation, who
  ;; task-step, with no irritant, for what is no status's symbol or no
  ;; event of task-events.
  (define (task-step status event)
    (unless (and (memq status statuses) (memq event task-events))
      (assertion-violation 'task-step "not a task's status and event"))
    (let-values (((next command)
                  (machine-step task-machine (cons status #f) (cons event #f))))
      (values (car next) (car command))))

  ;;; task-command (the plan's review, blocker 3)

  ;; task-command : Found (U Symbol #f) (U String #f) (U Symbol #f) Symbol
  ;;                -> (values Symbol (U Symbol #f))
  ;; A transition's request: what the job found (none, match, differ, as
  ;; found answers), the node's state (#f when none was found), its stored
  ;; kind (#f for none), its stored status with the default filled in (a
  ;; symbol of the table; #f when the node is no Task, or none), and the
  ;; event, one of task-events. Answers the command and, for close, keep
  ;; and open, the next status; else #f. In this order (ADR-0007, amended
  ;; 2026-11-27):
  ;;   1  node-command's answer for a replace in that found and state:
  ;;      refuse-404 (none), refuse-412 (differ, whatever the state) and
  ;;      refuse-wrong-state (a trashed node), as it answers them
  ;;   2  a kind that is not "task"                  refuse-not-a-task
  ;;   3  task-step's refusal                        refuse-wrong-status
  ;;   4  task-step's command, close, keep or open, and the next status
  ;; So an archived Task takes a transition, as it takes a replace. For none
  ;; and differ the state, the kind and the status are not looked at (any
  ;; value of their kinds is ignored). Commands: close keep open refuse-404
  ;; refuse-412 refuse-wrong-state refuse-not-a-task refuse-wrong-status.
  ;; An assertion violation, who task-command, with no irritant, for a cell
  ;; that cannot happen: an event not of task-events; a Found of none of
  ;; the three; a kind that is no string of node-kinds or #f, or a status
  ;; that is no symbol of the table or #f, whatever was found; and for
  ;; match, a state not active, archived or trashed, no kind, a Task with
  ;; no status, or another kind with one.
  (define (task-command found state kind status event)
    (define (bad what) (assertion-violation 'task-command what))
    (unless (memq event task-events) (bad "not a task's event"))
    (unless (memq found '(none match differ)) (bad "not what a job finds"))
    (unless (or (not kind) (and (string? kind) (member kind node-kinds)))
      (bad "a kind is one of the five or #f"))
    (unless (or (not status) (memq status statuses))
      (bad "a status is TODO, DONE, WONTDO or #f"))
    (when (eq? found 'match)
      (unless (memq state '(active archived trashed))
        (bad "a node found is active, archived or trashed"))
      (unless kind (bad "a node found has a kind"))
      (when (and (string=? kind "task") (not status)) (bad "a Task found has a status"))
      (when (and (not (string=? kind "task")) status) (bad "only a Task has a status")))
    (let-values (((command next) (node-command found state 'replace 'ok #f)))
      (case command
        ((refuse-404 refuse-412 refuse-wrong-state) (values command #f))
        ((write)
         (if (string=? kind "task")
             (let-values (((next command) (task-step status event)))
               (if (eq? command 'refuse-wrong-status)
                   (values command #f)
                   (values command next)))
             (values 'refuse-not-a-task #f)))
        (else (bad "node-command answers a replace with refuse-404, refuse-412, refuse-wrong-state or write")))))

  ;;; The document

  ;; task-cell : Symbol Symbol -> String
  ;; The row's command, with "-> next, " before it when the status moves;
  ;; "no row", which no test passes.
  (define (task-cell s e)
    (cond ((find (lambda (r) (and (eq? (car r) s) (eq? (cadr r) e))) task-rows)
           => (lambda (r)
                (if (eq? (caddr r) s)
                    (symbol->string (cadddr r))
                    (string-append "-> " (symbol->string (caddr r)) ", "
                                   (symbol->string (cadddr r))))))
          (else "no row")))

  ;; table-line : (Listof String) -> String     "| a | b |" and a newline
  (define (table-line cells)
    (string-append "| " (fold-left (lambda (acc c) (string-append acc " | " c))
                                  (car cells) (cdr cells))
                   " |\n"))

  ;; rule-line : (Listof Any) -> String     "|---|---|" for two columns
  (define (rule-line columns)
    (string-append (apply string-append (map (lambda (c) "|---") columns)) "|\n"))

  ;; task-document : -> String
  ;; The text of .plans/machines/task.md, rendered from the table: the
  ;; diagram, each cell's answer, and how task-command answers.
  (define (task-document)
    (string-append
     "# The task machine\n\n"
     "Generated from the table in `src/techo/tasks.sls`. Do not edit.\n"
     "Regenerate with `scripts/guix-env make machines`; "
     "a test fails when this file differs.\n\n"
     "A Task's status is `TODO`, `DONE` or `WONTDO`. A create may give any of them;\n"
     "after that only `done`, `wontdo` and `reopen` change it, each its own command.\n"
     "Every move between two different statuses is allowed. The table has no end, on\n"
     "purpose: a Task may be closed and reopened for ever.\n\n"
     "`close` sets `closed` to the write's time, `keep` leaves it, and `open` removes\n"
     "it. A refusal leaves the status.\n\n"
     "One function, `task-command`, answers a transition. It asks `node-command` in\n"
     "`(techo nodes)` as for a replace, then the kind, then this table. The first\n"
     "that applies:\n\n"
     "1. no node: `refuse-404`;\n"
     "2. stale: `refuse-412`, whatever the state;\n"
     "3. the node's state: a trashed node takes none, `refuse-wrong-state`. An\n"
     "   archived Task takes one, as it takes a replace;\n"
     "4. the kind: a node that is no Task, `refuse-not-a-task`;\n"
     "5. this table: `refuse-wrong-status`, or the cell's command and next status.\n\n"
     "```mermaid\n"
     (machine->mermaid task-machine)
     "```\n\n"
     "## The answer each cell names\n\n"
     (table-line (cons "Status" (map symbol->string task-events)))
     (rule-line (cons 'status task-events))
     (apply string-append
            (map (lambda (s)
                   (table-line (cons (symbol->string s)
                                     (map (lambda (e) (task-cell s e)) task-events))))
                 statuses))
     "\nEvery cell has a row: no cell cannot happen.\n"))
)
