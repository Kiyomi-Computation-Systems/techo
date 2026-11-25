#!r6rs
;;; The node routes suite: slice 4's seven routes, (techo node-routes), as
;;; a router serves them inside the whole stack (wrap-server), against real
;;; SQLite through the test doorway, raw HTTP bytes in through circuit's
;;; test host. The routes are not yet joined to make-app, so the rig makes
;;; its own router of them.
;;;
;;;   PUT  /v1/nodes/:id                         create (If-None-Match: *) or replace (If-Match)
;;;   GET  /v1/nodes/:id                         the node, with its ETag
;;;   GET  /v1/nodes                             the account's nodes, paged, no bodies
;;;   GET  /v1/nodes/:id/revisions               its snapshots, newest first, no bodies
;;;   GET  /v1/nodes/:id/revisions/:n            one snapshot, whole
;;;   POST /v1/nodes/:id/revisions/:n/restore    a new revision copied from snapshot n
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
        (only (techo keys) key-secret)
        (except (techo store) key-hash)
        (only (techo auth) key-hash)
        (only (techo doorway) tx-query tx-query-row)
        (only (techo nodes) parse-node-id body-cap request-cap)
        (only (techo node-store) insert-node! write-node!)
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
(define (with-rig name body)
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
                 (h (wrap-server (make-router (node-routes read write (lambda () now) clock)
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
             (lambda (tx) (insert-node! tx (nid n) owner kind "seed" "seed body" "text/plain" "{}" 5000))))

;; tables : Rig -> (List ...)
;; The three tables whole, and every key's id and last_used.
(define (tables g)
  (run-read (rig-store g)
            (lambda (tx)
              (list (tx-query tx "SELECT * FROM nodes ORDER BY num")
                    (tx-query tx "SELECT * FROM revisions ORDER BY node, revision")
                    (tx-query tx "SELECT * FROM changes ORDER BY owner, seq")
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

(define (get! g who path) ((rig-call g) 'GET path (list (key-h who))))

;;; What answers look like

;; status+code : Answer -> (List Natural Any)
(define (status+code a)
  (list (answer-status a)
        (let ((j (answer-json a)))
          (if (and (list? j) (assoc "code" j)) (cdr (assoc "code" j)) j))))

(define (member-of j name) (let ((m (and (list? j) (assoc name j)))) (if m (cdr m) 'absent)))
(define (names j) (map car j))

;; node-json : Natural String String String String Natural Natural Natural -> Alist
(define (node-json n kind title body type revision created updated)
  (list (cons "id" (nid-text n)) (cons "kind" kind) (cons "title" title) (cons "body" body)
        (cons "content_type" type) (cons "props" '()) (cons "revision" revision)
        (cons "created" created) (cons "updated" updated)))

;; item-json : as node-json, without the body
(define (item-json n kind title type revision created updated)
  (list (cons "id" (nid-text n)) (cons "kind" kind) (cons "title" title)
        (cons "content_type" type) (cons "props" '()) (cons "revision" revision)
        (cons "created" created) (cons "updated" updated)))

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
    (else (assertion-violation 'route-request "no such route" which))))

(define route-names '(list-nodes get-node create replace list-revisions get-revision restore))

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
      (else (assertion-violation 'id-request "no such route" which)))))

(define id-routes '(get-node create replace list-revisions get-revision restore))

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
    (else (assertion-violation 'missing-request "no such route" which))))

(for-each
 (lambda (which)
   (test-equal (string-append "owner: " (symbol->string which)
                              " on B's node and on a missing one: the same 404, one job each (a PUT's two), B's node untouched")
     (list '(404 "not_found") '(404 "not_found") #t #t (if (eq? which 'replace) 4 2) #t)
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
                    (equal? (map (lambda (t) (list-ref before t)) '(0 1 2))
                            (let ((after (tables g))) (map (lambda (t) (list-ref after t)) '(0 1 2))))))))))))
 '(get-node replace list-revisions get-revision restore))

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
                                               "text/plain" "{\"a\":1}" 5000)))
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
                                 "body" "text/plain" "{}" (+ 6000 n))
                   (loop (+ n 1))))
               (let loop ((n 200))
                 (when (<= n 204)
                   (insert-node! tx (nid n) acct-b "note" "b" "body" "text/plain" "{}" 7000)
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
               (insert-node! tx (nid 1) acct-a "note" "r1" "body 1" "text/plain" "{}" 100)
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
                     (equal? (map (lambda (t) (list-ref before t)) '(0 1 2))
                             (map (lambda (t) (list-ref after t)) '(0 1 2)))
                     (last-used g 1))))))))))

;;; A job closes over plain data; no title or body leaves in a log line

;; req-like? : Any -> Boolean     a request, or a member of a parsed JSON object
(define (req-like? x)
  (or (req? x) (and (pair? x) (member (car x) '("title" "body" "kind" "content_type")) #t)))

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

(test-end "node-routes")

(exit (suite-exit-status runner))
