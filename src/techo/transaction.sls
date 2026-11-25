#!r6rs
;;; (techo transaction): the three tables of slice 2b's doorway, and their
;;; pure step functions. Nothing here opens a file, calls SQLite or starts a
;;; thread (ADR-0007). The plan is .plans/2026-11-23-slice-2b-doorway.md; each
;;; row below carries its W, R or S number from the plan's tables. Slice 3b
;;; (.plans/2026-11-24-slice-3b-login.md, L5) put the hasher into `serve`:
;;; rows S15 to S18 are its own.
;;;
;;; State data
;;; ----------
;;; A state is (kind . data).
;;;
;;; A job's state (write or read), but for `ended`, carries a two-element
;;; list (latest pending):
;;;   latest   this binary's latest version, a Natural
;;;   pending  #f, or the Ending the job will take once its transaction is
;;;            rolled back or its connection closed
;;; `ended`'s data is its Ending itself: (answer), (raise-carried),
;;; (raise-ended) or (refuse . kind), kind busy, moved or unavailable. The
;;; command of `ended` is (end . Ending).
;;;
;;; Write state kinds: start beginning versioning running committing
;;;   rolling-back closing ended.
;;; Read state kinds: start beginning versioning running ending closing ended.
;;;
;;; `serve`'s state carries a two-element list (carried prints):
;;;   carried  #f, or the exit status carried so far: the FIRST one wins
;;;   prints   what the shell must print at the end, in order, each
;;;            (line . String)     the check's refusal line
;;;            (refused . Object)  a refused setting (serve's own exit 2)
;;;            (raised . Object)   an object raised
;;; `ended`'s data is (status prints), status the exit status: what was
;;; carried, else 0 after a clean stop. Its command is (end . status).
;;; State kinds: checking opening-writer opening-hasher opening-readers
;;;   serving stopping-readers stopping-hasher stopping-writer ended.
;;;
;;; An Event is (cons kind raw), the raw outcome as the shell saw it.
(library (techo transaction)
  (export write-rows read-rows serve-rows
          write-row-names read-row-names serve-row-names
          write-start read-start serve-start
          job-event-kind serve-event-kind
          write-step read-step serve-step
          write-cant-happen read-cant-happen serve-cant-happen
          job-state-latest job-state-pending serve-carried serve-prints
          empty-carry job-carry carry-values carry-raised carry-version
          set-up-verdict doorway-document)
  (import (rnrs)
          (techo machine)
          (techo migrations))

  ;;; Helpers

  ;; exact-integer : Any -> Boolean
  (define (whole? x) (and (integer? x) (exact? x)))

  ;; check-raw : Symbol Any -> Void
  ;; RawOutcome is (Symbol Any Boolean).
  (define (check-raw who raw)
    (unless (and (list? raw) (= (length raw) 3) (symbol? (car raw))
                 (boolean? (caddr raw)))
      (assertion-violation who "not a RawOutcome" raw)))

  ;; cants-of : (Listof (Pair StateKind (Listof EventKind))) (Listof EventKind)
  ;;            -> (Listof (List StateKind EventKind String))
  ;; Every pair the kind function cannot answer, with its reason.
  (define (cants-of possible universe)
    (apply append
           (map (lambda (entry)
                  (map (lambda (e)
                         (list (car entry) e
                               (string-append "the event kind never answers "
                                              (symbol->string e) " in "
                                              (symbol->string (car entry)))))
                       (filter (lambda (e) (not (memq e (cdr entry)))) universe)))
                possible)))

  ;; rows-of : (Listof (List Name StateKind EventKind StateKind CommandKind Update))
  ;;           -> (Listof Row)
  (define (rows-of table) (map cdr table))

  ;; names-of : (Listof NamedRow) -> (Listof (List Symbol StateKind EventKind))
  (define (names-of table)
    (map (lambda (r) (list (car r) (cadr r) (caddr r))) table))

  ;;; The job machines

  ;; data accessors, a job state's data: (latest pending)
  (define (d-latest d) (car d))
  (define (d-pending d) (cadr d))
  (define (mk latest pending) (list latest pending))

  ;; job-state-latest : State -> Natural
  ;; job-state-pending : State -> (U Ending #f)
  ;; Undefined on `ended`.
  (define (job-state-latest s) (d-latest (cdr s)))
  (define (job-state-pending s) (d-pending (cdr s)))

  ;; Updates: (Data EventData -> Data)
  (define (same d e) d)
  ;; carrying : Ending -> Update    heads for a rollback or a close
  (define (carrying ending)
    (lambda (d e) (mk (d-latest d) ending)))
  ;; ending-with : Ending -> Update    heads for `ended`
  (define (ending-with ending)
    (lambda (d e) ending))
  ;; finish : Update    ends with what was carried
  (define (finish d e)
    (or (d-pending d)
        (assertion-violation 'finish "nothing was carried" d)))
  ;; keep : Update    goes on carrying what is carried
  (define (keep d e)
    (unless (d-pending d)
      (assertion-violation 'keep "nothing was carried" d))
    d)

  ;; job-command : Symbol State -> Command
  ;; The command a job's state asks the shell for. BEGIN-KIND is what the
  ;; table begins with: begin-immediate for a write, begin for a read.
  (define (job-command begin-kind s)
    (case (car s)
      ((start) (list 'look))
      ((beginning) (list begin-kind))
      ((versioning) (cons 'read-version (d-latest (cdr s))))
      ((running) (list 'run-job))
      ((committing) (list 'commit))
      ((rolling-back ending) (list 'rollback))
      ((closing) (list 'close))
      ((ended) (cons 'end (cdr s)))
      (else (assertion-violation 'job-command "not a state" s))))

  ;; write-named, read-named : (Listof (List Name State Event Next Command Update))
  ;; The command is the next state's command kind.
  (define write-named
    (list
     (list 'W1 'start 'present 'beginning 'begin-immediate same)
     (list 'W2 'start 'absent 'ended 'end (ending-with '(refuse . unavailable)))
     (list 'W3 'beginning 'ok 'versioning 'read-version same)
     (list 'W4 'beginning 'busy 'ended 'end (ending-with '(refuse . busy)))
     (list 'W5 'beginning 'failed-closed 'ended 'end (ending-with '(raise-carried)))
     (list 'W6 'beginning 'failed-open 'rolling-back 'rollback
           (carrying '(raise-carried)))
     (list 'W7 'versioning 'same 'running 'run-job same)
     (list 'W8 'versioning 'moved 'rolling-back 'rollback
           (carrying '(refuse . moved)))
     (list 'W9 'versioning 'busy 'rolling-back 'rollback (carrying '(raise-carried)))
     (list 'W9 'versioning 'failed-open 'rolling-back 'rollback
           (carrying '(raise-carried)))
     (list 'W10 'versioning 'failed-closed 'ended 'end (ending-with '(raise-carried)))
     (list 'W11 'running 'returned-open 'committing 'commit same)
     (list 'W12 'running 'returned-closed 'ended 'end (ending-with '(raise-ended)))
     (list 'W13 'running 'raised-open 'rolling-back 'rollback
           (carrying '(raise-carried)))
     (list 'W14 'running 'raised-closed 'ended 'end (ending-with '(raise-carried)))
     (list 'W15 'committing 'ok 'ended 'end (ending-with '(answer)))
     (list 'W16 'committing 'busy 'rolling-back 'rollback (carrying '(raise-carried)))
     (list 'W16 'committing 'failed-open 'rolling-back 'rollback
           (carrying '(raise-carried)))
     (list 'W17 'committing 'failed-closed 'ended 'end (ending-with '(raise-carried)))
     (list 'W18 'rolling-back 'ok 'ended 'end finish)
     (list 'W18 'rolling-back 'failed-closed 'ended 'end finish)
     (list 'W19 'rolling-back 'busy 'closing 'close keep)
     (list 'W19 'rolling-back 'failed-open 'closing 'close keep)
     (list 'W20 'closing 'ok 'ended 'end finish)
     (list 'W20 'closing 'failed 'ended 'end finish)))

  (define read-named
    (list
     (list 'R1 'start 'present 'beginning 'begin same)
     (list 'R2 'start 'absent 'ended 'end (ending-with '(refuse . unavailable)))
     (list 'R3 'beginning 'ok 'versioning 'read-version same)
     (list 'R4 'beginning 'busy 'ended 'end (ending-with '(raise-carried)))
     (list 'R4 'beginning 'failed-closed 'ended 'end (ending-with '(raise-carried)))
     (list 'R5 'beginning 'failed-open 'ending 'rollback (carrying '(raise-carried)))
     (list 'R6 'versioning 'same 'running 'run-job same)
     (list 'R7 'versioning 'moved 'ending 'rollback (carrying '(refuse . moved)))
     (list 'R8 'versioning 'busy 'ending 'rollback (carrying '(raise-carried)))
     (list 'R8 'versioning 'failed-open 'ending 'rollback (carrying '(raise-carried)))
     (list 'R9 'versioning 'failed-closed 'ended 'end (ending-with '(raise-carried)))
     (list 'R10 'running 'returned-open 'ending 'rollback (carrying '(answer)))
     (list 'R11 'running 'returned-closed 'ended 'end (ending-with '(raise-ended)))
     (list 'R12 'running 'raised-open 'ending 'rollback (carrying '(raise-carried)))
     (list 'R13 'running 'raised-closed 'ended 'end (ending-with '(raise-carried)))
     (list 'R14 'ending 'ok 'ended 'end finish)
     (list 'R14 'ending 'failed-closed 'ended 'end finish)
     (list 'R15 'ending 'busy 'closing 'close keep)
     (list 'R15 'ending 'failed-open 'closing 'close keep)
     (list 'R16 'closing 'ok 'ended 'end finish)
     (list 'R16 'closing 'failed 'ended 'end finish)))

  ;; write-rows, read-rows : (Listof Row)
  ;; Row is (List StateKind EventKind StateKind CommandKind Update), as
  ;; (techo machine) takes it. The row's command kind is the next state's
  ;; command, and the steppers refuse a row whose kind is not.
  (define write-rows (rows-of write-named))
  (define read-rows (rows-of read-named))

  ;; write-row-names, read-row-names, serve-row-names
  ;;   : (Listof (List Symbol StateKind EventKind))
  ;; The plan's row name of each row, in the same order as the rows. A row the
  ;; plan gives two events ("busy or failed-open") has the one name twice.
  (define write-row-names (names-of write-named))
  (define read-row-names (names-of read-named))

  ;; job-possible : the event kinds job-event-kind can answer in each state
  (define write-possible
    '((start present absent)
      (beginning ok busy failed-open failed-closed)
      (versioning same moved busy failed-open failed-closed)
      (running returned-open returned-closed raised-open raised-closed)
      (committing ok busy failed-open failed-closed)
      (rolling-back ok busy failed-open failed-closed)
      (closing ok failed)))
  (define read-possible
    '((start present absent)
      (beginning ok busy failed-open failed-closed)
      (versioning same moved busy failed-open failed-closed)
      (running returned-open returned-closed raised-open raised-closed)
      (ending ok busy failed-open failed-closed)
      (closing ok failed)))
  (define job-event-kinds
    '(present absent ok busy failed-open failed-closed same moved
      returned-open returned-closed raised-open raised-closed failed))

  ;; write-cant-happen, read-cant-happen
  ;;   : (Listof (List StateKind EventKind String))
  ;; Every pair of a non-terminal state and an event kind with no row: the
  ;; event kind never answers it.
  (define write-cant-happen (cants-of write-possible job-event-kinds))
  (define read-cant-happen (cants-of read-possible job-event-kinds))

  ;; make-job-stepper : (Listof Row) Symbol -> (State Event -> (values State Command))
  ;; The step function over ROWS. The command is the next state's, with the
  ;; payload from its data; the row's command kind must be that command's
  ;; kind, else the table and the state's command have come apart.
  (define (make-job-stepper rows begin-kind)
    (let ((m (make-machine rows)))
      (lambda (state event)
        (let-values (((next row-command) (machine-step m state event)))
          (let ((cmd (job-command begin-kind next)))
            (unless (eq? (car cmd) (car row-command))
              (assertion-violation 'job-step
                "the row's command kind is not the next state's"
                (car state) (car event) (car row-command) (car cmd)))
            (values next cmd))))))

  ;; write-start, read-start : Natural -> (values State Command)
  ;; The first state and its command, (look). LATEST is this binary's latest
  ;; version.
  (define (job-start who begin-kind latest)
    (unless (and (whole? latest) (>= latest 0))
      (assertion-violation who "latest must be a Natural" latest))
    (let ((s (cons 'start (mk latest #f))))
      (values s (job-command begin-kind s))))
  (define (write-start latest) (job-start 'write-start 'begin-immediate latest))
  (define (read-start latest) (job-start 'read-start 'begin latest))

  ;; write-step, read-step : State Event -> (values State Command)
  ;; Event is (cons EventKind RawOutcome). Raises an assertion violation,
  ;; who 'machine-step, when the table has no row for the pair.
  (define write-step (make-job-stepper write-rows 'begin-immediate))
  (define read-step (make-job-stepper read-rows 'begin))

  ;;; Event kinds of a job

  ;; job-event-kind : Command RawOutcome -> EventKind
  ;; Sorts a raw outcome by the command it answers. A raw outcome a command
  ;; cannot give, a malformed one, and (end . _) are assertion violations.
  ;;   (look)                          present absent
  ;;   (begin-immediate) (begin)       ok busy failed-open failed-closed
  ;;   (read-version . latest)         same moved busy failed-open failed-closed
  ;;   (run-job)                       returned-open returned-closed
  ;;                                   raised-open raised-closed
  ;;   (commit) (rollback)             ok busy failed-open failed-closed
  ;;   (close)                         ok failed
  ;; Sortings: an ok read of the version with no transaction is failed-closed;
  ;; an ok commit or rollback with a transaction still open is failed-open;
  ;; a version that is not an exact integer is an assertion violation.
  (define (job-event-kind command raw)
    (check-raw 'job-event-kind raw)
    (let ((s (car raw)) (v (cadr raw)) (open? (caddr raw)))
      (define (bad)
        (assertion-violation 'job-event-kind
          "this command cannot have this outcome" command raw))
      (define (failure) (if open? 'failed-open 'failed-closed))
      (unless (pair? command)
        (assertion-violation 'job-event-kind "not a Command" command))
      (case (car command)
        ((look)
         (case s ((present) 'present) ((absent) 'absent) (else (bad))))
        ((begin-immediate begin)
         (case s ((ok) 'ok) ((busy) 'busy) ((failed) (failure)) (else (bad))))
        ((read-version)
         (case s
           ((ok)
            (unless (whole? v)
              (assertion-violation 'job-event-kind
                "the version read is not an exact integer" v))
            (cond ((not open?) 'failed-closed)
                  ((= v (cdr command)) 'same)
                  (else 'moved)))
           ((busy) 'busy)
           ((failed) (failure))
           (else (bad))))
        ((run-job)
         (case s
           ((returned) (if open? 'returned-open 'returned-closed))
           ((raised) (if open? 'raised-open 'raised-closed))
           (else (bad))))
        ((commit rollback)
         (case s
           ((ok) (if open? 'failed-open 'ok))
           ((busy) 'busy)
           ((failed) (failure))
           (else (bad))))
        ((close)
         (case s ((ok) 'ok) ((failed) 'failed) (else (bad))))
        (else
         (assertion-violation 'job-event-kind "no event for this command"
                              command)))))

  ;;; The carry

  ;; A Carry is what the shell holds for a job, beside the state:
  ;;   (values raised version)
  ;;   values   #f, or the list the job returned
  ;;   raised   #f, or (list obj): the FIRST object a command raised or was
  ;;            told busy with (a list, so that an object that is #f shows)
  ;;   version  #f, or the whole number the version read gave

  ;; empty-carry : Carry
  (define empty-carry (list #f #f #f))

  ;; carry-values : Carry -> (U #f (Listof Any))
  (define (carry-values c) (car c))
  ;; carry-raised : Carry -> (U #f (List Any))
  (define (carry-raised c) (cadr c))
  ;; carry-version : Carry -> (U #f Integer)
  (define (carry-version c) (caddr c))

  ;; job-carry : Carry Command RawOutcome -> Carry
  ;; Keeps the values the job returned, the first object with a status of
  ;; busy, failed or raised, and the version the version read gave. Pure:
  ;; the same carry for the same arguments.
  (define (job-carry carry command raw)
    (check-raw 'job-carry raw)
    (unless (pair? command)
      (assertion-violation 'job-carry "not a Command" command))
    (let ((s (car raw)) (v (cadr raw)))
      (list (if (and (eq? s 'returned) (eq? (car command) 'run-job))
                v
                (carry-values carry))
            (cond ((carry-raised carry) (carry-raised carry))
                  ((memq s '(busy failed raised)) (list v))
                  (else #f))
            (if (and (eq? s 'ok) (eq? (car command) 'read-version))
                v
                (carry-version carry)))))

  ;;; Machine 3: serve

  ;; serve data: (carried prints)
  (define (s-carried d) (car d))
  (define (s-prints d) (cadr d))

  ;; serve-carried : State -> (U #f Integer)
  ;; On `ended`, the exit status.
  (define (serve-carried s) (s-carried (cdr s)))
  ;; serve-prints : State -> (Listof (Pair (U 'line 'refused 'raised) Any))
  ;; What the shell prints at the end, in the order it happened.
  (define (serve-prints s) (s-prints (cdr s)))

  ;; The first thing carried wins: a later exit never replaces it.
  (define (with-exit d status print)
    (list (or (s-carried d) status)
          (append (s-prints d) (list print))))

  ;; carry-raised-obj : Integer Symbol -> Update
  ;; Carries STATUS unless a status is carried, and prints the object, under TAG.
  (define (carry-raised-obj status tag)
    (lambda (d e) (with-exit d status (cons tag (cadr e)))))

  ;; end-raised : Integer -> Update
  ;; Ends with the carried status, else STATUS, and prints the object.
  (define (end-raised status)
    (lambda (d e) (with-exit d status (cons 'raised (cadr e)))))

  ;; The order: the writer, the hasher, the readers open; the readers, the
  ;; hasher, the writer stop. A raise in an open stops what opened before
  ;; it; a raised open itself left nothing running.
  (define serve-named
    (list
     (list 'S2 'checking 'serve 'opening-writer 'open-writer same)
     (list 'S3 'checking 'refused 'ended 'end
           (lambda (d e) (with-exit d 1 (cons 'line (caddr (cadr e))))))
     (list 'S4 'opening-writer 'ok 'opening-hasher 'open-hasher same)
     (list 'S5 'opening-writer 'raised 'ended 'end (end-raised 1))
     (list 'S15 'opening-hasher 'ok 'opening-readers 'open-readers same)
     (list 'S16 'opening-hasher 'raised 'stopping-writer 'stop-writer
           (carry-raised-obj 1 'raised))
     (list 'S6 'opening-readers 'ok 'serving 'serve same)
     (list 'S7 'opening-readers 'raised 'stopping-hasher 'stop-hasher
           (carry-raised-obj 1 'raised))
     (list 'S8 'serving 'returned 'stopping-readers 'stop-readers same)
     (list 'S9 'serving 'refused-settings 'stopping-readers 'stop-readers
           (carry-raised-obj 2 'refused))
     (list 'S10 'serving 'raised 'stopping-readers 'stop-readers
           (carry-raised-obj 1 'raised))
     (list 'S11 'stopping-readers 'ok 'stopping-hasher 'stop-hasher same)
     (list 'S12 'stopping-readers 'raised 'stopping-hasher 'stop-hasher
           (carry-raised-obj 1 'raised))
     (list 'S17 'stopping-hasher 'ok 'stopping-writer 'stop-writer same)
     (list 'S18 'stopping-hasher 'raised 'stopping-writer 'stop-writer
           (carry-raised-obj 1 'raised))
     (list 'S13 'stopping-writer 'ok 'ended 'end
           (lambda (d e) (list (or (s-carried d) 0) (s-prints d))))
     (list 'S14 'stopping-writer 'raised 'ended 'end (end-raised 1))))

  ;; serve-rows : (Listof Row)
  (define serve-rows (rows-of serve-named))
  (define serve-row-names (names-of serve-named))

  (define serve-possible
    '((checking serve refused)
      (opening-writer ok raised)
      (opening-hasher ok raised)
      (opening-readers ok raised)
      (serving returned refused-settings raised)
      (stopping-readers ok raised)
      (stopping-hasher ok raised)
      (stopping-writer ok raised)))
  (define serve-event-kinds
    '(serve refused ok raised returned refused-settings))

  ;; serve-cant-happen : (Listof (List StateKind EventKind String))
  (define serve-cant-happen (cants-of serve-possible serve-event-kinds))

  ;; serve-command : State -> Command
  (define (serve-command s)
    (case (car s)
      ((checking) (list 'check))
      ((opening-writer) (list 'open-writer))
      ((opening-hasher) (list 'open-hasher))
      ((opening-readers) (list 'open-readers))
      ((serving) (list 'serve))
      ((stopping-readers) (list 'stop-readers))
      ((stopping-hasher) (list 'stop-hasher))
      ((stopping-writer) (list 'stop-writer))
      ((ended) (cons 'end (s-carried (cdr s))))
      (else (assertion-violation 'serve-command "not a state" s))))

  ;; serve-start : -> (values State Command)
  ;; The first state, `checking`, and its command, (check). There is no row
  ;; for it.
  (define (serve-start)
    (let ((s (cons 'checking (list #f '()))))
      (values s (serve-command s))))

  ;; serve-step : State Event -> (values State Command)
  ;; Event is (cons EventKind RawOutcome); see serve-event-kind.
  (define serve-step
    (let ((m (make-machine serve-rows)))
      (lambda (state event)
        (let-values (((next row-command) (machine-step m state event)))
          (let ((cmd (serve-command next)))
            (unless (eq? (car cmd) (car row-command))
              (assertion-violation 'serve-step
                "the row's command kind is not the next state's"
                (car state) (car event) (car row-command) (car cmd)))
            (values next cmd))))))

  ;; serve-event-kind : Command RawOutcome -> EventKind
  ;;   (check)        (ok verdict #f)      serve (verdict 'serve) or refused
  ;;                                       (verdict (refuse Symbol String))
  ;;   (open-writer) (open-hasher) (open-readers)
  ;;   (stop-readers) (stop-hasher) (stop-writer)
  ;;                  (ok #t #f) (raised obj #f)        ok, raised
  ;;   (serve)        (returned #t #f)     returned
  ;;                  (refused obj #f)     refused-settings
  ;;                  (raised obj #f)      raised
  ;; Anything else, and (end . _), is an assertion violation.
  (define (serve-event-kind command raw)
    (check-raw 'serve-event-kind raw)
    (let ((s (car raw)) (v (cadr raw)))
      (define (bad)
        (assertion-violation 'serve-event-kind
          "this command cannot have this outcome" command raw))
      (unless (pair? command)
        (assertion-violation 'serve-event-kind "not a Command" command))
      (case (car command)
        ((check)
         (cond ((not (eq? s 'ok)) (bad))
               ((eq? v 'serve) 'serve)
               ((and (list? v) (= (length v) 3) (eq? (car v) 'refuse)
                     (symbol? (cadr v)) (string? (caddr v)))
                'refused)
               (else (bad))))
        ((open-writer open-hasher open-readers stop-readers stop-hasher stop-writer)
         (case s ((ok) 'ok) ((raised) 'raised) (else (bad))))
        ((serve)
         (case s
           ((returned) 'returned)
           ((refused) 'refused-settings)
           ((raised) 'raised)
           (else (bad))))
        (else
         (assertion-violation 'serve-event-kind "no event for this command"
                              command)))))

  ;;; The set-up's verdict

  ;; set-up-verdict : DbFacts (Listof Migration)
  ;;                  -> (U 'serve (List 'refuse Symbol String))
  ;; What a worker's set-up decides, once it has read the file's four facts:
  ;; the answer the check machine gives, from the same table and the same
  ;; lines, so the two cannot drift.
  (define (set-up-verdict facts ms)
    (let-values (((next cmd)
                  (check-step ms (cons 'peeking '()) (list 'ok facts #f))))
      (cdr next)))

  ;;; The diagrams

  ;; doorway-document : -> String
  ;; The text of .plans/machines/doorway.md, rendered from the three tables.
  (define (doorway-document)
    (string-append
     "# The doorway machines\n\n"
     "Generated from the tables in `src/techo/transaction.sls`. Do not edit.\n"
     "Regenerate with `scripts/guix-env make machines`; "
     "a test fails when this file differs.\n\n"
     "## A write job\n\n"
     "```mermaid\n"
     (machine->mermaid (make-machine write-rows))
     "```\n\n"
     "## A read job\n\n"
     "```mermaid\n"
     (machine->mermaid (make-machine read-rows))
     "```\n\n"
     "## `techo serve`, from start to exit\n\n"
     "```mermaid\n"
     (machine->mermaid (make-machine serve-rows))
     "```\n"))
)
