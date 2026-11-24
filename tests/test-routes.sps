#!r6rs
;;; The routes suite: D9's four key routes, as make-app serves them inside
;;; the whole stack (wrap-server), against real SQLite through the test
;;; doorway, raw HTTP bytes in through circuit's test host.
;;;
;;;   GET  /v1/account                  who the key belongs to
;;;   GET  /v1/keys                     the account's keys, paged
;;;   POST /v1/keys/:id/revoke          D5's revoke
;;;   POST /v1/keys/:id/regenerate      D5's regenerate, a new secret once
;;;
;;; Each test gets a file of its own (a rig), seeded through the store's own
;;; procedures in a write job: account A (alice) with keys 1 "laptop", 2
;;; "phone" and 5 "old", revoked; account B (bob) with key 3. Key n's id is
;;; 16 bytes of n, its secret key-secret of 32 bytes of n. The wall clock is
;;; fixed (and moved by hand), the duration clock steps by 1, and random
;;; bytes come from a sequence. Jobs and draws are counted. Everything that
;;; can raise is computed under `attempt`, and a raise comes out as a value
;;; the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (circuit)
        (http-support)
        (techo errors)
        (techo keys)
        (except (techo store) key-hash)
        (rename (only (techo store) key-hash) (key-hash key-row-hash))
        (techo auth)
        (techo app))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (hex bv)
  (apply string-append
         (map (lambda (b)
                (string-append (if (< b 16) "0" "") (string-downcase (number->string b 16))))
              (bytevector->u8-list bv))))

(define dir (fresh-dir "test-routes"))

(define acct-a (make-bytevector 16 #xA1))
(define acct-b (make-bytevector 16 #xB2))
(define (kid n) (make-bytevector 16 n))
(define (kid-text n) (id->string (kid n)))
(define (secret-of n) (key-secret (make-bytevector 32 n)))
(define now0 1795515226123)

(define (seed! tx)
  (insert-account! tx acct-a "alice" "alice@example.com" "argon2id-hash-of-alice" 1000)
  (insert-account! tx acct-b "bob" "bob@example.com" "argon2id-hash-of-bob" 2000)
  (insert-key! tx (kid 1) acct-a "laptop" (key-hash (secret-of 1)) 1100)
  (insert-key! tx (kid 2) acct-a "phone" (key-hash (secret-of 2)) 1200)
  (insert-key! tx (kid 3) acct-b "bob's" (key-hash (secret-of 3)) 1300)
  (insert-key! tx (kid 5) acct-a "old" (key-hash (secret-of 5)) 1500)
  (revoke-key! tx acct-a (kid 5) 1600))

;; A rig: CALL sends a request and answers what the client read; JOBS,
;; DRAWS and LINES count jobs, random draws and the log's lines; STORE is
;; the file; SET-NOW! moves the wall clock.
(define-record-type rig (fields call jobs draws lines store set-now! job))

;; with-rig : String (Rig -> A) -> A
;; A fresh seeded file NAME, and make-app on it inside wrap-server, its
;; runners counted, the writer keeping the last job it was handed.
(define (with-rig name body)
  (let ((s (open-test-store dir name)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (run-write s seed!)
        (let*-values (((last-job) (vector #f))
                      ((read reads) (counting (store-reader s)))
                      ((write writes) (counting (lambda (job)
                                                  (vector-set! last-job 0 job)
                                                  ((store-writer s) job))))
                      ((random draws) (counting (byte-sequence))))
          (let* ((lines '())
                 (now now0)
                 (clock (step-clock 0 1))
                 (h (wrap-server (make-app read write (lambda () now) random clock)
                                 (lambda (l) (set! lines (cons l lines)))
                                 10000 clock)))
            (body (make-rig (case-lambda
                              ((method target headers) (exchange h method target headers))
                              ((method target) (exchange h method target '())))
                            (lambda () (+ (reads) (writes)))
                            draws
                            (lambda () (reverse lines))
                            s
                            (lambda (t) (set! now t))
                            (lambda () (vector-ref last-job 0)))))))
      (lambda () (close-test-store! s)))))

;; status+code : Answer -> (List Natural Any)
(define (status+code a)
  (list (answer-status a)
        (let ((j (answer-json a)))
          (if (and (list? j) (assoc "code" j)) (cdr (assoc "code" j)) j))))

;; key-json : Natural String Natural (U Natural #f) (U Natural #f) -> Alist
(define (key-json n name created last-used revoked)
  (list (cons "id" (kid-text n)) (cons "name" name) (cons "created" created)
        (cons "last_used" (or last-used 'null)) (cons "revoked" (or revoked 'null))))

(define k1 (key-json 1 "laptop" 1100 #f #f))
(define k2 (key-json 2 "phone" 1200 #f #f))
(define k5 (key-json 5 "old" 1500 #f 1600))

(define (with-key n) (list (bearer (secret-of n))))

(test-begin "routes")

;;; Every /v1 route: no key is a 401 with no job; an unknown key a 401 in one

(define v1-routes
  '((GET "/v1/account") (GET "/v1/keys")
    (POST "/v1/keys/02020202-0202-0202-0202-020202020202/revoke")
    (POST "/v1/keys/02020202-0202-0202-0202-020202020202/regenerate")))

(define bad-headers
  (list (cons "no key" '())
        (cons "a doubled key" (list (bearer (secret-of 1)) (bearer (secret-of 1))))
        (cons "a Basic header" (list (cons "Authorization" (string-append "Basic " (secret-of 1)))))
        (cons "a key in capitals" (list (bearer (string-append "techo_" (string-upcase (substring (key-secret (make-bytevector 32 #xAB)) 6 70))))))))

(for-each
 (lambda (h)
   (for-each
    (lambda (r)
      (test-equal (string-append (car h) ": " (symbol->string (car r)) " " (cadr r)
                                 ": 401 unauthorized, www-authenticate: Bearer, no job, no draw")
        '(401 "unauthorized" "Bearer" 0 0)
        (attempt
         (lambda ()
           (with-rig "no-key.db"
             (lambda (g)
               (let ((a ((rig-call g) (car r) (cadr r) (cdr h))))
                 (append (status+code a)
                         (list (answer-header a "www-authenticate") ((rig-jobs g)) ((rig-draws g)))))))))))
    v1-routes))
 bad-headers)

(for-each
 (lambda (r)
   (test-equal (string-append "unknown key: " (symbol->string (car r)) " " (cadr r)
                              ": 401, one job")
     '(401 "unauthorized" 1)
     (attempt
      (lambda ()
        (with-rig "unknown-key.db"
          (lambda (g)
            (let ((a ((rig-call g) (car r) (cadr r) (with-key 9))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 v1-routes)

(for-each
 (lambda (r)
   (test-equal (string-append "revoked key: " (symbol->string (car r)) " " (cadr r) ": 401, one job")
     '(401 "unauthorized" 1)
     (attempt
      (lambda ()
        (with-rig "revoked-key.db"
          (lambda (g)
            (let ((a ((rig-call g) (car r) (cadr r) (with-key 5))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 v1-routes)

;;; GET /v1/account

(test-equal "account: 200, application/json, id username email created and nothing else, one job"
  (list 200 "application/json"
        (list (cons "id" (id->string acct-a)) (cons "username" "alice")
              (cons "email" "alice@example.com") (cons "created" 1000))
        1)
  (attempt
   (lambda ()
     (with-rig "account.db"
       (lambda (g)
         (let ((a ((rig-call g) 'GET "/v1/account" (with-key 1))))
           (list (answer-status a) (answer-header a "content-type") (answer-json a)
                 ((rig-jobs g)))))))))

(test-equal "account: B's key is B's account; no password hash in either answer"
  '("bob" #f #f)
  (attempt
   (lambda ()
     (with-rig "account-b.db"
       (lambda (g)
         (let ((a ((rig-call g) 'GET "/v1/account" (with-key 3)))
               (b ((rig-call g) 'GET "/v1/account" (with-key 1))))
           (list (cdr (assoc "username" (answer-json a)))
                 (contains? (answer-body a) "argon2id")
                 (contains? (answer-body b) "argon2id"))))))))

(test-equal "account: HEAD is the GET's head, with no body"
  '(200 "application/json" "")
  (attempt
   (lambda ()
     (with-rig "account-head.db"
       (lambda (g)
         (let ((a ((rig-call g) 'HEAD "/v1/account" (with-key 1))))
           (list (answer-status a) (answer-header a "content-type") (answer-body a))))))))

;;; GET /v1/keys

(test-equal "keys: A's keys in id order, the revoked one too, B's never; next null; one job"
  (list 200 (list (cons "items" (vector k1 k2 k5)) (cons "next" 'null)) 1)
  (attempt
   (lambda ()
     (with-rig "keys.db"
       (lambda (g)
         (let ((a ((rig-call g) 'GET "/v1/keys" (with-key 1))))
           (list (answer-status a) (answer-json a) ((rig-jobs g)))))))))

(test-equal "keys: B sees only its own"
  (list (list (cons "items" (vector (key-json 3 "bob's" 1300 #f #f))) (cons "next" 'null)))
  (attempt
   (lambda ()
     (with-rig "keys-b.db"
       (lambda (g) (list (answer-json ((rig-call g) 'GET "/v1/keys" (with-key 3)))))))))

(test-equal "keys: a page of three keys holds no key's hash, as hex or by name"
  '(200 3 #f #f #f)
  (attempt
   (lambda ()
     (with-rig "keys-hash.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'GET "/v1/keys" (with-key 1)))
                (body (answer-body a)))
           (list (answer-status a)
                 (vector-length (cdr (assoc "items" (answer-json a))))
                 (contains? body (hex (key-hash (secret-of 1))))
                 (contains? body (hex (key-hash (secret-of 2))))
                 (contains? body "hash"))))))))

(test-equal "keys: limit=2 is k1 and k2, next k2; after k2 is k5, next null"
  (list (list (cons "items" (vector k1 k2)) (cons "next" (kid-text 2)))
        (list (cons "items" (vector k5)) (cons "next" 'null))
        2)
  (attempt
   (lambda ()
     (with-rig "keys-page.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'GET "/v1/keys?limit=2" (with-key 1)))
                (b ((rig-call g) 'GET (string-append "/v1/keys?limit=2&after=" (kid-text 2))
                                 (with-key 1))))
           (list (answer-json a) (answer-json b) ((rig-jobs g)))))))))

(test-equal "keys: after B's key, or an id in no row, is only a place to start: A's keys past it"
  (list (list (cons "items" (vector k5)) (cons "next" 'null))
        (list (cons "items" (vector k5)) (cons "next" 'null)))
  (attempt
   (lambda ()
     (with-rig "keys-after.db"
       (lambda (g)
         (list (answer-json ((rig-call g) 'GET (string-append "/v1/keys?after=" (kid-text 3))
                                          (with-key 1)))
               (answer-json ((rig-call g) 'GET (string-append "/v1/keys?after=" (kid-text 4))
                                          (with-key 1)))))))))

(test-equal "keys: an after in upper case is the same id"
  (list (list (cons "items" (vector k5)) (cons "next" 'null)))
  (attempt
   (lambda ()
     (with-rig "keys-upper.db"
       (lambda (g)
         (list (answer-json ((rig-call g) 'GET
                                          (string-append "/v1/keys?after="
                                                         (string-upcase (kid-text 2)))
                                          (with-key 1)))))))))

(for-each
 (lambda (q)
   (test-equal (string-append "keys: ?" q " is a 400 invalid_request, with no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "keys-bad.db"
          (lambda (g)
            (let ((a ((rig-call g) 'GET (string-append "/v1/keys?" q) (with-key 1))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 '("limit=0" "limit=-1" "limit=abc" "limit=" "limit=1.5" "limit=%201" "limit=2&limit=3"
   "after=xyz" "after=" "after=0101010101010101010101010101010101"
   "after=01010101-0101-0101-0101-010101010101&after=01010101-0101-0101-0101-010101010101"))

(test-equal "keys: a bad limit with no key is the 401: the header is checked first"
  '(401 "unauthorized" 0)
  (attempt
   (lambda ()
     (with-rig "keys-bad-nokey.db"
       (lambda (g)
         (let ((a ((rig-call g) 'GET "/v1/keys?limit=0")))
           (append (status+code a) (list ((rig-jobs g))))))))))

;; many-keys! : Tx -> Void     A's keys 10 to 114: 105 more, ids in order
(define (many-keys! tx)
  (let loop ((n 10))
    (when (<= n 114)
      (insert-key! tx (kid n) acct-a (string-append "k" (number->string n))
                   (key-hash (secret-of n)) (+ 2000 n))
      (loop (+ n 1)))))

;; page : Rig String -> (List Natural (U String 'null) (U String #f))
;; How many items, next, and the last item's id.
(define (page g query)
  (let* ((a ((rig-call g) 'GET (string-append "/v1/keys" query) (with-key 1)))
         (j (answer-json a))
         (items (vector->list (cdr (assoc "items" j)))))
    (list (length items) (cdr (assoc "next" j))
          (if (null? items) #f (cdr (assoc "id" (car (reverse items))))))))

(test-equal "paging: 108 keys; default 50; 100 and over are 100; the last page's next is null"
  (list (list 50 (kid-text 56) (kid-text 56))
        (list 100 (kid-text 106) (kid-text 106))
        (list 100 (kid-text 106) (kid-text 106))
        (list 100 (kid-text 106) (kid-text 106))
        (list 8 'null (kid-text 114)))
  (attempt
   (lambda ()
     (with-rig "paging.db"
       (lambda (g)
         (run-write (rig-store g) many-keys!)
         ;; ids in order: 1 2 5, then 10 .. 114, kid n the (n - 6)th.
         (list (page g "")
               (page g "?limit=100")
               (page g "?limit=101")
               (page g "?limit=99999999999999999999")
               (page g (string-append "?limit=100&after=" (kid-text 106)))))))))

(test-equal "paging: next is there exactly when a further row is: a limit that ends on the last row has none"
  (list (list 5 'null (kid-text 114)) (list 4 (kid-text 113) (kid-text 113)))
  (attempt
   (lambda ()
     (with-rig "paging-edge.db"
       (lambda (g)
         (run-write (rig-store g) many-keys!)
         (list (page g (string-append "?limit=5&after=" (kid-text 109)))
               (page g (string-append "?limit=4&after=" (kid-text 109)))))))))

;;; POST /v1/keys/:id/revoke

(define (revoke-path n) (string-append "/v1/keys/" (kid-text n) "/revoke"))
(define (regenerate-path n) (string-append "/v1/keys/" (kid-text n) "/regenerate"))

(test-equal "revoke: A's key 1 revokes key 2: 200, the key with its revoked time, one job"
  (list 200 "application/json" (key-json 2 "phone" 1200 #f now0) 1)
  (attempt
   (lambda ()
     (with-rig "revoke.db"
       (lambda (g)
         (let ((a ((rig-call g) 'POST (revoke-path 2) (with-key 1))))
           (list (answer-status a) (answer-header a "content-type") (answer-json a)
                 ((rig-jobs g)))))))))

;; row-of : Rig Bytevector Natural -> (List ...)
;; Key N's stored row, every column, its hash among them.
(define (row-of g account n)
  (run-read (rig-store g)
            (lambda (tx)
              (let ((k (key-of-account tx account (kid n))))
                (and k (list (key-id k) (key-account k) (key-name k) (key-row-hash k)
                             (key-created k) (key-last-used k) (key-revoked k)))))))

(test-equal "revoke: the second revoke of a key changes nothing of its row, its hash included"
  '(#t #t)
  (attempt
   (lambda ()
     (with-rig "revoke-twice-row.db"
       (lambda (g)
         ((rig-call g) 'POST (revoke-path 2) (with-key 1))
         (let ((first (row-of g acct-a 2)))
           ((rig-set-now! g) (+ now0 (* 5 86400000)))
           ((rig-call g) 'POST (revoke-path 2) (with-key 1))
           (list (equal? first (row-of g acct-a 2))
                 (bytevector=? (list-ref first 3) (key-hash (secret-of 2))))))))))

(test-equal "revoke: twice answers the same key with the first time; key 2 is then refused"
  (list 200 (key-json 2 "phone" 1200 #f now0) 200 (key-json 2 "phone" 1200 #f now0)
        '(401 "unauthorized"))
  (attempt
   (lambda ()
     (with-rig "revoke-twice.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'POST (revoke-path 2) (with-key 1)))
                (b (begin ((rig-set-now! g) (+ now0 5000))
                          ((rig-call g) 'POST (revoke-path 2) (with-key 1))))
                (c ((rig-call g) 'GET "/v1/account" (with-key 2))))
           (list (answer-status a) (answer-json a) (answer-status b) (answer-json b)
                 (status+code c))))))))

(test-equal "revoke: a key revokes itself: 200, and the next request with it is a 401"
  (list 200 (key-json 1 "laptop" 1100 now0 now0) '(401 "unauthorized"))
  (attempt
   (lambda ()
     (with-rig "revoke-self.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'POST (revoke-path 1) (with-key 1)))
                (b ((rig-call g) 'GET "/v1/keys" (with-key 1))))
           (list (answer-status a) (answer-json a) (status+code b))))))))

(test-equal "revoke: B's key is a 404 for A, one job, and stays live; A's last_used is left null"
  (list '(404 "not_found") 1 200
        (list (cons "items" (vector k1 k2 k5)) (cons "next" 'null)))
  (attempt
   (lambda ()
     (with-rig "revoke-other.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'POST (revoke-path 3) (with-key 1)))
                (jobs ((rig-jobs g)))
                (b ((rig-call g) 'GET "/v1/account" (with-key 3)))
                (c ((rig-call g) 'GET "/v1/keys" (with-key 1))))
           (list (status+code a) jobs (answer-status b) (answer-json c))))))))

(test-equal "revoke: an id in no row is a 404"
  '(404 "not_found")
  (attempt
   (lambda ()
     (with-rig "revoke-none.db"
       (lambda (g) (status+code ((rig-call g) 'POST (revoke-path 9) (with-key 1))))))))

(test-equal "revoke: a revoked key revoking is refused at its check"
  '(401 "unauthorized" 1)
  (attempt
   (lambda ()
     (with-rig "revoke-by-revoked.db"
       (lambda (g)
         (let ((a ((rig-call g) 'POST (revoke-path 2) (with-key 5))))
           (append (status+code a) (list ((rig-jobs g))))))))))

(for-each
 (lambda (bad)
   (test-equal (string-append "revoke: an id of " bad " is a 400, with no job")
     '(400 "invalid_request" 0)
     (attempt
      (lambda ()
        (with-rig "revoke-bad.db"
          (lambda (g)
            (let ((a ((rig-call g) 'POST (string-append "/v1/keys/" bad "/revoke") (with-key 1))))
              (append (status+code a) (list ((rig-jobs g)))))))))))
 '("x" "01010101010101010101010101010101" "01010101-0101-0101-0101-01010101010g"
   "01010101-0101-0101-0101-0101010101010"))

(test-equal "revoke: a bad id with no key is the 401"
  '(401 "unauthorized" 0)
  (attempt
   (lambda ()
     (with-rig "revoke-bad-nokey.db"
       (lambda (g)
         (let ((a ((rig-call g) 'POST "/v1/keys/x/revoke")))
           (append (status+code a) (list ((rig-jobs g))))))))))

(test-equal "revoke: GET is a 405 in the format, allow: POST"
  '(405 "method_not_allowed" "POST" 0)
  (attempt
   (lambda ()
     (with-rig "revoke-get.db"
       (lambda (g)
         (let ((a ((rig-call g) 'GET (revoke-path 2) (with-key 1))))
           (append (status+code a) (list (answer-header a "allow") ((rig-jobs g))))))))))

(test-equal "revoke: a write sets the asking key's last_used; the read after it does not move it"
  (list (key-json 1 "laptop" 1100 now0 #f) (key-json 1 "laptop" 1100 now0 #f))
  (attempt
   (lambda ()
     (with-rig "revoke-touch.db"
       (lambda (g)
         ((rig-call g) 'POST (revoke-path 2) (with-key 1))
         ((rig-set-now! g) (+ now0 (* 3 86400000)))
         (let* ((a ((rig-call g) 'GET "/v1/keys" (with-key 1)))
                (b ((rig-call g) 'GET "/v1/keys" (with-key 1))))
           (list (vector-ref (cdr (assoc "items" (answer-json a))) 0)
                 (vector-ref (cdr (assoc "items" (answer-json b))) 0))))))))

;;; POST /v1/keys/:id/regenerate

(define first-new-secret (key-secret ((byte-sequence) 32)))

(test-equal "regenerate: a key regenerates itself: 200, its row, the new secret once, no-store, one job, one draw"
  (list 200 "no-store"
        (append (key-json 1 "laptop" 1100 now0 #f) (list (cons "key" first-new-secret)))
        1 1)
  (attempt
   (lambda ()
     (with-rig "regenerate.db"
       (lambda (g)
         (let ((a ((rig-call g) 'POST (regenerate-path 1) (with-key 1))))
           (list (answer-status a) (answer-header a "cache-control") (answer-json a)
                 ((rig-jobs g)) ((rig-draws g)))))))))

(test-equal "regenerate: after it the old secret is a 401 and the new one works"
  (list '(401 "unauthorized") 200 "alice")
  (attempt
   (lambda ()
     (with-rig "regenerate-after.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'POST (regenerate-path 1) (with-key 1)))
                (new (cdr (assoc "key" (answer-json a))))
                (b ((rig-call g) 'GET "/v1/account" (with-key 1)))
                (c ((rig-call g) 'GET "/v1/account" (list (bearer new)))))
           (list (status+code b) (answer-status c)
                 (cdr (assoc "username" (answer-json c))))))))))

(test-equal "regenerate: another of its account's keys is a 403, one job, and that key's secret still works"
  (list '(403 "forbidden") 1 1 200 #f
        (list (cons "items" (vector k1 k2 k5)) (cons "next" 'null)))
  (attempt
   (lambda ()
     (with-rig "regenerate-other.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'POST (regenerate-path 2) (with-key 1)))
                (jobs ((rig-jobs g)))
                (b ((rig-call g) 'GET "/v1/account" (with-key 2)))
                (c ((rig-call g) 'GET "/v1/keys" (with-key 1))))
           (list (status+code a) jobs ((rig-draws g)) (answer-status b)
                 (contains? (answer-body a) "techo_")
                 (answer-json c))))))))

(test-equal "regenerate: a revoked key of its own account is a 403"
  '(403 "forbidden")
  (attempt
   (lambda ()
     (with-rig "regenerate-revoked.db"
       (lambda (g) (status+code ((rig-call g) 'POST (regenerate-path 5) (with-key 1))))))))

(test-equal "regenerate: B's key is a 404 for A, and B's secret still works"
  (list '(404 "not_found") 200)
  (attempt
   (lambda ()
     (with-rig "regenerate-b.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'POST (regenerate-path 3) (with-key 1)))
                (b ((rig-call g) 'GET "/v1/account" (with-key 3))))
           (list (status+code a) (answer-status b))))))))

(test-equal "regenerate: an id in no row is a 404"
  '(404 "not_found")
  (attempt
   (lambda ()
     (with-rig "regenerate-none.db"
       (lambda (g) (status+code ((rig-call g) 'POST (regenerate-path 9) (with-key 1))))))))

(test-equal "regenerate: a bad id is a 400 with no job and no draw; no key, a 401 with neither"
  '((400 "invalid_request" 0 0) (401 "unauthorized" 0 0))
  (attempt
   (lambda ()
     (list (with-rig "regenerate-bad.db"
             (lambda (g)
               (let ((a ((rig-call g) 'POST "/v1/keys/nope/regenerate" (with-key 1))))
                 (append (status+code a) (list ((rig-jobs g)) ((rig-draws g)))))))
           (with-rig "regenerate-bad-nokey.db"
             (lambda (g)
               (let ((a ((rig-call g) 'POST "/v1/keys/nope/regenerate")))
                 (append (status+code a) (list ((rig-jobs g)) ((rig-draws g)))))))))))

;;; Secrets: the new one is in its answer alone

;; file-text-has? : String Bytevector -> Boolean
;; Whether the file at PATH holds NEEDLE's bytes; #f for no file.
(define (file-has? path needle)
  (and (file-exists? path)
       (let* ((bv (call-with-port (open-file-input-port path) get-bytevector-all))
              (n (if (eof-object? bv) 0 (bytevector-length bv)))
              (m (bytevector-length needle)))
         (let loop ((i 0))
           (cond ((> (+ i m) n) #f)
                 ((let inner ((j 0))
                    (or (= j m)
                        (and (= (bytevector-u8-ref bv (+ i j)) (bytevector-u8-ref needle j))
                             (inner (+ j 1)))))
                  #t)
                 (else (loop (+ i 1))))))))

(test-equal "secrets: after a regenerate, no log line, later answer, job, file or -wal holds the new secret or the presented one"
  '(#t (#f #f #f #f) (#f #f) (#f #f) (#f #f #f #f))
  (attempt
   (lambda ()
     (with-rig "secrets.db"
       (lambda (g)
         (let* ((a ((rig-call g) 'POST (regenerate-path 1) (with-key 1)))
                (new (cdr (assoc "key" (answer-json a))))
                (job ((rig-job g)))
                (b ((rig-call g) 'GET "/v1/keys" (list (bearer new))))
                (lines (apply string-append (map (lambda (l) (string-append l "\n"))
                                                 ((rig-lines g)))))
                (p (store-path (rig-store g)))
                (is (lambda (s) (lambda (x) (and (string? x) (string=? x s))))))
           (list (string=? new first-new-secret)
                 (list (contains? lines new) (contains? lines (secret-of 1))
                       (contains? lines (hex (key-hash new)))
                       (contains? lines (hex (key-hash (secret-of 1)))))
                 (list (contains? (answer-body b) new) (contains? (answer-body b) (secret-of 1)))
                 (list (reaches? job (is new)) (reaches? job (is (secret-of 1))))
                 (list (file-has? p (string->utf8 new))
                       (file-has? (string-append p "-wal") (string->utf8 new))
                       (file-has? p (string->utf8 (secret-of 1)))
                       (file-has? (string-append p "-wal") (string->utf8 (secret-of 1)))))))))))

;;; The request log at the routes

(test-equal "log: a page of keys: no query on the line, the status, the account, db_ms"
  (list (string-append "request method=GET path=/v1/keys status=200 ending=written ms=3 db_ms=1 account="
                       (id->string acct-a) " address=-"))
  (attempt
   (lambda ()
     (with-rig "log-keys.db"
       (lambda (g)
         ((rig-call g) 'GET (string-append "/v1/keys?limit=2&after=" (kid-text 1)) (with-key 1))
         ((rig-lines g)))))))

(test-equal "log: a 401 with no key has no account and no db_ms"
  '("request method=POST path=/v1/keys/x/regenerate status=401 ending=written ms=1 db_ms=- account=- address=-")
  (attempt
   (lambda ()
     (with-rig "log-401.db"
       (lambda (g)
         ((rig-call g) 'POST "/v1/keys/x/regenerate")
         ((rig-lines g)))))))

(test-equal "log: a 403 has the asking account"
  (list (string-append "request method=POST path=" (regenerate-path 2)
                       " status=403 ending=written ms=3 db_ms=1 account=" (id->string acct-a)
                       " address=-"))
  (attempt
   (lambda ()
     (with-rig "log-403.db"
       (lambda (g)
         ((rig-call g) 'POST (regenerate-path 2) (with-key 1))
         ((rig-lines g)))))))

(test-equal "log: a 404 for B's key has A's account, not B's"
  (list (string-append "request method=POST path=" (revoke-path 3)
                       " status=404 ending=written ms=3 db_ms=1 account=" (id->string acct-a)
                       " address=-"))
  (attempt
   (lambda ()
     (with-rig "log-404.db"
       (lambda (g)
         ((rig-call g) 'POST (revoke-path 3) (with-key 1))
         ((rig-lines g)))))))

(test-end "routes")

(exit (suite-exit-status runner))
