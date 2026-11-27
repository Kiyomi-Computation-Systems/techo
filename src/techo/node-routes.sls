#!r6rs
;;; (techo node-routes): the node routes, slice 4's (D3), slice 4b's
;;; lifecycle (L3, L6), slice 5a's tree (T3, T4, T7, T9) and slice 5b's
;;; links (K3). The imperative shell.
;;;
;;;   PUT    /v1/nodes/:id                       create, with If-None-Match: * (201), under
;;;                                              the JSON's parent when it names one;
;;;                                              or replace, with If-Match: "N" (200)
;;;   GET    /v1/nodes/:id                       the node, with its ETag
;;;   DELETE /v1/nodes/:id                       purge, with If-Match: "N" (204, no body)
;;;   GET    /v1/nodes?state=&parent=            the account's nodes in one state (active
;;;                                              unless named): all of them, a node's
;;;                                              children, or the top level (null); paged,
;;;                                              no bodies
;;;   GET    /v1/nodes/:id/revisions             its snapshots, newest first, no bodies
;;;   GET    /v1/nodes/:id/revisions/:n          one snapshot, whole
;;;   POST   /v1/nodes/:id/revisions/:n/restore  snapshot n copied as a new revision (200)
;;;   POST   /v1/nodes/:id/archive               a state change, with If-Match: "N": 200,
;;;   POST   /v1/nodes/:id/unarchive             the node without its body, and its ETag
;;;   POST   /v1/nodes/:id/trash
;;;   POST   /v1/nodes/:id/untrash
;;;   POST   /v1/nodes/:id/move                  {"parent": id or null}, with If-Match: "N":
;;;                                              200, the node without its body, its ETag
;;;   POST   /v1/nodes/:id/move-children         {"parent": id or null}, with the node's
;;;                                              If-Match: "N": 200, {"moved": N, "left": M},
;;;                                              no ETag
;;;   PUT    /v1/nodes/:id/links/:type/:target   make the link from :id to :target: 201 and
;;;                                              the link when made, 200 and the link, its
;;;                                              stored created, when it was there
;;;   DELETE /v1/nodes/:id/links/:type/:target   remove it: 204, no body
;;;   GET    /v1/nodes/:id/links?direction=&type= the node's links, out (unless named) or
;;;                                              in, of one type or all; paged, each item
;;;                                              {"type", "created", "node"}: the other
;;;                                              node without its body
;;;
;;; Every node in an answer has its parent after its state: the id, or
;;; null at the top level. A snapshot has none. A link in an answer is
;;; {"source": id, "type": name, "target": id, "created": ms}. No link
;;; answer carries an ETag or a Location.
;;;
;;; Each handler is exactly one call of (techo auth): the PUT's and the two
;;; moves' are db-write-with-body-as, so no body is read before its key is
;;; known to be good; each of the others' is db-read-as or db-write-as. On
;;; the loop's thread, the prepare thunk makes the cheap checks, and the
;;; Reader of a write with a body reads it once the key has passed, so the
;;; order of checks is:
;;;
;;;   1. the key's shape (401), by (techo auth) itself, with no job;
;;;   2. the path's id, the path's revision, a link's type and target,
;;;      `limit`, `after`, `state`, `parent`, `direction`, `type` (400); a
;;;      link whose source is its own target, and a list's `after` of
;;;      another type than its `type` (400);
;;;   3. the preconditions: 428 for none, 400 for a bad shape (and for
;;;      If-None-Match on any write but a create); a link takes none, and
;;;      If-Match or If-None-Match on its PUT or DELETE is the 400 (on the
;;;      GET, as on every GET, they are ignored);
;;;   4. the key of a write with a body (401), by a read job of its own;
;;;   5. its Content-Type (415), then its body through wrap-json-body, under
;;;      request-cap for a PUT and move-body-cap for a move (413; 400
;;;      invalid_json for JSON that does not parse), then parse-content
;;;      (400; 413 for a body over body-cap) or parse-move-body (400);
;;;   6. the job: the key (401; again for a write with a body, as it may
;;;      have been revoked while the body came), then the work.
;;;
;;; A write with a body reads its time once the body has come, so a slow
;;; upload is stamped with when it arrived; a restore, a state change and a
;;; link's PUT or DELETE, with no body, read it first. None of them reads a
;;; body or a Content-Type.
;;;
;;; A write's work finds the node (its revision, kind, state and parent, or
;;; none), and for a create or a move with a parent, the parent's head and
;;; its ancestors, which parent-verdict judges; for a purge, whether the
;;; node has children. It names the event, asks (techo nodes)' node-command,
;;; by which the write's table and the lifecycle's answer it, and performs
;;; the command it names: insert, write, copy, set-state, purge, move or
;;; move-children, or a refusal raised as a &refusal, so the job rolls
;;; back, the key's last_used with it. The answer follows from the command
;;; alone; the handler decides none of its own (ADR-0007). A missing node on
;;; a read is a &refusal too, and so is a list's ?parent= naming no node of
;;; the account. A state is a symbol in (techo nodes) and a string in the
;;; store; the work converts.
;;;
;;; A bulk move moves, in id order, up to move-children-cap of the node's
;;; children that may move under the new parent, each at its own revision,
;;; a revision and a change row each; the node itself is not written.
;;;
;;; A link's work finds the source's head, for a PUT the target's too (a
;;; DELETE reads no target: a link's ends are live nodes of its owner, so
;;; "no such link" covers a bad one), and whether the link is there. It
;;; asks (techo links)' link-command, by which the lifecycle's table judges
;;; each end, and performs the command it names: link (the row and a change
;;; row on the source at its revision; no node row, no snapshot), keep
;;; (nothing written; the stored created answered), unlink, or a refusal
;;; raised as a &refusal. A link's list reads the node's head first, as the
;;; revisions list does: no node of the account is the 404, not an empty
;;; page; a trashed or an archived node's links are listed.
;;;
;;; A node's answer shows its stored state. A purged node is never found:
;;; the store leaves it out of every read, so it is a 404, and a create on
;;; its id a 412; as a parent, it is invalid_parent, as a missing one is.
;;;
;;; A job's work closes over plain data only: the id, the precondition, the
;;; five content values, a parent's id, the path's revision, the event, the
;;; time, a link's type, target, direction and cursor. Never the request,
;;; never the parsed JSON. Nothing waits in a job: a body is read in its
;;; Reader, between its two jobs. Nothing raised here carries a title or a
;;; body. The database is reached only through
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
                content-content-type content-props content-parent found found-for-create
                write-event node-command node-state->string string->node-state parse-state-param
                event-op depth-cap move-children-cap move-body-cap parse-move-body
                parse-parent-param parent-verdict child-kind-filter)
          (only (techo links) parse-link-type parse-type-param parse-direction parse-link-cursor
                link-cursor link-command)
          (only (techo node-store) node-in-use? node-head node-of-owner nodes-page
                snapshot-exists? snapshot-of snapshots-page insert-node! write-node!
                set-node-state! purge-node! move-node! ancestors has-children? count-children
                children-heads link-of insert-link! delete-link! links-page
                node-id node-kind node-title node-body node-content-type node-props
                node-revision node-created node-updated node-state node-parent
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
  ;; id (lower case), kind, state (the stored one), parent (its id in lower
  ;; case, or null at the top level), title, body when BODY?, content_type,
  ;; props, revision, created, updated. Never num, the owner or the author.
  (define (node->json n body?)
    (append (list (cons "id" (node-id->string (node-id n)))
                  (cons "kind" (node-kind n))
                  (cons "state" (node-state n))
                  (cons "parent" (let ((p (node-parent n))) (if p (node-id->string p) 'null)))
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

  ;; written : (Pair CommandKind (U Node #f (Pair Natural Natural))) -> Res
  ;; A write's answer, by the command its job performed: insert is 201 with
  ;; Location, the id in lower case; write and copy are 200, each with the
  ;; node whole and its ETag; set-state and move are 200, the node without
  ;; its body (the client has it, and the job read none), and its ETag;
  ;; purge is 204, no body and no ETag, as nothing is left to tag;
  ;; move-children is 200, {"moved": N, "left": M}, of the pair (N . M),
  ;; and no ETag, as the node was not written. Any other command is an
  ;; assertion violation.
  (define (written outcome)
    (let ((command (car outcome)) (n (cdr outcome)))
      (case command
        ((insert) (res-set-header (node-answer 201 n) "location"
                                  (string-append "/v1/nodes/" (node-id->string (node-id n)))))
        ((write copy) (node-answer 200 n))
        ((set-state move) (res-set-header (make-json-res 200 (node->json n #f))
                                          "etag" (etag (node-revision n))))
        ((purge) (make-res 204 '() #f))
        ((move-children) (make-json-res 200 (list (cons "moved" (car n)) (cons "left" (cdr n)))))
        (else (assertion-violation 'node-routes "a write's answer has no such command" command)))))

  ;; link->json : Bytevector String Bytevector Natural -> Alist
  ;; source, type, target (each id in lower case), created.
  (define (link->json source type target created)
    (list (cons "source" (node-id->string source)) (cons "type" type)
          (cons "target" (node-id->string target)) (cons "created" created)))

  ;; linked : Bytevector String Bytevector -> ((Pair Symbol (U Natural #f)) -> Res)
  ;; A link's answer, by the command its job performed, of the link from
  ;; SOURCE to TARGET of TYPE: link is 201 and keep 200, each with the link
  ;; and the created its job answered (now for link, the stored one for
  ;; keep); unlink is 204, no body. No ETag and no Location: a link is no
  ;; node's revision, and has no route of its own to read. Any other
  ;; command is an assertion violation.
  (define (linked source type target)
    (lambda (outcome)
      (let ((command (car outcome)) (created (cdr outcome)))
        (case command
          ((link) (make-json-res 201 (link->json source type target created)))
          ((keep) (make-json-res 200 (link->json source type target created)))
          ((unlink) (make-res 204 '() #f))
          (else (assertion-violation 'node-routes "a link's answer has no such command" command))))))

  ;; link-item->json : (List String Natural Node) -> Alist
  ;; A link list's item, of links-page's row: type, created, and the node
  ;; at the other end as the nodes list gives it, without its body.
  (define (link-item->json row)
    (list (cons "type" (car row)) (cons "created" (cadr row)) (cons "node" (node->json (caddr row) #f))))

  ;; link-item-next : (List String Natural Node) -> String
  ;; The next of a page ending on ROW: its type and the other node's id.
  (define (link-item-next row) (link-cursor (car row) (node-id (caddr row))))

  ;;; The work of a write, in its job

  ;; refusal-codes : (Listof (Pair CommandKind Symbol))
  (define refusal-codes
    '((refuse-404 . not_found) (refuse-409 . kind_fixed) (refuse-412 . precondition_failed)
      (refuse-wrong-state . wrong_state) (refuse-invalid-parent . invalid_parent)
      (refuse-would-loop . would_loop) (refuse-has-children . has_children)))

  ;; refuse : CommandKind Bytevector -> !
  ;; The refusal COMMAND names, raised as a &refusal for OWNER, so the job
  ;; rolls back. It carries the code and the account only.
  (define (refuse command owner)
    (raise (make-refusal (cdr (assq command refusal-codes)) owner)))

  ;; Head = (List Natural String String (U Bytevector #f))
  ;;   node-head's revision, kind, state and parent

  ;; head-state : (U Head #f) -> (U Symbol #f)
  ;; The stored state as (techo nodes) names it; #f for no node.
  (define (head-state head)
    (and head (string->node-state (caddr head))))

  ;; judge-parent : Tx Bytevector (U Bytevector #f) Bytevector (U String #f)
  ;;                -> (values Verdict (U String #f))
  ;; The verdict on PARENT, the new parent of a create, a move or a bulk
  ;; move for OWNER, and the parent's kind. For an id, its head (owner's
  ;; alone: missing, another account's and purged all read as none) and up
  ;; to depth-cap of its ancestors are read; for the top level (#f),
  ;; nothing. parent-verdict judges them, with KEEP-OUT, the id that may
  ;; not be the parent or among its ancestors, and KIND, the kind going in
  ;; (#f for a bulk move). The kind is #f for the top level and for none.
  (define (judge-parent tx owner parent keep-out kind)
    (if parent
        (let ((head (node-head tx owner parent)))
          (values (parent-verdict parent (and head (list (cadr head) (head-state head)))
                                  (ancestors tx owner parent depth-cap) keep-out kind)
                  (and head (cadr head))))
        (values (parent-verdict #f #f '() keep-out kind) #f)))

  ;; verdict-of : Tx Bytevector (U Bytevector #f) Bytevector (U String #f) -> Verdict
  ;; judge-parent's verdict alone.
  (define (verdict-of tx owner parent keep-out kind)
    (let-values (((verdict parent-kind) (judge-parent tx owner parent keep-out kind)))
      verdict))

  ;; put-work : Bytevector Precondition (U String #f) String String String String
  ;;            (U Bytevector #f) Natural -> Work
  ;; A PUT's work: what the job found (node-in-use? for a create, node-head
  ;; for a replace), the stored state, the event, for a create the verdict
  ;; on its PARENT (the id made kept out, its kind going in; ok for the top
  ;; level), node-command, and the command it names performed. A replace's
  ;; PARENT is #f: parse-content refuses one. Answers the command and the
  ;; node; a refusal is raised. A command a PUT has no action for is an
  ;; assertion violation.
  (define (put-work id pre kind title body type props parent now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (create? (eq? pre 'create))
             (head (and (not create?) (node-head tx owner id)))
             (found-kind (if create?
                             (found-for-create (node-in-use? tx id))
                             (found (and head (car head)) pre)))
             (event (write-event 'put pre kind (and head (cadr head)) #f))
             (verdict (if create? (verdict-of tx owner parent id kind) 'ok)))
        (let-values (((command next) (node-command found-kind (head-state head) event verdict #f)))
          (case command
            ((insert) (cons command (insert-node! tx id owner kind title body type props parent now)))
            ((write) (cons command (write-node! tx id owner pre title body type props "update" now)))
            ((refuse-404 refuse-409 refuse-412 refuse-wrong-state refuse-invalid-parent
              refuse-would-loop)
             (refuse command owner))
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
        (let-values (((command next) (node-command found-kind (head-state head) event 'ok #f)))
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
  ;; found, node-command with the stored state, EVENT, one of
  ;; lifecycle-events, and for a purge whether the node has children (any
  ;; row under it: purged rows have no parent), and the command performed.
  ;; set-state stores the state node-command names, with EVENT's op, and
  ;; answers the node as it now is, with no body; purge empties the node and
  ;; answers #f. Neither writes or reads a snapshot's body.
  (define (lifecycle-work id pre event now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (head (node-head tx owner id))
             (children? (and (eq? event 'purge) (has-children? tx owner id))))
        (let-values (((command next)
                      (node-command (found (and head (car head)) pre) (head-state head) event 'ok
                                    children?)))
          (case command
            ((set-state)
             (cons command (set-node-state! tx id owner pre (node-state->string next)
                                            (event-op event) now)))
            ((purge) (purge-node! tx id owner pre now) (cons command #f))
            ((refuse-404 refuse-412 refuse-wrong-state refuse-has-children) (refuse command owner))
            (else (assertion-violation 'node-routes "a state change has no action for this command"
                                       command)))))))

  ;; move-work : Bytevector Natural (U Bytevector #f) Natural -> Work
  ;; A move's work: the node's head and what was found; when there is a
  ;; node, the verdict on PARENT (#f: the top level), the node kept out of
  ;; its ancestors and its kind going in; when there is none, ok, as
  ;; node-command looks at no verdict for none; node-command with the
  ;; stored state and move; and the command performed. move sets the
  ;; parent, with no snapshot, and answers the node as it now is, with no
  ;; body.
  (define (move-work id pre parent now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (head (node-head tx owner id))
             (verdict (if head (verdict-of tx owner parent id (cadr head)) 'ok)))
        (let-values (((command next)
                      (node-command (found (and head (car head)) pre) (head-state head) 'move verdict
                                    #f)))
          (case command
            ((move) (cons command (move-node! tx id owner pre parent now)))
            ((refuse-404 refuse-412 refuse-wrong-state refuse-invalid-parent refuse-would-loop)
             (refuse command owner))
            (else (assertion-violation 'node-routes "a move has no action for this command"
                                       command)))))))

  ;; move-children-work : Bytevector Natural (U Bytevector #f) Natural -> Work
  ;; A bulk move's work: the node's head and what was found; when there is
  ;; a node, the verdict on PARENT with the node kept out of its ancestors
  ;; and no kind going in; node-command with the stored state and
  ;; move-children; and the command performed. move-children takes up to
  ;; move-children-cap of the node's children that may go under PARENT
  ;; (active or archived, of a kind it holds: child-kind-filter of its
  ;; kind), in id order, and moves each in that order at its own revision;
  ;; then counts the children left under the node. The node's own row is
  ;; not written. Answers the pair (moved . left).
  (define (move-children-work id pre parent now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (head (node-head tx owner id)))
        (let*-values (((verdict parent-kind)
                       (if head (judge-parent tx owner parent id #f) (values 'ok #f)))
                      ((command next)
                       (node-command (found (and head (car head)) pre) (head-state head) 'move-children
                                     verdict #f)))
          (case command
            ((move-children)
             (let ((heads (children-heads tx owner id (child-kind-filter parent-kind)
                                          move-children-cap)))
               (for-each (lambda (h) (move-node! tx (car h) owner (cdr h) parent now)) heads)
               (cons command (cons (length heads) (count-children tx owner id)))))
            ((refuse-404 refuse-412 refuse-wrong-state refuse-invalid-parent refuse-would-loop)
             (refuse command owner))
            (else (assertion-violation 'node-routes "a bulk move has no action for this command"
                                       command)))))))

  ;; link-work : Bytevector String Bytevector Symbol Natural -> Work
  ;; A link's work, EVENT link for the PUT or unlink for the DELETE, of the
  ;; link from SOURCE to TARGET of TYPE: the source's head (owner's alone:
  ;; missing, another account's and purged all read as none); for link the
  ;; target's head the same way, for unlink none (#f, not read); whether
  ;; the link is there, link-of's created or #f; link-command of the two
  ;; stored states, EVENT and that, as a boolean; and the command performed.
  ;; link writes the row and its change row at the source's revision as its
  ;; head read it, at NOW, and answers NOW; keep writes nothing and answers
  ;; the stored created; unlink deletes the row, with its change row, and
  ;; answers #f. A refusal is raised. A command a link has no action for is
  ;; an assertion violation.
  (define (link-work source type target event now)
    (lambda (tx account key)
      (let* ((owner (account-id account))
             (head (node-head tx owner source))
             (target-head (and (eq? event 'link) (node-head tx owner target)))
             (created (link-of tx owner source type target))
             (command (link-command (head-state head) (head-state target-head) event
                                    (and created #t))))
        (case command
          ((link) (insert-link! tx owner source type target (car head) now) (cons command now))
          ((keep) (cons command created))
          ((unlink) (delete-link! tx owner source type target (car head) now) (cons command #f))
          ((refuse-404 refuse-wrong-state) (refuse command owner))
          (else (assertion-violation 'node-routes "a link has no action for this command"
                                     command))))))

  ;;; The work of a read, in its job

  ;; missing : Bytevector -> !     the 404, raised as a &refusal for OWNER
  (define (missing owner) (raise (make-refusal 'not_found owner)))

  ;; node-work : Bytevector -> Work
  (define (node-work id)
    (lambda (tx account key)
      (let ((owner (account-id account)))
        (or (node-of-owner tx owner id) (missing owner)))))

  ;; nodes-work : Symbol (U 'any #f Bytevector) (U Bytevector #f) Natural -> Work
  ;; STATE's page: of every node ('any), the top level (#f), or the
  ;; children of the node PARENT names. That node first: one that is no
  ;; node of the account, or is purged, is the 404, not an empty page.
  (define (nodes-work state parent after limit)
    (lambda (tx account key)
      (let ((owner (account-id account)))
        (if (and (bytevector? parent) (not (node-head tx owner parent)))
            (missing owner)
            (nodes-page tx owner (node-state->string state) parent after (+ limit 1))))))

  ;; revisions-work : Bytevector (U Natural #f) Natural -> Work
  ;; The node first: a missing one is the 404, not an empty page.
  (define (revisions-work id before limit)
    (lambda (tx account key)
      (let ((owner (account-id account)))
        (if (node-head tx owner id)
            (snapshots-page tx owner id before (+ limit 1))
            (missing owner)))))

  ;; links-work : Bytevector (U 'out 'in) (U String #f) (U (Pair String Bytevector) #f) Natural
  ;;              -> Work
  ;; The node first: one that is no node of the account, or is purged, is
  ;; the 404, not an empty page. Then its links in DIRECTION, of TYPE (#f
  ;; for all), after AFTER, LIMIT + 1 of them.
  (define (links-work id direction type after limit)
    (lambda (tx account key)
      (let ((owner (account-id account)))
        (if (node-head tx owner id)
            (links-page tx owner id direction type after (+ limit 1))
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
  ;; five content values, the parent and NOW alone.
  (define (put-plan u now)
    (let ((c (upload-content u)))
      (make-plan (put-work (upload-id u) (upload-pre u) (content-kind c) (content-title c)
                           (content-body c) (content-content-type c) (content-props c)
                           (content-parent c) now)
                 written)))

  ;;; A move's body

  ;; Shift : what a move's or a bulk move's Reader hands on, read on the
  ;; loop's thread: the node's id, the precondition and the new parent (#f
  ;; for the top level).
  (define-record-type shift (fields id pre parent))

  ;; shift-plan : (Bytevector Natural (U Bytevector #f) Natural -> Work) -> (Shift Natural -> Plan)
  ;; A move's plan, of what its Reader read and NOW, the time read once the
  ;; body had come: WORK-OF's work, closed over the id, the precondition,
  ;; the parent and NOW alone.
  (define (shift-plan work-of)
    (lambda (m now)
      (make-plan (work-of (shift-id m) (shift-pre m) (shift-parent m) now) written)))

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

    ;; move-json-body : Middleware     a move's body, under move-body-cap
    (define move-json-body (wrap-json-body move-body-cap))

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

    ;; move-content : Req Bytevector Precondition -> (U Res Shift)
    ;; The body wrap-json-body read: no JSON (an empty body) or what
    ;; parse-move-body refuses is 400. Else the shift: the id, the
    ;; precondition and the new parent.
    (define (move-content r id pre)
      (let ((p (if (req-json? r) (parse-move-body (req-json r)) 'invalid)))
        (if (eq? p 'invalid) (bad-request) (make-shift id pre p))))

    ;; read-body : Middleware (Req -> (U Res A)) Req -> (U Res A)
    ;; The body under BODY's cap, as login's handler reads it, handed to
    ;; CONTENT: wrap-json-body's plain 400 for JSON that does not parse,
    ;; answered before its handler ran, is invalid_json here; past the cap
    ;; it raises the 413.
    (define (read-body body content req)
      (let* ((ran? #f)
             (step ((body (lambda (r) (set! ran? #t) (content r))) req)))
        (if ran? step (problem-res 'invalid_json))))

    ;; with-body : Req (Precondition -> Boolean) (Req Bytevector Precondition -> (U Res A))
    ;;             -> (-> (U Res Reader))
    ;; The prepare of a write with a body: the path's id (400), then the
    ;; preconditions (428 for none; 400 for a bad shape, or one ALLOWED?
    ;; refuses); then its Reader, called once the key has passed: the media
    ;; type (415), then READER-OF's read of the body.
    (define (with-body req allowed? reader-of)
      (lambda ()
        (let ((id (path-id req)))
          (if (eq? id 'invalid)
              (bad-request)
              (let ((pre (preconditions req)))
                (cond ((eq? pre 'missing) (problem-res 'precondition_required))
                      ((or (eq? pre 'invalid) (not (allowed? pre))) (bad-request))
                      (else (lambda ()
                              (if (json-type? req)
                                  (reader-of req id pre)
                                  (problem-res 'unsupported_media_type))))))))))

    ;; PUT /v1/nodes/:id
    ;; prepare checks the id and the preconditions, a create's or a
    ;; replace's; its Reader, called once the key has passed, the media
    ;; type and the body.
    (define (put-node req)
      (db-write-with-body-as read write clock wall-clock req
                             (with-body req
                                        (lambda (pre) #t)
                                        (lambda (r id pre)
                                          (read-body json-body (lambda (r) (put-content r id pre)) r)))
                             put-plan))

    ;; mover : (Bytevector Natural (U Bytevector #f) Natural -> Work) -> Handler
    ;; POST /v1/nodes/:id/move, of move-work, and /move-children, of
    ;; move-children-work: the PUT's checks and order, with If-Match alone
    ;; (If-None-Match is the 400, as a state change's), and the body under
    ;; move-body-cap, read by parse-move-body.
    (define (mover work-of)
      (lambda (req)
        (db-write-with-body-as read write clock wall-clock req
                               (with-body req
                                          (lambda (pre) (not (eq? pre 'create)))
                                          (lambda (r id pre)
                                            (read-body move-json-body
                                                       (lambda (r) (move-content r id pre)) r)))
                               (shift-plan work-of))))

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

    ;; GET /v1/nodes?limit=&after=&state=&parent=
    ;; state is one of active, archived and trashed, active when not given;
    ;; parent is a node's id, or null for the top level, every node when not
    ;; given.
    (define (list-nodes req)
      (db-read-as read clock req
                  (lambda ()
                    (let ((limit (parse-limit (query-one req "limit")))
                          (after (query-after req parse-node-id))
                          (state (parse-state-param (query-one req "state")))
                          (parent (parse-parent-param (query-one req "parent"))))
                      (if (or (eq? limit 'invalid) (eq? after 'invalid) (eq? state 'invalid)
                              (eq? parent 'invalid))
                          (bad-request)
                          (make-plan (nodes-work state parent after limit)
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

    ;; preconditioned? : Req -> Boolean
    ;; Whether REQ carries an If-Match or an If-None-Match field, of any
    ;; shape, even empty.
    (define (preconditioned? req)
      (or (pair? (req-header-values req "if-match"))
          (pair? (req-header-values req "if-none-match"))))

    ;; link-change : Symbol -> Handler
    ;; PUT /v1/nodes/:id/links/:type/:target, EVENT link, and its DELETE,
    ;; unlink. Before the job: the path's id, type and target, then a
    ;; source that is its own target (the same sixteen bytes), then any
    ;; precondition, each the 400. No body is read, and no Content-Type
    ;; looked at; the time is read first.
    (define (link-change event)
      (lambda (req)
        (let ((now (wall-clock)))
          (db-write-as write clock now req
                       (lambda ()
                         (let ((source (path-id req))
                               (type (parse-link-type (req-path-param req "type")))
                               (target (parse-node-id (req-path-param req "target"))))
                           (cond ((or (eq? source 'invalid) (eq? type 'invalid) (eq? target 'invalid))
                                  (bad-request))
                                 ((bytevector=? source target) (bad-request))
                                 ((preconditioned? req) (bad-request))
                                 (else (make-plan (link-work source type target event now)
                                                  (linked source type target))))))))))

    ;; GET /v1/nodes/:id/links?direction=&type=&limit=&after=
    ;; direction is out (the node is each link's source) unless it is in;
    ;; type is one of link-types, every type when not given; after is a
    ;; page's next, and with a type, of that type, or the 400.
    (define (list-links req)
      (db-read-as read clock req
                  (lambda ()
                    (let ((id (path-id req))
                          (direction (parse-direction (query-one req "direction")))
                          (type (parse-type-param (query-one req "type")))
                          (limit (parse-limit (query-one req "limit")))
                          (after (query-after req parse-link-cursor)))
                      (cond ((or (eq? id 'invalid) (eq? direction 'invalid) (eq? type 'invalid)
                                 (eq? limit 'invalid) (eq? after 'invalid))
                             (bad-request))
                            ((and type after (not (string=? type (car after)))) (bad-request))
                            (else (make-plan (links-work id direction type after limit)
                                             (page-answer limit link-item->json link-item-next))))))))

    (list (route "/v1/nodes" (GET list-nodes))
          (route "/v1/nodes/:id" (GET get-node) (PUT put-node) (DELETE (lifecycle 'purge)))
          (route "/v1/nodes/:id/archive" (POST (lifecycle 'archive)))
          (route "/v1/nodes/:id/unarchive" (POST (lifecycle 'unarchive)))
          (route "/v1/nodes/:id/trash" (POST (lifecycle 'trash)))
          (route "/v1/nodes/:id/untrash" (POST (lifecycle 'untrash)))
          (route "/v1/nodes/:id/move" (POST (mover move-work)))
          (route "/v1/nodes/:id/move-children" (POST (mover move-children-work)))
          (route "/v1/nodes/:id/revisions" (GET list-revisions))
          (route "/v1/nodes/:id/revisions/:n" (GET get-revision))
          (route "/v1/nodes/:id/revisions/:n/restore" (POST restore-node))
          (route "/v1/nodes/:id/links" (GET list-links))
          (route "/v1/nodes/:id/links/:type/:target" (PUT (link-change 'link))
                 (DELETE (link-change 'unlink)))))
)
