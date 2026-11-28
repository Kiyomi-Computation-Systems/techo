#!r6rs
;;; (techo props): slice 6's props' doorway. Each kind's props judged
;;; before the job (the plan's review, blocker 1), the one comparison a job
;;; makes (a Task's status and closed), the text a transition and a restore
;;; store, and what an answer shows. Pure: no database, no circuit, no clock.
;;;
;;;   props-cap           4,096 bytes of the stored text (P2)
;;;   request-props       on the loop's thread: a Draft for the kind named,
;;;                       or for every kind that takes the value
;;;   draft-for           in the job: the stored kind's Draft
;;;   props-command       in the job: the text to store, or a refusal
;;;   transition-props    in the job: a Task's text after done, wontdo, reopen
;;;   restore-props       in the job: the text a restore stores (P10)
;;;   stored-props->json  an answer's props, a Task's TODO filled in
;;;
;;; A Draft is what a job is handed of a request's props: for a Project, a
;;; Journal, a Note and a Contact the canonical text, a string; for a Task
;;; an opaque record of status, closed, deadline and scheduled, each the
;;; value as sent and checked, or not given. A Task's text needs the stored
;;; status and closed, which only the job reads, so it is made there. A
;;; caller never opens a Draft: it hands one to props-command.
;;;
;;; The canonical text: no white space; each object's members in the plan's
;;; order (a Task: status, closed, deadline, scheduled; a Note: at; a
;;; Contact: (techo contact)'s); a default not stored (a Task's TODO); a
;;; Project's and a Journal's only {}; numbers exact integers; a name twice
;;; refused; a member not of the kind refused. The writer writes it, and the
;;; cap is on its bytes of UTF-8, escapes as written.
;;;
;;; The five kinds share no member name, so the one value two kinds take is
;;; {} (2 bytes): a value a kind finds valid but over the cap is taken by no
;;; other kind, and request-props answers it 'too-large before the job.
;;;
;;; What a job does here reads stored text and judges none of it (R15): the
;;; stored props were judged when written. A stored text that is not a JSON
;;; object is an assertion violation with no irritant, and so is every
;;; other raise here: no raise carries props (ADR-0013).
(library (techo props)
  (export props-cap request-props draft-for props-command transition-props restore-props
          stored-props->json)
  (import (rnrs)
          (only (jsonparse easy) string->json json->string)
          (only (techo when) parse-when)
          (only (techo contact) parse-contact-props)
          (only (techo tasks) task-statuses))

  ;; props-cap : Natural
  ;; The stored text's limit, in bytes of UTF-8 as the JSON writer writes
  ;; it: 4 KiB (P2). Raising it is always safe.
  (define props-cap 4096)

  ;; The five kinds, in (techo nodes)' order; each has its rules below.
  (define kinds '("project" "journal" "note" "task" "contact"))

  (define (kind? x) (and (string? x) (member x kinds) #t))

  ;; The largest closed, and the largest now: I-JSON's largest exact
  ;; integer, 2^53 - 1.
  (define closed-max 9007199254740991)

  (define (closed? x) (and (integer? x) (exact? x) (<= 0 x closed-max)))

  ;; none : what value-of answers for a member not given: no JSON value is it
  (define none (list 'none))

  (define (given? v) (not (eq? v none)))

  ;;; Objects, read in bounded time

  ;; at-most? : Any Natural -> Boolean
  ;; Whether X is a proper list of at most N elements. It walks at most
  ;; N + 1 pairs, however long X is.
  (define (at-most? x n)
    (cond ((null? x) #t)
          ((and (pair? x) (> n 0)) (at-most? (cdr x) (- n 1)))
          (else #f)))

  ;; named? : Any -> Boolean     a (String . value) pair
  (define (named? m) (and (pair? m) (string? (car m))))

  ;; distinct? : (Listof String) -> Boolean     no name twice; at most seven here
  (define (distinct? names)
    (or (null? names)
        (and (not (member (car names) (cdr names))) (distinct? (cdr names)))))

  ;; object-of? : Any Natural -> Boolean
  ;; Whether X is an object as the reader gives one, '() or a list of
  ;; (String . value), of at most N members, no name twice. The members are
  ;; counted before any name is read, so its work is bounded by N.
  (define (object-of? x n)
    (and (at-most? x n) (for-all named? x) (distinct? (map car x))))

  ;; value-of : Alist String -> Any     the member's value, or none
  (define (value-of x name)
    (let ((m (find (lambda (m) (string=? (car m) name)) x)))
      (if m (cdr m) none)))

  ;;; The cap

  ;; utf8-width : Natural -> Natural     the bytes of UTF-8 a code point takes
  (define (utf8-width c)
    (cond ((< c #x80) 1) ((< c #x800) 2) ((< c #x10000) 3) (else 4)))

  ;; fits? : String -> Boolean
  ;; Whether TEXT is at most props-cap bytes of UTF-8. It stops counting
  ;; once past the cap, so its work is bounded by the cap.
  (define (fits? text)
    (let ((n (string-length text)))
      (let loop ((i 0) (bytes 0))
        (cond ((> bytes props-cap) #f)
              ((= i n) #t)
              (else (loop (+ i 1) (+ bytes (utf8-width (char->integer (string-ref text i))))))))))

  ;;; Each kind's rules (the plan's "Each kind's props", P4, P5, P7, P8)

  ;; A Task's Draft: each member as sent and checked, or none.
  (define-record-type (task-draft make-task-draft task-draft?)
    (fields (immutable status draft-status)
            (immutable closed draft-closed)
            (immutable deadline draft-deadline)
            (immutable scheduled draft-scheduled))
    (opaque #t)
    (sealed #t))

  ;; Verdict = (U Draft 'invalid 'too-large)

  ;; capped : String -> (U String 'too-large)
  (define (capped text) (if (fits? text) text 'too-large))

  ;; empty-verdict : Any -> Verdict     a Project's and a Journal's: {} alone
  (define (empty-verdict v) (if (null? v) "{}" 'invalid))

  ;; note-verdict : Any -> Verdict     {} or {"at": When}
  (define (note-verdict v)
    (cond ((null? v) "{}")
          ((object-of? v 1)
           (let ((at (value-of v "at")))
             (if (given? at)
                 (let ((w (parse-when at)))
                   (if (string? w) (capped (json->string (list (cons "at" w)))) 'invalid))
                 'invalid)))
          (else 'invalid)))

  (define task-members '("status" "closed" "deadline" "scheduled"))

  ;; when-or-none : Any -> (U String 'invalid none)     a When member's value checked
  (define (when-or-none v)
    (if (given? v)
        (let ((w (parse-when v))) (if (string? w) w 'invalid))
        none))

  ;; task-verdict : Any Boolean -> Verdict
  ;; At most the four members, each once: status one of task-statuses;
  ;; closed an exact integer, 0 to 2^53 - 1; deadline and scheduled Whens.
  ;; On a create, closed with a status of TODO, given or by default, is
  ;; invalid: a create names its kind, so this is known before the job.
  (define (task-verdict v create?)
    (if (and (object-of? v 4) (for-all (lambda (m) (member (car m) task-members)) v))
        (let ((status (value-of v "status"))
              (closed (value-of v "closed"))
              (deadline (when-or-none (value-of v "deadline")))
              (scheduled (when-or-none (value-of v "scheduled"))))
          (cond ((and (given? status) (not (member status task-statuses))) 'invalid)
                ((and (given? closed) (not (closed? closed))) 'invalid)
                ((or (eq? deadline 'invalid) (eq? scheduled 'invalid)) 'invalid)
                ((and create? (given? closed) (or (not (given? status)) (equal? status "TODO")))
                 'invalid)
                (else (make-task-draft status closed deadline scheduled))))
        'invalid))

  ;; contact-verdict : Any -> Verdict     (techo contact)'s value, written
  (define (contact-verdict v)
    (let ((c (parse-contact-props v)))
      (if (eq? c 'invalid) 'invalid (capped (json->string c)))))

  ;; verdict : String Any Boolean -> Verdict
  (define (verdict kind v create?)
    (cond ((string=? kind "project") (empty-verdict v))
          ((string=? kind "journal") (empty-verdict v))
          ((string=? kind "note") (note-verdict v))
          ((string=? kind "task") (task-verdict v create?))
          (else (contact-verdict v))))

  ;; all-verdicts : Any -> (U (Listof (Pair String Draft)) 'invalid 'too-large)
  ;; A replace that names no kind: every kind that takes V, in the kinds'
  ;; order, with its Draft; else 'too-large when a kind found it valid but
  ;; over the cap; else 'invalid.
  (define (all-verdicts v)
    (let* ((verdicts (map (lambda (k) (cons k (verdict k v #f))) kinds))
           (taken (filter (lambda (p) (not (symbol? (cdr p)))) verdicts)))
      (cond ((pair? taken) taken)
            ((exists (lambda (p) (eq? (cdr p) 'too-large)) verdicts) 'too-large)
            (else 'invalid))))

  ;;; Before the job

  ;; request-props : Alist Boolean -> (U (Listof (Pair String Draft)) 'invalid 'too-large 'absent)
  ;; The request's whole object, as parse-content took it, and whether this
  ;; is a create. Its kind and props are read from it:
  ;;   - a kind named: that kind's Draft, as a list of one pair;
  ;;   - a replace naming none: every kind that takes the value, in the
  ;;     kinds' order, each with its Draft;
  ;;   - a replace with no props: 'absent (P11). A create with none is as {}.
  ;; 'too-large when no kind in question takes the value and one finds it
  ;; valid but over props-cap; else 'invalid. 'invalid too for what
  ;; parse-content refuses: no object of at most seven members (a create's
  ;; kind, title, body, content_type, props, tags and parent; slice 7a), a
  ;; create with no kind, a kind not of the five, props that are no object,
  ;; create? that is no boolean. Never raises. Linear in the value's size: every
  ;; object's members are counted against its bound before any name is
  ;; read ((techo contact) does the same for a Contact's), and only a value
  ;; that passes is written, once.
  (define (request-props x create?)
    (if (and (boolean? create?) (object-of? x 7))
        (let ((kind (value-of x "kind"))
              (props (value-of x "props")))
          (cond ((and (given? kind) (not (kind? kind))) 'invalid)
                ((and create? (not (given? kind))) 'invalid)
                ((and (not create?) (not (given? props))) 'absent)
                (else
                 (let ((v (if (given? props) props '())))
                   (if (given? kind)
                       (let ((d (verdict kind v create?)))
                         (if (symbol? d) d (list (cons kind d))))
                       (all-verdicts v))))))
        'invalid))

  ;;; In the job

  ;; drafts? : Any -> Boolean     a list of (kind . Draft), as request-props answers
  (define (drafts? x)
    (and (list? x) (for-all (lambda (p) (and (pair? p) (kind? (car p)))) x)))

  ;; draft-for : (U (Listof (Pair String Draft)) 'absent) String -> (U Draft 'absent #f)
  ;; From request-props' answer, when it is no refusal, and the stored kind
  ;; (on a create, the kind made): that kind's Draft; 'absent for 'absent;
  ;; #f when the request's props suit no Draft of that kind. What
  ;; props-command takes. An assertion violation, with no irritant, for a
  ;; refusal (which is answered before the job) or what is no kind.
  (define (draft-for drafts kind)
    (unless (and (kind? kind) (or (eq? drafts 'absent) (drafts? drafts)))
      (assertion-violation 'draft-for "not request-props' Drafts and a kind"))
    (if (eq? drafts 'absent)
        'absent
        (let ((p (assoc kind drafts))) (if p (cdr p) #f))))

  ;; stored-object : Symbol Any -> Alist
  ;; Stored props read: the JSON object the text holds. An assertion
  ;; violation, who WHO, with no irritant, for anything else: what is no
  ;; text, no JSON, or JSON but no object. The reader's own raise, which
  ;; names an offset, is not passed on.
  (define (stored-object who text)
    (let ((x (and (string? text) (guard (e (#t #f)) (string->json text)))))
      (if (or (null? x) (pair? x))
          x
          (assertion-violation who "stored props are not a JSON object"))))

  ;; stored-task : Symbol String -> (values Any Any Any Any)
  ;; A Task's stored status, the default TODO filled in, then its closed,
  ;; deadline and scheduled, each none when not stored. Read, not judged.
  (define (stored-task who text)
    (let* ((x (stored-object who text))
           (status (value-of x "status")))
      (values (if (given? status) status "TODO")
              (value-of x "closed") (value-of x "deadline") (value-of x "scheduled"))))

  ;; task-text : Any Any Any Any -> String
  ;; A Task's canonical text: status, but not TODO, the default; closed,
  ;; deadline and scheduled when given.
  (define (task-text status closed deadline scheduled)
    (json->string
     (append (if (equal? status "TODO") '() (list (cons "status" status)))
             (if (given? closed) (list (cons "closed" closed)) '())
             (if (given? deadline) (list (cons "deadline" deadline)) '())
             (if (given? scheduled) (list (cons "scheduled" scheduled)) '()))))

  ;; written : String -> (U (Pair 'write String) 'refuse-props-too-large)
  (define (written text) (if (fits? text) (cons 'write text) 'refuse-props-too-large))

  ;; props-command : String (U Draft 'absent #f) (U String #f) Boolean Natural
  ;;                 -> (U (Pair 'write String) Symbol)
  ;; In the job, after node-command's answer is write or insert: the stored
  ;; kind (on a create, the kind made), its Draft as draft-for gives it, the
  ;; stored props text (#f on a create), whether this is a create, and now,
  ;; the write's time in milliseconds. Answers ('write . text), the
  ;; canonical text to store, or a refusal:
  ;;   #f                      refuse-invalid-props: the request's props
  ;;                           suit another kind, not this one
  ;;   'absent (a replace)     the stored text, kept whole (P11)
  ;;   a Task's, a create      the status given, TODO by default and not
  ;;                           stored; when it is not TODO, closed as given
  ;;                           (P14) or now
  ;;   a Task's, a replace     a claim of status or closed, when given, must
  ;;                           equal the stored one, TODO filled in for a
  ;;                           status not stored, by eqv? (5 is not 5.0):
  ;;                           else refuse-status-fixed. The stored status
  ;;                           and closed are kept; deadline and scheduled
  ;;                           are what was sent, absent ones removed
  ;;   another kind's          the Draft's text
  ;; and refuse-props-too-large for a text to store over props-cap, which
  ;; request-props' Drafts never give: the largest Task's text is 114 bytes.
  ;; It compares and judges nothing else (R15). An assertion violation, who
  ;; props-command, with no irritant, for a call that cannot happen: a kind
  ;; not of the five, create? no boolean, stored props on a create or none
  ;; on a replace, now no exact integer from 0 to 2^53 - 1, absent props on
  ;; a create, a Draft not of the kind; and for stored text that is no JSON
  ;; object.
  (define (props-command kind draft stored create? now)
    (define (bad what) (assertion-violation 'props-command what))
    (unless (kind? kind) (bad "a kind is one of the five"))
    (unless (boolean? create?) (bad "whether a create is a boolean"))
    (unless (if create? (not stored) (string? stored))
      (bad "a create has no stored props, and a replace has them"))
    (unless (closed? now) (bad "now is whole milliseconds from 0 to 2^53 - 1"))
    (cond ((not draft) 'refuse-invalid-props)
          ((eq? draft 'absent)
           (if create? (bad "a create's props are never absent") (cons 'write stored)))
          ((string=? kind "task")
           (unless (task-draft? draft)
             (bad "a Draft is the kind's: a Task's for a Task, a text for another"))
           (if create? (task-create draft now) (task-replace draft stored)))
          (else
           (unless (string? draft)
             (bad "a Draft is the kind's: a Task's for a Task, a text for another"))
           (written draft))))

  ;; task-create : TaskDraft Natural -> (U (Pair 'write String) Symbol)
  (define (task-create d now)
    (let ((status (if (given? (draft-status d)) (draft-status d) "TODO"))
          (closed (draft-closed d)))
      (cond ((not (string=? status "TODO"))
             (written (task-text status (if (given? closed) closed now)
                                 (draft-deadline d) (draft-scheduled d))))
            ((given? closed) 'refuse-invalid-props)
            (else (written (task-text status none (draft-deadline d) (draft-scheduled d)))))))

  ;; task-replace : TaskDraft String -> (U (Pair 'write String) Symbol)
  (define (task-replace d stored)
    (let-values (((status closed deadline scheduled) (stored-task 'props-command stored)))
      (if (or (and (given? (draft-status d)) (not (equal? (draft-status d) status)))
              (and (given? (draft-closed d))
                   (not (and (given? closed) (eqv? (draft-closed d) closed)))))
          'refuse-status-fixed
          (written (task-text status closed (draft-deadline d) (draft-scheduled d))))))

  ;; transition-props : String Symbol Symbol Natural -> String
  ;; A Task's stored text, the next status and the command task-step named
  ;; (close, keep or open), and now: the new canonical text. close sets
  ;; closed to now, keep leaves it, open removes it; deadline and scheduled
  ;; are kept; a status of TODO is not stored. An assertion violation, who
  ;; transition-props, with no irritant, for a status and a command that do
  ;; not go together (open lands on TODO; close and keep on DONE or
  ;; WONTDO), now no exact integer from 0 to 2^53 - 1, and stored text that
  ;; is no JSON object.
  (define (transition-props stored next command now)
    (define (bad what) (assertion-violation 'transition-props what))
    (unless (or (and (memq next '(DONE WONTDO)) (memq command '(close keep)))
                (and (eq? next 'TODO) (eq? command 'open)))
      (bad "not a task's next status and command"))
    (unless (closed? now) (bad "now is whole milliseconds from 0 to 2^53 - 1"))
    (let-values (((status closed deadline scheduled) (stored-task 'transition-props stored)))
      (task-text (symbol->string next)
                 (case command ((close) now) ((keep) closed) (else none))
                 deadline scheduled)))

  ;; restore-props : String String String -> String
  ;; The node's kind, the snapshot's props text and the node's stored props
  ;; text: what a restore stores. For a Task, the snapshot's deadline and
  ;; scheduled with the stored status and closed (P10: only a command
  ;; changes a status); for another kind, the snapshot's text. An assertion
  ;; violation, who restore-props, with no irritant, for a kind not of the
  ;; five, a snapshot's props that are no text, and a Task's stored or
  ;; snapshot text that is no JSON object.
  (define (restore-props kind snapshot stored)
    (unless (kind? kind) (assertion-violation 'restore-props "a kind is one of the five"))
    (cond ((string=? kind "task")
           (let*-values (((s c deadline scheduled) (stored-task 'restore-props snapshot))
                         ((status closed d2 s2) (stored-task 'restore-props stored)))
             (task-text status closed deadline scheduled)))
          ((string? snapshot) snapshot)
          (else (assertion-violation 'restore-props "a snapshot's props are a text"))))

  ;;; Answers

  ;; stored-props->json : String String -> Alist
  ;; A kind and a stored props text: the value an answer shows, as the JSON
  ;; writer takes it. It fills in a Task's status, "TODO", first, when it is
  ;; not stored, and nothing else: JSContact's defaults are the RFC's to
  ;; imply. So a Task stored {} reads as {"status":"TODO"} (P9). An
  ;; assertion violation, who stored-props->json, with no irritant, for a
  ;; kind not of the five and for text that is no JSON object.
  (define (stored-props->json kind text)
    (unless (kind? kind) (assertion-violation 'stored-props->json "a kind is one of the five"))
    (let ((x (stored-object 'stored-props->json text)))
      (if (and (string=? kind "task") (not (given? (value-of x "status"))))
          (cons (cons "status" "TODO") x)
          x)))
)
