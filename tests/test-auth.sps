#!r6rs
;;; The auth suite: (techo auth), the key check that every key route runs
;;; inside its own job (D3, D4, D5, D6, D10), against real SQLite through the
;;; test doorway and circuit's test host, raw HTTP bytes in.
;;;
;;;   key-hash        D3's fixed key and its hash
;;;   key-state       a row as D5's state
;;;   touch-due?      D6's "null or more than a day old"
;;;   the header      missing, doubled, malformed: a 401 and NO job (P6)
;;;   the check       one job a request (P5); unknown and revoked keys 401
;;;   refusals        a work's &refusal answered, rolled back, never a 500
;;;   last_used       set by a write when due, never by a read (D6)
;;;   the note        the account and db_ms on the request's line (D10)
;;;   the job         reaches no request and no secret
;;;
;;; Stand-in handlers call db-read-as and db-write-as as the routes do.
;;; Clocks are fixed; accounts and keys go in through the store's own
;;; procedures in a write job. Everything that can raise is computed under
;;; `attempt`, and a raise comes out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (circuit)
        (circuit json)
        (circuit test)
        (circuit http-server)
        (circuit middleware waits)
        (http-support)
        (techo errors)
        (techo keys)
        (except (techo store) key-hash)
        (techo log)
        (techo app)
        (techo auth))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-kind : (-> Any) -> (U 'no-raise 'assertion 'other)
(define (raised-kind thunk)
  (guard (e ((assertion-violation? e) 'assertion)
            (#t 'other))
    (thunk)
    'no-raise))

(define (hex bv)
  (apply string-append
         (map (lambda (b)
                (string-append (if (< b 16) "0" "") (string-downcase (number->string b 16))))
              (bytevector->u8-list bv))))

(test-begin "auth")

;;; key-hash (D3)

(define fixed-key "techo_000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

(test-equal "key-hash: D3's fixed key hashes to its fixed BLAKE2b-256"
  "1dbae9de3ada594eec713fb5f2fe6fd29969b4ce2bf4b07a755e31ab0e41efa9"
  (attempt (lambda () (hex (key-hash fixed-key)))))

(test-equal "key-hash: the fixed key is the bytes 0..31 as key-secret writes them"
  fixed-key
  (attempt (lambda ()
             (key-secret (u8-list->bytevector (let loop ((i 0))
                                                (if (= i 32) '() (cons i (loop (+ i 1))))))))))

(test-equal "key-hash: 32 bytes, and one capital letter is another key"
  '(32 #f)
  (attempt (lambda ()
             (list (bytevector-length (key-hash fixed-key))
                   (bytevector=? (key-hash fixed-key)
                                 (key-hash (string-append (substring fixed-key 0 69) "F")))))))

(test-equal "key-hash: what is no string raises"
  'other-or-assertion
  (let ((k (raised-kind (lambda () (key-hash (string->utf8 fixed-key))))))
    (if (eq? k 'no-raise) k 'other-or-assertion)))

;;; touch-due? (D6)

(define day 86400000)

(test-equal "touch-due?: null, older than a day: yes; a day exactly, newer, in the future: no"
  '(#t #t #f #f #f)
  (attempt (lambda ()
             (list (touch-due? #f 5000000000)
                   (touch-due? (- 5000000000 day 1) 5000000000)
                   (touch-due? (- 5000000000 day) 5000000000)
                   (touch-due? (- 5000000000 1000) 5000000000)
                   (touch-due? (+ 5000000000 1000) 5000000000)))))

;;; The fixture: two accounts and their keys

(define dir (fresh-dir "test-auth"))

(define acct-a (make-bytevector 16 #xA1))
(define acct-b (make-bytevector 16 #xB2))
(define acct-c (make-bytevector 16 #xC3))

;; secret-of : Natural -> String     a distinct, well-shaped key
(define (secret-of n) (key-secret (make-bytevector 32 n)))
(define (kid n) (make-bytevector 16 n))

(define now0 1795515226123)

;; Key n: id (kid n), secret (secret-of n). 1 and 2 are A's, 2 revoked; 3
;; is B's; 4 is A's, last used two days ago; 5 is A's, used an hour ago; 6
;; is A's, used a day ago exactly. 9 is in no row.
(define (seed! tx)
  (insert-account! tx acct-a "alice" "alice@example.com" "hash-a" 1000)
  (insert-account! tx acct-b "bob" "bob@example.com" "hash-b" 2000)
  (insert-key! tx (kid 1) acct-a "laptop" (key-hash (secret-of 1)) 1100)
  (insert-key! tx (kid 2) acct-a "old phone" (key-hash (secret-of 2)) 1200)
  (revoke-key! tx acct-a (kid 2) 1300)
  (insert-key! tx (kid 3) acct-b "bob's" (key-hash (secret-of 3)) 2100)
  (insert-key! tx (kid 4) acct-a "two days" (key-hash (secret-of 4)) 1400)
  (touch-key! tx (kid 4) (- now0 (* 2 day)))
  (insert-key! tx (kid 5) acct-a "an hour" (key-hash (secret-of 5)) 1500)
  (touch-key! tx (kid 5) (- now0 3600000))
  (insert-key! tx (kid 6) acct-a "a day" (key-hash (secret-of 6)) 1600)
  (touch-key! tx (kid 6) (- now0 day)))

(define store
  (guard (e (#t (list 'raised (describe e))))
    (let ((s (open-test-store dir "auth.db")))
      (run-write s seed!)
      s)))

(test-assert "fixture: the store opened and took the seed" (not (pair? store)))

;; last-used-of : Natural -> (U Natural #f 'missing)
(define (last-used-of n)
  (run-read store (lambda (tx)
                    (let ((k (key-by-hash tx (key-hash (secret-of n)))))
                      (if k (key-last-used k) 'missing)))))

;;; key-state (D5)

(test-equal "key-state: no row is none, a live row active, a revoked row revoked"
  '(none active revoked)
  (attempt (lambda ()
             (run-read store
                       (lambda (tx)
                         (map (lambda (n) (key-state (key-by-hash tx (key-hash (secret-of n)))))
                              '(9 1 2)))))))

;;; Stand-in handlers

;; read-app : Runner Clock -> (values Handler (-> Natural))
;; A handler whose plan's work answers the account's username and the
;; asking key's name, as JSON; and a count of the plans it made.
(define (read-app run clock)
  (let-values (((prepare plans)
                (counting (lambda ()
                            (make-plan (lambda (tx account key)
                                         (list (account-username account) (key-name key)))
                                       (lambda (v)
                                         (make-json-res 200 (list (cons "username" (car v))
                                                                  (cons "key" (cadr v))))))))))
    (values (lambda (req) (db-read-as run clock req prepare)) plans)))

;; write-app : Runner Clock (-> Natural) -> Handler
;; The same through db-write-as, the wall clock read at each request.
(define (write-app run clock wall)
  (lambda (req)
    (db-write-as run clock (wall) req
                 (lambda ()
                   (make-plan (lambda (tx account key)
                                (list (account-username account) (key-name key)))
                              (lambda (v)
                                (make-json-res 200 (list (cons "username" (car v))
                                                         (cons "key" (cadr v))))))))))

;; status+code : Answer -> (List Natural Any)
(define (status+code a)
  (list (answer-status a)
        (let ((j (answer-json a)))
          (if (and (list? j) (assoc "code" j)) (cdr (assoc "code" j)) j))))

;; try-read : (Listof Header) -> (List Status Code Jobs Plans WWW-Authenticate)
;; GET /x through a fresh read-app with a counting reader.
(define (try-read headers)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-reader store))))
       (let-values (((app plans) (read-app run (step-clock 0 1))))
         (let ((a (exchange app 'GET "/x" headers)))
           (append (status+code a) (list (jobs) (plans) (answer-header a "www-authenticate")))))))))

;;; The header (P6): a 401 and no job

(define good (secret-of 1))
(define (upcase-hex s) (string-append "techo_" (string-upcase (substring s 6 70))))

(for-each
 (lambda (case)
   (test-equal (string-append "header: " (car case) ": 401 unauthorized, no job, no plan")
     '(401 "unauthorized" 0 0 "Bearer")
     (try-read (cdr case))))
 (list (list "missing")
       (list "doubled, both well-shaped" (bearer good) (bearer good))
       (list "doubled, one well-shaped" (bearer good) (cons "Authorization" "Basic x"))
       (list "Basic" (cons "Authorization" (string-append "Basic " good)))
       (list "a scheme as long as Bearer" (cons "Authorization" (string-append "Bearex " good)))
       (list "two spaces" (cons "Authorization" (string-append "Bearer  " good)))
       (list "no space" (cons "Authorization" (string-append "Bearer" good)))
       (list "capital hex" (bearer (upcase-hex (secret-of #xAB))))
       (list "one character more" (bearer (string-append good "0")))
       (list "one character less" (bearer (substring good 0 69)))
       (list "no prefix" (bearer (substring good 6 70)))
       (list "the scheme alone" (cons "Authorization" "Bearer"))
       (list "empty" (cons "Authorization" ""))))

(test-equal "header: the scheme's case does not matter (bearer, BEARER)"
  '((200 empty-ok 1 1) (200 empty-ok 1 1))
  (map (lambda (scheme)
         (let ((r (try-read (list (cons "Authorization" (string-append scheme " " good))))))
           (if (and (pair? r) (= (car r) 200))
               (list 200 'empty-ok (caddr r) (cadddr r))
               r)))
       '("bearer" "BEARER")))

;;; The check (P5): one job; unknown and revoked keys are 401 in it

(test-equal "check: a live key: 200, its account and its own name, one job"
  '(200 (("username" . "alice") ("key" . "laptop")) 1)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-reader store))))
       (let-values (((app plans) (read-app run (step-clock 0 1))))
         (let ((a (exchange app 'GET "/x" (list (bearer good)))))
           (list (answer-status a) (answer-json a) (jobs))))))))

(test-equal "check: another account's key is that account's"
  '(200 (("username" . "bob") ("key" . "bob's")))
  (attempt
   (lambda ()
     (let-values (((app plans) (read-app (store-reader store) (step-clock 0 1))))
       (let ((a (exchange app 'GET "/x" (list (bearer (secret-of 3))))))
         (list (answer-status a) (answer-json a)))))))

(test-equal "check: a well-shaped key in no row: 401, one job, the plan made but its work never run"
  '(401 "unauthorized" 1 1 "Bearer")
  (try-read (list (bearer (secret-of 9)))))

(test-equal "check: a revoked key: 401, one job"
  '(401 "unauthorized" 1 1 "Bearer")
  (try-read (list (bearer (secret-of 2)))))

(test-equal "check: a write with a revoked key: 401, one job, and its last_used still null"
  '(401 "unauthorized" 1 #f)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-writer store))))
       (let ((a (exchange (write-app run (step-clock 0 1) (lambda () now0)) 'POST "/x"
                          (list (bearer (secret-of 2))))))
         (append (status+code a) (list (jobs))
                 (list (last-used-of 2))))))))

;;; A plan that is an answer: the handler's 400, after the header's 401

(define (four-hundred-app run)
  (let-values (((prepare plans) (counting (lambda () (problem-res 'invalid_request)))))
    (values (lambda (req) (db-read-as run (step-clock 0 1) req prepare)) plans)))

(test-equal "plan: a response in place of a plan is the answer, with no job"
  '(400 "invalid_request" 0 1)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-reader store))))
       (let-values (((app plans) (four-hundred-app run)))
         (let ((a (exchange app 'GET "/x" (list (bearer good)))))
           (append (status+code a) (list (jobs) (plans)))))))))

(test-equal "plan: a bad header is answered first: 401, the plan never asked for"
  '(401 "unauthorized" 0 0)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-reader store))))
       (let-values (((app plans) (four-hundred-app run)))
         (let ((a (exchange app 'GET "/x" '())))
           (append (status+code a) (list (jobs) (plans)))))))))

(test-equal "plan: what is neither a plan nor a response raises, with no job"
  '(raised 0)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-reader store))))
       (list (guard (e ((assertion-violation? e) 'raised))
               (db-read-as run (step-clock 0 1) (make-test-req 'GET "/x" (list (bearer good)))
                           (lambda () 'neither))
               'no-raise)
             (jobs))))))

;;; Refusals from the work

;; refusing-app : Runner Symbol -> Handler
;; A write whose work makes an account, then raises a &refusal of CODE for
;; the asking account.
(define (refusing-app run code)
  (wrap-app
   (lambda (req)
     (db-write-as run (step-clock 0 1) now0 req
                  (lambda ()
                    (make-plan (lambda (tx account key)
                                 (insert-account! tx acct-c "carol" "carol@example.com" "h" 1)
                                 (raise (make-refusal code (account-id account))))
                               (lambda (v) (make-res 200 '() "never"))))))
   (lambda (line) #f)))

(test-equal "refusal: a work's 403 is answered in the format, one job, rolled back, nothing logged"
  '(403 "forbidden" 1 #f "")
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-writer store))))
       (let-values (((a out) (capture-output
                              (lambda ()
                                (exchange (refusing-app run 'forbidden) 'POST "/x"
                                          (list (bearer good)))))))
         (append (status+code a)
                 (list (jobs)
                       (run-read store (lambda (tx) (and (account-by-id tx acct-c) #t)))
                       out)))))))

(test-equal "refusal: a work's 404 likewise, and the asking key's last_used is left as it was"
  '(404 "not_found" 1 #f two-days-ago)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-writer store))))
       (let ((a (exchange (refusing-app run 'not_found) 'POST "/x"
                          (list (bearer (secret-of 4))))))
         (append (status+code a)
                 (list (jobs)
                       (run-read store (lambda (tx) (and (account-by-id tx acct-c) #t)))
                       (if (eqv? (last-used-of 4) (- now0 (* 2 day))) 'two-days-ago
                           (last-used-of 4)))))))))

(test-equal "refusal: a work's raise that is no refusal is a 500, logged whole, with no secret in the line"
  '(500 #t #t #f #f #f)
  (attempt
   (lambda ()
     (let-values (((a out)
                   (capture-output
                    (lambda ()
                      (exchange (wrap-app
                                 (lambda (req)
                                   (db-read-as (store-reader store) (step-clock 0 1) req
                                               (lambda ()
                                                 (make-plan (lambda (tx account key)
                                                              (error 'work "the work fails with all it has"
                                                                     tx account key
                                                                     (account-username account)
                                                                     (key-name key)))
                                                            (lambda (v) (make-res 200 '() #f))))))
                                 (lambda (line) #f))
                                'GET "/x" (list (bearer good)))))))
       (list (answer-status a)
             (contains? out "handler-failed")
             (contains? out "laptop")
             (contains? out good)
             (contains? out (substring good 6 70))
             (contains? out (hex (key-hash good))))))))

;;; A deadline that passes while the job waits goes on to wrap-timeout

(test-equal "deadline: a runner that outlives the request's deadline is a 504, not a 500 or a refusal"
  '((504) 0)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (lambda (job) (sleep-ms 500) ((store-reader store) job)))))
       (let ((as (exchange-bytes
                  (wrap-app (let-values (((app plans) (read-app run (step-clock 0 1)))) app)
                            (lambda (line) #f) 50)
                  (request-bytes 'GET "/x" (list (bearer good)))
                  1000)))
         (list (map answer-status as)
               (length (filter (lambda (a) (not (= (answer-status a) 504))) as))))))))

;;; last_used (D6)

(define (write-with n wall)
  (exchange (write-app (store-writer store) (step-clock 0 1) (lambda () wall)) 'POST "/x"
            (list (bearer (secret-of n)))))

(test-equal "last_used: a write sets it when it is null"
  (list 200 now0)
  (attempt (lambda ()
             (let ((before (last-used-of 1)))
               (if before
                   (list 'not-null-before before)
                   (let ((a (write-with 1 now0)))
                     (list (answer-status a) (last-used-of 1))))))))

(test-equal "last_used: a write sets it when it is more than a day old"
  (list 200 now0)
  (attempt (lambda ()
             (let ((a (write-with 4 now0)))
               (list (answer-status a) (last-used-of 4))))))

(test-equal "last_used: a write leaves it when it is an hour old, and when a day old exactly"
  (list 200 (- now0 3600000) 200 (- now0 day))
  (attempt (lambda ()
             (let* ((a (write-with 5 now0)) (b (write-with 6 now0)))
               (list (answer-status a) (last-used-of 5) (answer-status b) (last-used-of 6))))))

(test-equal "last_used: a read never sets it, null or old"
  '(200 #f 200 old)
  (attempt
   (lambda ()
     (let ((s (open-test-store dir "reads.db")))
       (dynamic-wind
         (lambda () #f)
         (lambda ()
           (run-write s seed!)
           (let-values (((app plans) (read-app (store-reader s) (step-clock 0 1))))
             (let* ((a (exchange app 'GET "/x" (list (bearer (secret-of 1)))))
                    (b (exchange app 'GET "/x" (list (bearer (secret-of 4)))))
                    (lu (lambda (n) (run-read s (lambda (tx) (key-last-used
                                                              (key-by-hash tx (key-hash (secret-of n)))))))))
               (list (answer-status a) (lu 1) (answer-status b)
                     (if (eqv? (lu 4) (- now0 (* 2 day))) 'old (lu 4))))))
         (lambda () (close-test-store! s)))))))

;;; The note (D10)

;; quietly : Procedure Any ... -> Any     PROC's answer, its output dropped
(define (quietly proc . args)
  (let-values (((v out) (capture-output (lambda () (apply proc args))))) v))

;; line-of : Handler Clock (Listof Header) -> (U String Any)
;; The one request line HANDLER's request writes inside wrap-request-log,
;; the log and the handler sharing CLOCK.
(define (line-of make-handler headers)
  (attempt
   (lambda ()
     (let* ((lines '())
            (clock (step-clock 0 10))
            (h (wrap (make-handler clock) (wrap-request-log (lambda (l) (set! lines (cons l lines))) clock))))
       (exchange h 'GET "/x" headers)
       (if (= (length lines) 1) (car lines) (list 'lines lines))))))

(define acct-a-text (id->string acct-a))

(test-equal "note: a good read has its account and db_ms, the job's time alone"
  (string-append "request method=GET path=/x status=200 ending=written ms=30 db_ms=10 account="
                 acct-a-text " address=-")
  (line-of (lambda (clock) (let-values (((app plans) (read-app (store-reader store) clock))) app))
           (list (bearer good))))

(test-equal "note: a key refused in the job has db_ms and no account"
  "request method=GET path=/x status=401 ending=written ms=30 db_ms=10 account=- address=-"
  (line-of (lambda (clock) (let-values (((app plans) (read-app (store-reader store) clock))) app))
           (list (bearer (secret-of 9)))))

(test-equal "note: a header refused before any job has neither"
  "request method=GET path=/x status=401 ending=written ms=10 db_ms=- account=- address=-"
  (line-of (lambda (clock) (let-values (((app plans) (read-app (store-reader store) clock))) app))
           '()))

(test-equal "note: a work's refusal has the account it carries"
  (string-append "request method=GET path=/x status=403 ending=written ms=30 db_ms=10 account="
                 acct-a-text " address=-")
  (line-of (lambda (clock)
             (lambda (req)
               (db-read-as (store-reader store) clock req
                           (lambda ()
                             (make-plan (lambda (tx account key)
                                          (raise (make-refusal 'forbidden (account-id account))))
                                        (lambda (v) (make-res 200 '() #f)))))))
           (list (bearer good))))

(test-equal "note: a job's raise that is no refusal still has db_ms, and no account"
  "request method=GET path=/x status=500 ending=written ms=30 db_ms=10 account=- address=-"
  (quietly line-of (lambda (clock)
             (wrap-app
              (lambda (req)
                (db-read-as (store-reader store) clock req
                            (lambda ()
                              (make-plan (lambda (tx account key) (error 'work "fails"))
                                         (lambda (v) (make-res 200 '() #f))))))
              (lambda (l) #f)))
           (list (bearer good))))

;;; The job: plain data only

;; captured-job : (Req -> Res) builder -> (U Procedure #f)
;; The job the handler hands its runner, kept by a runner that runs it.
(define (captured-job secret make-handler)
  (let* ((job #f)
         (run (lambda (j) (set! job j) ((store-writer store) j))))
    (exchange (make-handler run) 'POST "/x" (list (bearer secret)))
    job))

(define (secret-string? s) (lambda (x) (and (string? x) (string=? x s))))

(test-equal "job: the detector sees a secret a job closes over, and a request"
  '(#t #t)
  (attempt
   (lambda ()
     (let* ((req-seen #f)
            (j1 (let ((s (string-copy good))) (lambda (tx) (string-length s))))
            (j2 (captured-job good
                              (lambda (run)
                                (lambda (req)
                                  (run (lambda (tx) (req-method req)))
                                  (make-res 200 '() #f))))))
       (list (reaches? j1 (secret-string? good)) (reaches? j2 req?))))))

(test-equal "job: a write's job reaches neither the request nor the presented secret"
  '(#t #f #f)
  (attempt
   (lambda ()
     (let ((job (captured-job (secret-of 1)
                              (lambda (run) (write-app run (step-clock 0 1) (lambda () now0))))))
       (list (procedure? job)
             (reaches? job req?)
             (reaches? job (secret-string? (secret-of 1))))))))

(test-equal "job: a read's job reaches neither"
  '(#t #f #f)
  (attempt
   (lambda ()
     (let* ((job #f)
            (run (lambda (j) (set! job j) ((store-reader store) j))))
       (let-values (((app plans) (read-app run (step-clock 0 1))))
         (exchange app 'GET "/x" (list (bearer (secret-of 1))))
         (list (procedure? job) (reaches? job req?)
               (reaches? job (secret-string? (secret-of 1)))))))))

(when (and store (not (pair? store))) (close-test-store! store))

(test-end "auth")

(exit (suite-exit-status runner))
