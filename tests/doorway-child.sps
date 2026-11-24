#!r6rs
;;; A test program, not a suite: a server on the REAL doorway and the real
;;; `wrap-app`, with a table of its own made by the fixture migrations, for
;;; tests/test-doorway-threads.sps (layer 5 of slice 2b).
;;;
;;;   doorway-child.sps
;;;
;;; The file must be current already: the suite prepares it with `migrate!`
;;; and (migrations-fixture)'s list, which this program checks it against.
;;; It runs machine 3's own loop, (techo serve)'s `serve-loop`, so its stop
;;; order is the program's. Settings come from the environment:
;;;
;;;   CHILD_DB         the database file (an absolute path)
;;;   CHILD_WCAP       the write queue's cap, default 64
;;;   CHILD_READERS    the read threads, default 2
;;;   CHILD_TIMEOUT    a request's timeout in ms, default the program's own
;;;   CHEZ_HTTP_*      the server's own (host, port, drain timeout)
;;;
;;; Routes (a job may not wait in production; here some do, on purpose, by
;;; sleeping on the worker thread). TAG is `tag=` in the query, default "x":
;;;
;;;   POST /add         one row, TAG; logs "write TAG" first
;;;   POST /add2        two rows in one job, TAG-1 and TAG-2
;;;   GET  /count       the row count, a read
;;;   GET  /rows        the bodies in order, joined by commas, a read
;;;   POST /hold        a write job: row TAG-1, line "held TAG", a sleep of
;;;                     `ms=` milliseconds, with `rows=2` a row TAG-2, line
;;;                     "released TAG"
;;;   POST /half        a write job: row TAG-1, then a raise (a 500)
;;;   GET  /health      the app's own, no database
;;;
;;; Every log line goes to standard output, with its newline, in one write.
(import (rnrs)
        (only (chezscheme) getenv sleep make-time)
        (circuit)
        (circuit params)
        (circuit router)
        (only (circuit http-server) run-server)
        (only (circuit request) req-path)
        (migrations-fixture)
        (techo app)
        (techo doorway)
        (techo serve))

;; env : String String -> String
(define (env name default)
  (let ((v (getenv name))) (if (and v (> (string-length v) 0)) v default)))

;; ms-sleep : Natural -> Void
(define (ms-sleep n)
  (sleep (make-time 'time-duration (* (mod n 1000) 1000000) (div n 1000))))

;; text : Natural String -> Res
(define (text status s)
  (make-res status '(("content-type" . "text/plain")) s))

;; param : Req String String -> String
(define (param req name default)
  (or (param-value (req-query-params req) name) default))

;; num-param : Req String Natural -> Natural
(define (num-param req name default)
  (or (string->number (param req name (number->string default))) default))

(define insert-sql "INSERT INTO notes (body) VALUES (?)")

;; routes : Doorway -> Handler
(define (routes d)
  (define (add req)
    (let ((tag (param req "tag" "x")))
      ;; In the loop's thread, with no wait before db-write queues the job:
      ;; a request sent after this line is behind the job.
      (stdout-log! (string-append "write " tag))
      (db-write d (lambda (tx) (tx-execute! tx insert-sql tag)))
      (text 200 "added\n")))
  (define (add2 req)
    (let ((tag (param req "tag" "x")))
      (stdout-log! (string-append "write " tag))
      (db-write d (lambda (tx)
                    (tx-execute! tx insert-sql (string-append tag "-1"))
                    (tx-execute! tx insert-sql (string-append tag "-2"))))
      (text 200 "added\n")))
  (define (count req)
    (let ((n (db-read d (lambda (tx)
                          (vector-ref (tx-query-row tx "SELECT count(*) FROM notes") 0)))))
      (text 200 (string-append (number->string n) "\n"))))
  (define (rows req)
    (let ((bodies (db-read d (lambda (tx)
                               (map (lambda (r) (vector-ref r 0))
                                    (tx-query tx "SELECT body FROM notes ORDER BY id"))))))
      (text 200 (string-append
                 (if (null? bodies)
                     ""
                     (fold-left (lambda (acc b) (string-append acc "," b))
                                (car bodies) (cdr bodies)))
                 "\n"))))
  (define (hold req)
    (let ((tag (param req "tag" "x"))
          (ms (num-param req "ms" 0))
          (two? (= (num-param req "rows" 1) 2)))
      (db-write d (lambda (tx)
                    (tx-execute! tx insert-sql (string-append tag "-1"))
                    (stdout-log! (string-append "held " tag))
                    (ms-sleep ms)
                    (when two?
                      (tx-execute! tx insert-sql (string-append tag "-2")))
                    (stdout-log! (string-append "released " tag))))
      (text 200 "held\n")))
  (define (half req)
    (let ((tag (param req "tag" "x")))
      (db-write d (lambda (tx)
                    (tx-execute! tx insert-sql (string-append tag "-1"))
                    (error 'half "the job raises after one row")))
      (text 200 "half\n")))
  (make-router
   (list (route "/add" (POST add))
         (route "/add2" (POST add2))
         (route "/count" (GET count))
         (route "/rows" (GET rows))
         (route "/hold" (POST hold))
         (route "/half" (POST half)))
   (lambda (req) (text 404 "not found\n"))))

(let* ((path (env "CHILD_DB" ""))
       (doorway (make-doorway path
                              (string->number (env "CHILD_READERS" "2"))
                              fixture-migrations
                              (string->number (env "CHILD_WCAP" "64"))
                              64))
       (app (make-app (lambda (job) (db-read doorway job)) (lambda (job) (db-write doorway job))
                      (lambda () 0) (lambda (n) (make-bytevector n 0))))
       (db-routes (routes doorway))
       (handler (lambda (req)
                  (if (string=? (req-path req) "/health") (app req) (db-routes req))))
       (timeout (string->number (env "CHILD_TIMEOUT" "0"))))
  (let-values (((status prints)
                (serve-loop path fixture-migrations doorway
                            (lambda ()
                              (run-server
                               (if (> timeout 0)
                                   (wrap-app handler stdout-log! timeout)
                                   (wrap-app handler stdout-log!)))))))
    (print-serve-ends! (current-error-port) prints)
    (exit status)))
