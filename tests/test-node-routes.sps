#!r6rs
;;; The node routes suite: slice 4's routes, slice 4b's lifecycle and slice
;;; 5a's tree, (techo node-routes), as a router serves them inside the whole
;;; stack (wrap-server), against real SQLite through the test doorway, raw
;;; HTTP bytes in through circuit's test host. The rig makes its own router
;;; of them; tests/test-app.sps holds them joined to make-app.
;;;
;;;   PUT    /v1/nodes/:id                       create (If-None-Match: *), perhaps under a
;;;                                              parent, or replace (If-Match)
;;;   GET    /v1/nodes/:id                       the node, with its ETag
;;;   DELETE /v1/nodes/:id                       a purge (If-Match), 204
;;;   GET    /v1/nodes?state=&parent=            the account's nodes in one state, all, a
;;;                                              node's children or the top level; paged, no bodies
;;;   GET    /v1/nodes/:id/revisions             its snapshots, newest first, no bodies
;;;   GET    /v1/nodes/:id/revisions/:n          one snapshot, whole
;;;   POST   /v1/nodes/:id/revisions/:n/restore  a new revision copied from snapshot n
;;;   POST   /v1/nodes/:id/archive, /unarchive, /trash, /untrash
;;;                                              a state change (If-Match), the node without its body
;;;   POST   /v1/nodes/:id/move                  a move (If-Match), the node without its body
;;;   POST   /v1/nodes/:id/move-children         a bulk move of its children (If-Match), counts
;;;   PUT    /v1/nodes/:id/links/:type/:target   make a link (no precondition, no body): 201, or
;;;                                              200 when it was there
;;;   DELETE /v1/nodes/:id/links/:type/:target   remove it: 204
;;;   GET    /v1/nodes/:id/links?direction=&type=
;;;                                              a page of the node's links, each with the
;;;                                              other node without its body
;;;
;;; Every node in an answer has its parent after its state: an id, or null.
;;; The tree's tests end by checking the whole table is a forest
;;; (forest-faults), by rules written out here, not read from the code.
;;; The links' tests judge each answer by the plan's table, as its review
;;; orders it, written out here (link-cell), not read from (techo links).
;;;
;;; Each test gets a file of its own (a rig), seeded through the store's own
;;; procedures in a write job: account A (alice) with key 1, account B (bob)
;;; with key 3. Key n's secret is key-secret of 32 bytes of n; neither key
;;; has a last_used, so the first write by each is due to set it. Node n's
;;; id is a UUID of version 7 whose last twelve hex digits are n, so ids
;;; sort by n. The wall clock is fixed (and moved by hand), the duration
;;; clock steps by 1. Jobs are counted, reads and writes apart, and kept in
;;; the order they were handed over; the writer keeps the last job it was
;;; handed. A PUT's key is checked in a read job before its body is read,
;;; and again in its write job: a PUT that reaches its write is two jobs.
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (circuit)
        (only (circuit router) make-router)
        (only (jsonparse easy) json->string)
        (http-support)
        (techo errors)
        (only (techo keys) key-secret id->string)
        (except (techo store) key-hash)
        (only (techo auth) key-hash)
        (only (techo doorway) tx-query tx-query-row)
        (only (techo nodes) parse-node-id body-cap request-cap node-states)
        (only (techo node-store) insert-node! write-node! set-node-state! purge-node! insert-link!)
        (only (techo migrations) migrations)
        (only (techo app) wrap-server)
        (techo node-routes))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define dir (fresh-dir "test-node-routes"))

(define acct-a (make-bytevector 16 #xA1))
(define acct-b (make-bytevector 16 #xB2))
(define (kid n) (make-bytevector 16 n))
(define (secret-of n) (key-secret (make-bytevector 32 n)))
(define now0 1795515226123)
(define day 86400000)

(define (seed! tx)
  (insert-account! tx acct-a "alice" "alice@example.com" "argon2id-hash-of-alice" 1000)
  (insert-account! tx acct-b "bob" "bob@example.com" "argon2id-hash-of-bob" 2000)
  (insert-key! tx (kid 1) acct-a "laptop" (key-hash (secret-of 1)) 1100)
  (insert-key! tx (kid 3) acct-b "bob's" (key-hash (secret-of 3)) 1300))

;;; Ids and paths

;; hex12 : Natural -> String     N as twelve lower-case hex digits
(define (hex12 n)
  (let ((s (string-downcase (number->string n 16))))
    (string-append (make-string (- 12 (string-length s)) #\0) s)))

;; nid-text : Natural -> String     node N's id, a v7 UUID, lower case
(define (nid-text n) (string-append "0190b3a4-5c6d-7e8f-9a0b-" (hex12 n)))
(define (nid n) (parse-node-id (nid-text n)))

;; A v4 id, well formed: refused for its version alone.
(define v4-text "0190b3a4-5c6d-4e8f-9a0b-1c2d3e4f5a6b")

(define (node-path-of text) (string-append "/v1/nodes/" text))
(define (node-path n) (node-path-of (nid-text n)))
(define (revisions-path n) (string-append (node-path n) "/revisions"))
(define (revision-path n r) (string-append (revisions-path n) "/" (number->string r)))
(define (restore-path n r) (string-append (revision-path n r) "/restore"))

;; Slice 5b's: a node's links, and one link, from the id S-TEXT to the id
;; T-TEXT, of TYPE.
(define (links-path-of text) (string-append (node-path-of text) "/links"))
(define (links-path n) (links-path-of (nid-text n)))
(define (link-path-of s-text type t-text) (string-append (links-path-of s-text) "/" type "/" t-text))
(define (link-path s type t) (link-path-of (nid-text s) type (nid-text t)))

;;; The rig

;; A rig: CALL sends a request and answers what the client read; JOBS
;; counts jobs, and READS and WRITES count each runner's apart; LINES are
;; the log's lines; STORE is the file; SET-NOW! moves the wall clock; JOB
;; is the last job the writer was handed; ORDER is each job's runner, read
;; or write, oldest first; HANDLER is the whole stack, for exchange-steps.
(define-record-type rig (fields call jobs lines store set-now! job reads writes order handler))

(define (not-found req) (problem-res 'not_found))

;; with-rig : String (Rig -> A) -> A
;; A fresh seeded file NAME, and a router of node-routes on it inside
;; wrap-server, its runners counted.
(define (with-rig name body) (with-rig-wall name #f body))

;; with-rig-wall : String (U (-> (-> Natural)) #f) (Rig -> A) -> A
;; with-rig, the wall clock the thunk WALL makes when given (SET-NOW! then
;; moves nothing), else the fixed one.
(define (with-rig-wall name wall body)
  (let ((s (open-test-store dir name)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (run-write s seed!)
        (let*-values (((last-job) (vector #f))
                      ((order) (vector '()))
                      ((note!) (lambda (which) (vector-set! order 0 (cons which (vector-ref order 0)))))
                      ((read reads) (counting (lambda (job) (note! 'read) ((store-reader s) job))))
                      ((write writes) (counting (lambda (job)
                                                  (note! 'write)
                                                  (vector-set! last-job 0 job)
                                                  ((store-writer s) job)))))
          (let* ((lines '())
                 (now now0)
                 (clock (step-clock 0 1))
                 (h (wrap-server (make-router (node-routes read write (if wall (wall) (lambda () now)) clock)
                                              not-found)
                                 (lambda (l) (set! lines (cons l lines)))
                                 10000 clock)))
            (body (make-rig (case-lambda
                              ((method target headers text) (exchange h method target headers text))
                              ((method target headers) (exchange h method target headers))
                              ((method target) (exchange h method target '())))
                            (lambda () (+ (reads) (writes)))
                            (lambda () (reverse lines))
                            s
                            (lambda (t) (set! now t))
                            (lambda () (vector-ref last-job 0))
                            reads
                            writes
                            (lambda () (reverse (vector-ref order 0)))
                            h)))))
      (lambda () (close-test-store! s)))))

;; seed-node! : Rig Bytevector Natural String -> Void
;; Node N for OWNER at revision 1, made at 5000, straight through the store.
(define (seed-node! g owner n kind)
  (run-write (rig-store g)
             (lambda (tx) (insert-node! tx (nid n) owner kind "seed" "seed body" "text/plain" "{}" #f 5000))))

;; tables : Rig -> (List ...)
;; The four tables whole (nodes, revisions, changes, links), and every
;; key's id and last_used, last: (list-ref t 4).
(define (tables g)
  (run-read (rig-store g)
            (lambda (tx)
              (list (tx-query tx "SELECT * FROM nodes ORDER BY num")
                    (tx-query tx "SELECT * FROM revisions ORDER BY node, revision")
                    (tx-query tx "SELECT * FROM changes ORDER BY owner, seq")
                    (tx-query tx "SELECT * FROM links ORDER BY owner, source, type, target")
                    (tx-query tx "SELECT id, last_used FROM api_keys ORDER BY id")))))

;; last-used : Rig Natural -> (U Natural #f)     key N's last_used
(define (last-used g n)
  (run-read (rig-store g)
            (lambda (tx)
              (let ((r (tx-query-row tx "SELECT last_used FROM api_keys WHERE id = ?" (kid n))))
                (let ((v (vector-ref r 0))) (and (integer? v) v))))))

;; stored : Rig Natural -> (List ...)
;; Node N's row: revision, kind, author, created, updated, and num.
(define (stored g n)
  (run-read (rig-store g)
            (lambda (tx)
              (let ((r (tx-query-row tx
                         "SELECT revision, kind, author, created, updated, num FROM nodes WHERE id = ?"
                         (nid n))))
                (and r (vector->list r))))))

;; snapshot-rows : Rig Natural -> (Listof (List ...))
;; Node N's snapshots, by revision: revision, author, title, body,
;; content_type, props, created.
(define (snapshot-rows g n)
  (run-read (rig-store g)
            (lambda (tx)
              (map vector->list
                   (tx-query tx
                     (string-append "SELECT revision, author, title, body, content_type, props, created"
                                    " FROM revisions WHERE node = ? ORDER BY revision")
                     (nid n))))))

;; change-rows : Rig Bytevector -> (Listof (List ...))
;; OWNER's change rows by seq: seq, node, revision, op, created.
(define (change-rows g owner)
  (run-read (rig-store g)
            (lambda (tx)
              (map vector->list
                   (tx-query tx
                     "SELECT seq, node, revision, op, created FROM changes WHERE owner = ? ORDER BY seq"
                     owner)))))

;;; Requests

(define (key-h n) (bearer (secret-of n)))
(define json-type (cons "Content-Type" "application/json"))
(define none-match (cons "If-None-Match" "*"))
(define (tag r) (string-append "\"" (number->string r) "\""))
(define (match-h r) (cons "If-Match" (tag r)))

;; content : (U String #f) String String String -> String
;; A write's JSON: kind (left out when #f), title, body, content_type.
(define (content kind title body type)
  (json->string (append (if kind (list (cons "kind" kind)) '())
                        (list (cons "title" title) (cons "body" body) (cons "content_type" type)))))

(define plain (content "note" "a title" "a body" "text/plain"))

(define (put! g n headers text) ((rig-call g) 'PUT (node-path n) headers text))

;; create! : Rig Natural Natural String String String String -> Answer
(define (create! g who n kind title body type)
  (put! g n (list (key-h who) json-type none-match) (content kind title body type)))

;; replace! : Rig Natural Natural Natural (U String #f) String String String -> Answer
(define (replace! g who n rev kind title body type)
  (put! g n (list (key-h who) json-type (match-h rev)) (content kind title body type)))

;; restore! : Rig Natural Natural Natural Natural -> Answer
(define (restore! g who n r rev)
  ((rig-call g) 'POST (restore-path n r) (list (key-h who) (match-h rev))))

;; The five lifecycle events, each its own route.
(define events '(archive unarchive trash untrash purge))

;; event-target : Symbol String -> (Pair Symbol String)
;; EVENT's method and path on the node at PATH: DELETE on the node itself
;; for purge, a POST to its sub-resource for the four others.
(define (event-target event path)
  (if (eq? event 'purge)
      (cons 'DELETE path)
      (cons 'POST (string-append path "/" (symbol->string event)))))

;; event-request : Symbol Natural (Listof Header) [(U String #f)]
;;                 -> (List Symbol String (Listof Header) (U String #f))
;; The arguments of a rig's call for EVENT on node N, with HEADERS and BODY
;; (none when not given).
(define (event-request event n headers . body)
  (let ((t (event-target event (node-path n))))
    (append (list (car t) (cdr t) headers) (if (null? body) (list #f) body))))

;; lifecycle! : Rig Natural Natural Symbol Natural -> Answer
;; WHO's EVENT on node N, with If-Match REV and no body.
(define (lifecycle! g who n event rev)
  (apply (rig-call g) (event-request event n (list (key-h who) (match-h rev)))))

;; send-event : Rig Symbol Natural (Listof Header) [(U String #f)] -> Answer
(define (send-event g event n headers . body)
  (apply (rig-call g) (apply event-request event n headers body)))

(define (get! g who path) ((rig-call g) 'GET path (list (key-h who))))

;; The two moves (slice 5a), each a POST with a body.
(define (move-path-of path) (string-append path "/move"))
(define (move-children-path-of path) (string-append path "/move-children"))
(define (move-path n) (move-path-of (node-path n)))
(define (move-children-path n) (move-children-path-of (node-path n)))

;; move-body : (U Natural #f) -> String     {"parent": P's id}, or {"parent": null} for #f
(define (move-body p)
  (json->string (list (cons "parent" (if p (nid-text p) 'null)))))

;; move! : Rig Natural Natural Natural (U Natural #f) -> Answer
;; WHO's move of node N, at If-Match REV, under P (#f: the top level).
(define (move! g who n rev p)
  ((rig-call g) 'POST (move-path n) (list (key-h who) json-type (match-h rev)) (move-body p)))

;; move-children! : Rig Natural Natural Natural (U Natural #f) -> Answer
;; WHO's bulk move of node N's children, at N's If-Match REV, under P.
(define (move-children! g who n rev p)
  ((rig-call g) 'POST (move-children-path n) (list (key-h who) json-type (match-h rev))
                (move-body p)))

;;; What answers look like

;; status+code : Answer -> (List Natural Any)
(define (status+code a)
  (list (answer-status a)
        (let ((j (answer-json a)))
          (if (and (list? j) (assoc "code" j)) (cdr (assoc "code" j)) j))))

(define (member-of j name) (let ((m (and (list? j) (assoc name j)))) (if m (cdr m) 'absent)))
(define (names j) (map car j))

;; node-json-in : String Natural String String String String Natural Natural Natural -> Alist
;; A node's answer in STATE, at the top level: id, kind, state, parent
;; (null), title, body, content_type, props, revision, created, updated, in
;; that order. `under` names another parent.
(define (node-json-in state n kind title body type revision created updated)
  (list (cons "id" (nid-text n)) (cons "kind" kind) (cons "state" state) (cons "parent" 'null)
        (cons "title" title)
        (cons "body" body) (cons "content_type" type) (cons "props" '()) (cons "revision" revision)
        (cons "created" created) (cons "updated" updated)))

;; node-json : as node-json-in, for an active node
(define (node-json . args) (apply node-json-in "active" args))

;; item-json-in : as node-json-in, without the body: a list's item, and a
;; state change's answer
(define (item-json-in state n kind title type revision created updated)
  (list (cons "id" (nid-text n)) (cons "kind" kind) (cons "state" state) (cons "parent" 'null)
        (cons "title" title)
        (cons "content_type" type) (cons "props" '()) (cons "revision" revision)
        (cons "created" created) (cons "updated" updated)))

;; parent-text : (U Natural #f) -> (U String 'null)     node P's id, or JSON null
(define (parent-text p) (if p (nid-text p) 'null))

;; under : Alist (U Natural #f) -> Alist     J with P as its parent member
(define (under j p)
  (map (lambda (m) (if (equal? (car m) "parent") (cons "parent" (parent-text p)) m)) j))

;; item-json : as item-json-in, for an active node
(define (item-json . args) (apply item-json-in "active" args))

;; snapshot-json : Natural String String String Natural -> Alist
(define (snapshot-json revision title body type created)
  (list (cons "revision" revision) (cons "title" title) (cons "body" body)
        (cons "content_type" type) (cons "props" '()) (cons "created" created)))

(define (snapshot-item revision title type created)
  (list (cons "revision" revision) (cons "title" title)
        (cons "content_type" type) (cons "props" '()) (cons "created" created)))

(define (items a) (vector->list (member-of (answer-json a) "items")))

(test-begin "node-routes")

;;; Every route: no key is a 401 with no job; an unknown key a 401 in one job

;; route-request : Symbol -> (List Symbol String (Listof Header) (U String #f))
;; Each route, aimed at node 1, which the rig seeds for A at revision 1, so
;; a key that passed would be answered 200 or 201's neighbours.
(define (route-request which)
  (case which
    ((list-nodes) (list 'GET "/v1/nodes" '() #f))
    ((get-node) (list 'GET (node-path 1) '() #f))
    ((create) (list 'PUT (node-path 2) (list json-type none-match) plain))
    ((replace) (list 'PUT (node-path 1) (list json-type (match-h 1)) plain))
    ((list-revisions) (list 'GET (revisions-path 1) '() #f))
    ((get-revision) (list 'GET (revision-path 1 1) '() #f))
    ((restore) (list 'POST (restore-path 1 1) (list (match-h 1)) #f))
    ((archive unarchive trash untrash purge) (event-request which 1 (list (match-h 1))))
    ((move) (list 'POST (move-path 1) (list json-type (match-h 1)) (move-body #f)))
    ((move-children) (list 'POST (move-children-path 1) (list json-type (match-h 1)) (move-body #f)))
    ((link) (list 'PUT (link-path 1 "related" 2) '() #f))
    ((unlink) (list 'DELETE (link-path 1 "related" 2) '() #f))
    ((list-links) (list 'GET (links-path 1) '() #f))
    (else (assertion-violation 'route-request "no such route" which))))

;; The links' three routes (slice 5b).
(define link-routes '(link unlink list-links))

(define route-names (append '(list-nodes get-node create replace list-revisions get-revision restore)
                            events '(move move-children) link-routes))

;; send : Rig Symbol (Listof Header) -> Answer     the route, with KEY-HEADERS first
(define (send g which key-headers)
  (let ((r (route-request which)))
    ((rig-call g) (car r) (cadr r) (append key-headers (caddr r)) (cadddr r))))

(for-each
 (lambda (which)
   (test-equal (string-append "no key: " (symbol->string which)
                              ": 401 unauthorized, www-authenticate: Bearer, no job, nothing written")
     '(401 "unauthorized" "Bearer" 0 #t)
     (attempt
      (lambda ()
        (with-rig "no-key.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let* ((before (tables g))
                   (a (send g which '())))
              (append (status+code a)
                      (list (answer-header a "www-authenticate") ((rig-jobs g))
                            (equal? before (tables g))))))))))
   (test-equal (string-append "unknown key: " (symbol->string which)
                              ": 401, one job, nothing written: the key is checked before the work")
     '(401 "unauthorized" 1 #t)
     (attempt
      (lambda ()
        (with-rig "unknown-key.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let* ((before (tables g))
                   (a (send g which (list (key-h 9)))))
              (append (status+code a) (list ((rig-jobs g)) (equal? before (tables g)))))))))))
 route-names)

;;; Ids: a v4 id is a 400 before any job; an id in capitals is the same id

;; id-request : Symbol String -> (List Symbol String (Listof Header) (U String #f))
;; Each route with an id, aimed at the id TEXT, with A's key.
(define (id-request which text)
  (let ((p (node-path-of text)))
    (case which
      ((get-node) (list 'GET p (list (key-h 1)) #f))
      ((create) (list 'PUT p (list (key-h 1) json-type none-match) plain))
      ((replace) (list 'PUT p (list (key-h 1) json-type (match-h 1)) plain))
      ((list-revisions) (list 'GET (string-append p "/revisions") (list (key-h 1)) #f))
      ((get-revision) (list 'GET (string-append p "/revisions/1") (list (key-h 1)) #f))
      ((restore) (list 'POST (string-append p "/revisions/1/restore") (list (key-h 1) (match-h 1)) #f))
      ((archive unarchive trash untrash purge)
       (let ((t (event-target which p))) (list (car t) (cdr t) (list (key-h 1) (match-h 1)) #f)))
      ((move) (list 'POST (move-path-of p) (list (key-h 1) json-type (match-h 1)) (move-body #f)))
      ((move-children)
       (list 'POST (move-children-path-of p) (list (key-h 1) json-type (match-h 1)) (move-body #f)))
      ((link) (list 'PUT (link-path-of text "related" (nid-text 2)) (list (key-h 1)) #f))
      ((unlink) (list 'DELETE (link-path-of text "related" (nid-text 2)) (list (key-h 1)) #f))
      ((list-links) (list 'GET (links-path-of text) (list (key-h 1)) #f))
      (else (assertion-violation 'id-request "no such route" which)))))

(define id-routes (append '(get-node create replace list-revisions get-revision restore) events
                          '(move move-children) link-routes))

(define (send-id g which text)
  (let ((r (id-request which text)))
    ((rig-call g) (car r) (cadr r) (caddr r) (cadddr r))))

(for-each
 (lambda (which)
   (for-each
    (lambda (bad)
      (test-equal (string-append "id: " (symbol->string which) " with the id " (car bad)
                                 ": 400 invalid_request, no job")
        '(400 "invalid_request" 0)
        (attempt
         (lambda ()
           (with-rig "bad-id.db"
             (lambda (g)
               (let ((a (send-id g which (cdr bad))))
                 (append (status+code a) (list ((rig-jobs g)))))))))))
    (list (cons "of version 4" v4-text)
          (cons "x" "x")
          (cons "of 32 hex digits, no hyphens" "0190b3a45c6d7e8f9a0b000000000001")))
   (test-equal (string-append "id: " (symbol->string which)
                              " with a v4 id and no key: the 401 comes first, no job")
     '(401 "unauthorized" 0)
     (attempt
      (lambda ()
        (with-rig "bad-id-nokey.db"
          (lambda (g)
            (let* ((r (id-request which v4-text))
                   (a ((rig-call g) (car r) (cadr r) (cdr (caddr r)) (cadddr r))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 id-routes)

(test-equal "id: in capitals, every route finds node 1, and answers its id in lower case"
  (list (list 201 (nid-text 2) (string-append "/v1/nodes/" (nid-text 2)))
        (list 200 (nid-text 1))
        (list 200 (nid-text 1))
        200
        200
        (list 200 (nid-text 1)))
  (attempt
   (lambda ()
     (with-rig "upper.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let* ((up (lambda (n) (string-upcase (nid-text n))))
                (c (send-id g 'create (up 2)))
                (r (send-id g 'get-node (up 1)))
                (p (send-id g 'replace (up 1)))
                (l (send-id g 'list-revisions (up 1)))
                (v (send-id g 'get-revision (up 1)))
                (s ((rig-call g) 'POST (string-append (node-path-of (up 1)) "/revisions/1/restore")
                                 (list (key-h 1) (match-h 2)))))
           (list (list (answer-status c) (member-of (answer-json c) "id") (answer-header c "location"))
                 (list (answer-status r) (member-of (answer-json r) "id"))
                 (list (answer-status p) (member-of (answer-json p) "id"))
                 (answer-status l)
                 (answer-status v)
                 (list (answer-status s) (member-of (answer-json s) "id")))))))))

;;; Another account's node is a missing node

;; missing-request : Symbol Natural -> (List ...)     each route on node N, with A's key
(define (missing-request which n)
  (case which
    ((get-node) (list 'GET (node-path n) (list (key-h 1)) #f))
    ((replace) (list 'PUT (node-path n) (list (key-h 1) json-type (match-h 1)) plain))
    ((list-revisions) (list 'GET (revisions-path n) (list (key-h 1)) #f))
    ((get-revision) (list 'GET (revision-path n 1) (list (key-h 1)) #f))
    ((restore) (list 'POST (restore-path n 1) (list (key-h 1) (match-h 1)) #f))
    ((archive unarchive trash untrash purge) (event-request which n (list (key-h 1) (match-h 1))))
    ((move) (list 'POST (move-path n) (list (key-h 1) json-type (match-h 1)) (move-body #f)))
    ((move-children)
     (list 'POST (move-children-path n) (list (key-h 1) json-type (match-h 1)) (move-body #f)))
    (else (assertion-violation 'missing-request "no such route" which))))

;; Routes with a body run two jobs: the key's read job, then the write job.
(define body-routes '(replace move move-children))

(for-each
 (lambda (which)
   (test-equal (string-append "owner: " (symbol->string which)
                              " on B's node and on a missing one: the same 404, one job each (a PUT's and a move's two), B's node untouched")
     (list '(404 "not_found") '(404 "not_found") #t #t (if (memq which body-routes) 4 2) #t)
     (attempt
      (lambda ()
        (with-rig "other.db"
          (lambda (g)
            (seed-node! g acct-b 2 "note")
            (let* ((before (tables g))
                   (send (lambda (n) (let ((r (missing-request which n)))
                                       ((rig-call g) (car r) (cadr r) (caddr r) (cadddr r)))))
                   (other (send 2))
                   (missing (send 3)))
              (list (status+code other) (status+code missing)
                    (equal? (answer-body other) (answer-body missing))
                    (equal? (answer-headers other) (answer-headers missing))
                    ((rig-jobs g))
                    (equal? (map (lambda (t) (list-ref before t)) '(0 1 2 3))
                            (let ((after (tables g))) (map (lambda (t) (list-ref after t)) '(0 1 2 3))))))))))))
 (append '(get-node replace list-revisions get-revision restore) events '(move move-children)))

(test-equal "owner: A's list holds A's nodes and never B's"
  (list (nid-text 1) (nid-text 3))
  (attempt
   (lambda ()
     (with-rig "other-list.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (seed-node! g acct-b 2 "note")
         (seed-node! g acct-a 3 "task")
         (map (lambda (j) (member-of j "id")) (items (get! g 1 "/v1/nodes"))))))))

;;; PUT: the preconditions

(test-equal "put: neither If-Match nor If-None-Match is 428 precondition_required, no job"
  '(428 "precondition_required" 0)
  (attempt
   (lambda ()
     (with-rig "pre-none.db"
       (lambda (g)
         (let ((a (put! g 1 (list (key-h 1) json-type) plain)))
           (append (status+code a) (list ((rig-jobs g))))))))))

(for-each
 (lambda (bad)
   (test-equal (string-append "put: " (car bad) " is 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "pre-bad.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let ((a (put! g 1 (append (list (key-h 1) json-type) (cdr bad)) plain)))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 (list (list "both headers" (match-h 1) none-match)
       (list "If-Match: *" (cons "If-Match" "*"))
       (list "a list in If-Match" (cons "If-Match" "\"1\", \"2\""))
       (list "a weak tag" (cons "If-Match" "W/\"1\""))
       (list "If-Match twice" (match-h 1) (match-h 1))
       (list "If-None-Match twice" none-match none-match)
       (list "an ETag in If-None-Match" (cons "If-None-Match" "\"1\""))
       (list "an empty If-Match" (cons "If-Match" "\"\""))
       (list "a tag of 0" (cons "If-Match" "\"0\""))))

;;; PUT: the body

(for-each
 (lambda (bad)
   (test-equal (string-append "put: " (car bad) " is 415 unsupported_media_type, after the key's read job, no write job")
     '(415 "unsupported_media_type" 1 0)
     (attempt
      (lambda ()
        (with-rig "type.db"
          (lambda (g)
            (let ((a (put! g 1 (append (list (key-h 1) none-match) (cdr bad)) plain)))
              (append (status+code a) (list ((rig-reads g)) ((rig-writes g)))))))))))
 (list (list "no Content-Type")
       (list "text/plain" (cons "Content-Type" "text/plain"))
       (list "a +json type" (cons "Content-Type" "application/merge-patch+json"))
       (list "two Content-Types" json-type json-type)))

(test-equal "put: the media type in capitals, with a parameter, is JSON"
  '(201 201)
  (attempt
   (lambda ()
     (with-rig "type-ok.db"
       (lambda (g)
         (list (answer-status (put! g 1 (list (key-h 1) none-match
                                              (cons "Content-Type" "APPLICATION/JSON")) plain))
               (answer-status (put! g 2 (list (key-h 1) none-match
                                              (cons "Content-Type" "application/json; charset=utf-8"))
                                    plain))))))))

(test-equal "put: JSON that does not parse is 400 invalid_json, after the key's read job, no write job"
  '(400 "invalid_json" 1 0)
  (attempt
   (lambda ()
     (with-rig "bad-json.db"
       (lambda (g)
         (let ((a (put! g 1 (list (key-h 1) json-type none-match) "{\"title\": \"t\", nope")))
           (append (status+code a) (list ((rig-reads g)) ((rig-writes g))))))))))

(test-equal "put: an empty body is 400 invalid_request, as login's, after the key's read job, no write job"
  '(400 "invalid_request" 1 0)
  (attempt
   (lambda ()
     (with-rig "empty-body.db"
       (lambda (g)
         (let ((a (put! g 1 (list (key-h 1) json-type none-match) "")))
           (append (status+code a) (list ((rig-reads g)) ((rig-writes g))))))))))

;; big : Natural Char -> String     a body of N copies of C
(define (big n c) (make-string n c))

;; padded-request : Natural -> String
;; A create's JSON of exactly N bytes: a small node, and spaces before its
;; first member, so only the request's size is over any limit.
(define (padded-request n)
  (let ((base (string-length plain)))
    (string-append "{" (make-string (- n base) #\space) (substring plain 1 base))))

(test-equal "put: the request's cap is 2 MiB: a request of exactly 2 MiB (spaces and a small node) is 201, one byte more is 413, after the key's read job and with no write job"
  (list (list request-cap 201 1 1) (list (+ request-cap 1) 413 "payload_too_large" 1 0))
  (attempt
   (lambda ()
     (list (with-rig "at-request-cap.db"
             (lambda (g)
               (let* ((text (padded-request request-cap))
                      (a (put! g 1 (list (key-h 1) json-type none-match) text)))
                 (list (bytevector-length (string->utf8 text)) (answer-status a)
                       ((rig-reads g)) ((rig-writes g))))))
           (with-rig "over-request.db"
             (lambda (g)
               (let* ((text (padded-request (+ request-cap 1)))
                      (a (put! g 1 (list (key-h 1) json-type none-match) text)))
                 (append (list (bytevector-length (string->utf8 text)))
                         (status+code a) (list ((rig-reads g)) ((rig-writes g)))))))))))

(test-equal "put: a request over 2 MiB whose body is over 1 MiB too is 413, after the key's read job, no write job"
  '(#t 413 "payload_too_large" 1 0)
  (attempt
   (lambda ()
     (with-rig "over-both.db"
       (lambda (g)
         (let* ((text (content "note" "t" (big request-cap #\a) "text/plain"))
                (a (put! g 1 (list (key-h 1) json-type none-match) text)))
           (append (list (> (bytevector-length (string->utf8 text)) request-cap))
                   (status+code a) (list ((rig-reads g)) ((rig-writes g))))))))))

(test-equal "put: a body one byte over 1 MiB, in a request under 2 MiB, is 413 payload_too_large, after the key's read job, no write job"
  '(#t 413 "payload_too_large" 1 0)
  (attempt
   (lambda ()
     (with-rig "over-body.db"
       (lambda (g)
         (let* ((text (content "note" "t" (big (+ body-cap 1) #\a) "text/plain"))
                (a (put! g 1 (list (key-h 1) json-type none-match) text)))
           (append (list (< (bytevector-length (string->utf8 text)) request-cap))
                   (status+code a) (list ((rig-reads g)) ((rig-writes g))))))))))

(test-equal "put: a body of exactly 1 MiB is 201 and reads back whole; in two-byte characters too, and one more byte is 413"
  '(201 #t 201 #t (413 "payload_too_large"))
  (attempt
   (lambda ()
     (with-rig "at-cap.db"
       (lambda (g)
         (let* ((ascii (big body-cap #\a))
                (wide (big (div body-cap 2) (integer->char #xe9)))
                (a (create! g 1 1 "note" "t" ascii "text/plain"))
                (ra (get! g 1 (node-path 1)))
                (b (create! g 1 2 "note" "t" wide "text/plain"))
                (rb (get! g 1 (node-path 2)))
                (c (create! g 1 3 "note" "t" (string-append wide "a") "text/plain")))
           (list (answer-status a) (equal? (member-of (answer-json ra) "body") ascii)
                 (answer-status b) (equal? (member-of (answer-json rb) "body") wide)
                 (status+code c))))))))

;; bad-contents : (Listof (Pair String String))
;; Bodies parse-content refuses, each as JSON text; a create's, so kind is
;; required.
(define bad-contents
  (list (cons "an array" "[]")
        (cons "a string" "\"x\"")
        (cons "a number" "1")
        (cons "null" "null")
        (cons "an empty object" "{}")
        (cons "no kind on a create" "{\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "no title" "{\"kind\":\"note\",\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "no body" "{\"kind\":\"note\",\"title\":\"t\",\"content_type\":\"text/plain\"}")
        (cons "no content_type" "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\"}")
        (cons "an unknown member" "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"x\":1}")
        (cons "an id member" "{\"id\":\"x\",\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "a revision member" "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"revision\":1}")
        (cons "the title twice" "{\"kind\":\"note\",\"title\":\"t\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "a kind not of the five" "{\"kind\":\"folder\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "a kind in capitals" "{\"kind\":\"Note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "a kind of null" "{\"kind\":null,\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "a title that is a number" "{\"kind\":\"note\",\"title\":1,\"body\":\"b\",\"content_type\":\"text/plain\"}")
        (cons "a body of null" "{\"kind\":\"note\",\"title\":\"t\",\"body\":null,\"content_type\":\"text/plain\"}")
        (cons "a content_type that is an array" "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":[]}")
        (cons "props with a member" "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"props\":{\"a\":1}}")
        (cons "props an array" "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"props\":[]}")
        (cons "props null" "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"props\":null}")
        (cons "a title of 1001 characters" (content "note" (make-string 1001 #\t) "b" "text/plain"))
        (cons "U+0000 in the title" (content "note" (string #\a (integer->char 0) #\b) "b" "text/plain"))
        (cons "U+0000 in the body" (content "note" "t" (string #\a (integer->char 0) #\b) "text/plain"))
        (cons "an empty content_type" (content "note" "t" "b" ""))
        (cons "a content_type with no slash" (content "note" "t" "b" "text"))
        (cons "a content_type of 256 characters" (content "note" "t" "b" (string-append "text/" (make-string 251 #\x))))
        (cons "a content_type with a newline" (content "note" "t" "b" "text/plain\n"))
        (cons "a content_type past ASCII" (content "note" "t" "b" (string-append "text/" (string (integer->char #xe9)))))))

(for-each
 (lambda (bad)
   (test-equal (string-append "put: " (car bad)
                              ": 400 invalid_request, on an id in use, after the key's read job and with no write job: before the 412")
     '(400 "invalid_request" 1 0)
     (attempt
      (lambda ()
        (with-rig "bad-content.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let ((a (put! g 1 (list (key-h 1) json-type none-match) (cdr bad))))
              (append (status+code a) (list ((rig-reads g)) ((rig-writes g)))))))))))
 bad-contents)

(test-equal "put: a replace with a bad kind, or with props, is 400 before its stale If-Match's 412: a read job each, no write job"
  '((400 "invalid_request") (400 "invalid_request") 2 0)
  (attempt
   (lambda ()
     (with-rig "bad-replace.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let ((a (put! g 1 (list (key-h 1) json-type (match-h 7))
                        "{\"kind\":\"folder\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\"}"))
               (b (put! g 1 (list (key-h 1) json-type (match-h 7))
                        "{\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"props\":{\"a\":1}}")))
           (list (status+code a) (status+code b) ((rig-reads g)) ((rig-writes g)))))))))

(test-equal "put: a state member is one the route does not know: 400 invalid_request on a create and on a replace at the node's revision, a read job each, no write job, the node still active"
  '((400 "invalid_request") (400 "invalid_request") 2 0 "active")
  (attempt
   (lambda ()
     (with-rig "put-state.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let* ((a (put! g 2 (list (key-h 1) json-type none-match)
                         "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"state\":\"active\"}"))
                (b (put! g 1 (list (key-h 1) json-type (match-h 1))
                         "{\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"state\":\"archived\"}"))
                (reads ((rig-reads g)))
                (writes ((rig-writes g))))
           (list (status+code a) (status+code b) reads writes
                 (member-of (answer-json (get! g 1 (node-path 1))) "state"))))))))

;;; PUT: create

(test-equal "create: 201, ETag \"1\", Location in lower case, the node whole; the key's read job, then the write job"
  (list 201 "application/json" (tag 1) (string-append "/v1/nodes/" (nid-text 1))
        (node-json 1 "note" "a title" "a body" "text/plain" 1 now0 now0)
        '(read write))
  (attempt
   (lambda ()
     (with-rig "create.db"
       (lambda (g)
         (let ((a (create! g 1 1 "note" "a title" "a body" "text/plain")))
           (list (answer-status a) (answer-header a "content-type") (answer-header a "etag")
                 (answer-header a "location") (answer-json a) ((rig-order g)))))))))

(test-equal "create: then read: the node whole, its ETag; the row, one snapshot and one change row"
  (list 200 (tag 1) (node-json 1 "task" "t1" "b1" "text/markdown" 1 now0 now0)
        (list 1 "task" acct-a now0 now0)
        (list (list 1 acct-a "t1" "b1" "text/markdown" "{}" now0))
        (list (list 1 (nid 1) 1 "create" now0)))
  (attempt
   (lambda ()
     (with-rig "create-read.db"
       (lambda (g)
         (create! g 1 1 "task" "t1" "b1" "text/markdown")
         (let ((a (get! g 1 (node-path 1))))
           (list (answer-status a) (answer-header a "etag") (answer-json a)
                 (reverse (cdr (reverse (stored g 1))))
                 (snapshot-rows g 1)
                 (change-rows g acct-a))))))))

(test-equal "create: on an id A holds, and on one B holds: 412 precondition_failed, no ETag, a read job and a write job each, nothing written"
  '((412 "precondition_failed") #f (412 "precondition_failed") #f (read write read write) #t)
  (attempt
   (lambda ()
     (with-rig "create-used.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (seed-node! g acct-b 2 "note")
         (let* ((before (tables g))
                (a (create! g 1 1 "note" "t" "b" "text/plain"))
                (b (create! g 1 2 "note" "t" "b" "text/plain")))
           (list (status+code a) (answer-header a "etag") (status+code b) (answer-header b "etag")
                 ((rig-order g)) (equal? before (tables g)))))))))

(test-equal "create: B's create of its own id after A's: B's node, by B"
  (list 201 (list 1 "journal" acct-b now0 now0) '(404 "not_found"))
  (attempt
   (lambda ()
     (with-rig "create-b.db"
       (lambda (g)
         (create! g 1 1 "note" "t" "b" "text/plain")
         (let* ((a (create! g 3 2 "journal" "t" "b" "text/plain"))
                (r (get! g 1 (node-path 2))))
           (list (answer-status a) (reverse (cdr (reverse (stored g 2)))) (status+code r))))))))

;;; PUT: replace

(test-equal "replace: at the node's revision: 200, ETag \"2\", created kept, updated the clock, kind kept; a read job and a write job"
  (list 200 (tag 2) (node-json 1 "note" "t2" "b2" "text/markdown" 2 now0 (+ now0 5000)) 2)
  (attempt
   (lambda ()
     (with-rig "replace.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         ((rig-set-now! g) (+ now0 5000))
         (let* ((jobs ((rig-jobs g)))
                (a (replace! g 1 1 1 #f "t2" "b2" "text/markdown")))
           (list (answer-status a) (answer-header a "etag") (answer-json a)
                 (- ((rig-jobs g)) jobs))))))))

(test-equal "replace: the row, the snapshots and the change rows after it (H15: created kept; updated is the snapshot's and the change's time)"
  (list (list 2 "note" acct-a now0 (+ now0 5000))
        (list (list 1 acct-a "t1" "b1" "text/plain" "{}" now0)
              (list 2 acct-a "t2" "b2" "text/markdown" "{}" (+ now0 5000)))
        (list (list 1 (nid 1) 1 "create" now0)
              (list 2 (nid 1) 2 "update" (+ now0 5000))))
  (attempt
   (lambda ()
     (with-rig "replace-rows.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         ((rig-set-now! g) (+ now0 5000))
         (replace! g 1 1 1 #f "t2" "b2" "text/markdown")
         (list (reverse (cdr (reverse (stored g 1))))
               (snapshot-rows g 1)
               (change-rows g acct-a)))))))

(test-equal "replace: a stale If-Match is 412, no ETag, a read job and a write job, and nothing changed: rows, snapshots, changes, last_used"
  '((412 "precondition_failed") #f 2 #t)
  (attempt
   (lambda ()
     (with-rig "stale.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         (replace! g 1 1 1 #f "t2" "b2" "text/plain")
         ((rig-set-now! g) (+ now0 (* 2 day)))
         (let* ((before (tables g))
                (jobs ((rig-jobs g)))
                (a (replace! g 1 1 1 #f "t3" "b3" "text/plain")))
           (list (status+code a) (answer-header a "etag") (- ((rig-jobs g)) jobs)
                 (equal? before (tables g)))))))))

(test-equal "replace: a revision past the node's is stale too"
  '(412 "precondition_failed")
  (attempt
   (lambda ()
     (with-rig "ahead.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (status+code (replace! g 1 1 2 #f "t" "b" "text/plain")))))))

(test-equal "replace: a missing node is 404, a read job and a write job, nothing written"
  '((404 "not_found") 2 #t)
  (attempt
   (lambda ()
     (with-rig "replace-missing.db"
       (lambda (g)
         (let* ((before (tables g))
                (a (replace! g 1 1 1 #f "t" "b" "text/plain")))
           (list (status+code a) ((rig-jobs g)) (equal? before (tables g)))))))))

(test-equal "replace: naming another kind is 409 kind_fixed; stale and naming another kind is 412; nothing written"
  '((409 "kind_fixed") (412 "precondition_failed") #t #f)
  (attempt
   (lambda ()
     (with-rig "kind.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let* ((before (tables g))
                (a (replace! g 1 1 1 "task" "t" "b" "text/plain"))
                (b (replace! g 1 1 2 "task" "t" "b" "text/plain")))
           (list (status+code a) (status+code b) (equal? before (tables g))
                 (answer-header a "etag"))))))))

(test-equal "replace: the same kind, or none, is 200 and the kind kept (H11)"
  (list (list 200 "contact" 2) (list 200 "contact" 3) "contact")
  (attempt
   (lambda ()
     (with-rig "kind-same.db"
       (lambda (g)
         (seed-node! g acct-a 1 "contact")
         (let* ((a (replace! g 1 1 1 "contact" "t" "b" "text/plain"))
                (b (replace! g 1 1 2 #f "t" "b" "text/plain")))
           (list (list (answer-status a) (member-of (answer-json a) "kind") (member-of (answer-json a) "revision"))
                 (list (answer-status b) (member-of (answer-json b) "kind") (member-of (answer-json b) "revision"))
                 (cadr (stored g 1)))))))))

(test-equal "replace: the same content twice is two revisions, two snapshots, two change rows"
  '((200 2) (200 3) (1 2 3) (1 2 3))
  (attempt
   (lambda ()
     (with-rig "twice.db"
       (lambda (g)
         (create! g 1 1 "note" "t" "b" "text/plain")
         (let* ((a (replace! g 1 1 1 #f "t" "b" "text/plain"))
                (b (replace! g 1 1 2 #f "t" "b" "text/plain")))
           (list (list (answer-status a) (member-of (answer-json a) "revision"))
                 (list (answer-status b) (member-of (answer-json b) "revision"))
                 (map car (snapshot-rows g 1))
                 (map car (change-rows g acct-a)))))))))

;;; H5: a refused write leaves no row, no change number and no last_used

(test-equal "H5: each refused write, the key's first, is refused in its write job (a PUT's after the key's read job) and leaves every table as it was, last_used null"
  '(((412 "precondition_failed") 2 #t #f)
    ((404 "not_found") 2 #t #f)
    ((409 "kind_fixed") 2 #t #f)
    ((412 "precondition_failed") 2 #t #f)
    ((404 "not_found") 1 #t #f)
    ((412 "precondition_failed") 1 #t #f))
  (attempt
   (lambda ()
     (map (lambda (refused)
            (with-rig "h5.db"
              (lambda (g)
                (seed-node! g acct-a 1 "note")
                (seed-node! g acct-b 2 "note")
                (let* ((before (tables g))
                       (a (refused g)))
                  (list (status+code a) ((rig-jobs g)) (equal? before (tables g)) (last-used g 1))))))
          (list (lambda (g) (create! g 1 1 "note" "t" "b" "text/plain"))
                (lambda (g) (replace! g 1 2 1 #f "t" "b" "text/plain"))
                (lambda (g) (replace! g 1 1 1 "task" "t" "b" "text/plain"))
                (lambda (g) (replace! g 1 1 3 #f "t" "b" "text/plain"))
                (lambda (g) (restore! g 1 1 4 1))
                (lambda (g) (restore! g 1 1 1 3)))))))

(test-equal "H5: an accepted write sets the key's last_used, so the refusals above would have shown it"
  now0
  (attempt
   (lambda ()
     (with-rig "h5-accepted.db"
       (lambda (g)
         (create! g 1 1 "note" "t" "b" "text/plain")
         (last-used g 1))))))

;;; Restore

(test-equal "restore: snapshot 1 copied as revision 3: title, body, content type and props; kind and created kept"
  (list 200 (tag 3) (node-json 1 "note" "t1" "b1" "text/plain" 3 now0 (+ now0 9000))
        (list 3 acct-a "t1" "b1" "text/plain" "{}" (+ now0 9000))
        (list 3 (nid 1) 3 "restore" (+ now0 9000)))
  (attempt
   (lambda ()
     (with-rig "restore.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         ((rig-set-now! g) (+ now0 5000))
         (replace! g 1 1 1 #f "t2" "b2" "text/markdown")
         ((rig-set-now! g) (+ now0 9000))
         (let ((a (restore! g 1 1 1 2)))
           (list (answer-status a) (answer-header a "etag") (answer-json a)
                 (list-ref (snapshot-rows g 1) 2)
                 (list-ref (change-rows g acct-a) 2))))))))

(test-equal "restore: the newest snapshot may be restored: one more revision, the same content"
  (list 200 (tag 3) (node-json 1 "note" "t2" "b2" "text/markdown" 3 now0 now0) '(1 2 3))
  (attempt
   (lambda ()
     (with-rig "restore-newest.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         (replace! g 1 1 1 #f "t2" "b2" "text/markdown")
         (let ((a (restore! g 1 1 2 2)))
           (list (answer-status a) (answer-header a "etag") (answer-json a)
                 (map car (snapshot-rows g 1)))))))))

(test-equal "restore: an unknown n at the node's revision is 404; at a stale one 412; nothing written either time"
  '((404 "not_found") (412 "precondition_failed") #t 2)
  (attempt
   (lambda ()
     (with-rig "restore-unknown.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let* ((before (tables g))
                (a (restore! g 1 1 2 1))
                (b (restore! g 1 1 2 5)))
           (list (status+code a) (status+code b) (equal? before (tables g)) ((rig-jobs g)))))))))

;; The table's differ x restore and differ x restore-unknown are both 412.
;; The job names restore whenever the node has snapshot n, so a stale
;; restore of one it has steps differ x restore.
(test-equal "restore: a stale If-Match is 412 whether the node has snapshot n or not, behind its revision or past it: one job each, nothing written"
  '((412 "precondition_failed") (412 "precondition_failed") (412 "precondition_failed")
    (412 "precondition_failed") (412 "precondition_failed") #t 5)
  (attempt
   (lambda ()
     (with-rig "restore-stale.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (run-write (rig-store g)
                    (lambda (tx) (write-node! tx (nid 1) acct-a 1 "t2" "b2" "text/plain" "{}" "update" 6000)))
         (let* ((before (tables g))
                (a (restore! g 1 1 1 1))
                (b (restore! g 1 1 2 1))
                (c (restore! g 1 1 1 3))
                (d (restore! g 1 1 5 1))
                (e (restore! g 1 1 5 3)))
           (append (map status+code (list a b c d e))
                   (list (equal? before (tables g)) ((rig-jobs g))))))))))

(test-equal "restore: at the node's revision, a snapshot n that only another of A's nodes has is 404, one job, nothing written"
  '((404 "not_found") #t 1)
  (attempt
   (lambda ()
     (with-rig "restore-other-node.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (seed-node! g acct-a 2 "note")
         (run-write (rig-store g)
                    (lambda (tx) (write-node! tx (nid 2) acct-a 1 "t2" "b2" "text/plain" "{}" "update" 6000)))
         (let* ((before (tables g))
                (a (restore! g 1 1 2 1)))
           (list (status+code a) (equal? before (tables g)) ((rig-jobs g)))))))))

(test-equal "snapshot and restore: of two nodes of A at the same revisions, each reads and restores its own snapshot"
  '(("1 t1" "1 b1") ("1 t2" "1 b2") ("2 t1" "2 b1") ("2 t2" "2 b2")
    (200 "2 t1" "2 b1") (200 "1 t1" "1 b1"))
  (attempt
   (lambda ()
     (with-rig "right-node.db"
       (lambda (g)
         (create! g 1 1 "note" "1 t1" "1 b1" "text/plain")
         (create! g 1 2 "note" "2 t1" "2 b1" "text/plain")
         (replace! g 1 1 1 #f "1 t2" "1 b2" "text/plain")
         (replace! g 1 2 1 #f "2 t2" "2 b2" "text/plain")
         (let* ((content (lambda (a) (list (member-of (answer-json a) "title")
                                           (member-of (answer-json a) "body"))))
                (s11 (content (get! g 1 (revision-path 1 1))))
                (s12 (content (get! g 1 (revision-path 1 2))))
                (s21 (content (get! g 1 (revision-path 2 1))))
                (s22 (content (get! g 1 (revision-path 2 2))))
                (r2 (restore! g 1 2 1 2))
                (r1 (restore! g 1 1 1 2)))
           (list s11 s12 s21 s22
                 (cons (answer-status r2) (content r2))
                 (cons (answer-status r1) (content r1)))))))))

(test-equal "restore: no If-Match is 428, no job"
  '(428 "precondition_required" 0)
  (attempt
   (lambda ()
     (with-rig "restore-none.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let ((a ((rig-call g) 'POST (restore-path 1 1) (list (key-h 1)))))
           (append (status+code a) (list ((rig-jobs g))))))))))

(for-each
 (lambda (bad)
   (test-equal (string-append "restore: " (car bad) " is 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "restore-bad-pre.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let ((a ((rig-call g) 'POST (restore-path 1 1) (cons (key-h 1) (cdr bad)))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 (list (list "If-None-Match: *" none-match)
       (list "both headers" (match-h 1) none-match)
       (list "a weak tag" (cons "If-Match" "W/\"1\""))
       (list "If-Match twice" (match-h 1) (match-h 1))))

(for-each
 (lambda (n)
   (test-equal (string-append "restore: n of " n " is 400 invalid_request, no job; so is it with no If-Match")
     '((400 "invalid_request" 0) (400 "invalid_request" 0))
     (attempt
      (lambda ()
        (with-rig "restore-bad-n.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let* ((p (string-append (revisions-path 1) "/" n "/restore"))
                   (a ((rig-call g) 'POST p (list (key-h 1) (match-h 1))))
                   (ja ((rig-jobs g)))
                   (b ((rig-call g) 'POST p (list (key-h 1))))
                   (jb ((rig-jobs g))))
              (list (append (status+code a) (list ja)) (append (status+code b) (list jb))))))))))
 '("0" "01" "x" "-1" "9007199254740993"))

(test-equal "restore: a body is not read: text/plain, or JSON that does not parse, and still 200"
  '(200 201 200 3)
  (attempt
   (lambda ()
     (with-rig "restore-body.db"
       (lambda (g)
         (let* ((c (create! g 1 1 "note" "t" "b" "text/plain"))
                (a ((rig-call g) 'POST (restore-path 1 1)
                                 (list (key-h 1) (match-h 1) (cons "Content-Type" "text/plain"))
                                 "not json at all"))
                (b ((rig-call g) 'POST (restore-path 1 1)
                                 (list (key-h 1) (match-h 2) json-type)
                                 "{nope")))
           (list (answer-status a) (answer-status c) (answer-status b)
                 (member-of (answer-json b) "revision"))))))))

;;; GET /v1/nodes/:id and /v1/nodes/:id/revisions/:n

(test-equal "read: a node is 200 with its ETag, one read job and no write job"
  (list 200 (tag 1) (node-json 1 "project" "seed" "seed body" "text/plain" 1 5000 5000) 1 0)
  (attempt
   (lambda ()
     (with-rig "read.db"
       (lambda (g)
         (seed-node! g acct-a 1 "project")
         (let ((a (get! g 1 (node-path 1))))
           (list (answer-status a) (answer-header a "etag") (answer-json a)
                 ((rig-reads g)) ((rig-writes g)))))))))

;; A read goes through the reader: the writer would set the key's
;; last_used, which a read never does.
(for-each
 (lambda (which)
   (test-equal (string-append "read: " (symbol->string which)
                              " is 200 in one read job and no write job; the key's last_used stays null")
     '(200 1 0 #f)
     (attempt
      (lambda ()
        (with-rig "read-runner.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let ((a (send g which (list (key-h 1)))))
              (list (answer-status a) ((rig-reads g)) ((rig-writes g)) (last-used g 1)))))))))
 '(list-nodes get-node list-revisions get-revision))

(test-equal "read: If-Match and If-None-Match on a GET are ignored"
  '(200 200)
  (attempt
   (lambda ()
     (with-rig "read-pre.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (list (answer-status ((rig-call g) 'GET (node-path 1) (list (key-h 1) (cons "If-Match" "W/\"9\""))))
               (answer-status ((rig-call g) 'GET (node-path 1) (list (key-h 1) none-match (match-h 4))))))))))

(test-equal "snapshot: one snapshot whole, and the older one after a replace"
  (list 200 (snapshot-json 1 "t1" "b1" "text/plain" now0)
        (snapshot-json 2 "t2" "b2" "text/markdown" (+ now0 5000)))
  (attempt
   (lambda ()
     (with-rig "snapshot.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         ((rig-set-now! g) (+ now0 5000))
         (replace! g 1 1 1 #f "t2" "b2" "text/markdown")
         (let ((a (get! g 1 (revision-path 1 1))))
           (list (answer-status a) (answer-json a)
                 (answer-json (get! g 1 (revision-path 1 2))))))))))

(test-equal "snapshot: an n the node has not reached is 404, one job"
  '((404 "not_found") 1)
  (attempt
   (lambda ()
     (with-rig "snapshot-missing.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (list (status+code (get! g 1 (revision-path 1 2))) ((rig-jobs g))))))))

(for-each
 (lambda (n)
   (test-equal (string-append "snapshot: n of " n " is 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "snapshot-bad-n.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let ((a (get! g 1 (string-append (revisions-path 1) "/" n))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 '("0" "01" "x" "+1"))

(test-equal "props: stored props other than {} are no answer: a 500, its logged raise naming no title, body or props"
  '((500 "internal") #t #f #f #f)
  (attempt
   (lambda ()
     (with-rig "props.db"
       (lambda (g)
         (run-write (rig-store g)
                    (lambda (tx) (insert-node! tx (nid 1) acct-a "note" "props-title" "props-body"
                                               "text/plain" "{\"a\":1}" #f 5000)))
         (let-values (((a text) (capture-output (lambda () (get! g 1 (node-path 1))))))
           (list (status+code a) (contains? text "handler-failed")
                 (contains? text "props-title") (contains? text "props-body")
                 (contains? text "\"a\""))))))))

;;; GET /v1/nodes

;; many-nodes! : Rig -> Void
;; A's nodes 10 to 114 (105 of them), and B's 200 to 204, through the store.
(define (many-nodes! g)
  (run-write (rig-store g)
             (lambda (tx)
               (let loop ((n 10))
                 (when (<= n 114)
                   (insert-node! tx (nid n) acct-a "note" (string-append "n" (number->string n))
                                 "body" "text/plain" "{}" #f (+ 6000 n))
                   (loop (+ n 1))))
               (let loop ((n 200))
                 (when (<= n 204)
                   (insert-node! tx (nid n) acct-b "note" "b" "body" "text/plain" "{}" #f 7000)
                   (loop (+ n 1)))))))

;; page : Rig String -> (List Natural (U String 'null) (U String #f))
;; How many items, next, and the last item's id.
(define (page g query)
  (let* ((a (get! g 1 (string-append "/v1/nodes" query)))
         (is (items a)))
    (list (length is) (member-of (answer-json a) "next")
          (if (null? is) #f (member-of (car (reverse is)) "id")))))

(test-equal "list: the default is 50; 100 and over are 100 (ADR-0002's cap); next is the last id shown, null at the end"
  (list (list 50 (nid-text 59) (nid-text 59))
        (list 100 (nid-text 109) (nid-text 109))
        (list 100 (nid-text 109) (nid-text 109))
        (list 5 'null (nid-text 114)))
  (attempt
   (lambda ()
     (with-rig "list.db"
       (lambda (g)
         (many-nodes! g)
         (list (page g "")
               (page g "?limit=100")
               (page g "?limit=101")
               (page g (string-append "?limit=100&after=" (nid-text 109)))))))))

(test-equal "list: pages of 7 cover A's 105 nodes once each, by id rising, and none of B's"
  (list 105 #t #t)
  (attempt
   (lambda ()
     (with-rig "list-walk.db"
       (lambda (g)
         (many-nodes! g)
         (let loop ((after #f) (seen '()) (pages 0))
           (let* ((a (get! g 1 (string-append "/v1/nodes?limit=7"
                                              (if after (string-append "&after=" after) ""))))
                  (ids (map (lambda (j) (member-of j "id")) (items a)))
                  (seen (append seen ids))
                  (next (member-of (answer-json a) "next")))
             (if (or (eq? next 'null) (> pages 30))
                 (list (length seen)
                       (equal? seen (let build ((n 10) (acc '()))
                                      (if (> n 114) (reverse acc) (build (+ n 1) (cons (nid-text n) acc)))))
                       (= pages 14))
                 (loop next seen (+ pages 1))))))))))

(test-equal "list: a page that ends on the last node has next null; one before it has next"
  (list (list 5 'null (nid-text 114)) (list 4 (nid-text 113) (nid-text 113)))
  (attempt
   (lambda ()
     (with-rig "list-edge.db"
       (lambda (g)
         (many-nodes! g)
         (list (page g (string-append "?limit=5&after=" (nid-text 109)))
               (page g (string-append "?limit=4&after=" (nid-text 109)))))))))

(test-equal "list: an item is the node without its body, members in order (H12, H20)"
  (list (item-json 1 "task" "t1" "text/markdown" 1 now0 now0) #f #f)
  (attempt
   (lambda ()
     (with-rig "list-item.db"
       (lambda (g)
         (create! g 1 1 "task" "t1" "a body that is not in a list" "text/markdown")
         (let ((a (get! g 1 "/v1/nodes")))
           (list (car (items a))
                 (contains? (answer-body a) "a body that is not in a list")
                 (contains? (answer-body a) "num"))))))))

(test-equal "list: no item in a page of many has a body member"
  '(50 #f)
  (attempt
   (lambda ()
     (with-rig "list-nobody.db"
       (lambda (g)
         (many-nodes! g)
         (let ((is (items (get! g 1 "/v1/nodes"))))
           (list (length is) (exists (lambda (j) (assoc "body" j)) is))))))))

(test-equal "list: after in capitals is the same id; after an id in no row starts past it"
  (list (list 2 (nid-text 12) (nid-text 12)) (list 1 (nid-text 10) (nid-text 10)))
  (attempt
   (lambda ()
     (with-rig "list-after.db"
       (lambda (g)
         (many-nodes! g)
         (list (page g (string-append "?limit=2&after=" (string-upcase (nid-text 10))))
               (page g (string-append "?limit=1&after=" (nid-text 3)))))))))

(for-each
 (lambda (q)
   (test-equal (string-append "list: ?" q " is a 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "list-bad.db"
          (lambda (g)
            (let ((a (get! g 1 (string-append "/v1/nodes?" q))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 (list "limit=0" "limit=x" "limit=" "limit=-1" "limit=2&limit=3"
       "after=x" "after=" (string-append "after=" v4-text)
       (string-append "after=" (nid-text 1) "&after=" (nid-text 2))))

(test-equal "list: a bad limit with no key is the 401, with an unknown key the 400: the key's shape, then the query, then the key"
  '((401 "unauthorized" 0) (400 "invalid_request" 0))
  (attempt
   (lambda ()
     (with-rig "list-bad-key.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'GET "/v1/nodes?limit=0"))
                (ja ((rig-jobs g)))
                (b ((rig-call g) 'GET "/v1/nodes?limit=0" (list (key-h 9))))
                (jb ((rig-jobs g))))
           (list (append (status+code a) (list ja)) (append (status+code b) (list jb)))))))))

(test-equal "list: an account with no nodes has an empty page"
  (list 200 (list (cons "items" (vector)) (cons "next" 'null)))
  (attempt
   (lambda ()
     (with-rig "list-empty.db"
       (lambda (g)
         (let ((a (get! g 3 "/v1/nodes")))
           (list (answer-status a) (answer-json a))))))))

;;; GET /v1/nodes/:id/revisions

;; five-revisions! : Rig -> Void     A's node 1 at revision 5, through the store
(define (five-revisions! g)
  (run-write (rig-store g)
             (lambda (tx)
               (insert-node! tx (nid 1) acct-a "note" "r1" "body 1" "text/plain" "{}" #f 100)
               (let loop ((r 1))
                 (when (< r 5)
                   (write-node! tx (nid 1) acct-a r (string-append "r" (number->string (+ r 1)))
                                "body" "text/plain" "{}" "update" (+ 100 r))
                   (loop (+ r 1)))))))

;; revisions : Rig String -> (List (Listof Natural) Any)
(define (revisions g query)
  (let ((a (get! g 1 (string-append (revisions-path 1) query))))
    (list (map (lambda (j) (member-of j "revision")) (items a)) (member-of (answer-json a) "next"))))

(test-equal "revisions: newest first, strictly falling; next the last revision shown, a number; null at the end"
  '(((5 4 3 2 1) null) ((5 4) 4) ((3 2) 2) ((1) null) ((2 1) null) (() null))
  (attempt
   (lambda ()
     (with-rig "revisions.db"
       (lambda (g)
         (five-revisions! g)
         (list (revisions g "")
               (revisions g "?limit=2")
               (revisions g "?limit=2&after=4")
               (revisions g "?limit=2&after=2")
               (revisions g "?after=3")
               (revisions g "?after=1")))))))

(test-equal "revisions: an item is the snapshot without its body, members in order"
  (list (snapshot-item 5 "r5" "text/plain" 104) #f)
  (attempt
   (lambda ()
     (with-rig "revisions-item.db"
       (lambda (g)
         (five-revisions! g)
         (let ((a (get! g 1 (revisions-path 1))))
           (list (car (items a)) (exists (lambda (j) (assoc "body" j)) (items a)))))))))

(test-equal "revisions: a missing node and B's node are 404 in one job each, not an empty page; B's own is 200"
  '((404 "not_found") (404 "not_found") 2 200)
  (attempt
   (lambda ()
     (with-rig "revisions-missing.db"
       (lambda (g)
         (seed-node! g acct-b 2 "note")
         (let* ((a (get! g 1 (revisions-path 2)))
                (b (get! g 1 (revisions-path 3)))
                (jobs ((rig-jobs g)))
                (c (get! g 3 (revisions-path 2))))
           (list (status+code a) (status+code b) jobs (answer-status c))))))))

(for-each
 (lambda (q)
   (test-equal (string-append "revisions: ?" q " is a 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "revisions-bad.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let ((a (get! g 1 (string-append (revisions-path 1) "?" q))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 '("limit=0" "limit=x" "after=0" "after=01" "after=x" "after=" "after=1&after=2"))

;;; H14, H15, H16, H20 across a node's life

(test-equal "H14: the ETag is the JSON's revision and the stored row's, after a create, a replace and a restore"
  '((#t #t) (#t #t) (#t #t) (#t #t))
  (attempt
   (lambda ()
     (with-rig "h14.db"
       (lambda (g)
         (let ((check (lambda (a)
                        (let ((rev (member-of (answer-json a) "revision")))
                          (list (equal? (answer-header a "etag") (tag rev))
                                (equal? rev (car (stored g 1))))))))
           (let* ((a (create! g 1 1 "note" "t" "b" "text/plain"))
                  (ca (check a))
                  (b (replace! g 1 1 1 #f "t2" "b2" "text/plain"))
                  (cb (check b))
                  (c (restore! g 1 1 1 2))
                  (cc (check c))
                  (d (get! g 1 (node-path 1))))
             (list ca cb cc (check d)))))))))

(test-equal "H16: author is the asking account, in the node's row and in each snapshot; B's writes are B's"
  (list acct-b (list acct-b acct-b acct-b) acct-a (list acct-a))
  (attempt
   (lambda ()
     (with-rig "h16.db"
       (lambda (g)
         (create! g 1 1 "note" "t" "b" "text/plain")
         (create! g 3 2 "note" "t" "b" "text/plain")
         (replace! g 3 2 1 #f "t2" "b2" "text/plain")
         (restore! g 3 2 1 2)
         (list (caddr (stored g 2)) (map cadr (snapshot-rows g 2))
               (caddr (stored g 1)) (map cadr (snapshot-rows g 1))))))))

(test-equal "H20: num is in the row, and in no answer: not create's, replace's, restore's, read's, a list's, a snapshot's"
  '(#t (#f #f #f #f #f #f #f))
  (attempt
   (lambda ()
     (with-rig "h20.db"
       (lambda (g)
         (let* ((a (create! g 1 1 "note" "t" "b" "text/plain"))
                (b (replace! g 1 1 1 #f "t" "b" "text/plain"))
                (c (restore! g 1 1 1 2))
                (d (get! g 1 (node-path 1)))
                (e (get! g 1 "/v1/nodes"))
                (f (get! g 1 (revisions-path 1)))
                (h (get! g 1 (revision-path 1 1))))
           (list (integer? (list-ref (stored g 1) 5))
                 (map (lambda (x) (contains? (answer-body x) "num"))
                      (list a b c d e f h)))))))))

;;; The order of checks

(test-equal "order: a bad id with no precondition is the 400: the id before the preconditions"
  '((400 "invalid_request") (400 "invalid_request") 0)
  (attempt
   (lambda ()
     (with-rig "order-id.db"
       (lambda (g)
         (let ((a ((rig-call g) 'PUT (node-path-of v4-text) (list (key-h 1) json-type) plain))
               (b ((rig-call g) 'POST (string-append (node-path-of v4-text) "/revisions/1/restore")
                               (list (key-h 1)))))
           (list (status+code a) (status+code b) ((rig-jobs g)))))))))

(test-equal "order: no precondition and no Content-Type is the 428: the preconditions before the media type"
  '(428 "precondition_required" 0)
  (attempt
   (lambda ()
     (with-rig "order-pre.db"
       (lambda (g)
         (let ((a (put! g 1 (list (key-h 1)) plain)))
           (append (status+code a) (list ((rig-jobs g))))))))))

(test-equal "order: a bad precondition and JSON that does not parse is the 400 invalid_request"
  '(400 "invalid_request" 0)
  (attempt
   (lambda ()
     (with-rig "order-pre-json.db"
       (lambda (g)
         (let ((a (put! g 1 (list (key-h 1) json-type (cons "If-Match" "*")) "{nope")))
           (append (status+code a) (list ((rig-jobs g))))))))))

(test-equal "order: text/plain, or a +json type wrap-json-body would read, with a body over 2 MiB or one that does not parse, is the 415, after the key's read job: the media type before the body"
  '((415 "unsupported_media_type") (415 "unsupported_media_type")
    (415 "unsupported_media_type") (415 "unsupported_media_type") 4 0)
  (attempt
   (lambda ()
     (with-rig "order-type.db"
       (lambda (g)
         (let* ((huge (content "note" "t" (big request-cap #\a) "text/plain"))
                (send (lambda (type text)
                        (status+code (put! g 1 (list (key-h 1) none-match (cons "Content-Type" type))
                                           text))))
                (a (send "text/plain" huge))
                (b (send "text/plain" "{nope"))
                (c (send "application/merge-patch+json" huge))
                (d (send "application/merge-patch+json" "{nope")))
           (list a b c d ((rig-reads g)) ((rig-writes g)))))))))

(test-equal "order: a bad body with an unknown key is the 401, in the key's read job: the key before the body"
  '(401 "unauthorized" 1 0)
  (attempt
   (lambda ()
     (with-rig "order-body-key.db"
       (lambda (g)
         (let ((a (put! g 1 (list (key-h 9) json-type none-match) "{}")))
           (append (status+code a) (list ((rig-reads g)) ((rig-writes g))))))))))

(test-equal "order: a body over 1 MiB on an id in use, with an unknown key, is the 401, in the key's read job"
  '(401 "unauthorized" 1 0)
  (attempt
   (lambda ()
     (with-rig "order-big-key.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let ((a (put! g 1 (list (key-h 9) json-type none-match)
                        (content "note" "t" (big (+ body-cap 1) #\a) "text/plain"))))
           (append (status+code a) (list ((rig-reads g)) ((rig-writes g))))))))))

(test-equal "order: with an unknown key, a bad id is still the 400 and no precondition the 428, with no job: the cheap checks before the key"
  '((400 "invalid_request") (428 "precondition_required") 0)
  (attempt
   (lambda ()
     (with-rig "order-id-key.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'PUT (node-path-of v4-text) (list (key-h 9) json-type none-match) plain))
                (b (put! g 1 (list (key-h 9) json-type) plain)))
           (list (status+code a) (status+code b) ((rig-jobs g)))))))))

(test-equal "order: a revoked key on a create is the 401 in the key's read job, the body not read"
  '(401 "unauthorized" (read))
  (attempt
   (lambda ()
     (with-rig "order-revoked.db"
       (lambda (g)
         (run-write (rig-store g) (lambda (tx) (revoke-key! tx acct-a (kid 1) 1500)))
         (let ((a (put! g 1 (list (key-h 1) json-type none-match) "{nope")))
           (append (status+code a) (list ((rig-order g))))))))))

(test-equal "order: an unknown key on B's node, at its revision, is the 401: the key before the work"
  '((401 "unauthorized") (401 "unauthorized"))
  (attempt
   (lambda ()
     (with-rig "order-key-work.db"
       (lambda (g)
         (seed-node! g acct-b 2 "note")
         (list (status+code (replace! g 9 2 1 #f "t" "b" "text/plain"))
               (status+code (restore! g 9 2 1 1))))))))

;;; A PUT's key is checked before its body is read

;; hostile-json : String
;; An array of 2,000 integers of 1,000 digits, about 2 MB: under the
;; request's cap, and costly to parse (about 260 ms of the loop's time by
;; the closing review's probe), though no node.
(define hostile-json
  (call-with-string-output-port
   (lambda (p)
     (put-string p "[")
     (let loop ((i 0))
       (when (< i 2000)
         (put-string p (make-string 1000 #\7))
         (put-string p ",")
         (loop (+ i 1))))
     (put-string p "1]"))))

(define hostile-length (bytevector-length (string->utf8 hostile-json)))

;; put-head : Natural (Listof Header) Natural -> Bytevector
;; The head alone of a PUT to node N, with HEADERS and a Content-Length of
;; LENGTH: the client has sent no byte of the body yet.
(define (put-head n headers length)
  (request-bytes 'PUT (node-path n)
                 (append headers (list (cons "Content-Length" (number->string length))))))

(test-equal "hostile: a 2 MB body's head alone, with an unknown key, is the 401 at once, from the key's read job: no byte of the body was needed, and the connection is ended"
  (list #t '((401 "unauthorized")) #f #t '(read))
  (attempt
   (lambda ()
     (with-rig "hostile-head.db"
       (lambda (g)
         (let-values (((answers waiting? closed?)
                       (exchange-steps (rig-handler g)
                                       (list (put-head 1 (list (key-h 9) json-type none-match)
                                                       hostile-length)))))
           (list (< hostile-length request-cap) (map status+code answers) waiting? closed?
                 ((rig-order g)))))))))

(test-equal "hostile: the same head with A's key is not answered yet: after the key's read job its handler waits for the body"
  '(() #t (read))
  (attempt
   (lambda ()
     (with-rig "hostile-head-a.db"
       (lambda (g)
         (let-values (((answers waiting? closed?)
                       (exchange-steps (rig-handler g)
                                       (list (put-head 1 (list (key-h 1) json-type none-match)
                                                       hostile-length)))))
           (list (map status+code answers) waiting? ((rig-order g)))))))))

(test-equal "hostile: the whole body with an unknown key is the 401 from the key's read job; with A's key it is read and parsed, and refused as no node, 400, with no write job"
  '((401 "unauthorized") (read) (400 "invalid_request") (read))
  (attempt
   (lambda ()
     (list (with-rig "hostile-unknown.db"
             (lambda (g) (status+code (put! g 1 (list (key-h 9) json-type none-match) hostile-json))))
           (with-rig "hostile-unknown-jobs.db"
             (lambda (g) (put! g 1 (list (key-h 9) json-type none-match) hostile-json) ((rig-order g))))
           (with-rig "hostile-a.db"
             (lambda (g) (status+code (put! g 1 (list (key-h 1) json-type none-match) hostile-json))))
           (with-rig "hostile-a-jobs.db"
             (lambda (g) (put! g 1 (list (key-h 1) json-type none-match) hostile-json) ((rig-order g))))))))

(test-equal "time: a create whose body comes after the wall clock has moved is stamped with the time read once the body had come: created, updated, the snapshot's, the change row's, last_used"
  (let ((t (+ now0 7000)))
    (list 201 t t (list 1 "note" acct-a t t) t t t))
  (attempt
   (lambda ()
     (with-rig "time.db"
       (lambda (g)
         (let ((bytes (string->utf8 (content "note" "t" "b" "text/plain"))))
           (let-values (((answers waiting? closed?)
                         (exchange-steps (rig-handler g)
                                         (list (put-head 1 (list (key-h 1) json-type none-match)
                                                         (bytevector-length bytes))
                                               (lambda () ((rig-set-now! g) (+ now0 7000)))
                                               bytes))))
             (let ((a (car answers)))
               (list (answer-status a) (member-of (answer-json a) "created")
                     (member-of (answer-json a) "updated")
                     (reverse (cdr (reverse (stored g 1))))
                     (list-ref (car (snapshot-rows g 1)) 6)
                     (list-ref (car (change-rows g acct-a)) 4)
                     (last-used g 1))))))))))

(test-equal "time: a replace whose body comes late keeps created and takes the later time as updated"
  (list 200 now0 (+ now0 9000) (+ now0 9000))
  (attempt
   (lambda ()
     (with-rig "time-replace.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         ((rig-set-now! g) (+ now0 5000))
         (let ((bytes (string->utf8 (content #f "t2" "b2" "text/plain"))))
           (let-values (((answers waiting? closed?)
                         (exchange-steps (rig-handler g)
                                         (list (put-head 1 (list (key-h 1) json-type (match-h 1))
                                                         (bytevector-length bytes))
                                               (lambda () ((rig-set-now! g) (+ now0 9000)))
                                               bytes))))
             (let ((a (car answers)))
               (list (answer-status a) (member-of (answer-json a) "created")
                     (member-of (answer-json a) "updated")
                     (list-ref (cadr (snapshot-rows g 1)) 6))))))))))

(test-equal "revoked: a key revoked after the head came and before the body did is the 401 from the write job, which checks it again: nothing written, last_used null"
  '(((401 "unauthorized")) (read write) #t #f)
  (attempt
   (lambda ()
     (with-rig "revoked-between.db"
       (lambda (g)
         (let* ((bytes (string->utf8 (content "note" "t" "b" "text/plain")))
                (before (tables g)))
           (let-values (((answers waiting? closed?)
                         (exchange-steps (rig-handler g)
                                         (list (put-head 1 (list (key-h 1) json-type none-match)
                                                         (bytevector-length bytes))
                                               (lambda ()
                                                 (run-write (rig-store g)
                                                            (lambda (tx) (revoke-key! tx acct-a (kid 1) 1500))))
                                               bytes))))
             (let ((after (tables g)))
               (list (map status+code answers) ((rig-order g))
                     (equal? (map (lambda (t) (list-ref before t)) '(0 1 2 3))
                             (map (lambda (t) (list-ref after t)) '(0 1 2 3)))
                     (last-used g 1))))))))))

;;; Slice 4b: the lifecycle

;; in-order : (A -> B) (Listof A) -> (Listof B)     F on each of XS, first to last
(define (in-order f xs)
  (if (null? xs) '() (let ((v (f (car xs)))) (cons v (in-order f (cdr xs))))))

;; repeat : Natural A -> (Listof A)
(define (repeat n x) (if (= n 0) '() (cons x (repeat (- n 1) x))))

;; seed-state! : Rig Bytevector Natural String Symbol -> Natural
;; Node N for OWNER, of KIND, through the store: made at 5000 ("seed",
;; "seed body", text/plain), replaced at 5500 ("seed 2", "seed body 2",
;; text/markdown), then, for archived or trashed, moved there at 6000, with
;; no snapshot. Its revision: 2 when active, else 3.
(define (seed-state! g owner n kind state)
  (run-write (rig-store g)
             (lambda (tx)
               (insert-node! tx (nid n) owner kind "seed" "seed body" "text/plain" "{}" #f 5000)
               (write-node! tx (nid n) owner 1 "seed 2" "seed body 2" "text/markdown" "{}" "update" 5500)
               (case state
                 ((active) 2)
                 ((archived) (set-node-state! tx (nid n) owner 2 "archived" "archive" 6000) 3)
                 ((trashed) (set-node-state! tx (nid n) owner 2 "trashed" "trash" 6000) 3)
                 (else (assertion-violation 'seed-state! "no such state" state))))))

(define live-states '(active archived trashed))

;; writes : (Listof Symbol)     every request that takes If-Match
(define writes (append events '(replace restore)))

;; write! : Rig Natural Natural Symbol Natural -> Answer
;; WHO's request WHICH on node N at If-Match REV: an event; a replace
;; naming no kind, of title "t3", body "b3", text/plain; or a restore of
;; revision 1.
(define (write! g who n which rev)
  (case which
    ((replace) (replace! g who n rev #f "t3" "b3" "text/plain"))
    ((restore) (restore! g who n 1 rev))
    (else (lifecycle! g who n which rev))))

;; state-of : Rig Natural -> (U String #f)     node N's stored state
(define (state-of g n)
  (run-read (rig-store g)
            (lambda (tx)
              (let ((r (tx-query-row tx "SELECT state FROM nodes WHERE id = ?" (nid n))))
                (and r (vector-ref r 0))))))

(define (id-of j) (member-of j "id"))
(define (sym->str s) (symbol->string s))

;; The lifecycle as the plan's table reads it, with a replace and a
;; restore: each state's answer to each request at the node's own
;; revision. (200 S) is 200 with the node now in S; 204 a purge; 409 the
;; state's refusal.
(define lifecycle-answers
  '((active (archive 200 "archived") (unarchive 409) (trash 200 "trashed") (untrash 409)
            (purge 409) (replace 200 "active") (restore 200 "active"))
    (archived (archive 409) (unarchive 200 "active") (trash 200 "trashed") (untrash 409)
              (purge 409) (replace 200 "archived") (restore 200 "archived"))
    (trashed (archive 409) (unarchive 409) (trash 409) (untrash 200 "active")
             (purge 204) (replace 409) (restore 409))))

;; expected-cell : Symbol Natural (List Symbol Natural [String]) -> (List ...)
;; For STATE at revision REV and its table ENTRY: the status, the code,
;; the ETag, the JSON's state and revision, the stored state and revision.
(define (expected-cell state rev entry)
  (case (cadr entry)
    ((200) (list 200 'absent (tag (+ rev 1)) (caddr entry) (+ rev 1) (caddr entry) (+ rev 1)))
    ((204) (list 204 'absent #f 'absent 'absent "purged" (+ rev 1)))
    ((409) (list 409 "wrong_state" #f 'absent 'absent (sym->str state) rev))
    (else (assertion-violation 'expected-cell "no such entry" entry))))

;; cell-at : Rig Natural Answer -> (List ...)     what expected-cell describes, for node N
(define (cell-at g n a)
  (let ((j (answer-json a)))
    (list (answer-status a) (member-of j "code") (answer-header a "etag")
          (member-of j "state") (member-of j "revision")
          (state-of g n) (car (stored g n)))))

(define (cell-of g a) (cell-at g 1 a))

(for-each
 (lambda (row)
   (let ((state (car row)))
     (for-each
      (lambda (entry)
        (let ((which (car entry)))
          (test-equal (string-append "lifecycle: " (sym->str state) " x " (sym->str which)
                                     ", at the node's revision: status, code, ETag, the answer's state and revision, the stored state and revision")
            (expected-cell state (if (eq? state 'active) 2 3) entry)
            (attempt
             (lambda ()
               (with-rig "cell.db"
                 (lambda (g)
                   (let* ((r (seed-state! g acct-a 1 "note" state))
                          (a (write! g 1 1 which r)))
                     (cell-of g a)))))))))
      (cdr row))))
 lifecycle-answers)

;; The state changes the table allows: from, event, to.
(define moves
  '((active archive "archived") (active trash "trashed") (archived unarchive "active")
    (archived trash "trashed") (trashed untrash "active")))

;; members : Alist (Listof String) -> Alist     J's members named NAMES, in J's order
(define (members j names) (filter (lambda (m) (member (car m) names)) j))

;; but-body : Alist -> Alist
(define (but-body j) (filter (lambda (m) (not (equal? (car m) "body"))) j))

(for-each
 (lambda (move)
   (let ((from (car move)) (event (cadr move)) (to (caddr move)))
     (test-equal (string-append "state change: " (sym->str from) " x " (sym->str event)
                                ": revision + 1, one change row of op " (sym->str event)
                                ", no snapshot; title, body, content type, props, kind, created and author as they were; the answer is the GET's node but its body (G3, G9, G11)")
       (let ((r (if (eq? from 'active) 2 3)))
         (list 200 (tag (+ r 1)) #t "seed body 2" #t (list to (+ r 1) now0) #t #t
               (list (+ r 1) "task" acct-a 5000 now0) #t))
       (attempt
        (lambda ()
          (with-rig "change.db"
            (lambda (g)
              (let* ((r (seed-state! g acct-a 1 "task" from))
                     (before (answer-json (get! g 1 (node-path 1))))
                     (snaps (snapshot-rows g 1))
                     (changes (change-rows g acct-a))
                     (row (stored g 1))
                     (a (lifecycle! g 1 1 event r))
                     (after (answer-json (get! g 1 (node-path 1))))
                     (row2 (stored g 1)))
                (list (answer-status a) (answer-header a "etag")
                      (equal? (answer-json a) (but-body after))
                      (member-of after "body")
                      (equal? (members before '("id" "kind" "title" "body" "content_type" "props" "created"))
                              (members after '("id" "kind" "title" "body" "content_type" "props" "created")))
                      (map (lambda (k) (member-of after k)) '("state" "revision" "updated"))
                      (equal? snaps (snapshot-rows g 1))
                      (equal? (change-rows g acct-a)
                              (append changes (list (list (+ r 1) (nid 1) (+ r 1) (sym->str event) now0))))
                      (list (car row2) (cadr row2) (caddr row2) (cadddr row2) (list-ref row2 4))
                      (equal? (list-ref row 5) (list-ref row2 5)))))))))))
 moves)

(for-each
 (lambda (move)
   (let ((from (car move)) (event (cadr move)) (to (caddr move)))
     (test-equal (string-append "answer: " (sym->str event) " from " (sym->str from)
                                ": 200, the node without its body, as a list's item, no text of the body, no num")
       (let ((r (if (eq? from 'active) 2 3)))
         (list 200 "application/json"
               (item-json-in to 1 "note" "seed 2" "text/markdown" (+ r 1) 5000 now0) #f #f))
       (attempt
        (lambda ()
          (with-rig "answer.db"
            (lambda (g)
              (let* ((r (seed-state! g acct-a 1 "note" from))
                     (a (lifecycle! g 1 1 event r)))
                (list (answer-status a) (answer-header a "content-type") (answer-json a)
                      (contains? (answer-body a) "seed body") (contains? (answer-body a) "num"))))))))))
 moves)

;; The cells where the state refuses, at the node's own revision.
(define wrong-state-cells
  '((active unarchive) (active untrash) (active purge)
    (archived archive) (archived untrash) (archived purge)
    (trashed archive) (trashed unarchive) (trashed trash) (trashed replace) (trashed restore)))

(for-each
 (lambda (cell)
   (test-equal (string-append "G13: " (sym->str (car cell)) " x " (sym->str (cadr cell))
                              " is 409 wrong_state in its write job (a PUT's after the key's read job): nodes, revisions, changes and last_used as they were")
     (list '(409 "wrong_state") (if (eq? (cadr cell) 'replace) '(read write) '(write)) #f #t #f)
     (attempt
      (lambda ()
        (with-rig "g13.db"
          (lambda (g)
            (let* ((r (seed-state! g acct-a 1 "note" (car cell)))
                   (before (tables g))
                   (a (write! g 1 1 (cadr cell) r)))
              (list (status+code a) ((rig-order g)) (answer-header a "etag")
                    (equal? before (tables g)) (last-used g 1)))))))))
 wrong-state-cells)

(for-each
 (lambda (event)
   (test-equal (string-append "G13: " (sym->str event)
                              " on a missing node is 404 not_found in its write job: every table as it was, last_used null")
     '((404 "not_found") (write) #t #f)
     (attempt
      (lambda ()
        (with-rig "g13-missing.db"
          (lambda (g)
            (seed-state! g acct-a 1 "note" 'trashed)
            (let* ((before (tables g))
                   (a (lifecycle! g 1 2 event 3)))
              (list (status+code a) ((rig-order g)) (equal? before (tables g)) (last-used g 1)))))))))
 events)

(test-equal "G13: an accepted state change and an accepted purge set the key's last_used, so the refusals above would have shown it"
  (list now0 (+ now0 (* 2 day)))
  (attempt
   (lambda ()
     (with-rig "g13-accepted.db"
       (lambda (g)
         (let* ((r (seed-state! g acct-a 1 "note" 'active))
                (a (lifecycle! g 1 1 'trash r))
                (t1 (last-used g 1)))
           ((rig-set-now! g) (+ now0 (* 2 day)))
           (lifecycle! g 1 1 'purge (+ r 1))
           (list t1 (last-used g 1))))))))

(for-each
 (lambda (state)
   (for-each
    (lambda (which)
      (test-equal (string-append "G5: " (sym->str state) " x " (sym->str which)
                                 ", a revision behind the node's and one past it: 412 precondition_failed, no ETag, every table as it was, last_used null")
        '((412 "precondition_failed") #f (412 "precondition_failed") #f #t #f)
        (attempt
         (lambda ()
           (with-rig "g5.db"
             (lambda (g)
               (let* ((r (seed-state! g acct-a 1 "note" state))
                      (before (tables g))
                      (a (write! g 1 1 which (- r 1)))
                      (b (write! g 1 1 which (+ r 1))))
                 (list (status+code a) (answer-header a "etag")
                       (status+code b) (answer-header b "etag")
                       (equal? before (tables g)) (last-used g 1)))))))))
    writes))
 live-states)

(test-equal "G15: a trashed node: a replace naming another kind is 409 wrong_state, never kind_fixed; stale, it is 412; nothing written"
  '((409 "wrong_state") (412 "precondition_failed") #t)
  (attempt
   (lambda ()
     (with-rig "g15.db"
       (lambda (g)
         (let* ((r (seed-state! g acct-a 1 "note" 'trashed))
                (before (tables g))
                (a (replace! g 1 1 r "task" "t" "b" "text/plain"))
                (b (replace! g 1 1 (+ r 1) "task" "t" "b" "text/plain")))
           (list (status+code a) (status+code b) (equal? before (tables g)))))))))

(test-equal "G15: an archived node is written as an active one: a replace naming another kind is 409 kind_fixed; the same kind is 200 and stays archived"
  '((409 "kind_fixed") (200 "archived") "archived")
  (attempt
   (lambda ()
     (with-rig "g15-archived.db"
       (lambda (g)
         (let* ((r (seed-state! g acct-a 1 "note" 'archived))
                (a (replace! g 1 1 r "task" "t" "b" "text/plain"))
                (b (replace! g 1 1 r "note" "t" "b" "text/plain")))
           (list (status+code a) (list (answer-status b) (member-of (answer-json b) "state"))
                 (state-of g 1))))))))

(test-equal "restore: on a trashed node at its revision, the revision its trash made (no snapshot) and one never reached are 409 wrong_state, not 404; nothing written"
  '((409 "wrong_state") (409 "wrong_state") #t)
  (attempt
   (lambda ()
     (with-rig "restore-trashed.db"
       (lambda (g)
         (let* ((r (seed-state! g acct-a 1 "note" 'trashed))
                (before (tables g))
                (a (restore! g 1 1 3 r))
                (b (restore! g 1 1 9 r)))
           (list (status+code a) (status+code b) (equal? before (tables g)))))))))

(test-equal "restore: on an archived node, the revision its archive made has no snapshot: 404 not_found; nothing written"
  '((404 "not_found") #t)
  (attempt
   (lambda ()
     (with-rig "restore-gap.db"
       (lambda (g)
         (let* ((r (seed-state! g acct-a 1 "note" 'archived))
                (before (tables g))
                (a (restore! g 1 1 3 r)))
           (list (status+code a) (equal? before (tables g)))))))))

(test-equal "G12: a replace and a restore of an archived node keep it archived, in the answer, the GET and the row; the body is the newest snapshot's"
  '((200 "archived" 4) (200 "archived" 5) ("archived" "seed body" 5) "archived")
  (attempt
   (lambda ()
     (with-rig "g12.db"
       (lambda (g)
         (let* ((r (seed-state! g acct-a 1 "note" 'archived))
                (a (replace! g 1 1 r #f "t4" "b4" "text/plain"))
                (b (restore! g 1 1 1 (+ r 1)))
                (c (answer-json (get! g 1 (node-path 1))))
                (shown (lambda (x) (list (answer-status x) (member-of (answer-json x) "state")
                                         (member-of (answer-json x) "revision")))))
           (list (shown a) (shown b)
                 (map (lambda (k) (member-of c k)) '("state" "body" "revision"))
                 (state-of g 1))))))))

;;; A purge

;; purged-row : Rig Natural -> (List ...)
;; Node N's row: title, props, content_type, state, revision, updated,
;; kind, author, created.
(define (purged-row g n)
  (run-read (rig-store g)
            (lambda (tx)
              (vector->list
               (tx-query-row tx
                 (string-append "SELECT title, props, content_type, state, revision, updated,"
                                " kind, author, created FROM nodes WHERE id = ?")
                 (nid n))))))

;; purged! : Rig -> Answer
;; A's node 1 trashed at revision 3 through the store, then purged through
;; the DELETE at "3": the node at revision 4.
(define (purged! g)
  (lifecycle! g 1 1 'purge (seed-state! g acct-a 1 "note" 'trashed)))

(test-equal "purge: 204, no body, no ETag, no content type; the row emptied (no title, props {}, application/octet-stream, purged, revision 4, updated now), kind, author and created kept; no snapshot left; its change row, op purge, the node's fourth and last (G6, G9)"
  (list 204 "" #f #f
        (list "" "{}" "application/octet-stream" "purged" 4 now0 "note" acct-a 5000)
        '()
        (list (list 1 "create") (list 2 "update") (list 3 "trash") (list 4 "purge"))
        (list 4 (nid 1) 4 "purge" now0))
  (attempt
   (lambda ()
     (with-rig "purge.db"
       (lambda (g)
         (let ((a (purged! g)))
           (list (answer-status a) (answer-body a) (answer-header a "etag")
                 (answer-header a "content-type")
                 (purged-row g 1)
                 (snapshot-rows g 1)
                 (map (lambda (c) (list (car c) (cadddr c))) (change-rows g acct-a))
                 (car (reverse (change-rows g acct-a))))))))))

(test-equal "purge: after it, every route but a create is the 404 a missing node gets, and writes nothing: the read, the revisions list, two revisions' reads, the five state changes, a replace and a restore at its new revision and its old; no change row follows the purge's (G6, G14, G16)"
  (list 204 (repeat 18 '(404 "not_found")) #t #t (list 4 (nid 1) 4 "purge" now0))
  (attempt
   (lambda ()
     (with-rig "purge-after.db"
       (lambda (g)
         (let* ((a (purged! g))
                (before (tables g))
                (answers (append (in-order (lambda (p) (get! g 1 p))
                                           (list (node-path 1) (revisions-path 1)
                                                 (revision-path 1 1) (revision-path 1 2)))
                                 (in-order (lambda (which) (write! g 1 1 which 4)) writes)
                                 (in-order (lambda (which) (write! g 1 1 which 3)) writes)))
                (missing (get! g 1 (node-path 2))))
           (list (answer-status a) (map status+code answers)
                 (for-all (lambda (x) (equal? (answer-body x) (answer-body missing))) answers)
                 (equal? before (tables g))
                 (car (reverse (change-rows g acct-a))))))))))

(test-equal "purge: a create on its id is 412 for its owner and for B, and writes nothing: the id is never used again (G6)"
  '(204 (412 "precondition_failed") (412 "precondition_failed") #t)
  (attempt
   (lambda ()
     (with-rig "purge-create.db"
       (lambda (g)
         (let* ((a (purged! g))
                (before (tables g))
                (c (create! g 1 1 "note" "t" "b" "text/plain"))
                (d (create! g 3 1 "note" "t" "b" "text/plain")))
           (list (answer-status a) (status+code c) (status+code d) (equal? before (tables g)))))))))

(test-equal "purge: no list shows it, in any state, though each shows its own; ?state=purged is 400 (G8, G14)"
  (list 204 (list (nid-text 2)) (list (nid-text 3)) (list (nid-text 4)) '(400 "invalid_request"))
  (attempt
   (lambda ()
     (with-rig "purge-list.db"
       (lambda (g)
         (seed-state! g acct-a 2 "note" 'active)
         (seed-state! g acct-a 3 "note" 'archived)
         (seed-state! g acct-a 4 "note" 'trashed)
         (let ((a (purged! g)))
           (list (answer-status a)
                 (map id-of (items (get! g 1 "/v1/nodes")))
                 (map id-of (items (get! g 1 "/v1/nodes?state=archived")))
                 (map id-of (items (get! g 1 "/v1/nodes?state=trashed")))
                 (status+code (get! g 1 "/v1/nodes?state=purged")))))))))

;;; Another account

(for-each
 (lambda (pair)
   (let ((event (car pair)) (state (cadr pair)))
     (test-equal (string-append "G7: B's " (sym->str event) " of A's " (sym->str state)
                                " node, at A's revision: 404 not_found, the answer an id no one holds gets; every table as it was; A's own, after it, passes")
       (list '(404 "not_found") #t #t #t (if (eq? event 'purge) 204 200))
       (attempt
        (lambda ()
          (with-rig "g7.db"
            (lambda (g)
              (let* ((r (seed-state! g acct-a 1 "note" state))
                     (before (tables g))
                     (a (lifecycle! g 3 1 event r))
                     (m (lifecycle! g 3 2 event r))
                     (after (tables g))
                     (own (lifecycle! g 1 1 event r)))
                (list (status+code a) (equal? (answer-body a) (answer-body m))
                      (equal? (answer-headers a) (answer-headers m))
                      (equal? before after) (answer-status own))))))))))
 '((archive active) (unarchive archived) (trash active) (trash archived) (untrash trashed)
   (purge trashed)))

;;; The revisions list across a state change

(test-equal "revisions: a state change leaves a gap, which pages step over: 5 2 1, by twos and by ones; the gap's revisions are 404, the others 200 (H3')"
  '(((5 2 1) null) ((5 2) 2) ((1) null) ((5) 5) ((2) 2) ((1) null) ((2 1) null) ((2 1) null)
    (404 "not_found") (404 "not_found") 200)
  (attempt
   (lambda ()
     (with-rig "revisions-gap.db"
       (lambda (g)
         (create! g 1 1 "note" "t1" "b1" "text/plain")
         (replace! g 1 1 1 #f "t2" "b2" "text/plain")
         (lifecycle! g 1 1 'archive 2)
         (lifecycle! g 1 1 'unarchive 3)
         (replace! g 1 1 4 #f "t5" "b5" "text/plain")
         (list (revisions g "") (revisions g "?limit=2") (revisions g "?limit=2&after=2")
               (revisions g "?limit=1") (revisions g "?limit=1&after=5")
               (revisions g "?limit=1&after=2") (revisions g "?after=5") (revisions g "?after=4")
               (status+code (get! g 1 (revision-path 1 3)))
               (status+code (get! g 1 (revision-path 1 4)))
               (answer-status (get! g 1 (revision-path 1 5)))))))))

;;; Reads in every state

(for-each
 (lambda (state)
   (test-equal (string-append "read: a " (sym->str state)
                              " node is 200 with its state, its ETag and its newest snapshot's body; its revisions list and a revision's read are 200")
     (let ((r (if (eq? state 'active) 2 3)))
       (list 200 (tag r)
             (node-json-in (sym->str state) 1 "note" "seed 2" "seed body 2" "text/markdown" r 5000
                           (if (eq? state 'active) 5500 6000))
             '((2 1) null) (list 200 "seed body")))
     (attempt
      (lambda ()
        (with-rig "read-state.db"
          (lambda (g)
            (seed-state! g acct-a 1 "note" state)
            (let ((a (get! g 1 (node-path 1)))
                  (v (get! g 1 (revision-path 1 1))))
              (list (answer-status a) (answer-header a "etag") (answer-json a)
                    (revisions g "")
                    (list (answer-status v) (member-of (answer-json v) "body"))))))))))
 live-states)

;;; The list's ?state=

;; states-fixture! : Rig -> Void
;; A's nodes 1 and 5 active, 2 and 6 archived, 3 and 7 trashed, 4 purged;
;; B's 8 archived and 9 trashed.
(define (states-fixture! g)
  (for-each (lambda (n s) (seed-state! g acct-a n "note" s))
            '(1 2 3 4 5 6 7) '(active archived trashed trashed active archived trashed))
  (seed-state! g acct-b 8 "note" 'archived)
  (seed-state! g acct-b 9 "note" 'trashed)
  (run-write (rig-store g) (lambda (tx) (purge-node! tx (nid 4) acct-a 3 6500))))

(define (listed g query)
  (map (lambda (j) (list (id-of j) (member-of j "state")))
       (items (get! g 1 (string-append "/v1/nodes" query)))))

(test-equal "list: by default and with ?state=active the active nodes; ?state=archived and ?state=trashed theirs; each node under one state, each item showing it; a purged node and B's under none (G8)"
  (list (list (list (nid-text 1) "active") (list (nid-text 5) "active"))
        (list (list (nid-text 1) "active") (list (nid-text 5) "active"))
        (list (list (nid-text 2) "archived") (list (nid-text 6) "archived"))
        (list (list (nid-text 3) "trashed") (list (nid-text 7) "trashed")))
  (attempt
   (lambda ()
     (with-rig "list-states.db"
       (lambda (g)
         (states-fixture! g)
         (list (listed g "") (listed g "?state=active") (listed g "?state=archived")
               (listed g "?state=trashed")))))))

(test-equal "list: within ?state=archived, pages of 3 cover its 8 nodes once each, by id rising, with after and next as without a state; an after that is no archived node's id starts past it"
  (list (list 3 (nid-text 14) (nid-text 14)) (list 3 (nid-text 20) (nid-text 20))
        (list 2 'null (nid-text 24)) (list 2 (nid-text 14) (nid-text 14)))
  (attempt
   (lambda ()
     (with-rig "list-state-pages.db"
       (lambda (g)
         (run-write (rig-store g)
                    (lambda (tx)
                      (let loop ((n 10))
                        (when (<= n 25)
                          (insert-node! tx (nid n) acct-a "note" "t" "b" "text/plain" "{}" #f 5000)
                          (when (even? n) (set-node-state! tx (nid n) acct-a 1 "archived" "archive" 5100))
                          (loop (+ n 1))))))
         (list (page g "?state=archived&limit=3")
               (page g (string-append "?state=archived&limit=3&after=" (nid-text 14)))
               (page g (string-append "?state=archived&limit=3&after=" (nid-text 20)))
               (page g (string-append "?state=archived&limit=2&after=" (nid-text 11)))))))))

(for-each
 (lambda (q)
   (test-equal (string-append "list: ?" q " is a 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "list-bad-state.db"
          (lambda (g)
            (let ((a (get! g 1 (string-append "/v1/nodes?" q))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 '("state=purged" "state=" "state=Active" "state=ARCHIVED" "state=deleted" "state=%20active"
   "state=active&state=archived" "state=trashed&state=trashed"))

;;; The five routes' preconditions, ids and bodies

;; from-state : Symbol -> Symbol     a state from which EVENT is allowed
(define (from-state event)
  (case event ((archive trash) 'active) ((unarchive) 'archived) (else 'trashed)))

(for-each
 (lambda (event)
   (test-equal (string-append "precondition: " (sym->str event) " with no If-Match is 428 precondition_required, no job")
     '(428 "precondition_required" 0)
     (attempt
      (lambda ()
        (with-rig "lc-none.db"
          (lambda (g)
            (seed-node! g acct-a 1 "note")
            (let ((a (send-event g event 1 (list (key-h 1)))))
              (append (status+code a) (list ((rig-jobs g))))))))))
   (for-each
    (lambda (bad)
      (test-equal (string-append "precondition: " (sym->str event) " with " (car bad)
                                 " is 400 invalid_request, no job")
        '(400 "invalid_request" 0)
        (attempt
         (lambda ()
           (with-rig "lc-bad-pre.db"
             (lambda (g)
               (seed-node! g acct-a 1 "note")
               (let ((a (send-event g event 1 (cons (key-h 1) (cdr bad)))))
                 (append (status+code a) (list ((rig-jobs g)))))))))))
    (list (list "If-None-Match: *" none-match)
          (list "both headers" (match-h 1) none-match)
          (list "If-Match: *" (cons "If-Match" "*"))
          (list "a weak tag" (cons "If-Match" "W/\"1\""))
          (list "a list in If-Match" (cons "If-Match" "\"1\", \"2\""))
          (list "If-Match twice" (match-h 1) (match-h 1))
          (list "a tag of 0" (cons "If-Match" "\"0\""))))
   (test-equal (string-append "order: " (sym->str event)
                              " on a bad id with no precondition is the 400; with an unknown key a bad id is still the 400 and no precondition the 428, with no job")
     '((400 "invalid_request") (400 "invalid_request") (428 "precondition_required") 0)
     (attempt
      (lambda ()
        (with-rig "lc-order.db"
          (lambda (g)
            (let* ((t (event-target event (node-path-of v4-text)))
                   (a ((rig-call g) (car t) (cdr t) (list (key-h 1))))
                   (b ((rig-call g) (car t) (cdr t) (list (key-h 9) (match-h 1))))
                   (c (send-event g event 1 (list (key-h 9)))))
              (list (status+code a) (status+code b) (status+code c) ((rig-jobs g)))))))))
   (test-equal (string-append "body: " (sym->str event)
                               " reads no body and no Content-Type: text/plain, or JSON that does not parse, is answered as with none")
     (let* ((s (from-state event))
            (entry (assq event (cdr (assq s lifecycle-answers))))
            (r (if (eq? s 'active) 2 3)))
       (list (expected-cell s r entry) (expected-cell s r entry)))
     (attempt
      (lambda ()
        (with-rig "lc-body.db"
          (lambda (g)
            (let* ((r1 (seed-state! g acct-a 1 "note" (from-state event)))
                   (r2 (seed-state! g acct-a 2 "note" (from-state event)))
                   (a (send-event g event 1
                                  (list (key-h 1) (match-h r1) (cons "Content-Type" "text/plain"))
                                  "not json at all"))
                   (b (send-event g event 2 (list (key-h 1) (match-h r2) json-type) "{nope")))
              (list (cell-at g 1 a) (cell-at g 2 b)))))))))
 events)

(test-equal "id: in capitals, a state change and a purge find node 1; the change answers its id in lower case"
  (list (list 200 (nid-text 1)) (list 200 (nid-text 1)) 204)
  (attempt
   (lambda ()
     (with-rig "lc-upper.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let* ((up (node-path-of (string-upcase (nid-text 1))))
                (send (lambda (event rev)
                        (let ((t (event-target event up)))
                          ((rig-call g) (car t) (cdr t) (list (key-h 1) (match-h rev))))))
                (a (send 'archive 1))
                (b (send 'trash 2))
                (c (send 'purge 3)))
           (list (list (answer-status a) (id-of (answer-json a)))
                 (list (answer-status b) (id-of (answer-json b)))
                 (answer-status c))))))))

;;; States and migration 4

;; state-check-names : String -> (U (Listof String) #f)
;; The quoted names in STATEMENT's "state IN ('a','b',...)", in order; #f
;; when it has none.
(define (state-check-names statement)
  (let* ((key "state IN (")
         (n (string-length statement))
         (k (string-length key))
         (start (let loop ((i 0))
                  (cond ((> (+ i k) n) #f)
                        ((string=? (substring statement i (+ i k)) key) (+ i k))
                        (else (loop (+ i 1)))))))
    (and start
         (let loop ((i start) (names '()))
           (let ((c (string-ref statement i)))
             (cond ((char=? c #\)) (reverse names))
                   ((char=? c #\')
                    (let close ((j (+ i 1)))
                      (if (char=? (string-ref statement j) #\')
                          (loop (+ j 1) (cons (substring statement (+ i 1) j) names))
                          (close (+ j 1)))))
                   (else (loop (+ i 1) names))))))))

(test-equal "states: (techo nodes)' node-states are the names in migration 4's CHECK, in its order"
  (map symbol->string node-states)
  (attempt
   (lambda ()
     (let ((statements (caddr (assv 4 migrations))))
       (and (= (length statements) 1) (state-check-names (car statements)))))))

;;; A job closes over plain data; no title or body leaves in a log line

;; req-like? : Any -> Boolean     a request, or a member of a parsed JSON object
(define (req-like? x)
  (or (req? x) (and (pair? x) (member (car x) '("title" "body" "kind" "content_type" "parent")) #t)))

(test-equal "job: a create's job holds its content, and reaches no request and no parsed JSON"
  '(201 #t #t #f)
  (attempt
   (lambda ()
     (with-rig "job.db"
       (lambda (g)
         (let* ((a (create! g 1 1 "note" "the-title-1" "the-body-1" "text/plain"))
                (job ((rig-job g))))
           (list (answer-status a)
                 (reaches? job (lambda (x) (equal? x "the-title-1")))
                 (reaches? job (lambda (x) (equal? x "the-body-1")))
                 (reaches? job req-like?))))))))

(test-equal "job: a replace's and a restore's jobs reach no request and no parsed JSON"
  '(200 #f 200 #f)
  (attempt
   (lambda ()
     (with-rig "job-replace.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let* ((a (replace! g 1 1 1 #f "t" "b" "text/plain"))
                (ja ((rig-job g)))
                (b (restore! g 1 1 1 2))
                (jb ((rig-job g))))
           (list (answer-status a) (reaches? ja req-like?)
                 (answer-status b) (reaches? jb req-like?))))))))

(test-equal "log: a create's, a replace's, a stale replace's and a read's lines hold no title and no body"
  '((201 200 412 200) 4 #f #f)
  (attempt
   (lambda ()
     (with-rig "log.db"
       (lambda (g)
         (let* ((a (create! g 1 1 "note" "secret-title-7" "secret-body-7" "text/plain"))
                (b (replace! g 1 1 1 #f "secret-title-8" "secret-body-8" "text/plain"))
                (c (replace! g 1 1 1 #f "secret-title-9" "secret-body-9" "text/plain"))
                (d (get! g 1 (node-path 1)))
                (text (apply string-append ((rig-lines g)))))
           (list (map answer-status (list a b c d))
                 (length ((rig-lines g)))
                 (exists (lambda (s) (contains? text s))
                         '("secret-title-7" "secret-title-8" "secret-title-9"))
                 (exists (lambda (s) (contains? text s))
                         '("secret-body-7" "secret-body-8" "secret-body-9")))))))))

(test-equal "job: a state change's job and a purge's hold plain data: no request, no parsed JSON"
  '(200 #f 204 #f)
  (attempt
   (lambda ()
     (with-rig "job-lifecycle.db"
       (lambda (g)
         (let* ((r (seed-state! g acct-a 1 "note" 'active))
                (a (lifecycle! g 1 1 'trash r))
                (ja ((rig-job g)))
                (b (lifecycle! g 1 1 'purge (+ r 1)))
                (jb ((rig-job g))))
           (list (answer-status a) (reaches? ja req-like?)
                 (answer-status b) (reaches? jb req-like?))))))))

(test-equal "log: each state change's line, and a purge's, names its route and the account and holds no title and no body"
  (list '(200 200 200 200 200 204) 6 #t #t #f #f)
  (attempt
   (lambda ()
     (with-rig "log-lifecycle.db"
       (lambda (g)
         (run-write (rig-store g)
                    (lambda (tx) (insert-node! tx (nid 1) acct-a "note" "secret-title-4" "secret-body-4"
                                               "text/plain" "{}" #f 5000)))
         (let* ((as (in-order (lambda (step) (lifecycle! g 1 1 (car step) (cdr step)))
                              '((archive . 1) (unarchive . 2) (trash . 3) (untrash . 4) (trash . 5)
                                (purge . 6))))
                (lines ((rig-lines g)))
                (text (apply string-append lines)))
           (list (map answer-status as) (length lines)
                 (for-all (lambda (l) (contains? l (string-append "account=" (id->string acct-a))))
                          lines)
                 (equal? (map (lambda (l) (contains? l "method=DELETE")) lines) '(#f #f #f #f #f #t))
                 (contains? text "secret-title-4") (contains? text "secret-body-4"))))))))

(test-equal "H20: num is in no state change's answer"
  '((200 #f) (200 #f))
  (attempt
   (lambda ()
     (with-rig "h20-lifecycle.db"
       (lambda (g)
         (seed-node! g acct-a 1 "note")
         (let* ((a (lifecycle! g 1 1 'archive 1))
                (b (lifecycle! g 1 1 'unarchive 2)))
           (map (lambda (x) (list (answer-status x) (contains? (answer-body x) "num"))) (list a b))))))))

;;; Slice 5a: the tree

;; create-in! : Rig Natural Natural String (U Natural #f 'text String) -> Answer
;; WHO's create of node N, of KIND, title "t", body "b", text/plain, under
;; P: a node's number, #f for JSON null, or a string sent as it is.
(define (create-in! g who n kind p)
  (put! g n (list (key-h who) json-type none-match)
        (json->string (list (cons "kind" kind) (cons "title" "t") (cons "body" "b")
                            (cons "content_type" "text/plain")
                            (cons "parent" (cond ((string? p) p) (p (nid-text p)) (else 'null)))))))

;; seed-in! : Rig Bytevector Natural String (U Natural #f) -> Void
;; Node N for OWNER, of KIND, under P (#f: the top level), at revision 1,
;; made at 5000, through the store, which judges nothing.
(define (seed-in! g owner n kind p)
  (run-write (rig-store g)
             (lambda (tx) (insert-node! tx (nid n) owner kind "seed" "seed body" "text/plain" "{}"
                                        (and p (nid p)) 5000))))

;; set-state-at! : Rig Bytevector Natural Natural String String -> Void
;; Node N, at revision REV, moved to STATE by OP at 6000, through the store.
(define (set-state-at! g owner n rev state op)
  (run-write (rig-store g) (lambda (tx) (set-node-state! tx (nid n) owner rev state op 6000))))

(define (trashed-at! g owner n rev) (set-state-at! g owner n rev "trashed" "trash"))
(define (archived-at! g owner n rev) (set-state-at! g owner n rev "archived" "archive"))

;; purged-at! : Rig Bytevector Natural Natural -> Void
;; Node N, active at revision REV, trashed and purged through the store: at
;; REV + 2.
(define (purged-at! g owner n rev)
  (run-write (rig-store g)
             (lambda (tx)
               (set-node-state! tx (nid n) owner rev "trashed" "trash" 6000)
               (purge-node! tx (nid n) owner (+ rev 1) 6100))))

;; parent-of : Rig Natural -> (U Bytevector #f)     node N's stored parent
(define (parent-of g n)
  (run-read (rig-store g)
            (lambda (tx)
              (let ((r (tx-query-row tx "SELECT parent FROM nodes WHERE id = ?" (nid n))))
                (and r (let ((v (vector-ref r 0))) (and (bytevector? v) v)))))))

;; row-of : Rig Natural -> (U (Vectorof Any) #f)     node N's whole row
(define (row-of g n)
  (run-read (rig-store g) (lambda (tx) (tx-query-row tx "SELECT * FROM nodes WHERE id = ?" (nid n)))))

;; holds-kind? : String String -> Boolean
;; T2, written out here and not read from (techo nodes): a Project holds
;; every kind, a Journal only Notes, the others nothing.
(define (holds-kind? parent child)
  (or (string=? parent "project") (and (string=? parent "journal") (string=? child "note"))))

;; forest-faults : Rig -> (Listof (List Symbol Bytevector))
;; What breaks the forest (P1, P2, P3, P8) in the whole nodes table, each
;; as a fault and the row's id: a purged row with a parent; a parent that
;; is no row, another owner's, purged, or of a kind that may not hold the
;; row's; a row whose walk up does not reach a root within the count of
;; rows. '() for a forest.
(define (forest-faults g)
  (let* ((rows (run-read (rig-store g)
                         (lambda (tx)
                           (map vector->list
                                (tx-query tx "SELECT id, owner, kind, state, parent FROM nodes ORDER BY num")))))
         (by-id (make-hashtable equal-hash equal?))
         (count (length rows))
         (parent (lambda (r) (let ((p (list-ref r 4))) (and (bytevector? p) p))))
         (state (lambda (r) (list-ref r 3))))
    (for-each (lambda (r) (hashtable-set! by-id (car r) r)) rows)
    (let loop ((rs rows) (faults '()))
      (if (null? rs)
          (reverse faults)
          (let* ((r (car rs))
                 (p (parent r))
                 (pr (and p (hashtable-ref by-id p #f)))
                 (fault (cond ((and p (string=? (state r) "purged")) 'purged-has-parent)
                              ((and p (not pr)) 'parent-no-row)
                              ((and pr (not (bytevector=? (cadr pr) (cadr r)))) 'parent-other-owner)
                              ((and pr (string=? (state pr) "purged")) 'parent-purged)
                              ((and pr (not (holds-kind? (caddr pr) (caddr r)))) 'parent-wrong-kind)
                              ((not (let walk ((x r) (steps 0))
                                      (let ((q (parent x)))
                                        (cond ((not q) #t)
                                              ((>= steps count) #f)
                                              (else (let ((qr (hashtable-ref by-id q #f)))
                                                      (and qr (walk qr (+ steps 1)))))))))
                               'no-root)
                              (else #f))))
            (loop (cdr rs) (if fault (cons (list fault (car r)) faults) faults)))))))

;; new-changes : (Listof (List ...)) (Listof (List ...)) -> (Listof (List ...))
;; The change rows in AFTER past BEFORE's, each seq counted from BEFORE's last.
(define (new-changes before after)
  (let ((last (if (null? before) 0 (car (car (reverse before))))))
    (map (lambda (r) (cons (- (car r) last) (cdr r))) (list-tail after (length before)))))

(define (children-query p) (string-append "/v1/nodes?parent=" (nid-text p)))

;;; A create with a parent (T3)

(test-equal "tree: a create in a Project: 201; the answer and the GET name the parent after the state; the row holds it; the Project's list holds the node; the forest holds"
  (list 201 (under (node-json 2 "note" "t" "b" "text/plain" 1 now0 now0) 1)
        (under (node-json 2 "note" "t" "b" "text/plain" 1 now0 now0) 1)
        (nid 1) (list (nid-text 2)) '())
  (attempt
   (lambda ()
     (with-rig "tree-create.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (let* ((a (create-in! g 1 2 "note" 1))
                (r (get! g 1 (node-path 2)))
                (l (get! g 1 (children-query 1))))
           (list (answer-status a) (answer-json a) (answer-json r) (parent-of g 2)
                 (map id-of (items l)) (forest-faults g))))))))

;; create-cases : (Listof (List String String Symbol String (U 201 String)))
;; The parent's kind and state, the kind made under it, and 201 or the 409's code.
(define create-cases
  '(("a Note in a Journal" "journal" active "note" 201)
    ("a Task in a Journal" "journal" active "task" "invalid_parent")
    ("a Journal in a Journal" "journal" active "journal" "invalid_parent")
    ("a Project in a Journal" "journal" active "project" "invalid_parent")
    ("a Contact in a Journal" "journal" active "contact" "invalid_parent")
    ("a Project in a Project" "project" active "project" 201)
    ("a Journal in a Project" "project" active "journal" 201)
    ("a Task in a Project" "project" active "task" 201)
    ("a Contact in a Project" "project" active "contact" 201)
    ("a Note in a Note" "note" active "note" "invalid_parent")
    ("a Note in a Task" "task" active "note" "invalid_parent")
    ("a Note in a Contact" "contact" active "note" "invalid_parent")
    ("a Note in a trashed Project" "project" trashed "note" "invalid_parent")
    ("a Note in a trashed Journal" "journal" trashed "note" "invalid_parent")
    ("a Note in an archived Project" "project" archived "note" 201)
    ("a Note in an archived Journal" "journal" archived "note" 201)))

(for-each
 (lambda (cc)
   (let ((what (car cc)) (kind (cadr cc)) (state (caddr cc)) (child (cadddr cc))
         (answer (car (cddddr cc))))
     (test-equal (string-append "tree: a create of " what ": "
                                (if (eqv? answer 201)
                                    "201, the row under it, last_used set"
                                    (string-append "409 " answer ", nothing written, last_used null")))
       (if (eqv? answer 201)
           (list 201 'absent (nid-text 1) (nid 1) #f now0 '())
           (list 409 answer 'absent #f #t #f '()))
       (attempt
        (lambda ()
          (with-rig "tree-create-case.db"
            (lambda (g)
              (seed-in! g acct-a 1 kind #f)
              (case state
                ((trashed) (trashed-at! g acct-a 1 1))
                ((archived) (archived-at! g acct-a 1 1))
                (else #f))
              (let* ((before (tables g))
                     (a (create-in! g 1 2 child 1))
                     (after (tables g)))
                (list (answer-status a) (member-of (answer-json a) "code")
                      (member-of (answer-json a) "parent") (parent-of g 2)
                      (equal? before after) (last-used g 1) (forest-faults g))))))))))
 create-cases)

(test-equal "tree: a create under a missing id, under B's Project and under A's purged Project: 409 invalid_parent each, the same bytes and headers (P12), nothing written, last_used null"
  '((409 "invalid_parent") (409 "invalid_parent") (409 "invalid_parent") #t #t #t #t #t #f ())
  (attempt
   (lambda ()
     (with-rig "tree-create-missing.db"
       (lambda (g)
         (seed-in! g acct-b 20 "project" #f)
         (seed-in! g acct-a 8 "project" #f)
         (purged-at! g acct-a 8 1)
         (let* ((before (tables g))
                (a (create-in! g 1 2 "note" 99))
                (b (create-in! g 1 3 "note" 20))
                (c (create-in! g 1 4 "note" 8)))
           (list (status+code a) (status+code b) (status+code c)
                 (equal? (answer-body a) (answer-body b)) (equal? (answer-body a) (answer-body c))
                 (equal? (answer-headers a) (answer-headers b))
                 (equal? (answer-headers a) (answer-headers c))
                 (equal? before (tables g)) (last-used g 1) (forest-faults g))))))))

(test-equal "tree: a create with \"parent\": null is at the top level, as one with no parent; a parent in capitals is the same id, answered in lower case"
  (list (list 201 'null #f) (list 201 'null #f) (list 201 (nid-text 1) (nid 1)))
  (attempt
   (lambda ()
     (with-rig "tree-create-null.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (let* ((a (create-in! g 1 2 "note" #f))
                (b (create! g 1 3 "note" "t" "b" "text/plain"))
                (c (create-in! g 1 4 "note" (string-upcase (nid-text 1)))))
           (map (lambda (x n) (list (answer-status x) (member-of (answer-json x) "parent")
                                    (parent-of g n)))
                (list a b c) '(2 3 4))))))))

(test-equal "tree: a create on an id in use, A's or B's, under a missing id, a Note, a trashed Project or itself, is 412 precondition_failed: stale before the parent; nothing written"
  '((412 "precondition_failed") (412 "precondition_failed") (412 "precondition_failed")
    (412 "precondition_failed") (412 "precondition_failed") #t)
  (attempt
   (lambda ()
     (with-rig "tree-create-used.db"
       (lambda (g)
         (seed-in! g acct-a 2 "project" #f)
         (seed-in! g acct-a 6 "note" #f)
         (seed-in! g acct-a 7 "project" #f)
         (trashed-at! g acct-a 7 1)
         (seed-in! g acct-b 20 "note" #f)
         (let* ((before (tables g))
                (a (create-in! g 1 2 "note" 99))
                (b (create-in! g 1 2 "note" 6))
                (c (create-in! g 1 2 "note" 7))
                (d (create-in! g 1 2 "note" 2))
                (e (create-in! g 1 20 "note" 6)))
           (append (map status+code (list a b c d e)) (list (equal? before (tables g))))))))))

(test-equal "tree: a create with a parent that is no id is 400 before any write job: a number, false, {}, a v4 id; and a replace naming parent, even its own, is 400"
  '((400 "invalid_request") (400 "invalid_request") (400 "invalid_request") (400 "invalid_request")
    (400 "invalid_request") 5 0)
  (attempt
   (lambda ()
     (with-rig "tree-create-bad.db"
       (lambda (g)
         (seed-in! g acct-a 1 "note" #f)
         (let* ((send (lambda (n v)
                        (put! g n (list (key-h 1) json-type none-match)
                              (string-append "{\"kind\":\"note\",\"title\":\"t\",\"body\":\"b\","
                                             "\"content_type\":\"text/plain\",\"parent\":" v "}"))))
                (a (send 2 "5"))
                (b (send 3 "false"))
                (c (send 4 "{}"))
                (d (send 5 (string-append "\"" v4-text "\"")))
                (e (put! g 1 (list (key-h 1) json-type (match-h 1))
                         "{\"title\":\"t\",\"body\":\"b\",\"content_type\":\"text/plain\",\"parent\":null}")))
           (append (map status+code (list a b c d e)) (list ((rig-reads g)) ((rig-writes g))))))))))

;;; A move (T4, P4)

(test-equal "move: under a Project, to the top level, and back: 200 each, the ETag the new revision, the answer's parent and the row's; the forest holds"
  (list (list 200 (tag 2) (nid-text 1) (nid 1))
        (list 200 (tag 3) 'null #f)
        (list 200 (tag 4) (nid-text 1) (nid 1))
        '())
  (attempt
   (lambda ()
     (with-rig "move.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 2 "note" #f)
         (let* ((shown (lambda (a) (list (answer-status a) (answer-header a "etag")
                                         (member-of (answer-json a) "parent") (parent-of g 2))))
                (a (move! g 1 2 1 1))
                (sa (shown a))
                (b (move! g 1 2 2 #f))
                (sb (shown b))
                (c (move! g 1 2 3 1))
                (sc (shown c)))
           (list sa sb sc (forest-faults g))))))))

(test-equal "move: revision + 1, one change row move, no snapshot; title, body, content type, props, kind, created, state and author as they were, updated the clock; the answer is the GET's node but its body, with no body member and no num"
  (list 200 (tag 3) "application/json" #t 'absent #t (list (nid-text 1) 3 now0) #t
        (list (list 1 (nid 2) 3 "move" now0)) (list 3 "note" acct-a 5000 now0) #f #f)
  (attempt
   (lambda ()
     (with-rig "move-what.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-state! g acct-a 2 "note" 'active)
         (let* ((before (answer-json (get! g 1 (node-path 2))))
                (snaps (snapshot-rows g 2))
                (changes (change-rows g acct-a))
                (a (move! g 1 2 2 1))
                (after (answer-json (get! g 1 (node-path 2))))
                (row (stored g 2))
                (same '("id" "kind" "state" "title" "body" "content_type" "props" "created")))
           (list (answer-status a) (answer-header a "etag") (answer-header a "content-type")
                 (equal? (answer-json a) (but-body after))
                 (member-of (answer-json a) "body")
                 (equal? (members before same) (members after same))
                 (map (lambda (k) (member-of after k)) '("parent" "revision" "updated"))
                 (equal? snaps (snapshot-rows g 2))
                 (new-changes changes (change-rows g acct-a))
                 (list (car row) (cadr row) (caddr row) (cadddr row) (list-ref row 4))
                 (contains? (answer-body a) "seed body") (contains? (answer-body a) "num"))))))))

(test-equal "move: to the parent it already has is a move: a new revision and a change row move, under a Project and at the top level"
  (list (list 200 (tag 2) (nid-text 1)) (list 200 (tag 2) 'null)
        (list (list 1 (nid 2) 2 "move" now0) (list 2 (nid 3) 2 "move" now0)))
  (attempt
   (lambda ()
     (with-rig "move-same.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 2 "note" 1)
         (seed-in! g acct-a 3 "note" #f)
         (let* ((changes (change-rows g acct-a))
                (a (move! g 1 2 1 1))
                (b (move! g 1 3 1 #f)))
           (list (list (answer-status a) (answer-header a "etag") (member-of (answer-json a) "parent"))
                 (list (answer-status b) (answer-header b "etag") (member-of (answer-json b) "parent"))
                 (new-changes changes (change-rows g acct-a)))))))))

(test-equal "move: the id and the parent in capitals are the same ids; the answer is in lower case"
  (list 200 (nid-text 2) (nid-text 1) (nid 1))
  (attempt
   (lambda ()
     (with-rig "move-upper.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 2 "note" #f)
         (let ((a ((rig-call g) 'POST (move-path-of (node-path-of (string-upcase (nid-text 2))))
                                (list (key-h 1) json-type (match-h 1))
                                (json->string (list (cons "parent" (string-upcase (nid-text 1))))))))
           (list (answer-status a) (id-of (answer-json a)) (member-of (answer-json a) "parent")
                 (parent-of g 2))))))))

;; tree! : Rig -> Void
;; A's tree, through the store, each node at revision 1 unless said:
;;   1 Project, at the top: 2 Project in it, 3 Project in 2, 4 Project in 3
;;   5 Journal, 6 Note, 9 Task, at the top
;;   7 Project, at the top, trashed (revision 2)
;;   8 Project, at the top, purged (revision 3)
;; and B's 20, a Project at the top.
(define (tree! g)
  (seed-in! g acct-a 1 "project" #f)
  (seed-in! g acct-a 2 "project" 1)
  (seed-in! g acct-a 3 "project" 2)
  (seed-in! g acct-a 4 "project" 3)
  (seed-in! g acct-a 5 "journal" #f)
  (seed-in! g acct-a 6 "note" #f)
  (seed-in! g acct-a 7 "project" #f)
  (trashed-at! g acct-a 7 1)
  (seed-in! g acct-a 8 "project" #f)
  (purged-at! g acct-a 8 1)
  (seed-in! g acct-a 9 "task" #f)
  (seed-in! g acct-b 20 "project" #f))

;; move-verdicts : (Listof (List String Natural Natural String))
;; In tree!: the node moved (each at revision 1), the parent, and the 409's
;; code (P17).
(define move-verdicts
  '(("a Note under a missing id" 6 99 "invalid_parent")
    ("a Note under B's Project" 6 20 "invalid_parent")
    ("a Note under A's purged Project" 6 8 "invalid_parent")
    ("a Note under a trashed Project" 6 7 "invalid_parent")
    ("a Task under a Journal" 9 5 "invalid_parent")
    ("a Project under a Journal" 2 5 "invalid_parent")
    ("a Note under a Task" 6 9 "invalid_parent")
    ("a Task under a Note" 9 6 "invalid_parent")
    ("a Note under itself" 6 6 "would_loop")
    ("a Project under itself" 1 1 "would_loop")
    ("a Journal under itself, which may not hold a Journal" 5 5 "would_loop")
    ("a Project under its child" 1 2 "would_loop")
    ("a Project under its deepest descendant" 1 4 "would_loop")
    ("a Project under its child, from the middle" 2 3 "would_loop")))

(for-each
 (lambda (v)
   (test-equal (string-append "move: " (car v) ": 409 " (cadddr v)
                              ", in its write job; nodes, revisions, changes and last_used as they were (P5)")
     (list (list 409 (cadddr v)) '(read write) #t #f '())
     (attempt
      (lambda ()
        (with-rig "move-verdict.db"
          (lambda (g)
            (tree! g)
            (let* ((before (tables g))
                   (a (move! g 1 (cadr v) 1 (caddr v))))
              (list (status+code a) ((rig-order g)) (equal? before (tables g)) (last-used g 1)
                    (forest-faults g)))))))))
 move-verdicts)

(test-equal "move: under a missing id, under B's Project and under A's purged Project, the same bytes and headers (P12)"
  '((409 "invalid_parent") #t #t #t #t)
  (attempt
   (lambda ()
     (with-rig "move-same-bytes.db"
       (lambda (g)
         (tree! g)
         (let* ((a (move! g 1 6 1 99))
                (b (move! g 1 6 1 20))
                (c (move! g 1 6 1 8)))
           (list (status+code a)
                 (equal? (answer-body a) (answer-body b)) (equal? (answer-body a) (answer-body c))
                 (equal? (answer-headers a) (answer-headers b))
                 (equal? (answer-headers a) (answer-headers c)))))))))

;; chain! : Rig Natural Natural -> Void
;; A's Projects FROM to TO, through the store in one job, each under the
;; one before and FROM at the top: node FROM + k has k ancestors.
(define (chain! g from to)
  (run-write (rig-store g)
             (lambda (tx)
               (let loop ((n from))
                 (when (<= n to)
                   (insert-node! tx (nid n) acct-a "project" "c" "b" "text/plain" "{}"
                                 (and (> n from) (nid (- n 1))) 5000)
                   (loop (+ n 1)))))))

(test-equal "depth: a parent with 63 ancestors takes a create and a move; one with 64 refuses both, 409 invalid_parent (P18); the forest holds"
  (list 201 (nid 163) '(409 "invalid_parent") 200 (nid 163) '(409 "invalid_parent") #f '())
  (attempt
   (lambda ()
     (with-rig "depth.db"
       (lambda (g)
         (chain! g 100 163)
         (seed-in! g acct-a 300 "note" #f)
         (seed-in! g acct-a 301 "note" #f)
         (let* ((a (create-in! g 1 200 "project" 163))
                (b (create-in! g 1 201 "note" 200))
                (c (move! g 1 300 1 163))
                (d (move! g 1 301 1 200)))
           (list (answer-status a) (parent-of g 200) (status+code b)
                 (answer-status c) (parent-of g 300) (status+code d) (parent-of g 301)
                 (forest-faults g))))))))

(test-equal "depth: a loop above the new parent's 64th ancestor is invalid_parent (too deep), not would_loop; one at its 64th is would_loop"
  '((409 "invalid_parent") (409 "would_loop") #t)
  (attempt
   (lambda ()
     (with-rig "depth-loop.db"
       (lambda (g)
         (chain! g 100 165)
         (let* ((before (tables g))
                (a (move! g 1 100 1 165))
                (b (move! g 1 100 1 164)))
           (list (status+code a) (status+code b) (equal? before (tables g)))))))))

(test-equal "move: order (P6): a stale If-Match is 412 before a trashed node's wrong_state, before a missing parent's invalid_parent and before a loop's would_loop; a trashed node under a missing parent is wrong_state; nothing written"
  '((412 "precondition_failed") (412 "precondition_failed") (412 "precondition_failed")
    (409 "wrong_state") (409 "wrong_state") #t #f)
  (attempt
   (lambda ()
     (with-rig "move-order.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 2 "note" #f)
         (trashed-at! g acct-a 2 1)
         (seed-in! g acct-a 3 "note" #f)
         (let* ((before (tables g))
                (a (move! g 1 2 1 1))
                (b (move! g 1 3 2 99))
                (c (move! g 1 3 2 3))
                (d (move! g 1 2 2 99))
                (e (move! g 1 2 2 1)))
           (list (status+code a) (status+code b) (status+code c) (status+code d) (status+code e)
                 (equal? before (tables g)) (last-used g 1))))))))

(test-equal "move: an archived node moves and stays archived, into an archived Project too; an archived Journal takes a Note (T8)"
  (list (list 200 "archived" (nid-text 1) 3) (list 200 "active" (nid-text 5) 2) "archived" '())
  (attempt
   (lambda ()
     (with-rig "move-archived.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (archived-at! g acct-a 1 1)
         (seed-in! g acct-a 2 "note" #f)
         (archived-at! g acct-a 2 1)
         (seed-in! g acct-a 5 "journal" #f)
         (archived-at! g acct-a 5 1)
         (seed-in! g acct-a 6 "note" #f)
         (let* ((shown (lambda (a) (map (lambda (k) (member-of (answer-json a) k))
                                        '("state" "parent" "revision"))))
                (a (move! g 1 2 2 1))
                (b (move! g 1 6 1 5)))
           (list (cons (answer-status a) (shown a)) (cons (answer-status b) (shown b))
                 (state-of g 2) (forest-faults g))))))))

(test-equal "move: a missing node, B's node and A's purged node are 404 not_found in the write job, the same bytes; under a good parent; nothing written"
  '((404 "not_found") (404 "not_found") (404 "not_found") #t #t #t (read write read write read write))
  (attempt
   (lambda ()
     (with-rig "move-missing.db"
       (lambda (g)
         (tree! g)
         (let* ((before (tables g))
                (a (move! g 1 99 1 1))
                (b (move! g 1 20 1 1))
                (c (move! g 1 8 3 1)))
           (list (status+code a) (status+code b) (status+code c)
                 (equal? (answer-body a) (answer-body b)) (equal? (answer-body a) (answer-body c))
                 (equal? before (tables g)) ((rig-order g)))))))))

(test-equal "move: a time read once the body had come: the head, then the clock moves, then the body; updated is the later time, and the change row's"
  (list 200 (+ now0 7000) (+ now0 7000))
  (attempt
   (lambda ()
     (with-rig "move-time.db"
       (lambda (g)
         (seed-in! g acct-a 2 "note" #f)
         (let ((bytes (string->utf8 (move-body #f))))
           (let-values (((answers waiting? closed?)
                         (exchange-steps (rig-handler g)
                                         (list (request-bytes 'POST (move-path 2)
                                                              (list (key-h 1) json-type (match-h 1)
                                                                    (cons "Content-Length"
                                                                          (number->string (bytevector-length bytes)))))
                                               (lambda () ((rig-set-now! g) (+ now0 7000)))
                                               bytes))))
             (let ((a (car answers)))
               (list (answer-status a) (member-of (answer-json a) "updated")
                     (list-ref (car (reverse (change-rows g acct-a))) 4))))))))))

;;; The two moves' checks before the job

(define move-routes
  (list (cons "move" move-path-of) (cons "move-children" move-children-path-of)))

;; padded-move : Natural -> String
;; {"parent":null} of exactly N bytes, spaces before its member.
(define (padded-move n)
  (let* ((base "{\"parent\":null}") (k (string-length base)))
    (string-append "{" (make-string (- n k) #\space) (substring base 1 k))))

;; bad-move-bodies : (Listof (Pair String String))     each a 400 invalid_request
(define bad-move-bodies
  (list (cons "an empty object, which is no top level" "{}")
        (cons "a parent of 5" "{\"parent\":5}")
        (cons "a parent of false" "{\"parent\":false}")
        (cons "a parent of true" "{\"parent\":true}")
        (cons "a parent of {}" "{\"parent\":{}}")
        (cons "a parent of []" "{\"parent\":[]}")
        (cons "a parent of \"\"" "{\"parent\":\"\"}")
        (cons "a parent of \"null\"" "{\"parent\":\"null\"}")
        (cons "a v4 id" (string-append "{\"parent\":\"" v4-text "\"}"))
        (cons "another member beside it" "{\"parent\":null,\"x\":1}")
        (cons "another member alone" "{\"x\":null}")
        (cons "the member twice" "{\"parent\":null,\"parent\":null}")
        (cons "a member in capitals" "{\"Parent\":null}")
        (cons "an array" "[]")
        (cons "an array holding it" "[{\"parent\":null}]")
        (cons "null" "null")
        (cons "a string" "\"x\"")
        (cons "a number" "1")
        (cons "an empty body" "")))

(for-each
 (lambda (route)
   (let* ((name (car route))
          (path-of (cdr route))
          (path (path-of (node-path 1)))
          (send (lambda (g headers text) ((rig-call g) 'POST path headers text)))
          (label (lambda (s) (string-append name ": " s))))
     (test-equal (label "no key is 401 unauthorized, no job")
       '(401 "unauthorized" 0)
       (attempt
        (lambda ()
          (with-rig "mv-nokey.db"
            (lambda (g)
              (seed-in! g acct-a 1 "project" #f)
              (let ((a (send g (list json-type (match-h 1)) (move-body #f))))
                (append (status+code a) (list ((rig-jobs g))))))))))
     (test-equal (label "no If-Match is 428 precondition_required, no job")
       '(428 "precondition_required" 0)
       (attempt
        (lambda ()
          (with-rig "mv-none.db"
            (lambda (g)
              (seed-in! g acct-a 1 "project" #f)
              (let ((a (send g (list (key-h 1) json-type) (move-body #f))))
                (append (status+code a) (list ((rig-jobs g))))))))))
     (for-each
      (lambda (bad)
        (test-equal (label (string-append (car bad) " is 400 invalid_request, no job"))
          '(400 "invalid_request" 0)
          (attempt
           (lambda ()
             (with-rig "mv-bad-pre.db"
               (lambda (g)
                 (seed-in! g acct-a 1 "project" #f)
                 (let ((a (send g (append (list (key-h 1) json-type) (cdr bad)) (move-body #f))))
                   (append (status+code a) (list ((rig-jobs g)))))))))))
      (list (list "If-None-Match: *" none-match)
            (list "both headers" (match-h 1) none-match)
            (list "If-Match: *" (cons "If-Match" "*"))
            (list "a weak tag" (cons "If-Match" "W/\"1\""))
            (list "a list in If-Match" (cons "If-Match" "\"1\", \"2\""))
            (list "If-Match twice" (match-h 1) (match-h 1))
            (list "a tag of 0" (cons "If-Match" "\"0\""))))
     (test-equal (label "order: a bad id with no precondition is the 400; with an unknown key a bad id is still the 400 and no precondition the 428; a bad precondition with JSON that does not parse the 400; no job")
       '((400 "invalid_request") (400 "invalid_request") (428 "precondition_required")
         (400 "invalid_request") 0)
       (attempt
        (lambda ()
          (with-rig "mv-order-cheap.db"
            (lambda (g)
              (let* ((bad (path-of (node-path-of v4-text)))
                     (a ((rig-call g) 'POST bad (list (key-h 1) json-type) (move-body #f)))
                     (b ((rig-call g) 'POST bad (list (key-h 9) json-type (match-h 1)) (move-body #f)))
                     (c (send g (list (key-h 9) json-type) (move-body #f)))
                     (d (send g (list (key-h 1) json-type (cons "If-Match" "*")) "{nope")))
                (list (status+code a) (status+code b) (status+code c) (status+code d)
                      ((rig-jobs g)))))))))
     (test-equal (label "no precondition and no Content-Type is the 428, no job")
       '(428 "precondition_required" 0)
       (attempt
        (lambda ()
          (with-rig "mv-order-pre.db"
            (lambda (g)
              (let ((a (send g (list (key-h 1)) (move-body #f))))
                (append (status+code a) (list ((rig-jobs g))))))))))
     (test-equal (label "an unknown key is 401 in the key's read job, no write job; with a bad body, one over the cap and one that does not parse, still the 401: the key before the body")
       '((401 "unauthorized") (401 "unauthorized") (401 "unauthorized") (401 "unauthorized")
         (read read read read) #t)
       (attempt
        (lambda ()
          (with-rig "mv-unknown.db"
            (lambda (g)
              (seed-in! g acct-a 1 "project" #f)
              (let* ((before (tables g))
                     (h (list (key-h 9) json-type (match-h 1)))
                     (a (send g h (move-body #f)))
                     (b (send g h "{\"parent\":5}"))
                     (c (send g h (padded-move 20000)))
                     (d (send g h "{nope")))
                (list (status+code a) (status+code b) (status+code c) (status+code d)
                      ((rig-order g)) (equal? before (tables g)))))))))
     (test-equal (label "a revoked key is the 401 in the key's read job, the body not read")
       '(401 "unauthorized" (read))
       (attempt
        (lambda ()
          (with-rig "mv-revoked.db"
            (lambda (g)
              (seed-in! g acct-a 1 "project" #f)
              (run-write (rig-store g) (lambda (tx) (revoke-key! tx acct-a (kid 1) 1500)))
              (let ((a (send g (list (key-h 1) json-type (match-h 1)) "{nope")))
                (append (status+code a) (list ((rig-order g))))))))))
     (for-each
      (lambda (bad)
        (test-equal (label (string-append (car bad) " is 415 unsupported_media_type, after the key's read job, no write job"))
          '(415 "unsupported_media_type" (read))
          (attempt
           (lambda ()
             (with-rig "mv-type.db"
               (lambda (g)
                 (seed-in! g acct-a 1 "project" #f)
                 (let ((a (send g (append (list (key-h 1) (match-h 1)) (cdr bad)) (move-body #f))))
                   (append (status+code a) (list ((rig-order g)))))))))))
      (list (list "no Content-Type")
            (list "text/plain" (cons "Content-Type" "text/plain"))
            (list "a +json type" (cons "Content-Type" "application/merge-patch+json"))
            (list "two Content-Types" json-type json-type)))
     (test-equal (label "text/plain with a body over the cap, or one that does not parse, is the 415: the media type before the body")
       '((415 "unsupported_media_type") (415 "unsupported_media_type") (read read))
       (attempt
        (lambda ()
          (with-rig "mv-type-body.db"
            (lambda (g)
              (seed-in! g acct-a 1 "project" #f)
              (let* ((h (list (key-h 1) (match-h 1) (cons "Content-Type" "text/plain")))
                     (a (send g h (padded-move 20000)))
                     (b (send g h "{nope")))
                (list (status+code a) (status+code b) ((rig-order g)))))))))
     (test-equal (label "the body's cap is 16 KiB: exactly 16384 bytes is 200; one byte more is 413 payload_too_large, after the key's read job, no write job, nothing written")
       '((16384 200) (16385 413 "payload_too_large" (read) #t))
       (attempt
        (lambda ()
          (list (with-rig "mv-at-cap.db"
                  (lambda (g)
                    (seed-in! g acct-a 1 "project" #f)
                    (let* ((text (padded-move 16384))
                           (a (send g (list (key-h 1) json-type (match-h 1)) text)))
                      (list (bytevector-length (string->utf8 text)) (answer-status a)))))
                (with-rig "mv-over-cap.db"
                  (lambda (g)
                    (seed-in! g acct-a 1 "project" #f)
                    (let* ((before (tables g))
                           (text (padded-move 16385))
                           (a (send g (list (key-h 1) json-type (match-h 1)) text)))
                      (append (list (bytevector-length (string->utf8 text))) (status+code a)
                              (list ((rig-order g)) (equal? before (tables g)))))))))))
     (test-equal (label "JSON that does not parse is 400 invalid_json, after the key's read job, no write job")
       '(400 "invalid_json" (read))
       (attempt
        (lambda ()
          (with-rig "mv-bad-json.db"
            (lambda (g)
              (seed-in! g acct-a 1 "project" #f)
              (let ((a (send g (list (key-h 1) json-type (match-h 1)) "{\"parent\": nope")))
                (append (status+code a) (list ((rig-order g))))))))))
     (for-each
      (lambda (bad)
        (test-equal (label (string-append (car bad) " is 400 invalid_request, after the key's read job, no write job, nothing written"))
          '(400 "invalid_request" (read) #t)
          (attempt
           (lambda ()
             (with-rig "mv-bad-body.db"
               (lambda (g)
                 (seed-in! g acct-a 1 "project" #f)
                 (let* ((before (tables g))
                        (a (send g (list (key-h 1) json-type (match-h 1)) (cdr bad))))
                   (append (status+code a) (list ((rig-order g)) (equal? before (tables g)))))))))))
      bad-move-bodies)
     (test-equal (label "the head alone, no byte of the body sent: of a 2 MB body with an unknown key, the 401 at once from the key's read job; with A's key, the 413 at once after it, the Content-Length past the cap; of 16 KiB with A's key, no answer yet: it waits for the body")
       (list (list '((401 "unauthorized")) #f '(read))
             (list '((413 "payload_too_large")) #f '(read))
             (list '() #t '(read)))
       (attempt
        (lambda ()
          (let* ((head (lambda (k n) (request-bytes 'POST path
                                                    (list (key-h k) json-type (match-h 1)
                                                          (cons "Content-Length" n)))))
                 (one (lambda (name k n)
                        (with-rig name
                          (lambda (g)
                            (seed-in! g acct-a 1 "project" #f)
                            (let-values (((answers waiting? closed?)
                                          (exchange-steps (rig-handler g) (list (head k n)))))
                              (list (map status+code answers) waiting? ((rig-order g)))))))))
            (let* ((a (one "mv-head.db" 9 "2000000"))
                   (b (one "mv-head-big.db" 1 "2000000"))
                   (c (one "mv-head-a.db" 1 "16384")))
              (list a b c))))))))
 move-routes)

;;; The bulk move (T7, P11, P16)

;; family! : Rig -> Void
;; A's Project 1 and its children, through the store, each at revision 1
;; unless said: 10 Note; 11 Note, archived (2); 12 Note, trashed (2); 13
;; Task; 14 Contact, archived (2); 15 Project, holding 16, a Note. At the
;; top: 2 Journal, 3 Project, 4 Note, 5 Project trashed (2), 8 Project
;; purged (3). B's 20, a Project.
(define (family! g)
  (seed-in! g acct-a 1 "project" #f)
  (seed-in! g acct-a 10 "note" 1)
  (seed-in! g acct-a 11 "note" 1)
  (archived-at! g acct-a 11 1)
  (seed-in! g acct-a 12 "note" 1)
  (trashed-at! g acct-a 12 1)
  (seed-in! g acct-a 13 "task" 1)
  (seed-in! g acct-a 14 "contact" 1)
  (archived-at! g acct-a 14 1)
  (seed-in! g acct-a 15 "project" 1)
  (seed-in! g acct-a 16 "note" 15)
  (seed-in! g acct-a 2 "journal" #f)
  (seed-in! g acct-a 3 "project" #f)
  (seed-in! g acct-a 4 "note" #f)
  (seed-in! g acct-a 5 "project" #f)
  (trashed-at! g acct-a 5 1)
  (seed-in! g acct-a 8 "project" #f)
  (purged-at! g acct-a 8 1)
  (seed-in! g acct-b 20 "project" #f))

;; parents : Rig (Listof Natural) -> (Listof (U Bytevector #f))
(define (parents g ns) (map (lambda (n) (parent-of g n)) ns))

;; bulk-moved : Rig Natural (U Natural #f) -> (List ...)
;; In family!, node 1's children moved under P at node 1's revision 1:
;; the status, the ETag, the content type, the JSON; whether node 1's row
;; is as it was; the new change rows; whether the snapshots are; the
;; parents of 10 to 16; the forest's faults.
(define (bulk-moved g p)
  (family! g)
  (let* ((row (row-of g 1))
         (snaps (run-read (rig-store g) (lambda (tx) (tx-query tx "SELECT * FROM revisions ORDER BY node, revision"))))
         (changes (change-rows g acct-a))
         (a (move-children! g 1 1 1 p)))
    (list (answer-status a) (answer-header a "etag") (answer-header a "content-type") (answer-json a)
          (equal? row (row-of g 1))
          (new-changes changes (change-rows g acct-a))
          (equal? snaps (run-read (rig-store g)
                                  (lambda (tx) (tx-query tx "SELECT * FROM revisions ORDER BY node, revision"))))
          (parents g '(10 11 12 13 14 15 16))
          (forest-faults g))))

(test-equal "bulk: into a Journal, only the Notes that are not trashed move: moved 2, left 4; each a revision + 1 with a change row move, by id; no row and no change row for the node itself, no ETag, no snapshot; the grandchild stays under its parent"
  (list 200 #f "application/json" '(("moved" . 2) ("left" . 4)) #t
        (list (list 1 (nid 10) 2 "move" now0) (list 2 (nid 11) 3 "move" now0))
        #t
        (list (nid 2) (nid 2) (nid 1) (nid 1) (nid 1) (nid 1) (nid 15))
        '())
  (attempt (lambda () (with-rig "bulk-journal.db" (lambda (g) (bulk-moved g 2))))))

(test-equal "bulk: into a Project, every child not trashed moves, of any kind: moved 5, left 1; the Project child takes its own child along"
  (list 200 #f "application/json" '(("moved" . 5) ("left" . 1)) #t
        (list (list 1 (nid 10) 2 "move" now0) (list 2 (nid 11) 3 "move" now0)
              (list 3 (nid 13) 2 "move" now0) (list 4 (nid 14) 3 "move" now0)
              (list 5 (nid 15) 2 "move" now0))
        #t
        (list (nid 3) (nid 3) (nid 1) (nid 3) (nid 3) (nid 3) (nid 15))
        '())
  (attempt (lambda () (with-rig "bulk-project.db" (lambda (g) (bulk-moved g 3))))))

(test-equal "bulk: to the top level, as into a Project: moved 5, left 1"
  (list 200 #f "application/json" '(("moved" . 5) ("left" . 1)) #t
        (list (list 1 (nid 10) 2 "move" now0) (list 2 (nid 11) 3 "move" now0)
              (list 3 (nid 13) 2 "move" now0) (list 4 (nid 14) 3 "move" now0)
              (list 5 (nid 15) 2 "move" now0))
        #t
        (list #f #f (nid 1) #f #f #f (nid 15))
        '())
  (attempt (lambda () (with-rig "bulk-top.db" (lambda (g) (bulk-moved g #f))))))

(test-equal "bulk: the moved children keep their state, kind, content and created; each answer and list shows the new parent"
  (list (list "note" "active" 2 (nid-text 3)) (list "note" "archived" 3 (nid-text 3))
        (list "contact" "archived" 3 (nid-text 3))
        (list (nid-text 10) (nid-text 11) (nid-text 13) (nid-text 14) (nid-text 15)))
  (attempt
   (lambda ()
     (with-rig "bulk-shown.db"
       (lambda (g)
         (bulk-moved g 3)
         (let ((shown (lambda (n) (let ((j (answer-json (get! g 1 (node-path n)))))
                                    (map (lambda (k) (member-of j k)) '("kind" "state" "revision" "parent"))))))
           (let* ((a (shown 10)) (b (shown 11)) (c (shown 14))
                  (l (append (items (get! g 1 (children-query 3)))
                             (items (get! g 1 (string-append (children-query 3) "&state=archived"))))))
             (list a b c (list-sort string<? (map id-of l))))))))))

;; brood! : Rig Natural Natural Natural -> Void
;; A's Project 1 and under it the Notes FROM to TO, through the store in
;; one job; those up to TRASHED-TO trashed (revision 2), the others at 1.
(define (brood! g from to trashed-to)
  (run-write (rig-store g)
             (lambda (tx)
               (insert-node! tx (nid 1) acct-a "project" "p" "b" "text/plain" "{}" #f 5000)
               (let loop ((n from))
                 (when (<= n to)
                   (insert-node! tx (nid n) acct-a "note" "c" "b" "text/plain" "{}" (nid 1) 5000)
                   (when (<= n trashed-to)
                     (set-node-state! tx (nid n) acct-a 1 "trashed" "trash" 5100))
                   (loop (+ n 1)))))))

;; top-ids : Rig -> (Listof Bytevector)     A's rows at the top level but 1, by id
(define (top-ids g)
  (run-read (rig-store g)
            (lambda (tx)
              (map (lambda (r) (vector-ref r 0))
                   (tx-query tx "SELECT id FROM nodes WHERE owner = ? AND parent IS NULL AND id <> ? ORDER BY id"
                             acct-a (nid 1))))))

;; ids-from : Natural Natural -> (Listof Bytevector)     nodes FROM to TO
(define (ids-from from to) (if (> from to) '() (cons (nid from) (ids-from (+ from 1) to))))

(test-equal "bulk: of 1,005 children, exactly the first 1,000 by id move, each with a change row move, by id; left 5; a second call moves the 5, a third moves none"
  (list '(("moved" . 1000) ("left" . 5)) #t #t #t
        '(("moved" . 5) ("left" . 0)) #t '(("moved" . 0) ("left" . 0)) '())
  (attempt
   (lambda ()
     (with-rig "bulk-1005.db"
       (lambda (g)
         (brood! g 1000 2004 0)
         (let* ((changes (change-rows g acct-a))
                (a (move-children! g 1 1 1 #f))
                (top-a (top-ids g))
                (new (new-changes changes (change-rows g acct-a)))
                (b (move-children! g 1 1 1 #f))
                (top-b (top-ids g))
                (c (move-children! g 1 1 1 #f)))
           (list (answer-json a)
                 (equal? top-a (ids-from 1000 1999))
                 (equal? (map cadr new) (ids-from 1000 1999))
                 (for-all (lambda (r) (equal? (cddr r) (list 2 "move" now0))) new)
                 (answer-json b) (equal? top-b (ids-from 1000 2004)) (answer-json c)
                 (forest-faults g))))))))

(test-equal "bulk: 1,000 trashed children sorting first and 5 active after them: moved 5, left 1,000 (the review's blocker 2)"
  (list '(("moved" . 5) ("left" . 1000)) #t)
  (attempt
   (lambda ()
     (with-rig "bulk-trashed-first.db"
       (lambda (g)
         (brood! g 1000 2004 1999)
         (let ((a (move-children! g 1 1 1 #f)))
           (list (answer-json a) (equal? (top-ids g) (ids-from 2000 2004)))))))))

(test-equal "bulk: a trashed Project's children may be moved out (T7): moved 2, left 0; the node stays trashed, at its revision"
  (list 200 '(("moved" . 2) ("left" . 0)) (list #f #f) "trashed" 2)
  (attempt
   (lambda ()
     (with-rig "bulk-trashed-node.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "note" 1)
         (seed-in! g acct-a 11 "task" 1)
         (trashed-at! g acct-a 1 1)
         (let ((a (move-children! g 1 1 2 #f)))
           (list (answer-status a) (answer-json a) (parents g '(10 11)) (state-of g 1)
                 (car (stored g 1)))))))))

(test-equal "bulk: a node with no children: moved 0, left 0; a Note's too"
  '((200 (("moved" . 0) ("left" . 0))) (200 (("moved" . 0) ("left" . 0))))
  (attempt
   (lambda ()
     (with-rig "bulk-empty.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 4 "note" #f)
         (let* ((a (move-children! g 1 1 1 #f))
                (b (move-children! g 1 4 1 #f)))
           (list (list (answer-status a) (answer-json a)) (list (answer-status b) (answer-json b)))))))))

;; The tests below close the 5a review's gaps.

(test-equal "bulk: an archived Project's children move (T7): 200, moved 2, left 0; the node stays archived, at its revision"
  (list 200 '(("moved" . 2) ("left" . 0)) (list #f #f) "archived" 2)
  (attempt
   (lambda ()
     (with-rig "bulk-archived-node.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "note" 1)
         (seed-in! g acct-a 11 "task" 1)
         (archived-at! g acct-a 1 1)
         (let ((a (move-children! g 1 1 2 #f)))
           (list (answer-status a) (answer-json a) (parents g '(10 11)) (state-of g 1)
                 (car (stored g 1)))))))))

(test-equal "move: a parent too deep (64 ancestors) and of a kind that cannot hold the node is invalid_parent, both verdicts' one code; nothing written, forest holds"
  '((409 "invalid_parent") (409 "invalid_parent") #t ())
  (attempt
   (lambda ()
     (with-rig "move-deep-wrong-kind.db"
       (lambda (g)
         (chain! g 100 163)
         (seed-in! g acct-a 164 "note" 163)       ; 64 ancestors, and no kind under it
         (seed-in! g acct-a 300 "project" #f)
         (let* ((before (tables g))
                (a (move! g 1 300 1 164))
                (b (create-in! g 1 301 "project" 164)))
           (list (status+code a) (status+code b) (equal? before (tables g)) (forest-faults g))))))))

(test-equal "move: a new parent that is trashed AND would make a loop is invalid_parent, not would_loop: trashed is judged first; a bulk move too; nothing written"
  '((409 "invalid_parent") (409 "invalid_parent") #t)
  (attempt
   (lambda ()
     (with-rig "move-trashed-loop.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 2 "project" 1)
         (trashed-at! g acct-a 2 1)
         (let* ((before (tables g))
                (a (move! g 1 1 1 2))
                (b (move-children! g 1 1 1 2)))
           (list (status+code a) (status+code b) (equal? before (tables g)))))))))

;; bulk-refusals : (Listof (List String Natural Natural Natural (List Natural String)))
;; In family!: the node whose children move, its If-Match, the new parent,
;; and the answer.
(define bulk-refusals
  '(("into the node itself" 1 1 1 (409 "would_loop"))
    ("under one of its children" 1 1 15 (409 "would_loop"))
    ("under a grandchild, a Note" 1 1 16 (409 "would_loop"))
    ("into a Note" 1 1 4 (409 "invalid_parent"))
    ("into a trashed Project" 1 1 5 (409 "invalid_parent"))
    ("into a missing id" 1 1 99 (409 "invalid_parent"))
    ("into B's Project" 1 1 20 (409 "invalid_parent"))
    ("into A's purged Project" 1 1 8 (409 "invalid_parent"))
    ("at a stale If-Match" 1 2 3 (412 "precondition_failed"))
    ("at a stale If-Match, into the node itself" 1 2 1 (412 "precondition_failed"))
    ("of a missing node" 99 1 3 (404 "not_found"))
    ("of B's node" 20 1 3 (404 "not_found"))
    ("of A's purged node" 8 3 3 (404 "not_found"))))

(for-each
 (lambda (r)
   (test-equal (string-append "bulk: " (car r) ": " (number->string (car (list-ref r 4))) " "
                              (cadr (list-ref r 4))
                              ", in its write job, no ETag; nodes, revisions, changes and last_used as they were")
     (list (list-ref r 4) '(read write) #f #t #f '())
     (attempt
      (lambda ()
        (with-rig "bulk-refused.db"
          (lambda (g)
            (family! g)
            (let* ((before (tables g))
                   (a (move-children! g 1 (cadr r) (caddr r) (cadddr r))))
              (list (status+code a) ((rig-order g)) (answer-header a "etag")
                    (equal? before (tables g)) (last-used g 1) (forest-faults g)))))))))
 bulk-refusals)

(test-equal "bulk: into a missing id, B's Project and A's purged Project: 409 invalid_parent, the same bytes and headers (P12)"
  '((409 "invalid_parent") #t #t #t #t)
  (attempt
   (lambda ()
     (with-rig "bulk-same-bytes.db"
       (lambda (g)
         (family! g)
         (let* ((a (move-children! g 1 1 1 99))
                (b (move-children! g 1 1 1 20))
                (c (move-children! g 1 1 1 8)))
           (list (status+code a) (equal? (answer-body a) (answer-body b)) (equal? (answer-body a) (answer-body c))
                 (equal? (answer-headers a) (answer-headers b))
                 (equal? (answer-headers a) (answer-headers c)))))))))

;;; Another account (G7)

(test-equal "G7: B's move and bulk move of A's node, at A's revision, to the top level: 404 not_found, the bytes an id no one holds gets; every table as it was; A's own pass after them"
  '((404 "not_found") (404 "not_found") #t #t #t 200 200)
  (attempt
   (lambda ()
     (with-rig "g7-tree.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "note" 1)
         (let* ((before (tables g))
                (a (move! g 3 10 1 #f))
                (b (move-children! g 3 1 1 #f))
                (m (move! g 3 99 1 #f))
                (after (tables g))
                (c (move! g 1 10 1 #f))
                (d (move-children! g 1 1 1 #f)))
           (list (status+code a) (status+code b)
                 (equal? (answer-body a) (answer-body m)) (equal? (answer-body b) (answer-body m))
                 (equal? before after) (answer-status c) (answer-status d))))))))

;;; A purge of a parent (T7, P8, P9)

(for-each
 (lambda (state)
   (test-equal (string-append "purge: a trashed Project with one " state
                              " child is 409 has_children: nodes, revisions, changes and last_used as they were")
     '((409 "has_children") #t #f)
     (attempt
      (lambda ()
        (with-rig "purge-parent.db"
          (lambda (g)
            (seed-in! g acct-a 1 "project" #f)
            (trashed-at! g acct-a 1 1)
            (seed-in! g acct-a 10 "note" 1)
            (cond ((string=? state "archived") (archived-at! g acct-a 10 1))
                  ((string=? state "trashed") (trashed-at! g acct-a 10 1)))
            (let* ((before (tables g))
                   (a (lifecycle! g 1 1 'purge 2)))
              (list (status+code a) (equal? before (tables g)) (last-used g 1)))))))))
 '("active" "archived" "trashed"))

(test-equal "purge: with a child, an active Project is 409 wrong_state and a trashed one at a stale If-Match 412: both before has_children"
  '((409 "wrong_state") (412 "precondition_failed") (412 "precondition_failed") #t)
  (attempt
   (lambda ()
     (with-rig "purge-parent-order.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "note" 1)
         (seed-in! g acct-a 2 "project" #f)
         (trashed-at! g acct-a 2 1)
         (seed-in! g acct-a 20 "note" 2)
         (let* ((before (tables g))
                (a (lifecycle! g 1 1 'purge 1))
                (b (lifecycle! g 1 2 'purge 1))
                (c (lifecycle! g 1 2 'purge 3)))
           (list (status+code a) (status+code b) (status+code c) (equal? before (tables g)))))))))

(test-equal "purge: once its one child is moved out, the trashed Project purges: 204; its row and the child's have no parent"
  '(200 204 #f #f ())
  (attempt
   (lambda ()
     (with-rig "purge-after-move.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "note" 1)
         (trashed-at! g acct-a 1 1)
         (let* ((a (move! g 1 10 1 #f))
                (b (lifecycle! g 1 1 'purge 2)))
           (list (answer-status a) (answer-status b) (parent-of g 1) (parent-of g 10)
                 (forest-faults g))))))))

(test-equal "purge: once its trashed child is purged, the Project purges: a purged child does not block it, and the purged child's row has no parent (P8)"
  '(204 #f 204 ())
  (attempt
   (lambda ()
     (with-rig "purge-after-purge.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "note" 1)
         (trashed-at! g acct-a 10 1)
         (trashed-at! g acct-a 1 1)
         (let* ((a (lifecycle! g 1 10 'purge 2))
                (p (parent-of g 10))
                (b (lifecycle! g 1 1 'purge 2)))
           (list (answer-status a) p (answer-status b) (forest-faults g))))))))

(test-equal "purge: once a bulk move has emptied it, the Project purges"
  '((200 (("moved" . 2) ("left" . 0))) 204 ())
  (attempt
   (lambda ()
     (with-rig "purge-after-bulk.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "note" 1)
         (seed-in! g acct-a 11 "note" 1)
         (archived-at! g acct-a 11 1)
         (trashed-at! g acct-a 1 1)
         (let* ((a (move-children! g 1 1 2 #f))
                (b (lifecycle! g 1 1 'purge 2)))
           (list (list (answer-status a) (answer-json a)) (answer-status b) (forest-faults g))))))))

(test-equal "purge: a Project with only a grandchild left, under a child moved away, purges; the child keeps its own"
  '(200 204 (#f) ())
  (attempt
   (lambda ()
     (with-rig "purge-grandchild.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 10 "project" 1)
         (seed-in! g acct-a 11 "note" 10)
         (trashed-at! g acct-a 1 1)
         (let* ((a (move! g 1 10 1 #f))
                (b (lifecycle! g 1 1 'purge 2)))
           (list (answer-status a) (answer-status b)
                 (list (parent-of g 10)) (forest-faults g))))))))

;;; The parent through every other write (P15)

(test-equal "tree: a replace, a restore, an archive, an unarchive, a trash and an untrash each keep the parent, in the answer and in the row"
  (list (list 200 (nid-text 1)) (list 200 (nid-text 1)) (list 200 (nid-text 1))
        (list 200 (nid-text 1)) (list 200 (nid-text 1)) (list 200 (nid-text 1)) (nid 1) '())
  (attempt
   (lambda ()
     (with-rig "tree-keep.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 2 "note" 1)
         (let* ((shown (lambda (a) (list (answer-status a) (member-of (answer-json a) "parent"))))
                (a (shown (replace! g 1 2 1 #f "t2" "b2" "text/plain")))
                (b (shown (restore! g 1 2 1 2)))
                (c (shown (lifecycle! g 1 2 'archive 3)))
                (d (shown (lifecycle! g 1 2 'unarchive 4)))
                (e (shown (lifecycle! g 1 2 'trash 5)))
                (f (shown (lifecycle! g 1 2 'untrash 6))))
           (list a b c d e f (parent-of g 2) (forest-faults g))))))))

;;; The list's ?parent= (T9, P13)

;; family-list! : Rig -> Void
;; A's Project 1, at the top, holding 10, 13 and 14 active, 11 archived and
;; 12 trashed; at the top too, 20 a Note and 21 a Note archived; 40 a
;; Project trashed, holding 41. B's 30, a Project holding 31. A's 8, a
;; Project purged.
(define (family-list! g)
  (seed-in! g acct-a 1 "project" #f)
  (for-each (lambda (n) (seed-in! g acct-a n "note" 1)) '(10 11 12 13 14))
  (archived-at! g acct-a 11 1)
  (trashed-at! g acct-a 12 1)
  (seed-in! g acct-a 20 "note" #f)
  (seed-in! g acct-a 21 "note" #f)
  (archived-at! g acct-a 21 1)
  (seed-in! g acct-a 40 "project" #f)
  (seed-in! g acct-a 41 "note" 40)
  (trashed-at! g acct-a 40 1)
  (seed-in! g acct-b 30 "project" #f)
  (seed-in! g acct-b 31 "note" 30)
  (seed-in! g acct-a 8 "project" #f)
  (purged-at! g acct-a 8 1))

;; listed-parent : Rig String -> (List (Listof (List String Any Any)) Any)
;; The page's items as id, state and parent, and next.
(define (listed-parent g query)
  (let ((a (get! g 1 (string-append "/v1/nodes" query))))
    (list (map (lambda (j) (list (id-of j) (member-of j "state") (member-of j "parent"))) (items a))
          (member-of (answer-json a) "next"))))

(test-equal "list: ?parent= a node is its children in a state, active by default; ?parent=null the top level; each item shows its parent; the flat list holds every active node whatever its parent (P13)"
  (let ((in1 (lambda (n s) (list (nid-text n) s (nid-text 1))))
        (top (lambda (n s) (list (nid-text n) s 'null))))
    (list (list (list (in1 10 "active") (in1 13 "active") (in1 14 "active")) 'null)
          (list (list (in1 11 "archived")) 'null)
          (list (list (in1 12 "trashed")) 'null)
          (list (list (top 1 "active") (top 20 "active")) 'null)
          (list (list (top 21 "archived")) 'null)
          (list (list (top 40 "trashed")) 'null)
          (list (list (list (nid-text 41) "active" (nid-text 40))) 'null)
          (list (list (top 1 "active") (in1 10 "active") (in1 13 "active") (in1 14 "active")
                      (top 20 "active") (list (nid-text 41) "active" (nid-text 40)))
                'null)))
  (attempt
   (lambda ()
     (with-rig "list-parent.db"
       (lambda (g)
         (family-list! g)
         (let* ((p (string-append "?parent=" (nid-text 1)))
                (a (listed-parent g p))
                (b (listed-parent g (string-append p "&state=archived")))
                (c (listed-parent g (string-append "?state=trashed&parent=" (nid-text 1))))
                (d (listed-parent g "?parent=null"))
                (e (listed-parent g "?parent=null&state=archived"))
                (f (listed-parent g "?state=trashed&parent=null"))
                (h (listed-parent g (string-append "?parent=" (nid-text 40))))
                (i (listed-parent g "")))
           (list a b c d e f h i)))))))

(test-equal "list: ?parent= pages by after and limit, as the flat list does, and in capitals is the same id"
  (list (list (list (nid-text 10) (nid-text 13)) (nid-text 13))
        (list (list (nid-text 14)) 'null)
        (list (list (nid-text 1)) (nid-text 1))
        (list (list (nid-text 20)) 'null)
        (list (list (nid-text 10) (nid-text 13) (nid-text 14)) 'null))
  (attempt
   (lambda ()
     (with-rig "list-parent-pages.db"
       (lambda (g)
         (family-list! g)
         (let* ((ids (lambda (q) (let ((r (listed-parent g q))) (list (map car (car r)) (cadr r)))))
                (p (string-append "?parent=" (nid-text 1)))
                (a (ids (string-append p "&limit=2")))
                (b (ids (string-append p "&limit=2&after=" (nid-text 13))))
                (c (ids "?parent=null&limit=1"))
                (d (ids (string-append "?parent=null&limit=1&after=" (nid-text 1))))
                (e (ids (string-append "?parent=" (string-upcase (nid-text 1))))))
           (list a b c d e)))))))

(test-equal "list: ?parent= a missing id, B's Project and A's purged Project: 404 not_found, the bytes and headers of any 404, in one read job each"
  '((404 "not_found") (404 "not_found") (404 "not_found") #t #t #t #t (read read read read))
  (attempt
   (lambda ()
     (with-rig "list-parent-missing.db"
       (lambda (g)
         (family-list! g)
         (let* ((a (get! g 1 (children-query 99)))
                (b (get! g 1 (children-query 30)))
                (c (get! g 1 (children-query 8)))
                (m (get! g 1 (node-path 99))))
           (list (status+code a) (status+code b) (status+code c)
                 (equal? (answer-body a) (answer-body m)) (equal? (answer-body b) (answer-body m))
                 (equal? (answer-body c) (answer-body m))
                 (and (equal? (answer-headers a) (answer-headers m))
                      (equal? (answer-headers b) (answer-headers m))
                      (equal? (answer-headers c) (answer-headers m)))
                 ((rig-order g)))))))))

(test-equal "list: ?parent= a Note, which holds nothing, is 200 and an empty page; B's own Project lists B's child"
  (list (list 200 (list (cons "items" (vector)) (cons "next" 'null))) (list (nid-text 31)))
  (attempt
   (lambda ()
     (with-rig "list-parent-note.db"
       (lambda (g)
         (family-list! g)
         (let* ((a (get! g 1 (children-query 20)))
                (b (get! g 3 (children-query 30))))
           (list (list (answer-status a) (answer-json a)) (map id-of (items b)))))))))

(for-each
 (lambda (q)
   (test-equal (string-append "list: ?" q " is a 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "list-bad-parent.db"
          (lambda (g)
            (let ((a (get! g 1 (string-append "/v1/nodes?" q))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 (list "parent=" "parent=NULL" "parent=Null" "parent=nil" "parent=x" (string-append "parent=" v4-text)
       "parent=null&parent=null" (string-append "parent=" (nid-text 1) "&parent=" (nid-text 1))
       (string-append "parent=" (nid-text 1) "&state=purged")))

(test-equal "list: a bad ?parent= with no key is the 401, with an unknown key the 400: the key's shape, then the query, then the key"
  '((401 "unauthorized" 0) (400 "invalid_request" 0))
  (attempt
   (lambda ()
     (with-rig "list-parent-key.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'GET "/v1/nodes?parent=x"))
                (ja ((rig-jobs g)))
                (b ((rig-call g) 'GET "/v1/nodes?parent=x" (list (key-h 9))))
                (jb ((rig-jobs g))))
           (list (append (status+code a) (list ja)) (append (status+code b) (list jb)))))))))

;;; Jobs and the log

(test-equal "job: a move's job and a bulk move's hold plain data: no request, no parsed JSON"
  '(200 #f 200 #f)
  (attempt
   (lambda ()
     (with-rig "job-move.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (seed-in! g acct-a 2 "note" #f)
         (let* ((a (move! g 1 2 1 1))
                (ja ((rig-job g)))
                (b (move-children! g 1 1 1 #f))
                (jb ((rig-job g))))
           (list (answer-status a) (reaches? ja req-like?)
                 (answer-status b) (reaches? jb req-like?))))))))

(test-equal "log: a move's line and a bulk move's name their route and the account and hold no title and no body; so does a refused move's"
  (list '(200 200 409) 3 #t (list #t #t #t) #f #f)
  (attempt
   (lambda ()
     (with-rig "log-move.db"
       (lambda (g)
         (seed-in! g acct-a 1 "project" #f)
         (run-write (rig-store g)
                    (lambda (tx) (insert-node! tx (nid 2) acct-a "note" "secret-title-5" "secret-body-5"
                                               "text/plain" "{}" #f 5000)))
         (let* ((a (move! g 1 2 1 1))
                (b (move-children! g 1 1 1 #f))
                (c (move! g 1 2 3 2))
                (lines ((rig-lines g)))
                (text (apply string-append lines)))
           (list (map answer-status (list a b c)) (length lines)
                 (for-all (lambda (l) (contains? l (string-append "account=" (id->string acct-a))))
                          lines)
                 (map (lambda (l p) (contains? l (string-append "path=" p " ")))
                      lines (list (move-path 2) (move-children-path 1) (move-path 2)))
                 (contains? text "secret-title-5") (contains? text "secret-body-5"))))))))

;;; Slice 5b: links

;; link-request : Rig Symbol Natural String (List [(Listof Header) [(U String #f)]]) -> Answer
;; WHO's METHOD on PATH: the key, then MORE's headers when given, then
;; MORE's body when given; no precondition and no body otherwise.
(define (link-request g method who path more)
  ((rig-call g) method path
                (cons (key-h who) (if (null? more) '() (car more)))
                (if (or (null? more) (null? (cdr more))) #f (cadr more))))

;; link! : Rig Natural Natural String Natural [(Listof Header) [(U String #f)]] -> Answer
;; WHO's PUT of the link from node S to node T of TYPE.
(define (link! g who s type t . more) (link-request g 'PUT who (link-path s type t) more))

;; unlink! : as link!, the DELETE
(define (unlink! g who s type t . more) (link-request g 'DELETE who (link-path s type t) more))

;; links-get : Rig Natural Natural String -> Answer
;; WHO's GET of node N's links, QUERY after the ? ("" for none).
(define (links-get g who n query)
  (get! g who (if (string=? query "") (links-path n) (string-append (links-path n) "?" query))))

;; link-json : Natural String Natural Natural -> Alist     a link's answer, in its order
(define (link-json s type t created)
  (list (cons "source" (nid-text s)) (cons "type" type) (cons "target" (nid-text t))
        (cons "created" created)))

;; link-rows : Rig -> (Listof (List Bytevector Bytevector String Bytevector Natural))
;; Every row of links: owner, source, type, target, created, in key order.
(define (link-rows g)
  (run-read (rig-store g)
            (lambda (tx)
              (map vector->list
                   (tx-query tx (string-append "SELECT owner, source, type, target, created FROM links"
                                               " ORDER BY owner, source, type, target"))))))

;; link-row : Bytevector Natural String Natural Natural -> (List ...)     a row as link-rows reads it
(define (link-row owner s type t created) (list owner (nid s) type (nid t) created))

;; seed-link! : Rig Bytevector Natural String Natural Natural Natural -> Void
;; OWNER's link from node S to node T of TYPE, made at CREATED, through the
;; store, which judges nothing: its change row at S's revision REV.
(define (seed-link! g owner s type t rev created)
  (run-write (rig-store g) (lambda (tx) (insert-link! tx owner (nid s) type (nid t) rev created))))

;; item-of : Alist -> (Pair String String)     a page item's type and its node's id
(define (item-of i) (cons (member-of i "type") (member-of (member-of i "node") "id")))

;; item-state-of : Alist -> (List String String String)     the type, the node's id and its state
(define (item-state-of i)
  (list (member-of i "type") (member-of (member-of i "node") "id") (member-of (member-of i "node") "state")))

;;; The job's table, cell by cell, through real requests

;; The ends of a cell: no node (missing), B's node (other), A's purged node,
;; and A's node in each live state.
(define link-ends '(missing other purged active archived trashed))

(define (live-end? end) (and (memq end live-states) #t))

;; seed-end! : Rig Natural Symbol -> Void
;; Node N as END: nothing for missing; B's note at revision 1 for other;
;; else A's note by seed-state! (revision 2 active, 3 archived or trashed),
;; and for purged, trashed and then purged through the store.
(define (seed-end! g n end)
  (case end
    ((missing) #f)
    ((other) (seed-node! g acct-b n "note"))
    ((purged) (let ((r (seed-state! g acct-a n "note" 'trashed)))
                (run-write (rig-store g) (lambda (tx) (purge-node! tx (nid n) acct-a r 6100)))))
    (else (seed-state! g acct-a n "note" end))))

;; end-revision : Symbol -> Natural     a live END's revision, as seed-end! leaves it
(define (end-revision end) (if (eq? end 'active) 2 3))

;; link-cell : Symbol Symbol Symbol Boolean -> Symbol
;; The plan's table of checks, as its review orders it, written out here:
;; for VERB (put or delete), the source's END, the target's and whether
;; the link is there, the outcome: made (201), kept (200), removed (204),
;; not-found (404) or wrong-state (409). Both 404s come before any 409; a
;; link that is there is kept, or removed, whatever the states; a DELETE
;; never asks after the target.
(define (link-cell verb source target there?)
  (cond ((not (live-end? source)) 'not-found)
        ((eq? verb 'delete) (if there? 'removed 'not-found))
        ((not (live-end? target)) 'not-found)
        (there? 'kept)
        ((or (eq? source 'trashed) (eq? target 'trashed)) 'wrong-state)
        (else 'made)))

;; seed-background! : Rig -> Void
;; What every cell's file holds besides its two ends: A's active nodes 3
;; and 4 with a link 3 to 4, and B's nodes 5 and 6 with a link 5 to 6, all
;; made at 3000.
(define (seed-background! g)
  (seed-state! g acct-a 3 "note" 'active)
  (seed-state! g acct-a 4 "note" 'active)
  (seed-node! g acct-b 5 "note")
  (seed-node! g acct-b 6 "note")
  (seed-link! g acct-a 3 "related" 4 2 3000)
  (seed-link! g acct-b 5 "related" 6 1 3000))

(define background-links
  (list (link-row acct-a 3 "related" 4 3000) (link-row acct-b 5 "related" 6 3000)))

;; The cell's own link, when it is there before the request: made at 7000.
(define cell-link-at 7000)

;; expected-link-cell : Symbol Symbol -> (List ...)
;; What a cell's request answers and leaves, for OUTCOME with the source's
;; END: the status; the code ('absent for none); the body (the link's JSON,
;; 'empty, or 'problem for a refusal's); ETag and Location (none on any);
;; the jobs (one write); whether nodes and revisions are as they were; the
;; links; A's change rows added (seq counted from the last before); whether
;; B's are as they were; the key's last_used (null after a refusal, which
;; rolls back).
(define (expected-link-cell outcome end)
  (case outcome
    ((made) (list 201 'absent (link-json 1 "related" 2 now0) #f #f '(write) #t
                  (cons (link-row acct-a 1 "related" 2 now0) background-links)
                  (list (list 1 (nid 1) (end-revision end) "link" now0)) #t now0))
    ((kept) (list 200 'absent (link-json 1 "related" 2 cell-link-at) #f #f '(write) #t
                  (cons (link-row acct-a 1 "related" 2 cell-link-at) background-links)
                  '() #t now0))
    ((removed) (list 204 'absent 'empty #f #f '(write) #t background-links
                     (list (list 1 (nid 1) (end-revision end) "unlink" now0)) #t now0))
    ((not-found) (list 404 "not_found" 'problem #f #f '(write) #t background-links '() #t #f))
    ((wrong-state) (list 409 "wrong_state" 'problem #f #f '(write) #t background-links '() #t #f))
    (else (assertion-violation 'expected-link-cell "no such outcome" outcome))))

;; observe-link-cell : Rig Symbol -> (List ...)
;; A's VERB of the link from node 1 to node 2, related, and what
;; expected-link-cell describes of it.
(define (observe-link-cell g verb)
  (let* ((before (tables g))
         (a-before (change-rows g acct-a))
         (b-before (change-rows g acct-b))
         (a (if (eq? verb 'put) (link! g 1 1 "related" 2) (unlink! g 1 1 "related" 2)))
         (after (tables g)))
    (list (answer-status a) (member-of (answer-json a) "code")
          (if (>= (answer-status a) 400) 'problem (answer-json a))
          (answer-header a "etag") (answer-header a "location") ((rig-order g))
          (equal? (list (list-ref before 0) (list-ref before 1))
                  (list (list-ref after 0) (list-ref after 1)))
          (link-rows g)
          (new-changes a-before (change-rows g acct-a))
          (equal? b-before (change-rows g acct-b))
          (last-used g 1))))

(for-each
 (lambda (verb)
   (for-each
    (lambda (source)
      (for-each
       (lambda (target)
         (for-each
          (lambda (there?)
            ;; A link is there only between two live nodes of its owner.
            (when (or (not there?) (and (live-end? source) (live-end? target)))
              (let ((outcome (link-cell verb source target there?)))
                (test-equal (string-append "link cell: " (if (eq? verb 'put) "PUT" "DELETE")
                                           ", source " (sym->str source) ", target " (sym->str target)
                                           (if there? ", the link there" ", no link")
                                           ": " (sym->str outcome)
                                           "; no ETag, no Location, one write job, no node row or snapshot changed")
                  (expected-link-cell outcome source)
                  (attempt
                   (lambda ()
                     (with-rig "link-cell.db"
                       (lambda (g)
                         (seed-end! g 1 source)
                         (seed-end! g 2 target)
                         (seed-background! g)
                         (when there?
                           (seed-link! g acct-a 1 "related" 2 (end-revision source) cell-link-at))
                         (observe-link-cell g verb)))))))))
          '(#f #t)))
       link-ends))
    link-ends))
 '(put delete))

;;; Q11 and G7': another account's node, a purged one and a missing id

(test-equal "Q11: B's node, A's purged node and an id no one holds, at either end of a PUT and a DELETE and as a GET's node: one 404, byte for byte and header for header, each in its one job; nothing changed, last_used null"
  (list (repeat 15 '(404 "not_found")) #t #t (append (repeat 12 'write) (repeat 3 'read)) #t #f)
  (attempt
   (lambda ()
     (with-rig "link-q11.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-end! g 2 'other)
         (seed-end! g 3 'purged)
         (let* ((before (tables g))
                (ends (list (cons 2 1) (cons 3 1) (cons 4 1) (cons 1 2) (cons 1 3) (cons 1 4)))
                (puts (in-order (lambda (e) (link! g 1 (car e) "related" (cdr e))) ends))
                (deletes (in-order (lambda (e) (unlink! g 1 (car e) "related" (cdr e))) ends))
                (gets (in-order (lambda (n) (links-get g 1 n "")) '(2 3 4)))
                (as (append puts deletes gets)))
           (list (map status+code as)
                 (for-all (lambda (a) (equal? (answer-body a) (answer-body (car as)))) as)
                 (for-all (lambda (a) (equal? (answer-headers a) (answer-headers (car as)))) as)
                 ((rig-order g))
                 (equal? before (tables g))
                 (last-used g 1))))))))

(test-equal "G7': B never sees or changes A's links: B's PUT and DELETE of A's link, a PUT from or to A's node from B's, B's GET of A's two nodes, each a 404; B's list is B's link alone, A's is A's alone, and A's GET of B's node a 404; every link, change and node row as it was"
  (list (repeat 7 '(404 "not_found"))
        (list (cons "mentions" (nid-text 6)))
        (list (cons "related" (nid-text 2)))
        '(404 "not_found")
        #t)
  (attempt
   (lambda ()
     (with-rig "link-g7.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (seed-node! g acct-b 5 "note")
         (seed-node! g acct-b 6 "note")
         (seed-link! g acct-a 1 "related" 2 2 7000)
         (seed-link! g acct-b 5 "mentions" 6 1 3000)
         (let* ((before (tables g))
                (bs (list (link! g 3 1 "related" 2)
                          (unlink! g 3 1 "related" 2)
                          (link! g 3 5 "related" 1)
                          (link! g 3 1 "related" 5)
                          (unlink! g 3 5 "related" 1)
                          (links-get g 3 1 "")
                          (links-get g 3 2 "direction=in")))
                (b-own (links-get g 3 5 ""))
                (a-own (links-get g 1 1 ""))
                (a-other (links-get g 1 6 "direction=in"))
                (after (tables g)))
           (list (map status+code bs)
                 (map item-of (items b-own))
                 (map item-of (items a-own))
                 (status+code a-other)
                 (equal? before after))))))))

;;; Q3, Q5, Q15: one link per source, type and target; created is the first PUT's

(test-equal "Q15: a second PUT a day later is 200 with the first's created, as are the row and the list; it writes no change row and no link row (Q3); the first wrote one change row, link, on the source at its revision (Q5)"
  (list 201 (link-json 1 "related" 2 now0) 200 (link-json 1 "related" 2 now0)
        (list (link-row acct-a 1 "related" 2 now0)) (list now0)
        (list (list 1 (nid 1) 2 "link" now0)))
  (attempt
   (lambda ()
     (with-rig "link-q15.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let* ((changes0 (change-rows g acct-a))
                (a (link! g 1 1 "related" 2)))
           ((rig-set-now! g) (+ now0 day 1))
           (let* ((b (link! g 1 1 "related" 2))
                  (l (links-get g 1 1 "")))
             (list (answer-status a) (answer-json a) (answer-status b) (answer-json b)
                   (link-rows g)
                   (map (lambda (i) (member-of i "created")) (items l))
                   (new-changes changes0 (change-rows g acct-a))))))))))

(test-equal "Q2/K2: one link per source, type and target; another type between the same two, and the same type the other way, are links of their own, each 201"
  (list '(201 201 201 200)
        (list (link-row acct-a 1 "blocks" 2 now0) (link-row acct-a 1 "related" 2 now0)
              (link-row acct-a 2 "related" 1 now0)))
  (attempt
   (lambda ()
     (with-rig "link-twins.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let ((as (in-order (lambda (l) (apply link! g 1 l))
                             '((1 "related" 2) (1 "blocks" 2) (2 "related" 1) (1 "blocks" 2)))))
           (list (map answer-status as) (link-rows g))))))))

(test-equal "unlink: removes that link alone: the same ends' other type and the other way stay; a second DELETE is 404 and writes nothing"
  (list 204 '(404 "not_found")
        (list (link-row acct-a 1 "blocks" 2 7000) (link-row acct-a 2 "related" 1 7000))
        (list (list 1 (nid 1) 2 "unlink" now0)))
  (attempt
   (lambda ()
     (with-rig "unlink-one.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (seed-link! g acct-a 1 "related" 2 2 7000)
         (seed-link! g acct-a 1 "blocks" 2 2 7000)
         (seed-link! g acct-a 2 "related" 1 2 7000)
         (let* ((changes0 (change-rows g acct-a))
                (a (unlink! g 1 1 "related" 2))
                (b (unlink! g 1 1 "related" 2)))
           (list (answer-status a) (status+code b) (link-rows g)
                 (new-changes changes0 (change-rows g acct-a)))))))))

;;; Q9: the other writes leave links as they were

(test-equal "Q9: an archive, an unarchive, a replace, a restore, a move, a trash and an untrash of a linked node, and a trash of the other end, each 200 and each leaving every link as it was; the list shows the other node as it now is"
  (list (repeat 8 '(200 #t))
        (list (list "mentions" (nid-text 1) "active" 8 (nid-text 3)))
        (list (list "related" (nid-text 2) "trashed" 2 'null)))
  (attempt
   (lambda ()
     (with-rig "link-q9.db"
       (lambda (g)
         (seed-in! g acct-a 1 "note" #f)
         (seed-in! g acct-a 2 "note" #f)
         (seed-in! g acct-a 3 "project" #f)
         (seed-link! g acct-a 1 "related" 2 1 7000)
         (seed-link! g acct-a 2 "mentions" 1 1 7000)
         (seed-link! g acct-a 3 "blocks" 1 1 7000)
         (let* ((links0 (link-rows g))
                (steps (list (lambda () (lifecycle! g 1 1 'archive 1))
                             (lambda () (lifecycle! g 1 1 'unarchive 2))
                             (lambda () (replace! g 1 1 3 #f "t2" "b2" "text/plain"))
                             (lambda () (restore! g 1 1 1 4))
                             (lambda () (move! g 1 1 5 3))
                             (lambda () (lifecycle! g 1 1 'trash 6))
                             (lambda () (lifecycle! g 1 2 'trash 1))
                             (lambda () (lifecycle! g 1 1 'untrash 7))))
                (seen (in-order (lambda (step)
                                  (let ((a (step)))
                                    (list (answer-status a) (equal? links0 (link-rows g)))))
                                steps))
                (node-of (lambda (i) (member-of i "node")))
                (shown (lambda (a)
                         (map (lambda (i) (list (member-of i "type") (member-of (node-of i) "id")
                                                (member-of (node-of i) "state")
                                                (member-of (node-of i) "revision")
                                                (member-of (node-of i) "parent")))
                              (items a)))))
           (list seen (shown (links-get g 1 2 "")) (shown (links-get g 1 1 "")))))))))

;;; Q8, Q17: a purge through DELETE /v1/nodes/:id

(test-equal "Q8/Q17: the purge of a node linked both ways, three out and two in, is 204; no link of it is left, the others are as they were; one change row, the purge's; no other node's row changed; the lists of the other ends no longer show it"
  (list 200 204
        (list (link-row acct-a 2 "related" 3 7000) (link-row acct-a 3 "mentions" 4 7000)
              (link-row acct-b 5 "related" 6 3000))
        (list (list 1 (nid 1) 3 "purge" now0))
        #t #t
        (list (cons "related" (nid-text 3))) '() (list (cons "related" (nid-text 2))))
  (attempt
   (lambda ()
     (with-rig "link-purge.db"
       (lambda (g)
         (for-each (lambda (n) (seed-in! g acct-a n "note" #f)) '(1 2 3 4))
         (seed-node! g acct-b 5 "note")
         (seed-node! g acct-b 6 "note")
         (for-each (lambda (l) (seed-link! g acct-a (car l) (cadr l) (caddr l) 1 7000))
                   '((1 "related" 2) (1 "blocks" 2) (1 "mentions" 3) (2 "related" 1) (3 "blocks" 1)
                     (2 "related" 3) (3 "mentions" 4)))
         (seed-link! g acct-b 5 "related" 6 1 3000)
         (let* ((t (lifecycle! g 1 1 'trash 1))
                (others (lambda ()
                          (run-read (rig-store g)
                                    (lambda (tx) (tx-query tx "SELECT * FROM nodes WHERE id <> ? ORDER BY num"
                                                           (nid 1))))))
                (others0 (others))
                (changes0 (change-rows g acct-a))
                (b0 (change-rows g acct-b))
                (p (lifecycle! g 1 1 'purge 2)))
           (list (answer-status t) (answer-status p) (link-rows g)
                 (new-changes changes0 (change-rows g acct-a))
                 (equal? others0 (others))
                 (equal? b0 (change-rows g acct-b))
                 (map item-of (items (links-get g 1 2 "")))
                 (map item-of (items (links-get g 1 2 "direction=in")))
                 (map item-of (items (links-get g 1 3 "direction=in"))))))))))

;;; The list: pages (Q10, Q21)

(define type-names '("related" "mentions" "blocks"))

;; out-type, in-type : Natural -> String     the type of node 1's link to K, and of K's to 1
(define (out-type k) (list-ref type-names (mod k 3)))
(define (in-type k) (list-ref type-names (mod (+ k 1) 3)))

(define web-nodes (let loop ((k 106) (acc '())) (if (< k 2) acc (loop (- k 1) (cons k acc)))))

;; seed-web! : Rig -> Void
;; In one write job, through the store: A's node 1 and nodes 2 to 106, each
;; a note at revision 1 made at 5000; every seventh archived and every
;; eleventh trashed (77 is trashed); node 1 linked to each, by out-type,
;; and each to node 1, by in-type; links between 2 and 3 both ways, which
;; are no link of node 1; B's nodes 200 and 201, linked.
(define (seed-web! g)
  (run-write (rig-store g)
             (lambda (tx)
               (let ((note! (lambda (owner n)
                              (insert-node! tx (nid n) owner "note" "seed" "seed body" "text/plain" "{}"
                                            #f 5000))))
                 (note! acct-a 1)
                 (for-each (lambda (k)
                             (note! acct-a k)
                             (cond ((= (mod k 11) 0) (set-node-state! tx (nid k) acct-a 1 "trashed" "trash" 6000))
                                   ((= (mod k 7) 0) (set-node-state! tx (nid k) acct-a 1 "archived" "archive" 6000))))
                           web-nodes)
                 (for-each (lambda (k)
                             (insert-link! tx acct-a (nid 1) (out-type k) (nid k) 1 7000)
                             (insert-link! tx acct-a (nid k) (in-type k) (nid 1) 1 7000))
                           web-nodes)
                 (insert-link! tx acct-a (nid 2) "related" (nid 3) 1 7000)
                 (insert-link! tx acct-a (nid 3) "blocks" (nid 2) 1 7000)
                 (note! acct-b 200)
                 (note! acct-b 201)
                 (insert-link! tx acct-b (nid 200) "related" (nid 201) 1 7000)))))

;; web-expected : Symbol (U String #f) -> (Listof (Pair String String))
;; Node 1's links in DIRECTION, of TYPE or all, as the plan orders them,
;; written out here: by the type's name, then the other node's id.
(define (web-expected direction type)
  (let ((type-of (if (eq? direction 'out) out-type in-type)))
    (apply append
           (map (lambda (t)
                  (map (lambda (k) (cons t (nid-text k)))
                       (filter (lambda (k) (string=? (type-of k) t)) web-nodes)))
                (if type (list type) '("blocks" "mentions" "related"))))))

;; walk-links : Rig Natural String Natural -> (List (Listof (Pair String String)) (U Boolean Symbol))
;; Node N's links for QUERY (its parameters but limit and after), in pages
;; of LIMIT, each page's next handed back as after, to the end: every
;; item's type and node id, and whether every answer was a 200 and every
;; page but the last full; 'too-many-pages past 400 pages.
(define (walk-links g n query limit)
  (let loop ((after #f) (acc '()) (ok #t) (pages 1))
    (let* ((q (string-append query (if (string=? query "") "" "&") "limit=" (number->string limit)
                             (if after (string-append "&after=" after) "")))
           (a (links-get g 1 n q))
           (its (items a))
           (next (member-of (answer-json a) "next"))
           (acc (append acc (map item-of its)))
           (ok (and ok (= (answer-status a) 200))))
      (cond ((> pages 400) (list acc 'too-many-pages))
            ((string? next) (loop next acc (and ok (= (length its) limit)) (+ pages 1)))
            (else (list acc ok))))))

(for-each
 (lambda (direction)
   (for-each
    (lambda (type)
      (for-each
       (lambda (limit)
         (test-equal (string-append "Q10/Q21: node 1's links, " (sym->str direction)
                                    (if type (string-append ", type " type) ", every type")
                                    ", in pages of " (number->string limit)
                                    ": each link once, by type then the other node's id, to the end; no other node's link, no other account's")
           (list (web-expected direction type) #t)
           (attempt
            (lambda ()
              (with-rig "link-pages.db"
                (lambda (g)
                  (seed-web! g)
                  (walk-links g 1 (string-append (if (eq? direction 'in) "direction=in" "direction=out")
                                                 (if type (string-append "&type=" type) ""))
                              limit)))))))
       '(1 100)))
    '(#f "blocks" "mentions" "related")))
 '(out in))

;; cursor-of : (Pair String String) -> String     an item's next: its type, a colon, its node's id
(define (cursor-of p) (string-append (car p) ":" (cdr p)))

(test-equal "list: no direction is out; the default limit is 50, and 100 and over are 100; next is the last item's type, a colon and its node's id, in lower case; null at the end"
  (let ((out (web-expected 'out #f)))
    (list #t
          (list 50 (cursor-of (list-ref out 49)))
          (list 100 (cursor-of (list-ref out 99)))
          (list 100 (cursor-of (list-ref out 99)))
          (list 5 'null)))
  (attempt
   (lambda ()
     (with-rig "link-limits.db"
       (lambda (g)
         (seed-web! g)
         (let ((page (lambda (q) (let ((a (links-get g 1 1 q)))
                                   (list (length (items a)) (member-of (answer-json a) "next"))))))
           (list (equal? (answer-body (links-get g 1 1 "")) (answer-body (links-get g 1 1 "direction=out")))
                 (page "")
                 (page "limit=100")
                 (page "limit=1000")
                 (page (string-append "after=" (cursor-of (list-ref (web-expected 'out #f) 99)))))))))))

(test-equal "list: an after that names no link starts past its place: between two ids, before a type's first, past a type's last; typed too; in capitals it is the same place"
  (list (list (cons "related" (nid-text 4)) (cons "related" (nid-text 6)))
        (list (cons "related" (nid-text 2)) (cons "related" (nid-text 4)) (cons "related" (nid-text 6)))
        '()
        (list (cons "related" (nid-text 4)) (cons "related" (nid-text 6)))
        (list (cons "related" (nid-text 4)) (cons "related" (nid-text 6))))
  (attempt
   (lambda ()
     (with-rig "link-after.db"
       (lambda (g)
         (for-each (lambda (n) (seed-state! g acct-a n "note" 'active)) '(1 2 4 6))
         (for-each (lambda (n) (seed-link! g acct-a 1 "related" n 2 7000)) '(2 4 6))
         (map (lambda (q) (map item-of (items (links-get g 1 1 q))))
              (list (string-append "after=related:" (nid-text 3))
                    (string-append "after=mentions:" (nid-text 9))
                    (string-append "after=related:" (nid-text 7))
                    (string-append "type=related&after=related:" (nid-text 3))
                    (string-append "after=related:" (string-upcase (nid-text 3))))))))))

(test-equal "list: a trashed node's links and an archived one's are listed, 200; the other end is listed in whatever state it is, with that state"
  (list (list (list "blocks" (nid-text 3) "trashed"))
        (list (list "related" (nid-text 1) "active") (list "related" (nid-text 3) "trashed"))
        (list (list "related" (nid-text 1) "active") (list "related" (nid-text 2) "archived"))
        (list (list "blocks" (nid-text 2) "archived") (list "mentions" (nid-text 1) "active"))
        (list (list "mentions" (nid-text 3) "trashed") (list "related" (nid-text 2) "archived")))
  (attempt
   (lambda ()
     (with-rig "link-states.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'archived)
         (seed-state! g acct-a 3 "note" 'trashed)
         (for-each (lambda (l) (seed-link! g acct-a (car l) (cadr l) (caddr l) 2 7000))
                   '((1 "related" 2) (1 "mentions" 3) (2 "blocks" 3) (3 "related" 1) (3 "related" 2)))
         (map (lambda (q) (let ((a (links-get g 1 (car q) (cdr q))))
                            (if (= (answer-status a) 200) (map item-state-of (items a)) (status+code a))))
              (list (cons 2 "") (cons 2 "direction=in") (cons 3 "") (cons 3 "direction=in") (cons 1 ""))))))))

;; between : String String String -> String
;; What lies in TEXT after the first OPEN and before the last CLOSE.
(define (between text open close)
  (let* ((n (string-length text))
         (start (let loop ((i 0)) (if (string=? (substring text i (+ i 1)) open) (+ i 1) (loop (+ i 1)))))
         (end (let loop ((i (- n 1))) (if (string=? (substring text i (+ i 1)) close) i (loop (- i 1))))))
    (substring text start end)))

(test-equal "Q14: a page item's node is, byte for byte, the nodes list's item for that node: active, archived under none, trashed under a Project"
  '(#t #t #t)
  (attempt
   (lambda ()
     (with-rig "link-q14.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (seed-in! g acct-a 3 "project" #f)
         (archived-at! g acct-a 3 1)
         (seed-in! g acct-a 4 "note" 3)
         (trashed-at! g acct-a 4 1)
         (for-each (lambda (n) (seed-link! g acct-a 1 "related" n 2 7000)) '(2 3 4))
         (let ((links-body (answer-body (links-get g 1 1 ""))))
           (map (lambda (nk)
                  (let ((listed (answer-body
                                 (get! g 1 (string-append "/v1/nodes?state=" (cdr nk) "&limit=1&after="
                                                          (nid-text (- (car nk) 1)))))))
                    (contains? links-body (string-append "\"node\":" (between listed "[" "]")))))
                '((2 . "active") (3 . "archived") (4 . "trashed")))))))))

;;; The checks before the job

;; links-query-bad : (Listof String)     the list's queries refused, each a 400 with no job
(define links-query-bad
  (let ((id (nid-text 2)))
    (list "direction=out&direction=out" "direction=" "direction=OUT" "direction=In" "direction=both"
          "type=related&type=related" "type=" "type=Related" "type=link" "type=related%20"
          "limit=" "limit=0" "limit=-1" "limit=x" "limit=1&limit=1"
          (string-append "after=related:" id "&after=related:" id)
          "after=" (string-append "after=" id) (string-append "after=links:" id)
          (string-append "after=Related:" id) (string-append "after=related:" v4-text)
          (string-append "after=related:" id "0") (string-append "after=:" id) "after=related:"
          (string-append "type=blocks&after=related:" id)
          (string-append "direction=in&type=mentions&after=blocks:" id))))

(for-each
 (lambda (q)
   (test-equal (string-append "list: ?" q " is a 400 invalid_request, no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "link-query.db"
          (lambda (g)
            (seed-state! g acct-a 1 "note" 'active)
            (append (status+code (links-get g 1 1 q)) (list ((rig-jobs g))))))))))
 links-query-bad)

(test-equal "list: an after of the ?type= given is a 200; with no ?type= any type's after is"
  '(200 200)
  (attempt
   (lambda ()
     (with-rig "link-query-ok.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (map (lambda (q) (answer-status (links-get g 1 1 q)))
              (list (string-append "type=blocks&after=blocks:" (nid-text 2))
                    (string-append "after=related:" (nid-text 2)))))))))

(test-equal "list: a bad query with no key is the 401, with an unknown key the 400, neither with a job: the key's shape, then the query, then the key"
  '((401 "unauthorized") (400 "invalid_request") 0)
  (attempt
   (lambda ()
     (with-rig "link-query-order.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'GET (string-append (links-path 1) "?direction=both") '()))
                (b (links-get g 9 1 "direction=both")))
           (list (status+code a) (status+code b) ((rig-jobs g)))))))))

(test-equal "list: If-Match and If-None-Match on the GET are ignored: 200, the page as without"
  '(200 #t)
  (attempt
   (lambda ()
     (with-rig "link-get-pre.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (seed-link! g acct-a 1 "related" 2 2 7000)
         (let ((a ((rig-call g) 'GET (links-path 1)
                               (list (key-h 1) (match-h 7) none-match (cons "If-Match" "*"))))
               (b (links-get g 1 1 "")))
           (list (answer-status a) (equal? (answer-body a) (answer-body b)))))))))

;; link-verbs : (Listof (Pair String (Rig Natural Natural String Natural . Any -> Answer)))
(define link-verbs (list (cons "PUT" link!) (cons "DELETE" unlink!)))

;; link-path-bad : (Listof (List String String String String))
;; A path refused before any job: what is wrong, the source's text, the
;; type, the target's text.
(define link-path-bad
  (list (list "a type in another case" (nid-text 1) "Related" (nid-text 2))
        (list "a type in capitals" (nid-text 1) "MENTIONS" (nid-text 2))
        (list "a type not of the three" (nid-text 1) "relates" (nid-text 2))
        (list "a type that is a word of no list" (nid-text 1) "link" (nid-text 2))
        (list "a v4 target" (nid-text 1) "related" v4-text)
        (list "a target that is no id" (nid-text 1) "related" "x")
        (list "a target of 32 hex digits, no hyphens" (nid-text 1) "related" "0190b3a45c6d7e8f9a0b000000000002")
        (list "a v4 source" v4-text "related" (nid-text 2))
        (list "the source its own target" (nid-text 1) "related" (nid-text 1))
        (list "the source its own target, the target in capitals" (nid-text 1) "related"
              (string-upcase (nid-text 1)))))

(for-each
 (lambda (verb)
   (for-each
    (lambda (bad)
      (test-equal (string-append "link: " (car verb) " with " (car bad) ": 400 invalid_request, no job, nothing written")
        '(400 "invalid_request" 0 #t)
        (attempt
         (lambda ()
           (with-rig "link-path.db"
             (lambda (g)
               (seed-state! g acct-a 1 "note" 'active)
               (seed-state! g acct-a 2 "note" 'active)
               (seed-link! g acct-a 1 "related" 2 2 7000)
               (let* ((before (tables g))
                      (a ((rig-call g) (string->symbol (car verb))
                                       (link-path-of (cadr bad) (caddr bad) (cadddr bad))
                                       (list (key-h 1)))))
                 (append (status+code a) (list ((rig-jobs g)) (equal? before (tables g)))))))))))
    link-path-bad)
   (for-each
    (lambda (bad)
      (test-equal (string-append "link: " (car verb) " with " (car bad)
                                 ": 400 invalid_request, no job, nothing written: a link takes no precondition")
        '(400 "invalid_request" 0 #t)
        (attempt
         (lambda ()
           (with-rig "link-pre.db"
             (lambda (g)
               (seed-state! g acct-a 1 "note" 'active)
               (seed-state! g acct-a 2 "note" 'active)
               (seed-link! g acct-a 1 "related" 2 2 7000)
               (let* ((before (tables g))
                      (a ((cdr verb) g 1 1 "related" 2 (cdr bad))))
                 (append (status+code a) (list ((rig-jobs g)) (equal? before (tables g)))))))))))
    (list (list "If-Match: \"2\", the source's revision" (match-h 2))
          (list "If-Match: *" (cons "If-Match" "*"))
          (list "If-None-Match: *" none-match)
          (list "If-None-Match: \"2\"" (cons "If-None-Match" "\"2\""))
          (list "both" (match-h 2) none-match)
          (list "an empty If-Match" (cons "If-Match" ""))
          (list "If-Match twice" (match-h 2) (match-h 2)))))
 link-verbs)

(test-equal "link: order: a bad type, a self link and an If-Match with no key are the 401; with an unknown key the 400; no job"
  '((401 "unauthorized") (401 "unauthorized") (401 "unauthorized")
    (400 "invalid_request") (400 "invalid_request") (400 "invalid_request") 0)
  (attempt
   (lambda ()
     (with-rig "link-order.db"
       (lambda (g)
         (let* ((call (lambda (key path . headers)
                        ((rig-call g) 'PUT path (append (if key (list (key-h key)) '()) headers))))
                (bad-type (link-path-of (nid-text 1) "Related" (nid-text 2)))
                (self (link-path 1 "related" 1))
                (good (link-path 1 "related" 2))
                (as (list (call #f bad-type) (call #f self) (call #f good (match-h 1))
                          (call 9 bad-type) (call 9 self) (call 9 good (match-h 1)))))
           (append (map status+code as) (list ((rig-jobs g))))))))))

(test-equal "link: ids in capitals are the same ids: a PUT is 201 and answers them in lower case, the row is the link's; a DELETE in capitals is 204; a GET in capitals lists it"
  (list 201 (link-json 1 "related" 2 now0) (list (link-row acct-a 1 "related" 2 now0))
        (list (cons "related" (nid-text 2))) 204 '())
  (attempt
   (lambda ()
     (with-rig "link-upper.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let* ((up (lambda (n) (string-upcase (nid-text n))))
                (path (link-path-of (up 1) "related" (up 2)))
                (a ((rig-call g) 'PUT path (list (key-h 1))))
                (rows (link-rows g))
                (l (get! g 1 (links-path-of (up 1))))
                (d ((rig-call g) 'DELETE path (list (key-h 1)))))
           (list (answer-status a) (answer-json a) rows (map item-of (items l)) (answer-status d)
                 (link-rows g))))))))

(test-equal "link: POST, GET and HEAD on one link are 405, allow PUT, DELETE; PUT, POST and DELETE on a node's links 405, allow GET, HEAD; no job"
  '((405 "method_not_allowed" "PUT, DELETE") (405 "method_not_allowed" "PUT, DELETE")
    (405 #f "PUT, DELETE")
    (405 "method_not_allowed" "GET, HEAD") (405 "method_not_allowed" "GET, HEAD")
    (405 "method_not_allowed" "GET, HEAD")
    0)
  (attempt
   (lambda ()
     (with-rig "link-405.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let ((shape (lambda (a) (list (answer-status a)
                                        (let ((c (member-of (answer-json a) "code"))) (if (eq? c 'absent) #f c))
                                        (answer-header a "allow")))))
           (let* ((one (in-order (lambda (m) (shape ((rig-call g) m (link-path 1 "related" 2)
                                                           (list (key-h 1)))))
                                 '(POST GET HEAD)))
                  (all (in-order (lambda (m) (shape ((rig-call g) m (links-path 1) (list (key-h 1)))))
                                 '(PUT POST DELETE))))
             (append one all (list ((rig-jobs g)))))))))))

;;; No body is read

(test-equal "body: a PUT's body is not read: text/plain, or JSON that does not parse, and the answer is the bytes a PUT with none gets, 201; a DELETE with a body is 204"
  '(201 #t 204)
  (attempt
   (lambda ()
     (let ((made (lambda (name more)
                   (with-rig name
                     (lambda (g)
                       (seed-state! g acct-a 1 "note" 'active)
                       (seed-state! g acct-a 2 "note" 'active)
                       (let ((a (apply link! g 1 1 "related" 2 more)))
                         (list (answer-status a) (answer-body a))))))))
       (let ((none (made "link-body-none.db" '()))
             (plain (made "link-body-plain.db" (list (list (cons "Content-Type" "text/plain")) "not json at all")))
             (broken (made "link-body-json.db" (list (list json-type) "{nope"))))
         (list (car plain)
               (and (equal? none plain) (equal? none broken))
               (with-rig "unlink-body.db"
                 (lambda (g)
                   (seed-state! g acct-a 1 "note" 'active)
                   (seed-state! g acct-a 2 "note" 'active)
                   (seed-link! g acct-a 1 "related" 2 2 7000)
                   (answer-status (unlink! g 1 1 "related" 2 (list json-type) "{nope"))))))))))

(test-equal "body: a PUT's head alone, a Content-Length of 2 MB and no byte of the body sent, is answered at once, 201, in its one write job, and the connection is ended: no body is waited for"
  (list '(201) #f #t '(write))
  (attempt
   (lambda ()
     (with-rig "link-head.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let-values (((answers waiting? closed?)
                       (exchange-steps (rig-handler g)
                                       (list (request-bytes 'PUT (link-path 1 "related" 2)
                                                            (list (key-h 1) json-type
                                                                  (cons "Content-Length" "2000000")))))))
           (list (map answer-status answers) waiting? closed? ((rig-order g)))))))))

(test-equal "body: a DELETE's head alone and a GET's, each a Content-Length of 2 MB and no byte of the body sent, are answered at once, 204 and 200, each in its one job, and the connection ended; a GET with a body that does not parse is the page as without one"
  (list (list '(204) #f #t '(write)) (list '(200) #f #t '(read)) '(200 #t))
  (attempt
   (lambda ()
     (let ((head-alone (lambda (name method path)
                         (with-rig name
                           (lambda (g)
                             (seed-state! g acct-a 1 "note" 'active)
                             (seed-state! g acct-a 2 "note" 'active)
                             (seed-link! g acct-a 1 "related" 2 2 7000)
                             (let-values (((answers waiting? closed?)
                                           (exchange-steps (rig-handler g)
                                                           (list (request-bytes method path
                                                                                (list (key-h 1) json-type
                                                                                      (cons "Content-Length" "2000000")))))))
                               (list (map answer-status answers) waiting? closed? ((rig-order g)))))))))
       (list (head-alone "unlink-head.db" 'DELETE (link-path 1 "related" 2))
             (head-alone "links-head.db" 'GET (links-path 1))
             (with-rig "links-body.db"
               (lambda (g)
                 (seed-state! g acct-a 1 "note" 'active)
                 (seed-state! g acct-a 2 "note" 'active)
                 (seed-link! g acct-a 1 "related" 2 2 7000)
                 (let* ((a ((rig-call g) 'GET (links-path 1) (list (key-h 1) json-type) "{nope"))
                        (b (links-get g 1 1 "")))
                   (list (answer-status a) (equal? (answer-body a) (answer-body b)))))))))))

;;; Jobs and the log

(test-equal "job: a link's job and an unlink's hold plain data: no request, no parsed JSON"
  '(201 #f 204 #f)
  (attempt
   (lambda ()
     (with-rig "job-link.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let* ((a (link! g 1 1 "related" 2))
                (ja ((rig-job g)))
                (b (unlink! g 1 1 "related" 2))
                (jb ((rig-job g))))
           (list (answer-status a) (reaches? ja req-like?)
                 (answer-status b) (reaches? jb req-like?))))))))

(test-equal "log: each link request's line names its route, its path with no query string, and the account, a refusal's too; none holds a title or a body"
  (list '(201 200 409 404 204 404 200 404) 8 #t (repeat 8 #t) #f #f #f)
  (attempt
   (lambda ()
     (with-rig "log-link.db"
       (lambda (g)
         (for-each (lambda (n)
                     (run-write (rig-store g)
                                (lambda (tx) (insert-node! tx (nid n) acct-a "note" "secret-title-6"
                                                           "secret-body-6" "text/plain" "{}" #f 5000))))
                   '(1 2 3))
         (set-state-at! g acct-a 3 1 "trashed" "trash")
         (let* ((as (in-order (lambda (send) (send))
                              (list (lambda () (link! g 1 1 "related" 2))
                                    (lambda () (link! g 1 1 "related" 2))
                                    (lambda () (link! g 1 1 "related" 3))
                                    (lambda () (link! g 1 1 "related" 4))
                                    (lambda () (unlink! g 1 1 "related" 2))
                                    (lambda () (unlink! g 1 1 "related" 2))
                                    (lambda () (links-get g 1 1 "direction=in&type=related"))
                                    (lambda () (links-get g 1 4 "")))))
                (lines ((rig-lines g)))
                (text (apply string-append lines))
                (paths (list (link-path 1 "related" 2) (link-path 1 "related" 2) (link-path 1 "related" 3)
                             (link-path 1 "related" 4) (link-path 1 "related" 2) (link-path 1 "related" 2)
                             (links-path 1) (links-path 4))))
           (list (map answer-status as) (length lines)
                 (for-all (lambda (l) (contains? l (string-append "account=" (id->string acct-a)))) lines)
                 (map (lambda (l p) (contains? l (string-append "path=" p " "))) lines paths)
                 (contains? text "?")
                 (contains? text "secret-title-6") (contains? text "secret-body-6"))))))))


(test-equal "link: a DELETE's 204 has no body, and its headers whole are the date alone: no content-type, etag or location"
  (list 204 "" (list (cons "date" "Thu, 01 Jan 1970 00:00:00 GMT")))
  (attempt
   (lambda ()
     (with-rig "link-204.db"
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let* ((p (link! g 1 1 "related" 2))
                (d (unlink! g 1 1 "related" 2)))
           (list (answer-status d) (answer-body d) (answer-headers d))))))))

;; stepping-wall : -> (-> Natural)     a wall clock that steps by 1000 on each read
(define (stepping-wall)
  (let ((t (- now0 1000)))
    (lambda () (set! t (+ t 1000)) t)))

;; The key's last_used is written by (techo auth) from the now db-write-as
;; is handed, so it is held with the others: all of them one read. A key's
;; first write sets it, so each request is the first of its own file.
(test-equal "time: a link's PUT reads the wall clock once: the link's created, its change row's time and the key's last_used are one time"
  (list #t #t #t)
  (attempt
   (lambda ()
     (with-rig-wall "link-time-put.db" stepping-wall
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (let* ((p (link! g 1 1 "related" 2))
                (c (member-of (answer-json p) "created"))
                (row (car (reverse (change-rows g acct-a)))))
           (list (equal? (list-ref row 3) "link") (= c (list-ref row 4)) (= c (last-used g 1)))))))))

(test-equal "time: a link's DELETE reads the wall clock once: the unlink row's time and the key's last_used are one time"
  (list #t #t)
  (attempt
   (lambda ()
     (with-rig-wall "link-time-del.db" stepping-wall
       (lambda (g)
         (seed-state! g acct-a 1 "note" 'active)
         (seed-state! g acct-a 2 "note" 'active)
         (seed-link! g acct-a 1 "related" 2 2 3000)
         (let* ((d (unlink! g 1 1 "related" 2))
                (row (car (reverse (change-rows g acct-a)))))
           (list (equal? (list-ref row 3) "unlink") (and (last-used g 1) (= (list-ref row 4) (last-used g 1))))))))))
(test-end "node-routes")

(exit (suite-exit-status runner))
