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

(test-equal "note: a work's raise after the key check, a 500, has db_ms and the account (L8)"
  (string-append "request method=GET path=/x status=500 ending=written ms=30 db_ms=10 account="
                 acct-a-text " address=-")
  (quietly line-of (lambda (clock)
             (wrap-app
              (lambda (req)
                (db-read-as (store-reader store) clock req
                            (lambda ()
                              (make-plan (lambda (tx account key) (error 'work "fails"))
                                         (lambda (v) (make-res 200 '() #f))))))
              (lambda (l) #f)))
           (list (bearer good))))

;;; A raise while the answer is awaited (L8): the account once the key passed

;; line-of-raise : Runner (Listof Header) Boolean -> (U String Any)
;; GET /x with HEADERS through read-app with RUN, inside wrap-app with a
;; 50 ms deadline and wrap-request-log, the clock then moved 1000 ms (the
;; client hung up first with CLOSE?); the one line. The test doorway runs a
;; job while its caller waits, so a runner that sleeps after it has the
;; job done before the deadline, and one that sleeps first has not.
(define (line-of-raise run headers close?)
  (attempt
   (lambda ()
     (let* ((lines '())
            (clock (step-clock 0 10))
            (app (let-values (((app plans) (read-app run clock))) app))
            (h (wrap (wrap-app app (lambda (l) #f) 50)
                     (wrap-request-log (lambda (l) (set! lines (cons l lines))) clock))))
       (if close?
           (exchange-closed h (request-bytes 'GET "/x" headers) 1000)
           (exchange-bytes h (request-bytes 'GET "/x" headers) 1000))
       (if (= (length lines) 1) (car lines) (list 'lines lines))))))

;; job-then-sleep : Runner     the job done, then a wait past the deadline
(define (job-then-sleep job)
  (let ((r ((store-reader store) job)))
    (sleep-ms 500)
    r))

(test-equal "L8: a deadline after the key check, the job done, logs the 504 with the account"
  (string-append "request method=GET path=/x status=504 ending=written ms=30 db_ms=10 account="
                 acct-a-text " address=-")
  (line-of-raise job-then-sleep (list (bearer good)) #f))

(test-equal "L8: a deadline while the job is still queued logs - for the account"
  "request method=GET path=/x status=504 ending=written ms=30 db_ms=10 account=- address=-"
  (line-of-raise (lambda (job) (sleep-ms 500) ((store-reader store) job)) (list (bearer good)) #f))

(test-equal "L8: a client that hangs up after the key check logs the account"
  (string-append "request method=GET path=/x status=- ending=client-closed ms=30 db_ms=10 account="
                 acct-a-text " address=-")
  (line-of-raise job-then-sleep (list (bearer good)) #t))

(test-equal "L8: a key the job refused, then a deadline, logs the 504 with -"
  "request method=GET path=/x status=504 ending=written ms=30 db_ms=10 account=- address=-"
  (line-of-raise (lambda (job)
                   ;; the job's refusal held back past the deadline
                   (let ((r (guard (e (#t (list 'raised e))) ((store-reader store) job))))
                     (sleep-ms 500)
                     (if (and (pair? r) (eq? (car r) 'raised)) (raise (cadr r)) r)))
                 (list (bearer (secret-of 9))) #f))

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

;;; Login's two jobs (L7): login-read and login-write

;; with-login-store : (Store -> A) -> A
;; A fresh file with the seed, closed after.
(define (with-login-store name body)
  (let ((s (open-test-store dir name)))
    (dynamic-wind
      (lambda () #f)
      (lambda () (run-write s seed!) (body s))
      (lambda () (close-test-store! s)))))

(define login-req (make-test-req 'POST "/v1/login"))

;; new-key : Natural -> Key-fields     key N's id, a name, its hash, now0
(define (new-key n) (list (kid n) "from login" (key-hash (secret-of n)) now0))

;; active-keys : Store Bytevector -> Natural
(define (active-keys s account) (run-read s (lambda (tx) (count-active-keys tx account))))

;; password-of : Store Bytevector -> String
(define (password-of s account)
  (run-read s (lambda (tx) (account-password-hash (account-by-id tx account)))))

;; key-shape : Any -> Any     a Key's fields but its hash, or the value itself
(define (key-shape k)
  (if (key? k)
      (list (key-id k) (key-account k) (key-name k) (key-created k) (key-last-used k)
            (key-revoked k))
      k))

(test-equal "login-read: a known email is its account's id and password hash; one read job"
  (list (cons acct-a "hash-a") 1)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-reader store))))
       (let ((r (in-host (lambda () (login-read run (step-clock 0 1) login-req "alice@example.com")))))
         (list r (jobs)))))))

(test-equal "login-read: an unknown email is #f"
  #f
  (attempt (lambda ()
             (in-host (lambda () (login-read (store-reader store) (step-clock 0 1) login-req
                                             "carol@example.com"))))))

(test-equal "login-read: the job reaches no request; it closes over the email"
  '(#t #f #t)
  (attempt
   (lambda ()
     (let* ((job #f)
            (run (lambda (j) (set! job j) ((store-reader store) j))))
       (in-host (lambda () (login-read run (step-clock 0 1) login-req "alice@example.com")))
       (list (procedure? job) (reaches? job req?)
             (reaches? job (lambda (x) (and (string? x) (string=? x "alice@example.com")))))))))

(test-equal "login-write: made: the key's row, active, and one more active key; the hash kept"
  (list (list (kid 40) acct-a "from login" now0 #f #f) 4 5 "hash-a" #t)
  (attempt
   (lambda ()
     (with-login-store "login-write.db"
       (lambda (s)
         (let* ((before (active-keys s acct-a))
                (k (in-host (lambda () (login-write (store-writer s) (step-clock 0 1) login-req
                                                    acct-a "hash-a" #f (new-key 40))))))
           (list (key-shape k) before (active-keys s acct-a) (password-of s acct-a)
                 ;; found by the hash it was given
                 (bytevector=? (run-read s (lambda (tx) (key-id (key-by-hash tx (key-hash (secret-of 40))))))
                               (kid 40)))))))))

(test-equal "login-write: a new hash is stored with the key, in the same write"
  (list (list (kid 41) acct-a "from login" now0 #f #f) "hash-a-new")
  (attempt
   (lambda ()
     (with-login-store "login-rehash.db"
       (lambda (s)
         (let ((k (in-host (lambda () (login-write (store-writer s) (step-clock 0 1) login-req
                                                   acct-a "hash-a" "hash-a-new" (new-key 41))))))
           (list (key-shape k) (password-of s acct-a))))))))

(test-equal "Q4: the hash changed after the verify: stale, no key, the hash left as it is"
  '(stale 4 4 "reset-by-admin" #f)
  (attempt
   (lambda ()
     (with-login-store "login-stale.db"
       (lambda (s)
         (run-write s (lambda (tx) (set-password-hash! tx acct-a "hash-a" "reset-by-admin")))
         (let* ((before (active-keys s acct-a))
                (r (in-host (lambda () (login-write (store-writer s) (step-clock 0 1) login-req
                                                    acct-a "hash-a" "hash-a-new" (new-key 42))))))
           (list r before (active-keys s acct-a) (password-of s acct-a)
                 (run-read s (lambda (tx) (and (key-of-account tx acct-a (kid 42)) #t))))))))))

(test-equal "login-write: an account that is gone is stale"
  'stale
  (attempt
   (lambda ()
     (with-login-store "login-gone.db"
       (lambda (s)
         (in-host (lambda () (login-write (store-writer s) (step-clock 0 1) login-req
                                          acct-c "hash-c" #f (new-key 43)))))))))

;; keys-up-to! : Store Natural -> Void     A's active keys made N in all
(define (keys-up-to! s n)
  (let ((have (active-keys s acct-a)))
    (run-write s (lambda (tx)
                   (let loop ((i 0))
                     (when (< i (- n have))
                       (insert-key! tx (kid (+ 100 i)) acct-a "filler" (key-hash (secret-of (+ 100 i)))
                                    (+ 3000 i))
                       (loop (+ i 1))))))))

(test-equal "Q10: 99 active keys: made, and 100"
  '(99 #t 100)
  (attempt
   (lambda ()
     (with-login-store "login-99.db"
       (lambda (s)
         (keys-up-to! s 99)
         (let* ((before (active-keys s acct-a))
                (k (in-host (lambda () (login-write (store-writer s) (step-clock 0 1) login-req
                                                    acct-a "hash-a" #f (new-key 44))))))
           (list before (key? k) (active-keys s acct-a))))))))

(test-equal "Q10: 100 active keys: full, still 100, the new hash not stored"
  '(100 full 100 "hash-a")
  (attempt
   (lambda ()
     (with-login-store "login-100.db"
       (lambda (s)
         (keys-up-to! s 100)
         (let* ((before (active-keys s acct-a))
                (r (in-host (lambda () (login-write (store-writer s) (step-clock 0 1) login-req
                                                    acct-a "hash-a" "hash-a-new" (new-key 45))))))
           (list before r (active-keys s acct-a) (password-of s acct-a))))))))

(test-equal "Q10: a revoked key does not count: 100 keys, one revoked, is made"
  '(99 #t)
  (attempt
   (lambda ()
     (with-login-store "login-revoked.db"
       (lambda (s)
         (keys-up-to! s 100)
         (run-write s (lambda (tx) (revoke-key! tx acct-a (kid 100) 9000)))
         (let* ((before (active-keys s acct-a))
                (k (in-host (lambda () (login-write (store-writer s) (step-clock 0 1) login-req
                                                    acct-a "hash-a" #f (new-key 46))))))
           (list before (key? k))))))))

(test-equal "login-write: the job reaches no request and no secret, only the key's hash"
  '(#t #f #f #t)
  (attempt
   (lambda ()
     (with-login-store "login-job.db"
       (lambda (s)
         (let* ((job #f)
                (run (lambda (j) (set! job j) ((store-writer s) j))))
           (in-host (lambda () (login-write run (step-clock 0 1) login-req acct-a "hash-a" #f (new-key 47))))
           (list (procedure? job) (reaches? job req?)
                 (reaches? job (secret-string? (secret-of 47)))
                 (reaches? job (lambda (x) (and (bytevector? x)
                                                (bytevector=? x (key-hash (secret-of 47)))))))))))))

(test-equal "login-write: Key-fields of the wrong shape are refused before any job"
  '(assertion assertion assertion 0)
  (attempt
   (lambda ()
     (let-values (((run jobs) (counting (store-writer store))))
       (let ((try (lambda (f)
                    (raised-kind (lambda ()
                                   (in-host (lambda () (login-write run (step-clock 0 1) login-req
                                                                    acct-a "hash-a" #f f))))))))
         (list (try (list (make-bytevector 15 1) "n" (key-hash (secret-of 1)) now0))
               (try (list (kid 48) "n" (make-bytevector 31 1) now0))
               (try (list (kid 48) "n" (key-hash (secret-of 1))))
               (jobs)))))))

;;; Login's note: the account the handler wrote stays; db_ms is the sum

;; login-line : Store (Req -> Void) -> String
;; One POST /v1/login inside wrap-app and wrap-request-log, a clock of 0,
;; 10, 20 ...: the handler is DO, then a 200.
(define (login-line do)
  (attempt
   (lambda ()
     (let* ((lines '())
            (clock (step-clock 0 10))
            (h (wrap (wrap-app (lambda (req) (do req clock) (make-res 200 '() #f)) (lambda (l) #f) 50)
                     (wrap-request-log (lambda (l) (set! lines (cons l lines))) clock))))
       (exchange-bytes h (request-bytes 'POST "/v1/login" '()) 1000)
       (if (= (length lines) 1) (car lines) (list 'lines lines))))))

(test-equal "note: a read, the account noted, a write: db_ms the two jobs' sum, the account kept"
  (string-append "request method=POST path=/v1/login status=200 ending=written ms=50 db_ms=20 account="
                 acct-a-text " address=-")
  (with-login-store "login-note.db"
    (lambda (s)
      (login-line (lambda (req clock)
                    (login-read (store-reader s) clock req "alice@example.com")
                    (note-account! req acct-a)
                    (login-write (store-writer s) clock req acct-a "hash-a" #f (new-key 50)))))))

(test-equal "note: a read alone shows its db_ms and no account"
  "request method=POST path=/v1/login status=200 ending=written ms=30 db_ms=10 account=- address=-"
  (login-line (lambda (req clock)
                (login-read (store-reader store) clock req "alice@example.com"))))

(test-equal "note: stale and full keep the account the handler wrote"
  (list (string-append "request method=POST path=/v1/login status=200 ending=written ms=30 db_ms=10 account="
                       acct-a-text " address=-")
        (string-append "request method=POST path=/v1/login status=200 ending=written ms=30 db_ms=10 account="
                       acct-a-text " address=-"))
  (list (login-line (lambda (req clock)
                      (note-account! req acct-a)
                      (login-write (store-writer store) clock req acct-a "not-the-hash" #f (new-key 51))))
        (with-login-store "login-note-full.db"
          (lambda (s)
            (keys-up-to! s 100)
            (login-line (lambda (req clock)
                          (note-account! req acct-a)
                          (login-write (store-writer s) clock req acct-a "hash-a" #f (new-key 52))))))))

(test-equal "note: a raise in the write, and a deadline in it, keep the account and add db_ms"
  (list (string-append "request method=POST path=/v1/login status=500 ending=written ms=30 db_ms=10 account="
                       acct-a-text " address=-")
        (string-append "request method=POST path=/v1/login status=504 ending=written ms=30 db_ms=10 account="
                       acct-a-text " address=-"))
  (list (quietly login-line (lambda (req clock)
                              (note-account! req acct-a)
                              (login-write (lambda (job) (error 'runner "the write fails"))
                                           clock req acct-a "hash-a" #f (new-key 53))))
        (login-line (lambda (req clock)
                      (note-account! req acct-a)
                      (login-write (lambda (job) (sleep-ms 500) ((store-writer store) job))
                                   clock req acct-a "hash-a" #f (new-key 54))))))

(when (and store (not (pair? store))) (close-test-store! store))

(test-end "auth")

(exit (suite-exit-status runner))
