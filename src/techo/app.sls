#!r6rs
;;; (techo app): Techo's HTTP handler, a circuit handler built from circuit's
;;; router, and the middlewares around it, in their order. It reads no
;;; clock, no entropy and no environment of its own: they are arguments.
(library (techo app)
  (export make-app wrap-app wrap-errors wrap-server request-timeout-ms)
  (import (rnrs)
          (only (chezscheme) real-time)
          (circuit)
          (circuit json)
          (circuit router)
          (circuit worker)
          (circuit middleware waits)
          (only (techo doorway) wrap-db db-retry-after)
          (only (techo errors) problem-res status-problem-res)
          (only (techo log) wrap-request-log)
          (only (techo routes) key-routes))

  ;; Runner = ((Tx -> Any) -> Any)
  ;; Clock = (-> Integer)

  ;; request-timeout-ms : Natural
  ;; A request's deadline, 10 seconds: above the connection's busy timeout (5
  ;; seconds), so a write that lost the lock is answered 503, not 504 (D8).
  (define request-timeout-ms 10000)

  ;; health : Req -> Res
  (define (health req)
    (make-json-res 200 '(("status" . "ok"))))

  ;; not-found : Req -> Res
  (define (not-found req) (problem-res 'not_found))

  ;; make-app : Runner Runner (-> Natural) (Natural -> Bytevector) [Clock] -> Handler
  ;; A handler from a request to a response: /health, free of the database,
  ;; and D9's key routes under /v1. READ and WRITE each run one job: the
  ;; program makes them from db-read and db-write and its doorway, a test
  ;; gives its own. WALL-CLOCK is the time of day in whole milliseconds since
  ;; 1970, UTC; RANDOM-BYTES gives N random bytes; CLOCK reads milliseconds
  ;; for a job's db_ms, real-time by default. No such route is a 404 in the
  ;; format. HEAD and 405 (with its allow header) are the router's own; its
  ;; bare 400 and 405 get the format from wrap-errors.
  (define make-app
    (case-lambda
      ((read write wall-clock random-bytes)
       (make-app read write wall-clock random-bytes real-time))
      ((read write wall-clock random-bytes clock)
       (for-each (lambda (p)
                   (unless (procedure? p)
                     (assertion-violation 'make-app "runners, clocks and random-bytes are procedures"
                                          p)))
                 (list read write wall-clock random-bytes clock))
       (make-router
        (cons (route "/health" (GET health))
              (key-routes read write wall-clock random-bytes clock))
        not-found))))

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

  ;; ascii-downcase : String -> String
  (define (ascii-downcase s)
    (list->string (map (lambda (c) (if (char<=? #\A c #\Z)
                                       (integer->char (+ (char->integer c) 32))
                                       c))
                       (string->list s))))

  ;; problem-type? : (U String #f) -> Boolean
  ;; Whether a content-type field's media type, its parameters and the
  ;; spaces before them left off, is application/problem+json, in any case.
  (define (problem-type? value)
    (and value
         (let* ((n (string-length value))
                (end (let loop ((i 0))
                       (if (or (= i n) (char=? (string-ref value i) #\;)) i (loop (+ i 1)))))
                (end (let trim ((e end))
                       (if (and (> e 0) (memv (string-ref value (- e 1)) '(#\space #\tab)))
                           (trim (- e 1))
                           e))))
           (string=? (ascii-downcase (substring value 0 end)) "application/problem+json"))))

  ;; wrap-errors : Handler -> Handler
  ;; D7's outer middleware. An answer of 400 or more whose content type is
  ;; not application/problem+json gets the format's body for its status
  ;; (status-problem-res: status->code's code, `error` where it has none),
  ;; keeping every header but content-type and content-length, so allow and
  ;; retry-after stay, and a 401 gets www-authenticate: Bearer when it has
  ;; none. The status is never changed. The old body is dropped, its port
  ;; closed when it holds one (res-with-body closes it), a streamed or sized
  ;; body's too. A HEAD is answered as its GET: the server sends the head,
  ;; its content-length the body's, and no body. Anything else, an answer
  ;; already in the format among it, is passed as it is. A raise goes on.
  ;; A handler that is no procedure is an assertion violation.
  (define (wrap-errors handler)
    (unless (procedure? handler)
      (assertion-violation 'wrap-errors "a handler is a procedure" handler))
    (lambda (req)
      (let ((res (handler req)))
        (if (and (res? res)
                 (>= (res-status res) 400)
                 (not (problem-type? (res-header res "content-type"))))
            (begin
              (res-with-body res #f)
              (status-problem-res (res-status res) (res-headers res)))
            res))))

  ;; wrap-server : Handler (String -> Void) [Natural [Clock]] -> Handler
  ;; What the server runs: HANDLER inside wrap-app (LOG for wrap-db's lines,
  ;; TIMEOUT-MS as wrap-app takes it), then wrap-request-log (LOG for its
  ;; lines, CLOCK for ms, real-time by default), then wrap-errors
  ;; outermost. As wrap takes them, innermost first:
  ;;   (wrap router (wrap-db log) (wrap-busy 5) wrap-catch (wrap-timeout ms)
  ;;         wrap-request-log wrap-errors)
  ;; So the log sees the 500, 503 and 504 the client gets, and wrap-errors,
  ;; which never changes a status, cannot make its line wrong. LOG gets each
  ;; line without its newline.
  (define wrap-server
    (case-lambda
      ((handler log) (wrap-server handler log request-timeout-ms real-time))
      ((handler log timeout-ms) (wrap-server handler log timeout-ms real-time))
      ((handler log timeout-ms clock)
       (wrap (wrap-app handler log timeout-ms)
             (wrap-request-log log clock)
             wrap-errors))))
)
