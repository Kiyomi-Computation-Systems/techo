#!r6rs
;;; The app suite: Techo's HTTP handler, called directly with circuit's
;;; test request constructor where nothing waits, and through the server's
;;; test host, raw bytes in, where something does.
;;;
;;;   GET /health       200, application/json, {"status":"ok"}, no job
;;;   HEAD /health      what circuit's router does for HEAD on a GET route
;;;   other method      405 with an Allow header, from the router itself
;;;   any other path    404 in the format (D7), code not_found
;;;   (make-app) twice  two handlers that both work
;;;   wrap-app          unchanged: 503, 500, the moved line, the timeout
;;;   wrap-errors       a bare 400 or more gets the format; nothing else moves
;;;   wrap-server       the whole stack: every status of D7's table in the
;;;                     format (P4), and the log line with the status the
;;;                     client got, which pins the order
;;;   imports           only techo.sps and serve.sls name db-read or db-write;
;;;                     (techo store) takes three names from the doorway (P5)
;;;
;;; Bodies are parsed with jsonparse and the values compared, never the
;;; strings. Everything that can raise is computed under `attempt`, and a
;;; raise comes out as a sentinel no expected value is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (circuit)
        (circuit test)
        (circuit worker)
        (circuit json)
        (circuit http-server)
        (http-server testing)
        (jsonparse easy)
        (only (chezscheme) directory-list port-closed?)
        (http-support)
        (techo errors)
        (only (techo keys) key-secret id->string)
        (only (techo auth) key-hash)
        (only (techo store) insert-account! insert-key!)
        (only (unique-id) uuid->string bytevector->uuid)
        (techo app)
        (techo doorway))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; header : Res String -> (U String #f)
;; The value of the named header, name compared without case.
(define (header res name)
  (let loop ((hs (res-headers res)))
    (cond ((null? hs) #f)
          ((string=? (string-downcase (caar hs)) name) (cdar hs))
          (else (loop (cdr hs))))))

;; body-text : Res -> String
(define (body-text res)
  (utf8->string (res-body->bytevector res)))

;; call : Handler Symbol String -> Res
(define (call handler method target)
  (handler (make-test-req method target)))

;; summary : Handler Symbol String -> (U (List Nat (U String #f) Any) (List 'raised String))
;; Status, content-type and the body parsed as JSON.
(define (summary handler method target)
  (attempt
   (lambda ()
     (let ((res (call handler method target)))
       (list (res-status res)
             (header res "content-type")
             (string->json (body-text res)))))))

;; The app is made with runners that raise if they are ever called, and
;; count it: /health stays free of the database, and so does a 404.
(define calls 0)
(define (never job) (set! calls (+ calls 1)) (raise 'a-job-was-run))
(define (stopped-clock) 0)
(define (no-bytes n) (raise 'random-bytes-was-called))
(define (new-app) (make-app never never stopped-clock no-bytes))
(define app (attempt new-app))

;; problem : Symbol -> Alist     CODE's body, as problem-res makes it
(define (problem code)
  (let ((s (error-status code)))
    (list (cons "type" "about:blank") (cons "title" (status-phrase s)) (cons "status" s)
          (cons "code" (symbol->string code)) (cons "detail" (error-message code)))))

(define not-found-summary (list 404 "application/problem+json" (problem 'not_found)))

(test-begin "app")

(test-equal "GET /health: 200, application/json, {\"status\":\"ok\"}"
  '(200 "application/json" (("status" . "ok")))
  (summary app 'GET "/health"))

(test-equal "HEAD /health: the router answers it with the GET's status and content-type"
  '(200 "application/json")
  (attempt (lambda ()
             (let ((res (call app 'HEAD "/health")))
               (list (res-status res) (header res "content-type"))))))

(test-equal "POST /health: 405 with allow: GET, HEAD, from the router"
  '(405 "GET, HEAD")
  (attempt (lambda ()
             (let ((res (call app 'POST "/health")))
               (list (res-status res) (header res "allow"))))))

(test-equal "DELETE /health: 405 with allow: GET, HEAD"
  '(405 "GET, HEAD")
  (attempt (lambda ()
             (let ((res (call app 'DELETE "/health")))
               (list (res-status res) (header res "allow"))))))

(test-equal "GET /nowhere: 404 in the format, not_found"
  not-found-summary
  (summary app 'GET "/nowhere"))

(test-equal "GET /: 404 in the format"
  not-found-summary
  (summary app 'GET "/"))

(test-equal "GET /healthz: 404 in the format, not the health route"
  not-found-summary
  (summary app 'GET "/healthz"))

(test-equal "GET /health/: the trailing slash is another path, a 404"
  not-found-summary
  (summary app 'GET "/health/"))

(test-equal "POST /nowhere: 404 in the format, whatever the method"
  not-found-summary
  (summary app 'POST "/nowhere"))

(test-equal "GET /v1, /v1/ and /v1/keys/: no route, a 404 in the format"
  (list not-found-summary not-found-summary not-found-summary)
  (list (summary app 'GET "/v1") (summary app 'GET "/v1/") (summary app 'GET "/v1/keys/")))

(test-equal "GET /v1/health: /health stays outside /v1"
  not-found-summary
  (summary app 'GET "/v1/health"))

(test-equal "two (make-app) handlers both answer /health, in any order"
  (list '(200 "application/json" (("status" . "ok")))
        '(200 "application/json" (("status" . "ok")))
        '(200 "application/json" (("status" . "ok")))
        not-found-summary)
  (attempt
   (lambda ()
     (let ((a (new-app)) (b (new-app)))
       (list (summary a 'GET "/health")
             (summary b 'GET "/health")
             (summary a 'GET "/health")
             (summary b 'GET "/other"))))))

(test-equal "POST /v1/login with no login kit, or #f for one: a 404 like any unknown path"
  (list not-found-summary not-found-summary)
  (list (summary app 'POST "/v1/login")
        (summary (attempt (lambda () (make-app never never stopped-clock no-bytes stopped-clock #f)))
                 'POST "/v1/login")))

(test-equal "make-app: a kit that is no login kit raises at once"
  'assertion
  (guard (e ((assertion-violation? e) 'assertion) (#t 'other))
    (make-app never never stopped-clock no-bytes stopped-clock 'not-a-kit)
    'no-raise))

(test-equal "/health and the 404s ran no job and drew no random bytes"
  0 calls)

;; --- wrap-app --------------------------------------------------------------

(define (unavailable-of reason expected found)
  ((record-constructor (make-record-constructor-descriptor (record-type-descriptor &db-unavailable) #f #f))
   reason expected found))
(define worker-full-condition
  ((record-constructor (make-record-constructor-descriptor (record-type-descriptor &worker-full) #f #f))))

;; wrap-app has a wrap-timeout inside, which needs the server's coroutine, so
;; each request goes through the server's own test host: bytes in, bytes out.

;; unset : String -> #f
(define (unset name) #f)

;; wire-of : Handler -> String
;; The raw response to GET /x on a test host serving HANDLER.
(define (wire-of handler)
  (let* ((host (make-test-host (circuit->handler handler unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (string->utf8 "GET /x HTTP/1.1\r\nHost: x\r\n\r\n"))
    (let ((rs (test-client-responses c)))
      (if (= (length rs) 1)
          (utf8->string (test-response-bytes (car rs)))
          (list 'responses (length rs))))))

;; status-line-of, has? : the answer's first line, and a substring test
(define (status-line-of w)
  (if (string? w) (car (lines-of w)) w))
(define (lines-of s)
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (cond ((null? cs) (reverse (cons (list->string (reverse cur)) acc)))
          ((char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
          ((char=? (car cs) #\return) (loop (cdr cs) cur acc))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))
(define (has? w line) (and (string? w) (member line (lines-of w)) #t))

;; answer-of : (-> Any) (String -> Void) -> (List String Boolean Boolean)
;; A handler that raises what THUNK makes, in wrap-app's stack: the status
;; line, whether it has retry-after: 5, whether its body is empty.
(define (answer-of thunk log)
  (attempt
   (lambda ()
     (let ((w (wire-of (wrap-app (lambda (req) (raise (thunk))) log))))
       (list (status-line-of w) (has? w "retry-after: 5") (has? w "Content-Length: 0"))))))

(test-equal "wrap-app: a handler that raises &db-unavailable answers an empty 503 with retry-after: 5"
  '("HTTP/1.1 503 Service Unavailable" #t #t)
  (answer-of (lambda () (unavailable-of 'busy #f #f)) (lambda (line) #f)))

(test-equal "wrap-app: a handler that raises &worker-full answers an empty 503 with retry-after: 5"
  '("HTTP/1.1 503 Service Unavailable" #t #t)
  (answer-of (lambda () worker-full-condition) (lambda (line) #f)))

(test-equal "wrap-app: a handler that raises an error answers 500, not 503"
  '("HTTP/1.1 500 Internal Server Error" #f #t)
  (answer-of (lambda () (make-error)) (lambda (line) #f)))

(test-equal "wrap-app: a handler that answers is passed through"
  '("HTTP/1.1 200 OK" #f)
  (attempt (lambda ()
             (let ((w (wire-of (wrap-app (lambda (req) (make-json-res 200 '(("a" . "b"))))
                                         (lambda (l) #f)))))
               (list (status-line-of w) (has? w "retry-after: 5"))))))

(test-equal "wrap-app: the log gets the moved line once, whole and with no newline, for two requests"
  '(("HTTP/1.1 503 Service Unavailable" "HTTP/1.1 503 Service Unavailable")
    ("database moved: the file is at version 4 and this server expects 3; a newer techo migrate ran beside it; database requests get 503 until the newer techo serves"))
  (attempt
   (lambda ()
     (let* ((seen '())
            (h (wrap-app (lambda (req) (raise (unavailable-of 'moved 3 4)))
                         (lambda (line) (set! seen (cons line seen)))))
            (a (status-line-of (wire-of h)))
            (b (status-line-of (wire-of h))))
       (list (list a b) seen)))))

(test-equal "wrap-app: the request timeout is 10 seconds, a named constant"
  10000 request-timeout-ms)

;;; --- wrap-errors ------------------------------------------------------------

;; errors-of : Res [Symbol] -> Res
;; What wrap-errors makes of a handler that answers RES, for a GET (or
;; METHOD) of /x. Nothing here waits, so no server is needed.
(define (errors-of res . method)
  ((wrap-errors (lambda (req) res))
   (make-test-req (if (null? method) 'GET (car method)) "/x")))

;; res-summary : Res -> (List Nat (U String #f) Any)
(define (res-summary res)
  (list (res-status res) (header res "content-type") (string->json (body-text res))))

(test-equal "wrap-errors: a bare 404 gets the format: not_found"
  (list 404 "application/problem+json" (problem 'not_found))
  (attempt (lambda () (res-summary (errors-of (make-res 404 '() #f))))))

(test-equal "wrap-errors: an answer already in the format is passed as it is, the same object"
  '(#t #t #t)
  (attempt (lambda ()
             (let ((a (problem-res 'invalid_json))
                   (b (make-res 422 '(("content-type" . "application/problem+json; charset=utf-8")) "{}"))
                   (c (make-res 409 '(("Content-Type" . "Application/Problem+JSON")) "{}")))
               (list (eq? a (errors-of a)) (eq? b (errors-of b)) (eq? c (errors-of c)))))))

(test-equal "wrap-errors: an answer under 400 is passed as it is"
  '(#t #t #t #t)
  (attempt (lambda ()
             (map (lambda (r) (eq? r (errors-of r)))
                  (list (make-res 200 '(("content-type" . "text/plain")) "ok")
                        (make-res 204 '() #f)
                        (make-res 301 '(("location" . "/y")) "moved")
                        (make-res 399 '() #f))))))

(test-equal "wrap-errors: a text/plain 400 (wrap-json-body's own) is replaced: invalid_request, one content-type"
  (list 400 "application/problem+json" (problem 'invalid_request) 1)
  (attempt (lambda ()
             (let ((r (errors-of (make-res 400 '(("content-type" . "text/plain")) "bad at byte 3\n"))))
               (append (res-summary r)
                       (list (length (filter (lambda (h) (string=? (string-downcase (car h)) "content-type"))
                                             (res-headers r)))))))))

(test-equal "wrap-errors: a JSON 404 that is not the format is replaced"
  (list 404 "application/problem+json" (problem 'not_found))
  (attempt (lambda () (res-summary (errors-of (make-json-res 404 '(("error" . "not_found"))))))))

(test-equal "wrap-errors: every header is kept but content-type and content-length"
  '(("content-type" . "application/problem+json") ("allow" . "GET, HEAD") ("x-a" . "b"))
  (attempt (lambda ()
             (res-headers (errors-of (make-res 405 '(("Content-Type" . "text/html")
                                                    ("allow" . "GET, HEAD")
                                                    ("Content-Length" . "4")
                                                    ("x-a" . "b"))
                                               "nope"))))))

(test-equal "wrap-errors: a bare 401 gets www-authenticate: Bearer; a 503 keeps its retry-after"
  '("Bearer" "5" "unavailable")
  (attempt (lambda ()
             (let ((a (errors-of (make-res 401 '() #f)))
                   (b (errors-of (make-res 503 '(("retry-after" . "5")) #f))))
               (list (header a "www-authenticate") (header b "retry-after")
                     (cdr (assoc "code" (string->json (body-text b)))))))))

(test-equal "wrap-errors: never changes a status; a status with no code of its own is `error`"
  '(#t ("error" "error" "error" "error"))
  (attempt (lambda ()
             (list (for-all (lambda (s) (= s (res-status (errors-of (make-res s '() #f)))))
                            (let loop ((s 400) (acc '()))
                              (if (> s 599) acc (loop (+ s 1) (cons s acc)))))
                   (map (lambda (s) (cdr (assoc "code" (string->json (body-text (errors-of (make-res s '() #f)))))))
                        '(402 418 502 599))))))

(test-equal "wrap-errors: a streamed body is replaced, and its port closed"
  (list #t 500 (problem 'internal))
  (attempt (lambda ()
             (let* ((p (open-bytevector-input-port (string->utf8 "a stack trace")))
                    (r (errors-of (make-res 500 '(("content-type" . "text/plain")) p))))
               (list (port-closed? p) (res-status r) (string->json (body-text r)))))))

(test-equal "wrap-errors: a sized body's port is closed too; a producer's body replaced"
  (list #t (problem 'unavailable) (problem 'timeout))
  (attempt (lambda ()
             (let* ((p (open-bytevector-input-port (string->utf8 "abcd")))
                    (a (errors-of (make-res 503 '() (make-sized-body 4 p))))
                    (b (errors-of (make-res 504 '() (lambda () (eof-object))))))
               (list (port-closed? p) (string->json (body-text a)) (string->json (body-text b)))))))

(test-equal "wrap-errors: a HEAD is answered as its GET would be; the server sends no body"
  (list (list 404 "application/problem+json" (problem 'not_found)) #t)
  (attempt (lambda ()
             (let ((h (errors-of (make-res 404 '() #f) 'HEAD))
                   (g (errors-of (make-res 404 '() #f) 'GET)))
               (list (res-summary h) (equal? (body-text h) (body-text g)))))))

(test-equal "wrap-errors: a handler that is no procedure raises at once"
  'assertion
  (guard (e ((assertion-violation? e) 'assertion) (#t 'other))
    (wrap-errors 'nope)
    'no-raise))

;;; --- wrap-server: the whole stack, through the test host --------------------

;; serve : Handler Natural Bytevector [Natural] -> (List (Listof Answer) (Listof String) String)
;; HANDLER inside wrap-server with TIMEOUT-MS, its log lines kept, and a
;; duration clock stepping by 1; BYTES sent, the host's clock moved on
;; ADVANCE-MS. The answers, the lines, and what was written on the current
;; output port (wrap-catch's handler-failed line).
(define serve
  (case-lambda
    ((handler timeout bytes) (serve handler timeout bytes 0))
    ((handler timeout bytes advance)
     (let* ((lines '())
            (h (wrap-server handler (lambda (l) (set! lines (cons l lines))) timeout
                            (step-clock 0 1))))
       (let-values (((answers out) (capture-output (lambda () (exchange-bytes h bytes advance)))))
         (list answers (reverse lines) out))))))

;; served : Handler Symbol String (Listof Header) [(U String #f)] [Natural]
;;          -> (List Nat Any (U String #f) (Listof String) String)
;; One request: its status, its code (or its JSON), its www-authenticate, allow
;; and retry-after, its log lines and the output.
(define (served handler method target headers . more)
  (attempt
   (lambda ()
     (let* ((body (if (pair? more) (car more) #f))
            (advance (if (and (pair? more) (pair? (cdr more))) (cadr more) 0))
            (r (serve handler 50 (request-bytes method target headers body) advance))
            (a (car (car r)))
            (j (answer-json a)))
       (list (answer-status a)
             (answer-header a "content-type")
             (if (and (list? j) (assoc "code" j)) (cdr (assoc "code" j)) j)
             (list (answer-header a "www-authenticate") (answer-header a "allow")
                   (answer-header a "retry-after"))
             (cadr r)
             (caddr r))))))

;; status-of-line : String -> String     the status=... field's value
(define (status-of-line line)
  (let* ((at (let loop ((i 0))
               (if (string=? (substring line i (+ i 8)) " status=") (+ i 8) (loop (+ i 1)))))
         (end (let loop ((j at)) (if (char=? (string-ref line j) #\space) j (loop (+ j 1))))))
    (substring line at end)))

;; p4 : (List ...) -> (List Nat String String Extras (Listof String))
;; What a P4 test compares: status, content type, code, the extras, and the
;; status on each request line.
(define (p4 r)
  (if (and (pair? r) (integer? (car r)))
      (list (car r) (cadr r) (caddr r) (cadddr r)
            (map status-of-line (filter (lambda (l) (string=? (substring l 0 8) "request "))
                                        (list-ref r 4))))
      r))

(define key-header (list (cons "Authorization"
                               "Bearer techo_000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")))

;; stand-ins
(define (bare status . headers) (lambda (req) (make-res status headers #f)))
(define (json-route req)
  ;; What a 3b route that takes a body does: wrap-json-body inside the
  ;; catch, and its own invalid_json for a body that does not parse.
  (let ((r (((wrap-json-body 8) (lambda (req) (make-json-res 200 '(("ok" . #t))))) req)))
    (if (and (= (res-status r) 400) (not (equal? (res-header r "content-type") "application/problem+json")))
        (problem-res 'invalid_json)
        r)))
(define json-headers '(("Content-Type" . "application/json")))

(test-equal "P4: 400 invalid_request, a real route's bad limit, before any job"
  '(400 "application/problem+json" "invalid_request" (#f #f #f) ("400"))
  (p4 (served (new-app) 'GET "/v1/keys?limit=0" key-header)))

(test-equal "P4: 400 invalid_request, the router's own for a capture that is not UTF-8"
  '(400 "application/problem+json" "invalid_request" (#f #f #f) ("400"))
  (p4 (served (new-app) 'POST "/v1/keys/%C3%28/revoke" key-header)))

(test-equal "P4, not covered (D7): a malformed escape is the server's own bare 400, before any handler, unlogged"
  '(400 #f empty () "")
  (let ((r (served (new-app) 'POST "/v1/keys/%ZZ/revoke" key-header)))
    (if (pair? r) (list (car r) (cadr r) (caddr r) (list-ref r 4) (list-ref r 5)) r)))

(test-equal "P4: 400 invalid_json, a body route's own answer, kept as it is"
  '(400 "application/problem+json" "invalid_json" (#f #f #f) ("400"))
  (p4 (served json-route 'POST "/x" json-headers "{nope")))

(test-equal "P4: 401 unauthorized, with www-authenticate: Bearer"
  '(401 "application/problem+json" "unauthorized" ("Bearer" #f #f) ("401"))
  (p4 (served (new-app) 'GET "/v1/account" '())))

(test-equal "P4: 403 forbidden, from a bare 403"
  '(403 "application/problem+json" "forbidden" (#f #f #f) ("403"))
  (p4 (served (bare 403) 'GET "/x" '())))

(test-equal "P4: 404 not_found, no such route"
  '(404 "application/problem+json" "not_found" (#f #f #f) ("404"))
  (p4 (served (new-app) 'GET "/nowhere" '())))

(test-equal "P4: 405 method_not_allowed, the router's, its allow kept"
  '(405 "application/problem+json" "method_not_allowed" (#f "GET, HEAD" #f) ("405"))
  (p4 (served (new-app) 'POST "/health" '())))

(test-equal "P4: 413 payload_too_large, a body past wrap-json-body's cap, inside the catch"
  '(413 "application/problem+json" "payload_too_large" (#f #f #f) ("413"))
  (p4 (served json-route 'POST "/x" json-headers "{\"a\": \"a long value past the cap\"}")))

(test-equal "P4: 415 unsupported_media_type, from a bare 415"
  '(415 "application/problem+json" "unsupported_media_type" (#f #f #f) ("415"))
  (p4 (served (bare 415) 'POST "/x" '(("Content-Type" . "text/plain")) "hi")))

(test-equal "P4: 500 internal, a handler that raises; its line has the 500 the client got"
  '((500 "application/problem+json" "internal" (#f #f #f) ("500")) #t)
  (let ((r (served (lambda (req) (error 'stand-in "it raises")) 'GET "/x" '())))
    (list (p4 r) (and (pair? r) (contains? (list-ref r 5) "handler-failed")))))

(test-equal "P4: 503 unavailable from wrap-db, its retry-after kept; the line has the 503"
  '(503 "application/problem+json" "unavailable" (#f #f "5") ("503"))
  (p4 (served (lambda (req) (raise (unavailable-of 'busy #f #f))) 'GET "/x" '())))

(test-equal "P4: 503 unavailable from wrap-busy, a full worker"
  '(503 "application/problem+json" "unavailable" (#f #f "5") ("503"))
  (p4 (served (lambda (req) (raise worker-full-condition)) 'GET "/x" '())))

(test-equal "P4: 504 timeout, a handler that outlives its deadline; the line has the 504"
  '(504 "application/problem+json" "timeout" (#f #f #f) ("504"))
  (p4 (served (lambda (req) (sleep-ms 1000) (make-res 200 '() "late")) 'GET "/x" '() #f 2000)))

(test-equal "P4: a bare status with no code of its own is `error`: 418, 429, 502"
  '((418 "application/problem+json" "error" (#f #f #f) ("418"))
    (429 "application/problem+json" "error" (#f #f #f) ("429"))
    (502 "application/problem+json" "error" (#f #f #f) ("502")))
  (map (lambda (s) (p4 (served (bare s) 'GET "/x" '()))) '(418 429 502)))

(test-equal "P4: a 200 passes untouched"
  '(200 "application/json" "ok")
  (let ((r (served (new-app) 'GET "/health" '())))
    (if (pair? r) (list (car r) (cadr r) (cdr (assoc "status" (caddr r)))) r)))

(test-equal "wrap-server: HEAD /nowhere: the 404's head in the format, its length the GET's, no body"
  '(404 "application/problem+json" #t "")
  (attempt
   (lambda ()
     (let* ((h (wrap-server (new-app) (lambda (l) #f)))
            (g (exchange h 'GET "/nowhere" '()))
            (a (exchange h 'HEAD "/nowhere" '())))
       (list (answer-status a) (answer-header a "content-type")
             (equal? (answer-header a "content-length")
                     (number->string (bytevector-length (string->utf8 (answer-body g)))))
             (answer-body a))))))

(test-equal "wrap-server: one line a request, and wrap-db's line through the same writer"
  '(2 "database moved: the file is at version 4 and this server expects 3; a newer techo migrate ran beside it; database requests get 503 until the newer techo serves")
  (let ((r (served (lambda (req) (raise (unavailable-of 'moved 3 4))) 'GET "/x" '())))
    (if (pair? r) (list (length (list-ref r 4)) (car (list-ref r 4))) r)))

(test-equal "wrap-server: the default timeout is the program's, the default clock real-time's"
  '(200 #t)
  (attempt
   (lambda ()
     (let* ((lines '())
            (h (wrap-server (new-app) (lambda (l) (set! lines (cons l lines)))))
            (a (exchange h 'GET "/health" '())))
       (list (answer-status a) (= (length lines) 1))))))

;;; --- imports (P5) ------------------------------------------------------------

;; datums : String -> (Listof Any)     every datum of the file, as data
(define (datums path)
  (call-with-input-file path
    (lambda (p)
      (let loop ((acc '()))
        (let ((d (read p)))
          (if (eof-object? d) (reverse acc) (loop (cons d acc))))))))

;; import-specs : String -> (Listof Any)
;; A library's import specs, or a program's (its first datum's).
(define (import-specs path)
  (let ((ds (datums path)))
    (cond ((and (pair? (car ds)) (eq? (caar ds) 'library))
           (cdr (assq 'import (cddr (car ds)))))
          ((and (pair? (car ds)) (eq? (caar ds) 'import)) (cdar ds))
          (else (assertion-violation 'import-specs "neither a library nor a program" path)))))

;; import-target : Any -> (values Any (Symbol -> Boolean))
;; The library an import spec names (its version dropped), and which of
;; its exported names the spec makes visible, by their own names.
(define (import-target spec)
  (cond ((and (pair? spec) (memq (car spec) '(only except prefix rename)))
         (let-values (((lib visible?) (import-target (cadr spec))))
           (case (car spec)
             ((only) (values lib (lambda (n) (and (visible? n) (memq n (cddr spec)) #t))))
             ((except) (values lib (lambda (n) (and (visible? n) (not (memq n (cddr spec)))))))
             (else (values lib visible?)))))
        ((and (pair? spec) (eq? (car spec) 'for)) (import-target (cadr spec)))
        ((and (pair? spec) (eq? (car spec) 'library)) (import-target (cadr spec)))
        ((and (list? spec) (pair? spec) (list? (car (reverse spec))))
         (values (reverse (cdr (reverse spec))) (lambda (n) #t)))
        (else (values spec (lambda (n) #t)))))

;; doorway-names : (Listof Symbol)     (techo doorway)'s exports
(define doorway-names
  (attempt (lambda ()
             (let ((lib (car (datums "src/techo/doorway.sls"))))
               (cdr (assq 'export (cddr lib)))))))

;; doorway-visible : String -> (Listof Symbol)
;; The doorway's names the file's imports make visible.
(define (doorway-visible path)
  (let ((preds (let loop ((specs (import-specs path)) (acc '()))
                 (if (null? specs)
                     acc
                     (let-values (((lib visible?) (import-target (car specs))))
                       (loop (cdr specs)
                             (if (equal? lib '(techo doorway)) (cons visible? acc) acc)))))))
    (filter (lambda (n) (exists (lambda (p) (p n)) preds)) doorway-names)))

(define sources
  (append (map (lambda (f) (string-append "src/techo/" f))
               (list-sort string<?
                          (filter (lambda (f) (let ((n (string-length f)))
                                                (and (> n 4) (string=? (substring f (- n 4) n) ".sls"))))
                                  (directory-list "src/techo"))))
          '("techo.sps")))

(test-assert "imports: the sources are read: some libraries and the program"
  (let ((n (length sources))) (and (> n 10) (member "techo.sps" sources) #t)))

(test-equal "imports: only serve.sls and techo.sps make db-read or db-write visible"
  '("src/techo/serve.sls" "techo.sps")
  (attempt (lambda ()
             (filter (lambda (path)
                       (let ((v (doorway-visible path)))
                         (or (memq 'db-read v) (memq 'db-write v))))
                     sources))))

(test-equal "imports: (techo store) takes tx-execute!, tx-query and tx-query-row from the doorway, nothing more"
  '(tx-execute! tx-query tx-query-row)
  (attempt (lambda () (doorway-visible "src/techo/store.sls"))))

(test-equal "imports: (techo app) takes only wrap-db and db-retry-after from the doorway"
  '(db-retry-after wrap-db)
  (attempt (lambda () (doorway-visible "src/techo/app.sls"))))

;; mentions? : Any Symbol -> Boolean     NAME anywhere in DATUM, as a symbol
(define (mentions? datum name)
  (cond ((eq? datum name) #t)
        ((pair? datum) (or (mentions? (car datum) name) (mentions? (cdr datum) name)))
        ((vector? datum) (exists (lambda (d) (mentions? d name)) (vector->list datum)))
        (else #f)))

(test-equal "imports: no source but the doorway's and techo.sps writes db-read or db-write"
  '("src/techo/doorway.sls" "techo.sps")
  (attempt (lambda ()
             (filter (lambda (path)
                       (let ((ds (datums path)))
                         (or (mentions? ds 'db-read) (mentions? ds 'db-write))))
                     sources))))


;;; --- the node routes, joined (slice 4) ---------------------------------------

;; Real SQLite behind make-app: one account with one key, the wall clock a
;; fixed time, the duration clock stepping by 1 (so the two differ).
(define node-dir (fresh-dir "test-app-nodes"))
(define node-acct (make-bytevector 16 #xA1))
(define node-secret (key-secret (make-bytevector 32 1)))
(define node-wall 1795515226123)
(define node-id-text "0190b3a4-5c6d-7e8f-9a0b-000000000001")
(define marker "zxqmarkerword")

;; node-world : String -> (U (List Handler (-> (Listof String))) (List 'raised String))
;; A seeded file, the app over it inside wrap-server, and a reader of the
;; request log's lines.
(define (node-world name)
  (attempt
   (lambda ()
     (let* ((s (open-test-store node-dir name))
            (lines '())
            (clock (step-clock 0 1)))
       (run-write s (lambda (tx)
                      (insert-account! tx node-acct "alice" "alice@example.com" "argon2id-hash" 1000)
                      (insert-key! tx (make-bytevector 16 1) node-acct "laptop"
                                   (key-hash node-secret) 1100)))
       (list (wrap-server (make-app (store-reader s) (store-writer s) (lambda () node-wall)
                                    no-bytes clock)
                          (lambda (l) (set! lines (cons l lines))) 10000 clock)
             (lambda () (reverse lines)))))))

(define node-key (bearer node-secret))
(define json-h (cons "Content-Type" "application/json"))
(define (node-body title body)
  (json->string (list (cons "kind" "note") (cons "title" title) (cons "body" body)
                      (cons "content_type" "text/plain"))))

;; ask : World Symbol String (Listof Header) [String] -> (U Answer (List 'raised String))
(define (ask w method target headers . body)
  (attempt (lambda () (apply exchange (car w) method target headers body))))

;; code-of : Answer -> (U String #f)
(define (code-of a)
  (let ((j (answer-json a))) (and (list? j) (assoc "code" j) (cdr (assoc "code" j)))))

;; shape : (U Answer (List 'raised String)) -> (U (List Nat String String) (List 'raised String))
(define (shape a)
  (if (answer? a) (list (answer-status a) (answer-header a "content-type") (code-of a)) a))

(define w1 (node-world "one.db"))
(define node-path (string-append "/v1/nodes/" node-id-text))

(test-equal "nodes: GET /v1/nodes with no key is 401 unauthorized in the format, not 404"
  '(401 "application/problem+json" "unauthorized")
  (shape (ask w1 'GET "/v1/nodes" '())))

(define created
  (ask w1 'PUT node-path (list node-key json-h (cons "If-None-Match" "*"))
       (node-body "t" "b")))

(test-equal "nodes: PUT with a key and If-None-Match: * creates, 201, created is the wall clock's time"
  '(201 #t)
  (if (answer? created)
      (list (answer-status created)
            (let ((j (answer-json created)))
              (and (list? j) (equal? (cdr (assoc "created" j)) node-wall))))
      created))

(test-equal "nodes: the GET after it is 200 with the same content"
  '(200 "t" "b" "text/plain" "note")
  (let ((a (ask w1 'GET node-path (list node-key))))
    (if (answer? a)
        (let ((j (answer-json a)))
          (list (answer-status a) (cdr (assoc "title" j)) (cdr (assoc "body" j))
                (cdr (assoc "content_type" j)) (cdr (assoc "kind" j))))
        a)))

(test-equal "nodes: an unknown path under /v1/nodes/ is the 404 in the format"
  '(404 "application/problem+json" "not_found")
  (shape (ask w1 'GET "/v1/nodes/a/b/c/d" (list node-key))))

(test-equal "nodes: PATCH on a node is 405 in the format, its allow naming GET, HEAD, PUT and DELETE"
  '(405 "application/problem+json" "method_not_allowed" "GET, HEAD, PUT, DELETE")
  (let ((a (ask w1 'PATCH node-path (list node-key))))
    (if (answer? a)
        (list (answer-status a) (answer-header a "content-type") (code-of a) (answer-header a "allow"))
        a)))

(test-equal "nodes: DELETE on a node, and a POST to its archive, unarchive, trash and untrash, reach their routes: with no If-Match, 428 precondition_required"
  '((428 "application/problem+json" "precondition_required")
    (428 "application/problem+json" "precondition_required")
    (428 "application/problem+json" "precondition_required")
    (428 "application/problem+json" "precondition_required")
    (428 "application/problem+json" "precondition_required"))
  (list (shape (ask w1 'DELETE node-path (list node-key)))
        (shape (ask w1 'POST (string-append node-path "/archive") (list node-key)))
        (shape (ask w1 'POST (string-append node-path "/unarchive") (list node-key)))
        (shape (ask w1 'POST (string-append node-path "/trash") (list node-key)))
        (shape (ask w1 'POST (string-append node-path "/untrash") (list node-key)))))

(test-equal "nodes: GET on a node's archive is 405, its allow POST"
  '(405 "method_not_allowed" "POST")
  (let ((a (ask w1 'GET (string-append node-path "/archive") (list node-key))))
    (if (answer? a) (list (answer-status a) (code-of a) (answer-header a "allow")) a)))

(test-equal "nodes: a POST to a node's move and move-children reach their routes: with no If-Match, 428 precondition_required"
  '((428 "application/problem+json" "precondition_required")
    (428 "application/problem+json" "precondition_required"))
  (list (shape (ask w1 'POST (string-append node-path "/move") (list node-key json-h)
                    "{\"parent\":null}"))
        (shape (ask w1 'POST (string-append node-path "/move-children") (list node-key json-h)
                    "{\"parent\":null}"))))

(test-equal "nodes: GET on a node's move and move-children is 405, its allow POST"
  '((405 "method_not_allowed" "POST") (405 "method_not_allowed" "POST"))
  (map (lambda (sub)
         (let ((a (ask w1 'GET (string-append node-path sub) (list node-key))))
           (if (answer? a) (list (answer-status a) (code-of a) (answer-header a "allow")) a)))
       '("/move" "/move-children")))

(test-equal "nodes: a move through make-app: 200, the node under its new parent, ETag \"2\"; a bulk move: 200, its counts"
  (list (list 201 201) (list 200 "\"2\"" "0190b3a4-5c6d-7e8f-9a0b-000000000010")
        (list 200 #f '(("moved" . 1) ("left" . 0))))
  (let* ((w (node-world "move.db"))
         (project "/v1/nodes/0190b3a4-5c6d-7e8f-9a0b-000000000010")
         (note "/v1/nodes/0190b3a4-5c6d-7e8f-9a0b-000000000011")
         (create (lambda (path kind)
                   (ask w 'PUT path (list node-key json-h (cons "If-None-Match" "*"))
                        (json->string (list (cons "kind" kind) (cons "title" "t") (cons "body" "b")
                                            (cons "content_type" "text/plain"))))))
         (p (create project "project"))
         (n (create note "note"))
         (m (ask w 'POST (string-append note "/move") (list node-key json-h (cons "If-Match" "\"1\""))
                 "{\"parent\":\"0190b3a4-5c6d-7e8f-9a0b-000000000010\"}"))
         (b (ask w 'POST (string-append project "/move-children")
                 (list node-key json-h (cons "If-Match" "\"1\"")) "{\"parent\":null}")))
    (if (for-all answer? (list p n m b))
        (list (list (answer-status p) (answer-status n))
              (list (answer-status m) (answer-header m "etag")
                    (let ((j (answer-json m))) (and (list? j) (assoc "parent" j) (cdr (assoc "parent" j)))))
              (list (answer-status b) (answer-header b "etag") (answer-json b)))
        (list p n m b))))

(test-equal "nodes: a node's links reach their routes through make-app: a PUT 201 with the link, a second 200, the list 200 with its one item, a DELETE 204; POST on one link is 405, its allow PUT, DELETE; PUT on the list 405, its allow GET, HEAD"
  (list (list 201 201)
        (list 201 '(("source" . "0190b3a4-5c6d-7e8f-9a0b-000000000010") ("type" . "related")
                    ("target" . "0190b3a4-5c6d-7e8f-9a0b-000000000011") ("created" . 1795515226123)))
        200
        (list 200 "related" "0190b3a4-5c6d-7e8f-9a0b-000000000011")
        204
        (list 405 "method_not_allowed" "PUT, DELETE")
        (list 405 "method_not_allowed" "GET, HEAD"))
  (let* ((w (node-world "links.db"))
         (source "/v1/nodes/0190b3a4-5c6d-7e8f-9a0b-000000000010")
         (target "/v1/nodes/0190b3a4-5c6d-7e8f-9a0b-000000000011")
         (link (string-append source "/links/related/0190b3a4-5c6d-7e8f-9a0b-000000000011"))
         (create (lambda (path)
                   (ask w 'PUT path (list node-key json-h (cons "If-None-Match" "*"))
                        (node-body "t" "b"))))
         (s (create source))
         (t (create target))
         (a (ask w 'PUT link (list node-key)))
         (b (ask w 'PUT link (list node-key)))
         (l (ask w 'GET (string-append source "/links") (list node-key)))
         (d (ask w 'DELETE link (list node-key)))
         (p (ask w 'POST link (list node-key)))
         (q (ask w 'PUT (string-append source "/links") (list node-key))))
    (if (for-all answer? (list s t a b l d p q))
        (let ((item (let ((j (answer-json l)))
                      (and (list? j) (assoc "items" j) (vector? (cdr (assoc "items" j)))
                           (= (vector-length (cdr (assoc "items" j))) 1)
                           (vector-ref (cdr (assoc "items" j)) 0))))
              (allowed (lambda (a) (list (answer-status a) (code-of a) (answer-header a "allow")))))
          (list (list (answer-status s) (answer-status t))
                (list (answer-status a) (answer-json a))
                (answer-status b)
                (list (answer-status l)
                      (and item (cdr (assoc "type" item)))
                      (and item (cdr (assoc "id" (cdr (assoc "node" item))))))
                (answer-status d)
                (allowed p)
                (allowed q)))
        (list s t a b l d p q))))

(test-equal "nodes: a stale If-Match is 412 precondition_failed, application/problem+json"
  '(412 "application/problem+json" "precondition_failed")
  (shape (ask w1 'PUT node-path (list node-key json-h (cons "If-Match" "\"7\""))
              (node-body "t2" "b2"))))

(test-equal "nodes: a PUT with neither If-Match nor If-None-Match is 428 precondition_required"
  '(428 "application/problem+json" "precondition_required")
  (shape (ask w1 'PUT node-path (list node-key json-h) (node-body "t2" "b2"))))

(test-equal "nodes: the request log's line for a node write holds no title or body, and shows the account"
  '(201 #t #f)
  (let* ((w (node-world "log.db"))
         (a (ask w 'PUT "/v1/nodes/0190b3a4-5c6d-7e8f-9a0b-000000000002"
                 (list node-key json-h (cons "If-None-Match" "*"))
                 (node-body (string-append "title " marker) (string-append "body " marker)))))
    (if (answer? a)
        (let ((line (car ((cadr w)))))
          (list (answer-status a)
                (contains? line (string-append "account="
                                               (uuid->string (bytevector->uuid node-acct))))
                (contains? line marker)))
        a)))

;;; the node libraries' imports

(test-equal "imports: (techo node-store) takes tx-execute!, tx-query and tx-query-row from the doorway, nothing more"
  '(tx-execute! tx-query tx-query-row)
  (attempt (lambda () (doorway-visible "src/techo/node-store.sls"))))

(test-equal "imports: (techo node-routes) takes nothing from the doorway"
  '()
  (attempt (lambda () (doorway-visible "src/techo/node-routes.sls"))))

;; importers-of : (Listof Symbol) -> (Listof String)     the sources importing LIB
(define (importers-of lib)
  (filter (lambda (path)
            (exists (lambda (spec)
                      (let-values (((target visible?) (import-target spec)))
                        (equal? target lib)))
                    (import-specs path)))
          sources))

(test-equal "imports: only (techo node-routes) imports (techo node-store)"
  '("src/techo/node-routes.sls")
  (attempt (lambda () (importers-of '(techo node-store)))))

(test-equal "imports: only (techo app) imports (techo node-routes)"
  '("src/techo/app.sls")
  (attempt (lambda () (importers-of '(techo node-routes)))))

(test-end "app")

(exit (suite-exit-status runner))
