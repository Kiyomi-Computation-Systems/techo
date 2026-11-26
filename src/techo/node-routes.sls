#!r6rs
;;; (techo node-routes): the node routes, slice 4's (D3) and slice 4b's
;;; lifecycle (L3, L6). The imperative shell.
;;;
;;;   PUT    /v1/nodes/:id                       create, with If-None-Match: * (201),
;;;                                              or replace, with If-Match: "N" (200)
;;;   GET    /v1/nodes/:id                       the node, with its ETag
;;;   DELETE /v1/nodes/:id                       purge, with If-Match: "N" (204, no body)
;;;   GET    /v1/nodes?state=                    the account's nodes in one state (active
;;;                                              unless named), paged, no bodies
;;;   GET    /v1/nodes/:id/revisions             its snapshots, newest first, no bodies
;;;   GET    /v1/nodes/:id/revisions/:n          one snapshot, whole
;;;   POST   /v1/nodes/:id/revisions/:n/restore  snapshot n copied as a new revision (200)
;;;   POST   /v1/nodes/:id/archive               a state change, with If-Match: "N": 200,
;;;   POST   /v1/nodes/:id/unarchive             the node without its body, and its ETag
;;;   POST   /v1/nodes/:id/trash
;;;   POST   /v1/nodes/:id/untrash
;;;
;;; Each handler is exactly one call of (techo auth): the PUT's is
;;; db-write-with-body-as, so no body is read before its key is known to be
;;; good; each of the others' is db-read-as or db-write-as. On the loop's
;;; thread, the prepare thunk makes the cheap checks, and the PUT's Reader
;;; reads the body once the key has passed, so the order of checks is:
;;;
;;;   1. the key's shape (401), by (techo auth) itself, with no job;
;;;   2. the path's id, the path's revision, `limit`, `after`, `state` (400);
;;;   3. the preconditions: 428 for none, 400 for a bad shape;
;;;   4. a PUT's key (401), by a read job of its own;
;;;   5. a PUT's Content-Type (415), then its body under request-cap
;;;      through wrap-json-body (413; 400 invalid_json for JSON that does
;;;      not parse), then parse-content (400; 413 for a body over body-cap);
;;;   6. the job: the key (401; a PUT's again, as it may have been revoked
;;;      while the body came), then the work.
;;;
;;; A PUT's time is read once its body has come, so a slow upload is
;;; stamped with when it arrived; a restore and a state change, with no
;;; body, read it first. Neither reads a body or a Content-Type.
;;;
;;; A write's work finds the node (its revision, kind and state, or none),
;;; names the event, asks (techo nodes)' node-command, by which the write's
;;; table and the lifecycle's answer it, and performs the command it names:
;;; insert, write, copy, set-state or purge, or a refusal raised as a
;;; &refusal, so the job rolls back, the key's last_used with it. The
;;; answer follows from the command alone; the handler decides none of its
;;; own (ADR-0007). A missing node on a read is a &refusal too. A state is
;;; a symbol in (techo nodes) and a string in the store; the work converts.
;;;
;;; A node's answer shows its stored state. A purged node is never found:
;;; the store leaves it out of every read, so it is a 404, and a create on
;;; its id a 412.
;;;
;;; A job's work closes over plain data only: the id, the precondition, the
;;; five content values, the path's revision, the event, the time. Never
;;; the request, never the parsed JSON. Nothing waits in a job: the body is
;;; read in the PUT's Reader, between its two jobs. Nothing raised here
;;; carries a title or a body. The database is reached only through
;;; db-read-as, db-write-as, db-write-with-body-as and (techo node-store).
(library (techo node-routes)
  (export node-routes)
  (import (rnrs)
          (only (circuit) make-res res-set-header req-header-values)
          (only (circuit json) make-json-res wrap-json-body req-json? req-json)
          (only (circuit router) route GET PUT POST DELETE req-path-param)
          (only (techo errors) problem-res make-refusal)
          (only (techo keys) parse-limit)
          (only (techo store) account-id)
          (only (techo auth) make-plan db-read-as db-write-as db-write-with-body-as)
          (only (techo requests) query-one take json-type? bad-request)
          (only (techo nodes) request-cap parse-node-id node-id->string parse-revision etag
                precondition parse-content content-kind content-title content-body
                content-content-type content-props found found-for-create write-event
                node-command node-state->string string->node-state parse-state-param event-op)
          (only (techo node-store) node-in-use? node-head node-of-owner nodes-page
                snapshot-exists? snapshot-of snapshots-page insert-node! write-node!
                set-node-state! purge-node!
                node-id node-kind node-title node-body node-content-type node-props
                node-revision node-created node-updated node-state
                snapshot-revision snapshot-title snapshot-body snapshot-content-type
                snapshot-props snapshot-created))

  ;; Runner = ((Tx -> Any) -> Any)
  ;; Clock = (-> Integer)

  ;;; Answers

  ;; props->json : String -> Alist
  ;; The stored props as a JSON value: always the text "{}" in this slice,
  ;; the empty object. Any other text is an assertion violation, with no
  ;; irritant: slice 6 decides props, and this changes with it.
  (define (props->json text)
    (if (string=? text "{}")
        '()
        (assertion-violation 'node-routes "stored props other than {} before slice 6")))

  ;; node->json : Node Boolean -> Alist
  ;; id (lower case), kind, state (the stored one), title, body when BODY?,
  ;; content_type, props, revision, created, updated. Never num, the owner
  ;; or the author.
  (define (node->json n body?)
    (append (list (cons "id" (node-id->string (node-id n)))
                  (cons "kind" (node-kind n))
                  (cons "state" (node-state n))
                  (cons "title" (node-title n)))
            (if body? (list (cons "body" (node-body n))) '())
            (list (cons "content_type" (node-content-type n))
                  (cons "props" (props->json (node-props n)))
                  (cons "revision" (node-revision n))
                  (cons "created" (node-created n))
                  (cons "updated" (node-updated n)))))

  ;; snapshot->json : Snapshot Boolean -> Alist
  ;; revision, title, body when BODY?, content_type, props, created.
  (define (snapshot->json s body?)
    (append (list (cons "revision" (snapshot-revision s))
                  (cons "title" (snapshot-title s)))
            (if body? (list (cons "body" (snapshot-body s))) '())
            (list (cons "content_type" (snapshot-content-type s))
                  (cons "props" (props->json (snapshot-props s)))
                  (cons "created" (snapshot-created s)))))

  ;; node-answer : Natural Node -> Res     STATUS, the node whole, its ETag
  (define (node-answer status n)
    (res-set-header (make-json-res status (node->json n #t)) "etag" (etag (node-revision n))))

  ;; page-answer : Natural (A -> Alist) (A -> Any) -> ((Listof A) -> Res)
  ;; ROWS is what the store gave for LIMIT + 1: a row past LIMIT says there
  ;; is a next page, which starts after the last row shown, NEXT of it.
  (define (page-answer limit ->json next-of)
    (lambda (rows)
      (let ((shown (take rows limit)))
        (make-json-res 200
                       (list (cons "items" (list->vector (map ->json shown)))
                             (cons "next" (if (> (length rows) limit)
                                              (next-of (car (reverse shown)))
                                              'null)))))))

  ;; written : (Pair CommandKind (U Node #f)) -> Res
  ;; A write's answer, by the command its job performed: insert is 201 with
  ;; Location, the id in lower case; write and copy are 200, each with the
  ;; node whole and its ETag; set-state is 200, the node without its body
  ;; (the client has it, and the job read none), and its ETag; purge is
  ;; 204, no body and no ETag, as nothing is left to tag. Any other
  ;; command is an assertion violation.
  (define (written outcome)
    (let ((command (car outcome)) (n (cdr outcome)))
      (case command
        ((insert) (res-set-header (node-answer 201 n) "location"
                                  (string-append "/v1/nodes/" (node-id->string (node-id n)))))
        ((write copy) (node-answer 200 n))
        ((set-state) (res-set-header (make-json-res 200 (node->json n #f))
                                     "etag" (etag (node-revision n))))
        ((purge) (make-res 204 '() #f))
        (else (assertion-violation 'node-routes "a write's answer has no such command" command)))))

  ;;; The work of a write, in its job

  ;; refusal-codes : (Listof (Pair CommandKind Symbol))
  (define refusal-codes
    '((refuse-404 . not_found) (refuse-409 . kind_fixed) (refuse-412 . precondition_failed)
      (refuse-wrong-state . wrong_state)))

  ;; refuse : CommandKind Bytevector -> !
  ;; The refusal COMMAND names, raised as a &refusal for OWNER, so the job
  ;; rolls back. It carries the code and the account only.
  (define (refuse command owner)
    (raise (make-refusal (cdr (assq command refusal-codes)) owner)))

  ;; Head = (List Natural String String)     node-head's revision, kind and state

  ;; head-state : (U Head #f) -> (U Symbol #f)
  ;; The stored state as (techo nodes) names it; #f for no node.
  (define (head-state head)
    (and head (string->node-state (caddr head))))

  ;; put-work : Bytevector Precondition (U String #f) String String String String Natural
  ;;            -> Work
  ;; A PUT's work: what the job found (node-in-use? for a create, node-head
  ;; for a replace), the stored state, the event, node-command, and the
  ;; command it names performed. Answers the command and the node; a
  ;; refusal is raised. A command a PUT has no action for is an assertion
  ;; violation.
  (define (put-work id pre kind title body type props now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (head (and (not (eq? pre 'create)) (node-head tx owner id)))
             (found-kind (if (eq? pre 'create)
                             (found-for-create (node-in-use? tx id))
                             (found (and head (car head)) pre)))
             (event (write-event 'put pre kind (and head (cadr head)) #f)))
        (let-values (((command next) (node-command found-kind (head-state head) event)))
          (case command
            ((insert) (cons command (insert-node! tx id owner kind title body type props now)))
            ((write) (cons command (write-node! tx id owner pre title body type props "update" now)))
            ((refuse-404 refuse-409 refuse-412 refuse-wrong-state) (refuse command owner))
            (else (assertion-violation 'node-routes "a PUT has no action for this command"
                                       command)))))))

  ;; restore-work : Bytevector Natural Natural Natural -> Work
  ;; A restore's work: the node's head and what was found; whether the node
  ;; has snapshot N, asked by snapshot-exists? whenever a node was found, at
  ;; the revision given or another, so the event is restore when it has it;
  ;; restore-unknown when no node was found (none x restore cannot happen);
  ;; node-command, with the stored state; and the command performed. Only
  ;; copy reads the snapshot whole, and writes its title, body, content
  ;; type and props as the next revision.
  (define (restore-work id pre n now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (head (node-head tx owner id))
             (found-kind (found (and head (car head)) pre))
             (event (write-event 'restore pre #f #f (and head (snapshot-exists? tx owner id n)))))
        (let-values (((command next) (node-command found-kind (head-state head) event)))
          (case command
            ((copy)
             (let ((snap (snapshot-of tx owner id n)))
               (cons command
                     (write-node! tx id owner pre (snapshot-title snap) (snapshot-body snap)
                                  (snapshot-content-type snap) (snapshot-props snap) "restore"
                                  now))))
            ((refuse-404 refuse-412 refuse-wrong-state) (refuse command owner))
            (else (assertion-violation 'node-routes "a restore has no action for this command"
                                       command)))))))

  ;; lifecycle-work : Bytevector Natural Symbol Natural -> Work
  ;; A state change's or a purge's work: the node's head and what was
  ;; found, node-command with the stored state and EVENT, one of
  ;; lifecycle-events, and the command performed. set-state stores the state
  ;; node-command names, with EVENT's op, and answers the node as it now is,
  ;; with no body; purge empties the node and answers #f. Neither writes or
  ;; reads a snapshot's body.
  (define (lifecycle-work id pre event now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (head (node-head tx owner id)))
        (let-values (((command next)
                      (node-command (found (and head (car head)) pre) (head-state head) event)))
          (case command
            ((set-state)
             (cons command (set-node-state! tx id owner pre (node-state->string next)
                                            (event-op event) now)))
            ((purge) (purge-node! tx id owner pre now) (cons command #f))
            ((refuse-404 refuse-412 refuse-wrong-state) (refuse command owner))
            (else (assertion-violation 'node-routes "a state change has no action for this command"
                                       command)))))))

  ;;; The work of a read, in its job

  ;; missing : Bytevector -> !     the 404, raised as a &refusal for OWNER
  (define (missing owner) (raise (make-refusal 'not_found owner)))

  ;; node-work : Bytevector -> Work
  (define (node-work id)
    (lambda (tx account key)
      (let ((owner (account-id account)))
        (or (node-of-owner tx owner id) (missing owner)))))

  ;; nodes-work : Symbol (U Bytevector #f) Natural -> Work     STATE's page
  (define (nodes-work state after limit)
    (lambda (tx account key)
      (nodes-page tx (account-id account) (node-state->string state) after (+ limit 1))))

  ;; revisions-work : Bytevector (U Natural #f) Natural -> Work
  ;; The node first: a missing one is the 404, not an empty page.
  (define (revisions-work id before limit)
    (lambda (tx account key)
      (let ((owner (account-id account)))
        (if (node-head tx owner id)
            (snapshots-page tx owner id before (+ limit 1))
            (missing owner)))))

  ;; snapshot-work : Bytevector Natural -> Work
  (define (snapshot-work id n)
    (lambda (tx account key)
      (let ((owner (account-id account)))
        (or (snapshot-of tx owner id n) (missing owner)))))

  ;;; The PUT's upload

  ;; Upload : what a PUT's Reader hands on, read on the loop's thread: the
  ;; node's id, the precondition and the parsed content.
  (define-record-type upload (fields id pre content))

  ;; put-plan : Upload Natural -> Plan
  ;; The PUT's plan, of what its Reader read and NOW, the time read once
  ;; the body had come: its work closed over the id, the precondition, the
  ;; five content values and NOW alone.
  (define (put-plan u now)
    (let ((c (upload-content u)))
      (make-plan (put-work (upload-id u) (upload-pre u) (content-kind c) (content-title c)
                           (content-body c) (content-content-type c) (content-props c) now)
                 written)))

  ;;; The routes

  ;; node-routes : Runner Runner (-> Natural) Clock -> (Listof Route)
  ;; The routes the header lists, for make-router. READ and WRITE
  ;; run a job each; WALL-CLOCK is whole milliseconds since 1970, UTC;
  ;; CLOCK reads milliseconds for db_ms. Both clocks are read on the loop's
  ;; thread only.
  (define (node-routes read write wall-clock clock)

    ;; path-id : Req -> (U Bytevector 'invalid)
    (define (path-id req) (parse-node-id (req-path-param req "id")))

    ;; path-revision : Req -> (U Natural 'invalid)
    (define (path-revision req) (parse-revision (req-path-param req "n")))

    ;; json-body : Middleware     the PUT's body, under request-cap
    (define json-body (wrap-json-body request-cap))

    ;; preconditions : Req -> (U Precondition 'missing 'invalid)
    (define (preconditions req)
      (precondition (req-header-values req "if-match") (req-header-values req "if-none-match")))

    ;; query-after : Req (String -> (U A 'invalid)) -> (U A #f 'invalid)
    (define (query-after req parse)
      (let ((a (query-one req "after")))
        (if a (parse a) #f)))

    ;; put-content : Req Bytevector Precondition -> (U Res Upload)
    ;; The body wrap-json-body read: no JSON (an empty body) or what
    ;; parse-content refuses is 400; a body over body-cap is 413. Else the
    ;; upload: the id, the precondition and the content.
    (define (put-content r id pre)
      (let ((c (if (req-json? r) (parse-content (req-json r) (eq? pre 'create)) 'invalid)))
        (cond ((eq? c 'invalid) (bad-request))
              ((eq? c 'too-large) (problem-res 'payload_too_large))
              (else (make-upload id pre c)))))

    ;; put-body : Req Bytevector Precondition -> (U Res Upload)
    ;; The body under the cap, as login's handler reads it: wrap-json-body's
    ;; plain 400 for JSON that does not parse, answered before its handler
    ;; ran, is invalid_json here; past the cap it raises the 413.
    (define (put-body req id pre)
      (let* ((ran? #f)
             (step ((json-body (lambda (r) (set! ran? #t) (put-content r id pre))) req)))
        (if ran? step (problem-res 'invalid_json))))

    ;; PUT /v1/nodes/:id
    ;; prepare checks the id and the preconditions; its Reader, called once
    ;; the key has passed, the media type and the body.
    (define (put-node req)
      (db-write-with-body-as read write clock wall-clock req
                             (lambda ()
                               (let ((id (path-id req)))
                                 (if (eq? id 'invalid)
                                     (bad-request)
                                     (let ((pre (preconditions req)))
                                       (cond ((eq? pre 'missing) (problem-res 'precondition_required))
                                             ((eq? pre 'invalid) (bad-request))
                                             (else (lambda ()
                                                     (if (json-type? req)
                                                         (put-body req id pre)
                                                         (problem-res 'unsupported_media_type)))))))))
                             put-plan))

    ;; revision-plan : Req (Natural -> Work) -> (U Res Plan)
    ;; A write with no body: REQ's If-Match, one revision, handed to
    ;; WORK-OF for the plan's work. None is the 428; If-None-Match (a
    ;; create's), or any other shape, is the 400.
    (define (revision-plan req work-of)
      (let ((pre (preconditions req)))
        (cond ((eq? pre 'missing) (problem-res 'precondition_required))
              ((or (eq? pre 'invalid) (eq? pre 'create)) (bad-request))
              (else (make-plan (work-of pre) written)))))

    ;; POST /v1/nodes/:id/revisions/:n/restore
    ;; No body is read, and no Content-Type looked at.
    (define (restore-node req)
      (let ((now (wall-clock)))
        (db-write-as write clock now req
                     (lambda ()
                       (let ((id (path-id req))
                             (n (path-revision req)))
                         (if (or (eq? id 'invalid) (eq? n 'invalid))
                             (bad-request)
                             (revision-plan req (lambda (pre) (restore-work id pre n now)))))))))

    ;; lifecycle : Symbol -> Handler
    ;; EVENT's route: POST /v1/nodes/:id/archive, /unarchive, /trash and
    ;; /untrash, and DELETE /v1/nodes/:id for purge. The id, then the
    ;; precondition, as a restore's; no body is read, and no Content-Type
    ;; looked at.
    (define (lifecycle event)
      (lambda (req)
        (let ((now (wall-clock)))
          (db-write-as write clock now req
                       (lambda ()
                         (let ((id (path-id req)))
                           (if (eq? id 'invalid)
                               (bad-request)
                               (revision-plan req (lambda (pre)
                                                    (lifecycle-work id pre event now))))))))))

    ;; GET /v1/nodes/:id
    (define (get-node req)
      (db-read-as read clock req
                  (lambda ()
                    (let ((id (path-id req)))
                      (if (eq? id 'invalid)
                          (bad-request)
                          (make-plan (node-work id) (lambda (n) (node-answer 200 n))))))))

    ;; GET /v1/nodes?limit=&after=&state=
    ;; state is one of active, archived and trashed, active when not given.
    (define (list-nodes req)
      (db-read-as read clock req
                  (lambda ()
                    (let ((limit (parse-limit (query-one req "limit")))
                          (after (query-after req parse-node-id))
                          (state (parse-state-param (query-one req "state"))))
                      (if (or (eq? limit 'invalid) (eq? after 'invalid) (eq? state 'invalid))
                          (bad-request)
                          (make-plan (nodes-work state after limit)
                                     (page-answer limit
                                                  (lambda (n) (node->json n #f))
                                                  (lambda (n) (node-id->string (node-id n))))))))))

    ;; GET /v1/nodes/:id/revisions?limit=&after=
    (define (list-revisions req)
      (db-read-as read clock req
                  (lambda ()
                    (let ((id (path-id req))
                          (limit (parse-limit (query-one req "limit")))
                          (after (query-after req parse-revision)))
                      (if (or (eq? id 'invalid) (eq? limit 'invalid) (eq? after 'invalid))
                          (bad-request)
                          (make-plan (revisions-work id after limit)
                                     (page-answer limit
                                                  (lambda (s) (snapshot->json s #f))
                                                  snapshot-revision)))))))

    ;; GET /v1/nodes/:id/revisions/:n
    (define (get-revision req)
      (db-read-as read clock req
                  (lambda ()
                    (let ((id (path-id req))
                          (n (path-revision req)))
                      (if (or (eq? id 'invalid) (eq? n 'invalid))
                          (bad-request)
                          (make-plan (snapshot-work id n)
                                     (lambda (s) (make-json-res 200 (snapshot->json s #t)))))))))

    (list (route "/v1/nodes" (GET list-nodes))
          (route "/v1/nodes/:id" (GET get-node) (PUT put-node) (DELETE (lifecycle 'purge)))
          (route "/v1/nodes/:id/archive" (POST (lifecycle 'archive)))
          (route "/v1/nodes/:id/unarchive" (POST (lifecycle 'unarchive)))
          (route "/v1/nodes/:id/trash" (POST (lifecycle 'trash)))
          (route "/v1/nodes/:id/untrash" (POST (lifecycle 'untrash)))
          (route "/v1/nodes/:id/revisions" (GET list-revisions))
          (route "/v1/nodes/:id/revisions/:n" (GET get-revision))
          (route "/v1/nodes/:id/revisions/:n/restore" (POST restore-node))))
)
