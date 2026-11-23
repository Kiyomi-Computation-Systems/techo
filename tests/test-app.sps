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
        (jsonparse easy)
        (techo app))

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

(define app (attempt make-app))

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
     (let ((a (make-app)) (b (make-app)))
       (list (summary a 'GET "/health")
             (summary b 'GET "/health")
             (summary a 'GET "/health")
             (summary b 'GET "/other"))))))

(test-end "app")

(exit (suite-exit-status runner))
