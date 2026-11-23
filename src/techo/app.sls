#!r6rs
;;; (techo app): Techo's HTTP handler, a circuit handler built from circuit's
;;; router. It waits for nothing and touches no database, clock or
;;; environment.
(library (techo app)
  (export make-app)
  (import (rnrs) (circuit) (circuit json) (circuit router))

  ;; health : Req -> Res
  (define (health req)
    (make-json-res 200 '(("status" . "ok"))))

  ;; not-found : Req -> Res
  ;; PROVISIONAL body: the project's one error format is designed in a
  ;; later slice, and this answer changes with it.
  (define (not-found req)
    (make-json-res 404 '(("error" . "not_found"))))

  ;; make-app : -> Handler
  ;; A handler from a request to a response. HEAD and 405 (with its allow
  ;; header) are the router's own. Later slices pass an argument, such as a
  ;; database doorway, which the route handlers close over.
  (define (make-app)
    (make-router
     (list (route "/health" (GET health)))
     not-found))
)
