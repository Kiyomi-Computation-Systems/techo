#!r6rs
;;; (techo machine): a state machine as a table of rows, and its pure step.
;;;
;;;   make-machine      a machine from its rows
;;;   machine-rows      the rows back, in order
;;;   machine-step      the next state and the command, from the table
;;;   machine-problems  what is wrong with the table, as data
;;;   machine->mermaid  the table as a Mermaid stateDiagram-v2
;;;
;;; A row is (state-kind event-kind next-kind command-kind update). The
;;; table is over kinds; a state is (kind . data), an event is
;;; (kind . data), and the row's update makes the next state's data. Pure:
;;; nothing here reads a clock, a file or a database (ADR-0007).
(library (techo machine)
  (export make-machine machine-rows machine-step machine-problems
          machine->mermaid)
  (import (rnrs))

  (define-record-type (machine make-machine-record machine?)
    (fields (immutable rows machine-rows))
    (opaque #t))

  ;; make-machine : (Listof Row) -> Machine
  ;; Row is (List StateKind EventKind StateKind CommandKind Update)
  ;;   StateKind, EventKind, CommandKind are symbols
  ;;   Update is (StateData EventData -> StateData), pure
  ;; Raises an assertion violation on a row of the wrong shape. Two rows for
  ;; one state and event are allowed here: machine-problems names them.
  (define (make-machine rows)
    (unless (list? rows)
      (assertion-violation 'make-machine "rows must be a list" rows))
    (for-each
     (lambda (r)
       (unless (and (list? r) (= (length r) 5)
                    (symbol? (car r)) (symbol? (cadr r))
                    (symbol? (caddr r)) (symbol? (cadddr r))
                    (procedure? (car (cddddr r))))
         (assertion-violation 'make-machine
           "a row is (state event next command update), the first four symbols"
           r)))
     rows)
    (make-machine-record rows))

  ;; machine-rows : Machine -> (Listof Row)
  ;; The rows as given, in order (the record's accessor).

  ;; row accessors
  (define (row-state r) (car r))
  (define (row-event r) (cadr r))
  (define (row-next r) (caddr r))
  (define (row-command r) (cadddr r))
  (define (row-update r) (car (cddddr r)))

  ;; machine-step : Machine State Event -> (values State Command)
  ;; State is (Pairof StateKind StateData); Event is (Pairof EventKind EventData)
  ;; Command is (Pairof CommandKind StateData): the NEW state's data.
  ;; Raises an assertion violation, who 'machine-step, irritants the state
  ;; kind and the event kind, when the table has no row for the pair.
  (define (machine-step m state event)
    (let ((r (find-row (machine-rows m) (car state) (car event))))
      (unless r
        (assertion-violation 'machine-step "no row for this state and event"
                             (car state) (car event)))
      (let ((data ((row-update r) (cdr state) (cdr event))))
        (values (cons (row-next r) data)
                (cons (row-command r) data)))))

  ;; find-row : (Listof Row) Symbol Symbol -> (U Row #f)
  (define (find-row rows s e)
    (cond ((null? rows) #f)
          ((and (eq? (row-state (car rows)) s) (eq? (row-event (car rows)) e))
           (car rows))
          (else (find-row (cdr rows) s e))))

  ;; adjoin : A (Listof A) -> (Listof A)
  ;; X at the end of XS unless it is there already (eq? on symbols).
  (define (adjoin x xs)
    (if (memq x xs) xs (append xs (list x))))

  ;; adjoin-all : (Listof A) (Listof A) -> (Listof A)
  (define (adjoin-all new xs)
    (fold-left (lambda (acc x) (adjoin x acc)) xs new))

  ;; reachable : (Listof Row) (Listof StateKind) (Row -> Symbol) (Row -> Symbol)
  ;;             -> (Listof StateKind)
  ;; Kinds reachable from FROM-KINDS following each row from its key to its
  ;; value. Forward: (row-state, row-next). Backward: the other way round.
  (define (reachable rows from-kinds key val)
    (let loop ((seen from-kinds) (frontier from-kinds))
      (if (null? frontier)
          seen
          (let ((new (fold-left
                      (lambda (acc r)
                        (if (and (memq (key r) frontier)
                                 (not (memq (val r) seen))
                                 (not (memq (val r) acc)))
                            (append acc (list (val r)))
                            acc))
                      '() rows)))
            (loop (append seen new) new)))))

  ;; machine-problems : Machine (Listof StateKind) (Listof StateKind)
  ;;                    (Listof (List StateKind EventKind String))
  ;;                    -> (Listof Problem)
  ;; Arguments: the machine; the start state kinds; the terminal state
  ;; kinds; the "can't happen" pairs, each with its reason.
  ;; The state kinds are every kind in a row (either column) plus the starts
  ;; and the terminals; the event kinds are every kind in a row.
  ;; Problem is one of
  ;;   (double-row state event)          two or more rows for the pair
  ;;   (unlisted-gap state event)        a non-terminal state, an event kind,
  ;;                                     no row, and not a can't-happen pair
  ;;   (listed-but-has-row state event)  a can't-happen pair that has a row
  ;;   (unreachable state)               not reachable from any start
  ;;   (dead-end state)                  no terminal reachable from it
  ;;   (terminal-has-row state)          a terminal state with a row
  ;; Grouped in that order, each group in table order.
  (define (machine-problems m starts terminals cants)
    (let* ((rows (machine-rows m))
           (states (adjoin-all terminals
                    (adjoin-all starts
                     (fold-left (lambda (acc r)
                                  (adjoin (row-next r) (adjoin (row-state r) acc)))
                                '() rows))))
           (events (fold-left (lambda (acc r) (adjoin (row-event r) acc)) '() rows))
           (pairs (fold-left (lambda (acc r)
                               (let ((p (cons (row-state r) (row-event r))))
                                 (if (member p acc) acc (append acc (list p)))))
                             '() rows))
           (count (lambda (s e)
                    (length (filter (lambda (r) (and (eq? (row-state r) s)
                                                     (eq? (row-event r) e)))
                                    rows))))
           (cant? (lambda (s e)
                    (exists (lambda (c) (and (eq? (car c) s) (eq? (cadr c) e)))
                            cants)))
           (fwd (reachable rows starts row-state row-next))
           (back (reachable rows terminals row-next row-state)))
      (append
       (map (lambda (p) (list 'double-row (car p) (cdr p)))
            (filter (lambda (p) (> (count (car p) (cdr p)) 1)) pairs))
       (apply append
              (map (lambda (s)
                     (if (memq s terminals)
                         '()
                         (map (lambda (e) (list 'unlisted-gap s e))
                              (filter (lambda (e)
                                        (and (= (count s e) 0) (not (cant? s e))))
                                      events))))
                   states))
       (map (lambda (c) (list 'listed-but-has-row (car c) (cadr c)))
            (filter (lambda (c) (> (count (car c) (cadr c)) 0)) cants))
       (map (lambda (s) (list 'unreachable s))
            (filter (lambda (s) (not (memq s fwd))) states))
       (map (lambda (s) (list 'dead-end s))
            (filter (lambda (s) (not (memq s back))) states))
       (map (lambda (s) (list 'terminal-has-row s))
            (filter (lambda (s) (exists (lambda (r) (eq? (row-state r) s)) rows))
                    terminals)))))

  ;; machine->mermaid : Machine -> String
  ;; A stateDiagram-v2: one line per distinct (state, next) pair, in the
  ;; order the table first gives it, labelled with its event kinds joined by
  ;; ", ". Ends with a newline. Knows no start or terminal arrows.
  (define (machine->mermaid m)
    (let* ((rows (machine-rows m))
           (edges (fold-left
                   (lambda (acc r)
                     (let ((k (cons (row-state r) (row-next r))))
                       (if (assoc k acc)
                           (map (lambda (entry)
                                  (if (equal? (car entry) k)
                                      (cons k (adjoin (row-event r) (cdr entry)))
                                      entry))
                                acc)
                           (append acc (list (list k (row-event r)))))))
                   '() rows)))
      (apply string-append
             "stateDiagram-v2\n"
             (map (lambda (entry)
                    (string-append "    "
                                   (symbol->string (caar entry)) " --> "
                                   (symbol->string (cdar entry)) ": "
                                   (join (map symbol->string (cdr entry)) ", ")
                                   "\n"))
                  edges))))

  ;; join : (Listof String) String -> String
  (define (join strs sep)
    (if (null? strs)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))
)
