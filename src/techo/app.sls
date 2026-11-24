#!r6rs
;;; (techo app): Techo's HTTP handler, a circuit handler built from circuit's
;;; router. It waits for nothing and touches no database, clock or
;;; environment.
(library (techo app)
  (export make-app wrap-app request-timeout-ms)
  (import (rnrs)
          (circuit)
          (circuit json)
          (circuit router)
          (circuit worker)
          (circuit middleware waits)
          (techo doorway))

  ;; request-timeout-ms : Natural
  ;; A request's deadline, 10 seconds: above the connection's busy timeout (5
  ;; seconds), so a write that lost the lock is answered 503, not 504 (D8).
  (define request-timeout-ms 10000)

  ;; health : Req -> Res
  (define (health req)
    (make-json-res 200 '(("status" . "ok"))))

  ;; not-found : Req -> Res
  ;; PROVISIONAL body: the project's one error format is designed in a
  ;; later slice, and this answer changes with it.
  (define (not-found req)
    (make-json-res 404 '(("error" . "not_found"))))

  ;; make-app : Doorway -> Handler
  ;; A handler from a request to a response. HEAD and 405 (with its allow
  ;; header) are the router's own. DOORWAY is where the route handlers will
  ;; reach SQLite, by db-write and db-read; no route uses it yet, and /health
  ;; stays free of the database.
  (define (make-app doorway)
    (make-router
     (list (route "/health" (GET health)))
     not-found))

  ;; wrap-app : Handler (String -> Void) [Natural] -> Handler
  ;; HANDLER inside the stack, innermost first: wrap-db (an unavailable
  ;; database is a 503, its reason logged once by LOG), wrap-busy (a full or
  ;; stopped worker is a 503), wrap-catch (any other raise is a 500), and
  ;; wrap-timeout outermost (a request is a 504 after TIMEOUT-MS, by default
  ;; request-timeout-ms). wrap-busy and wrap-db sit inside wrap-catch, or it
  ;; would answer their raises as 500s. LOG gets one line without its
  ;; newline. The optional timeout is for the layer 5 test server, which
  ;; needs a short one; the program never passes it.
  (define wrap-app
    (case-lambda
      ((handler log) (wrap-app handler log request-timeout-ms))
      ((handler log timeout-ms)
       (wrap handler
             (wrap-db log)
             (wrap-busy db-retry-after)
             wrap-catch
             (wrap-timeout timeout-ms)))))
)
