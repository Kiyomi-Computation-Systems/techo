#!r6rs
;;; The app suite: Techo's HTTP handler, called directly with circuit's
;;; test request constructor. No server, no port.
;;;
;;;   GET /health       200, application/json, {"status":"ok"}
;;;   HEAD /health      what circuit's router does for HEAD on a GET route
;;;   other method      405 with an Allow header, from the router itself
;;;   any other path    404, application/json, {"error":"not_found"}
;;;   (make-app) twice  two handlers that both work
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
        (techo app)
        (techo doorway)
        (only (migrations-fixture) fixture-migrations))

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

;; The app is made with a doorway that has no worker: no route uses it, so it
;; must never be called. A /health that touched it would raise here.
(define never-opened (make-doorway "/nonexistent/never.db" 1 fixture-migrations))
(define app (attempt (lambda () (make-app never-opened))))

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

(test-equal "GET /nowhere: 404, application/json, {\"error\":\"not_found\"}"
  '(404 "application/json" (("error" . "not_found")))
  (summary app 'GET "/nowhere"))

(test-equal "GET /: 404 as JSON"
  '(404 "application/json" (("error" . "not_found")))
  (summary app 'GET "/"))

(test-equal "GET /healthz: 404 as JSON, not the health route"
  '(404 "application/json" (("error" . "not_found")))
  (summary app 'GET "/healthz"))

(test-equal "GET /health/: the trailing slash is another path, 404 as JSON"
  '(404 "application/json" (("error" . "not_found")))
  (summary app 'GET "/health/"))

(test-equal "POST /nowhere: 404 as JSON, whatever the method"
  '(404 "application/json" (("error" . "not_found")))
  (summary app 'POST "/nowhere"))

(test-equal "two (make-app) handlers both answer /health, in any order"
  '((200 "application/json" (("status" . "ok")))
    (200 "application/json" (("status" . "ok")))
    (200 "application/json" (("status" . "ok")))
    (404 "application/json" (("error" . "not_found"))))
  (attempt
   (lambda ()
     (let ((a (make-app never-opened)) (b (make-app never-opened)))
       (list (summary a 'GET "/health")
             (summary b 'GET "/health")
             (summary a 'GET "/health")
             (summary b 'GET "/other"))))))

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

(test-end "app")

(exit (suite-exit-status runner))
