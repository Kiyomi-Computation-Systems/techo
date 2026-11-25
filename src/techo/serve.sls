#!r6rs
;;; (techo serve): machine 3's loop, from start to exit (slice 2b, ADR-0013).
;;;
;;; The imperative shell for (techo transaction)'s `serve-step`. It decides
;;; nothing: it performs the command the table gives, builds the raw outcome,
;;; feeds the event back, and goes on until the table says `end`. It never
;;; calls `exit` itself: in Chez `exit` ends the process at once with its
;;; threads running, which would kill a write and leave the `-wal`. The
;;; caller prints what comes back, then exits with the status.
;;;
;;; `techo.sps` and the layer 5 test server (tests/doorway-child.sps) both
;;; call `serve-loop`, so the test's stop order is the program's. Slice 3b
;;; put the password hasher between the writer and the readers: its open
;;; and stop are two thunks the caller gives, so this library needs no
;;; chez-sodium, and the four-argument form opens a hasher that does
;;; nothing.
(library (techo serve)
  (export serve-loop print-serve-ends! stdout-log! server-config-refusal)
  (import (rnrs)
          (only (circuit http-server) http-server-config-error?)
          (techo db)
          (techo doorway)
          (techo transaction))

  ;; serve-loop : String (Listof Migration) Doorway (-> Any) [(-> Any) (-> Any)]
  ;;              -> (values Integer (Listof (Pair Symbol Any)))
  ;; Runs machine 3. PATH and MIGRATIONS are for the start check. It opens
  ;; the writer, the hasher, then the readers, and stops them the other way
  ;; round. DOORWAY is the writer and the readers; OPEN-HASHER! and
  ;; STOP-HASHER! are the hasher's open and stop, and without them the
  ;; hasher does nothing. RUN! is the server: it returns when the server
  ;; stops. A raise from any of them is an outcome the table sees. Answers
  ;; the exit status and what `serve-prints` lists, in order:
  ;; (line . String), (refused . Any), (raised . Any).
  (define serve-loop
    (case-lambda
      ((path migrations doorway run!)
       (serve-loop path migrations doorway run! nothing nothing))
      ((path migrations doorway run! open-hasher! stop-hasher!)
       (let-values (((state command) (serve-start)))
         (let loop ((state state) (command command))
           (if (eq? (car command) 'end)
               (values (cdr command) (serve-prints state))
               (let* ((raw (perform path migrations doorway run! open-hasher!
                                    stop-hasher! command))
                      (event (cons (serve-event-kind command raw) raw)))
                 (let-values (((next next-command) (serve-step state event)))
                   (loop next next-command)))))))))

  ;; nothing : -> Void    the four-argument form's hasher open and stop
  (define (nothing) (if #f #f))

  ;; perform : String (Listof Migration) Doorway (-> Any) (-> Any) (-> Any)
  ;;           Command -> RawOutcome
  ;; One command's one effect. Every raise from an open, the server or a stop
  ;; becomes an outcome, so the table sees it.
  (define (perform path migrations doorway run! open-hasher! stop-hasher! command)
    (define (attempt! thunk)
      (guard (e (#t (list 'raised e #f)))
        (thunk)
        (list 'ok #t #f)))
    (case (car command)
      ((check) (list 'ok (check-db path migrations) #f))
      ((open-writer) (attempt! (lambda () (doorway-open-writer! doorway))))
      ((open-hasher) (attempt! open-hasher!))
      ((open-readers) (attempt! (lambda () (doorway-open-readers! doorway))))
      ((stop-readers) (attempt! (lambda () (doorway-stop-readers! doorway))))
      ((stop-hasher) (attempt! stop-hasher!))
      ((stop-writer) (attempt! (lambda () (doorway-stop-writer! doorway))))
      ((serve)
       (guard (e ((http-server-config-error? e) (list 'refused e #f))
                 (#t (list 'raised e #f)))
         (run!)
         (list 'returned #t #f)))
      (else (assertion-violation 'serve-loop "not a command" command))))

  ;; server-config-refusal : Condition -> String
  ;; The server's message and the variables it names. Never a variable's
  ;; value: only an irritant that is a CHEZ_HTTP_ name is repeated.
  (define (server-config-refusal e)
    (let ((names (filter (lambda (x)
                           (and (string? x)
                                (>= (string-length x) 10)
                                (string=? (substring x 0 10) "CHEZ_HTTP_")))
                         (if (irritants-condition? e) (condition-irritants e) '()))))
      (apply string-append
             (if (message-condition? e) (condition-message e) "the server refused its settings")
             (map (lambda (n) (string-append " (" n ")")) names))))

  ;; print-serve-ends! : TextualOutputPort (Listof (Pair Symbol Any)) -> Void
  ;; Each print as a line with "techo: ": a line as it is, a refusal by
  ;; `server-config-refusal`, a raise by its message, or, for &db-refused, the
  ;; check's own line. Never a value of a setting.
  (define (print-serve-ends! port prints)
    (for-each
     (lambda (p)
       (put-string port
         (string-append "techo: "
                        (case (car p)
                          ((line) (cdr p))
                          ((refused) (server-config-refusal (cdr p)))
                          (else (raised-text (cdr p))))
                        "\n"))
       (flush-output-port port))
     prints))

  ;; raised-text : Any -> String
  (define (raised-text obj)
    (cond ((db-refused? obj) (db-refused-line obj))
          ((message-condition? obj) (condition-message obj))
          ((condition? obj) "an error ended the server")
          (else "something other than a condition was raised")))

  ;; stdout-log! : String -> Void
  ;; wrap-db's log: LINE and its newline in ONE put-string (so two threads'
  ;; lines cannot run together), then a flush, on standard output.
  (define (stdout-log! line)
    (let ((out (current-output-port)))
      (put-string out (string-append line "\n"))
      (flush-output-port out)))
)
