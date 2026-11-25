#!r6rs
;;; techo: the server and the admin CLI, one program (ADR-0009).
;;;
;;; The imperative shell. It reads the command line and the environment,
;;; hands both to the pure parsers, (techo cli) and (techo config), and acts
;;; on what they answer. Nothing here decides anything.
;;;
;;; Exit status: 0 when a command ends well, 2 for a command line or an
;;; environment that is refused, 1 for a database that a command refuses or
;;; cannot use (ADR-0012), and for a `user` command that is refused. Refusals go to standard error, and
;;; nothing listens before the environment and the database are accepted.
;;; Without libsodium every command, `help` and `version` too, ends before
;;; its first line with chez-sodium's own message and status 255: this
;;; program imports its verbs (slice 3's plan, "Smaller choices").
(import (rnrs)
        (only (chezscheme) getenv current-time time-second time-nanosecond)
        (only (chez-sodium) random-bytes)
        (only (circuit http-server) run-server)
        (techo cli)
        (techo config)
        (techo db)
        (techo doorway)
        (techo migrations)
        (techo serve)
        (only (techo hasher) hasher-open! hasher-stop!)
        (only (techo users) user-add-command! user-password-command!)
        (only (techo wiring) id-source sodium-hasher program-login-kit program-app
              program-server program-user-kit)
        (techo version))

;; say : TextualOutputPort String ... -> Void
(define (say port . strings)
  (for-each (lambda (s) (put-string port s)) strings)
  (newline port)
  (flush-output-port port))

;; usage! : String -> [exits]
;; An empty message is a request for help: the usage, on standard output,
;; and 0. Any other is a refusal: the message and the usage, on standard
;; error, and 2.
(define (usage! message)
  (if (string=? message "")
      (begin (put-string (current-output-port) usage-text)
             (flush-output-port (current-output-port))
             (exit 0))
      (begin (say (current-error-port) "techo: " message)
             (put-string (current-error-port) usage-text)
             (flush-output-port (current-error-port))
             (exit 2))))

;; config! : -> Config
;; Techo's own settings. A refused environment prints the problems on standard
;; error and exits 2.
(define (config!)
  (let-values (((config problems) (read-config getenv)))
    (unless config
      (for-each (lambda (p) (say (current-error-port) "techo: " (problem->string p)))
                problems)
      (exit 2))
    config))

;; migrate-command! : -> [exits]
;; `techo migrate`: the run's progress lines (a conversion, each migration
;; applied) on standard output; its ending line or lines there too when the
;; run ended well, else on standard error with "techo: ". Exits by the
;; result's status. No observer is passed.
(define (migrate-command!)
  (let* ((config (config!))
         (result (migrate! (config-db-path config) migrations))
         (status (result->exit-status result)))
    (for-each (lambda (line) (say (current-output-port) line))
              (result->progress-lines result))
    (for-each (lambda (line)
                (if (= status 0)
                    (say (current-output-port) line)
                    (say (current-error-port) "techo: " line)))
              (result->ending-lines result))
    (exit status)))

;; wall-clock : -> Natural
;; The time of day in whole milliseconds since 1970, UTC: a row's times
;; (D15). Durations use (techo wiring)'s duration-clock instead.
(define (wall-clock)
  (let ((t (current-time 'time-utc)))
    (+ (* (time-second t) 1000) (div (time-nanosecond t) 1000000))))

;; serve! : -> [does not return until the server has stopped]
;; Techo's settings, then machine 3 (ADR-0013) in (techo serve): the database
;; check, the write thread, the read threads, the server, and the stops in
;; the reverse order. The loop decides nothing and calls no `exit`: this
;; prints what it lists on standard error, then exits with its status (0, 1
;; for a database refused or an error, 2 for settings the server refuses).
;; The server's host and port are chez-http-server's own variables,
;; CHEZ_HTTP_HOST and CHEZ_HTTP_PORT, which run-server reads.
;;
;; The app gets its two job runners, made here from db-read and db-write
;; and the doorway, so no route reaches the doorway by another way; the
;; wall clock; chez-sodium's random-bytes; and login's kit, which (techo
;; wiring) builds: the hasher's three calls (one thread, which machine 3
;; opens after the writer and stops before it), the rate limiter, the
;; count of proxies in front and the ids. program-server puts the request
;; log, with the client's address by that same count, and the error format
;; around it; stdout-log! writes both kinds of
;; line, each in one write, from the loop's thread.
(define (serve!)
  (let* ((config (config!))
         (doorway (make-doorway (config-db-path config) (config-db-readers config)
                                migrations))
         (reader (lambda (job) (db-read doorway job)))
         (writer (lambda (job) (db-write doorway job)))
         (hasher (sodium-hasher random-bytes))
         (kit (program-login-kit hasher (config-behind-proxy config)
                                 (id-source wall-clock random-bytes) stdout-log!)))
    (let-values (((status prints)
                  (serve-loop (config-db-path config) migrations doorway
                              (lambda ()
                                (run-server
                                 (program-server
                                  (program-app reader writer wall-clock random-bytes kit)
                                  stdout-log!
                                  (config-behind-proxy config))))
                              (lambda () (hasher-open! hasher))
                              (lambda () (hasher-stop! hasher)))))
      (print-serve-ends! (current-error-port) prints)
      (exit status))))

;; user-kit! : -> UserKit
;; What the `user` commands need, from (techo wiring): the settings'
;; database, the migrations, chez-sodium's hash, the wall clock and the ids.
(define (user-kit!)
  (program-user-kit (config-db-path (config!)) migrations wall-clock random-bytes))

(let ((command (parse-command (cdr (command-line)))))
  (cond ((eq? command 'serve) (serve!))
        ((eq? command 'migrate) (migrate-command!))
        ((eq? command 'version) (say (current-output-port) "techo " techo-version))
        ((eq? (car command) 'user-add)
         (exit (user-add-command! (user-kit!) (cadr command) (caddr command))))
        ((eq? (car command) 'user-password)
         (exit (user-password-command! (user-kit!) (cadr command))))
        (else (usage! (cadr command)))))
