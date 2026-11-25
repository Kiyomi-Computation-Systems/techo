#!r6rs
;;; The log suite: (techo log), D10's request line and its note, with
;;; circuit's test requests: test-req-done! ends a response, as the server
;;; does when it has written one. No server and no database; the middleware's
;;; place in the stack, and the lines a real request writes, are held in
;;; tests/test-app.sps and tests/test-routes.sps.
;;;
;;;   request-line      the one line, field by field, `-` for nothing
;;;   wrap-request-log  one line when the response ends, never before, once
;;;   the note          what a handler writes into it is on the line
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (circuit)
        (circuit test)
        (techo log))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; contains? : String String -> Boolean
(define (contains? s part)
  (let ((n (string-length s)) (m (string-length part)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) part) #t)
            (else (loop (+ i 1)))))))

(define acct (bytevector-copy #vu8(1 147 0 0 0 0 112 0 128 0 0 0 0 0 0 42)))
(define acct-text "01930000-0000-7000-8000-00000000002a")

;; step-clock : Integer Integer -> (-> Integer)
;; START, then START + STEP, and so on, one reading a call.
(define (step-clock start step)
  (let ((t (- start step)))
    (lambda () (set! t (+ t step)) t)))

;; logged : -> (values (String -> Void) (-> (Listof Any)))
;; A line writer that keeps what it is given, and a reader of it, oldest
;; first.
(define (logged)
  (let ((lines '()))
    (values (lambda (line) (set! lines (cons line lines)))
            (lambda () (reverse lines)))))

(test-begin "log")

;;; request-line

(test-equal "request-line: every field, in D10's order"
  (string-append "request method=GET path=/v1/keys status=200 ending=written ms=4 db_ms=1 account="
                 acct-text " address=203.0.113.9")
  (attempt (lambda () (request-line 'GET "/v1/keys" 200 'written 4 1 acct "203.0.113.9"))))

(test-equal "request-line: a field with nothing to show is -"
  "request method=POST path=/x status=- ending=client-closed ms=0 db_ms=- account=- address=-"
  (attempt (lambda () (request-line 'POST "/x" #f 'client-closed 0 #f #f #f))))

(test-equal "request-line: an empty address is -"
  "request method=GET path=/ status=404 ending=written ms=2 db_ms=- account=- address=-"
  (attempt (lambda () (request-line 'GET "/" 404 'written 2 #f #f ""))))

(test-equal "request-line: control characters in the method, the path and the address are spaces"
  "request method=G T path=/a b c d status=400 ending=failed ms=1 db_ms=- account=- address=1 2"
  (attempt (lambda ()
             (request-line (string->symbol (string #\G (integer->char 0) #\T))
                           (string #\/ #\a #\newline #\b #\tab #\c (integer->char 127) #\d)
                           400 'failed 1 #f #f (string #\1 #\return #\2)))))

(test-equal "request-line: a 504 that the job outlived shows db_ms as given, account -"
  "request method=POST path=/v1/keys/x/revoke status=504 ending=written ms=10000 db_ms=10000 account=- address=-"
  (attempt (lambda () (request-line 'POST "/v1/keys/x/revoke" 504 'written 10000 10000 #f #f))))

;;; wrap-request-log

;; run-logged : Handler Req (U Symbol #f) -> (List Any (Listof Any) (Listof Any))
;; HANDLER inside wrap-request-log, with a step clock of 0, 10, 20 ... :
;; what it answered (its status, or what it raised), the lines before the
;; response ends, and the lines after test-req-done! with ENDING (none for
;; #f).
(define (run-logged handler req ending)
  (attempt
   (lambda ()
     (let-values (((write! lines) (logged)))
       (let* ((h ((wrap-request-log write! (step-clock 0 10)) handler))
              (answer (guard (e (#t (list 'handler-raised e))) (h req)))
              (before (lines)))
         (when ending (test-req-done! req ending))
         (list (if (res? answer) (res-status answer) answer) before (lines)))))))

(test-equal "wrap-request-log: nothing before the response ends; one line when it does"
  '(200 ()
    ("request method=GET path=/v1/account status=200 ending=written ms=10 db_ms=- account=- address=-"))
  (run-logged (lambda (req) (make-res 200 '() "ok")) (make-test-req 'GET "/v1/account") 'written))

;; logged-address : Any (Listof (Pair String String)) -> (U String Any)
;; The address field of the one line a GET with HEADERS writes, behind
;; PROXIES proxies. The test host has no peer, so the peer's address is "-".
(define (logged-address proxies headers)
  (attempt
   (lambda ()
     (let-values (((write! lines) (logged)))
       (let* ((h ((wrap-request-log write! (step-clock 0 10) proxies)
                  (lambda (req) (make-res 200 '() "ok"))))
              (req (make-test-req 'GET "/x" headers "")))
         (h req)
         (test-req-done! req 'written)
         (let ((ls (lines)))
           (if (= (length ls) 1)
               (let loop ((i 0))
                 (cond ((> (+ i 9) (string-length (car ls))) (car ls))
                       ((string=? (substring (car ls) i (+ i 9)) " address=")
                        (substring (car ls) (+ i 9) (string-length (car ls))))
                       (else (loop (+ i 1)))))
               ls)))))))

(define forwarded '(("X-Forwarded-For" . "6.6.6.6, 203.0.113.9")))

(test-equal "wrap-request-log: behind one proxy the address is the last X-Forwarded-For entry; behind two, the one before"
  '("203.0.113.9" "6.6.6.6")
  (list (logged-address 1 forwarded) (logged-address 2 forwarded)))

(test-equal "wrap-request-log: with no proxy the header is ignored: the peer's address"
  "-"
  (logged-address 0 forwarded))

(test-equal "wrap-request-log: a list too short, or an entry that is no address, gives the peer's; a port is dropped"
  '("-" "-" "203.0.113.9")
  (list (logged-address 3 forwarded)
        (logged-address 1 '(("X-Forwarded-For" . "6.6.6.6, unknown")))
        (logged-address 1 '(("X-Forwarded-For" . "203.0.113.9:5555")))))

(test-equal "wrap-request-log: a proxy count that is no whole number is refused when the middleware is made"
  '(refused refused)
  (map (lambda (bad)
         (guard (e ((assertion-violation? e) 'refused) (#t (list 'other e)))
           (wrap-request-log (lambda (l) #f) (step-clock 0 10) bad)
           'made))
       '(-1 "1")))

(test-equal "wrap-request-log: the path has no query string"
  '(200 ()
    ("request method=GET path=/v1/keys status=200 ending=written ms=10 db_ms=- account=- address=-"))
  (run-logged (lambda (req) (make-res 200 '() "ok"))
              (make-test-req 'GET "/v1/keys?limit=5&after=0193-secret-looking")
              'written))

(define secret "techo_000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

(test-equal "wrap-request-log: no header and no body reaches the line"
  '(#f #f #f)
  (let ((r (run-logged (lambda (req) (make-res 401 '() "no"))
                       (make-test-req 'POST "/v1/keys/1/revoke"
                                      (list (cons "Authorization" (string-append "Bearer " secret))
                                            (cons "X-Other" "header-value"))
                                      "body-text")
                       'written)))
    (if (and (pair? r) (= (length (caddr r)) 1))
        (let ((line (car (caddr r))))
          (list (contains? line secret) (contains? line "header-value") (contains? line "body-text")))
        r)))

(test-equal "wrap-request-log: the status is the handler's; the ending is the server's"
  '(503 () ("request method=GET path=/x status=503 ending=client-closed ms=10 db_ms=- account=- address=-"))
  (run-logged (lambda (req) (make-res 503 '() #f)) (make-test-req 'GET "/x") 'client-closed))

(test-equal "wrap-request-log: a handler's raise goes on untouched, and its line has status -"
  '(handler-raised (the-raise) ()
    ("request method=GET path=/x status=- ending=failed ms=10 db_ms=- account=- address=-"))
  (let ((r (run-logged (lambda (req) (raise 'the-raise)) (make-test-req 'GET "/x") 'failed)))
    (if (and (pair? r) (pair? (car r)) (eq? (caar r) 'handler-raised))
        (cons 'handler-raised (cons (list (cadar r)) (cdr r)))
        r)))

(test-equal "wrap-request-log: an answer that is no response has status -"
  '(not-a-res () ("request method=GET path=/x status=- ending=written ms=10 db_ms=- account=- address=-"))
  (run-logged (lambda (req) 'not-a-res) (make-test-req 'GET "/x") 'written))

(test-equal "wrap-request-log: one line however often the response is said to end"
  1
  (attempt
   (lambda ()
     (let-values (((write! lines) (logged)))
       (let* ((req (make-test-req 'GET "/x")))
         (((wrap-request-log write! (step-clock 0 1)) (lambda (r) (make-res 200 '() #f))) req)
         (test-req-done! req 'written)
         (test-req-done! req 'failed)
         (length (lines)))))))

(test-equal "wrap-request-log: the writer gets one string, with no newline"
  '(#t #f)
  (attempt
   (lambda ()
     (let-values (((write! lines) (logged)))
       (let ((req (make-test-req 'GET "/x")))
         (((wrap-request-log write! (step-clock 0 1)) (lambda (r) (make-res 200 '() #f))) req)
         (test-req-done! req 'written)
         (let ((line (car (lines))))
           (list (string? line) (contains? line (string #\newline)))))))))

(test-equal "wrap-request-log: the default clock is real-time's, so ms is a whole number of 0 or more"
  #t
  (attempt
   (lambda ()
     (let-values (((write! lines) (logged)))
       (let ((req (make-test-req 'GET "/x")))
         (((wrap-request-log write!) (lambda (r) (make-res 200 '() #f))) req)
         (test-req-done! req 'written)
         (let* ((line (car (lines)))
                (after (let loop ((i 0))
                         (if (string=? (substring line i (+ i 4)) " ms=") (+ i 4) (loop (+ i 1)))))
                (end (let loop ((j after))
                       (if (char=? (string-ref line j) #\space) j (loop (+ j 1)))))
                (n (string->number (substring line after end))))
           (and (integer? n) (exact? n) (>= n 0))))))))

(test-equal "wrap-request-log: a writer that is no procedure raises at once"
  'assertion
  (guard (e ((assertion-violation? e) 'assertion) (#t 'other))
    (wrap-request-log "stdout")
    'no-raise))

;;; The note

(test-equal "note: what the handler writes is on the line"
  '(200 ()
    ("request method=GET path=/v1/account status=200 ending=written ms=10 db_ms=3 account=01930000-0000-7000-8000-00000000002a address=-"))
  (run-logged (lambda (req) (note-request! req acct 3) (make-res 200 '() #f))
              (make-test-req 'GET "/v1/account") 'written))

(test-equal "note: a request inside the middleware has one, empty at first"
  '(#t #f #f)
  (attempt
   (lambda ()
     (let ((seen #f))
       (((wrap-request-log (lambda (l) #f) (step-clock 0 1))
         (lambda (req)
           (let ((n (req-note req)))
             (set! seen (list (note? n) (note-account n) (note-db-ms n))))
           (make-res 200 '() #f)))
        (make-test-req 'GET "/x"))
       seen))))

(test-equal "note: a request no log has made has none, and writing it does nothing"
  '(#f ok)
  (attempt
   (lambda ()
     (let ((req (make-test-req 'GET "/x")))
       (list (req-note req)
             (begin (note-request! req acct 1) 'ok))))))

(test-equal "note: an account only, with no db_ms"
  '(200 ()
    ("request method=GET path=/x status=200 ending=written ms=10 db_ms=- account=01930000-0000-7000-8000-00000000002a address=-"))
  (run-logged (lambda (req) (note-request! req acct #f) (make-res 200 '() #f))
              (make-test-req 'GET "/x") 'written))

(test-equal "note: it is shared by the request's copies, so a copy's handler writes the line's"
  '(200 ()
    ("request method=GET path=/x status=200 ending=written ms=10 db_ms=7 account=- address=-"))
  (run-logged (lambda (req)
                (note-request! (req-with-path (req-set req (make-req-key 'other) 1) "/other") #f 7)
                (make-res 200 '() #f))
              (make-test-req 'GET "/x") 'written))

;;; The note, a piece at a time (slice 3b: login's two jobs)

(test-equal "note-account!: writes the account alone, and keeps db_ms"
  '(200 ()
    ("request method=POST path=/v1/login status=200 ending=written ms=10 db_ms=3 account=01930000-0000-7000-8000-00000000002a address=-"))
  (run-logged (lambda (req) (note-request! req #f 3) (note-account! req acct) (make-res 200 '() #f))
              (make-test-req 'POST "/v1/login") 'written))

(test-equal "note-add-db-ms!: adds to db_ms, nothing yet counting as 0, and keeps the account"
  '(200 ()
    ("request method=POST path=/v1/login status=200 ending=written ms=10 db_ms=7 account=01930000-0000-7000-8000-00000000002a address=-"))
  (run-logged (lambda (req)
                (note-add-db-ms! req 2)
                (note-account! req acct)
                (note-add-db-ms! req 5)
                (make-res 200 '() #f))
              (make-test-req 'POST "/v1/login") 'written))

(test-equal "note-account! and note-add-db-ms!: a request with no note is left as it is"
  '(#f ok)
  (attempt
   (lambda ()
     (let ((req (make-test-req 'GET "/x")))
       (note-account! req acct)
       (note-add-db-ms! req 4)
       (list (req-note req) 'ok)))))

(test-end "log")

(exit (suite-exit-status runner))
