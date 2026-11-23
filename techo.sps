#!r6rs
;;; techo: the server and the admin CLI, one program (ADR-0009).
;;;
;;; The imperative shell. It reads the command line and the environment,
;;; hands both to the pure parsers, (techo cli) and (techo config), and acts
;;; on what they answer. Nothing here decides anything.
;;;
;;; Exit status: 0 when a command ends well, 2 for a command line or an
;;; environment that is refused, 1 for a database that `migrate` or `serve`
;;; refuses or cannot use (ADR-0012). Refusals go to standard error, and
;;; nothing listens before the environment and the database are accepted.
(import (rnrs)
        (only (chezscheme) getenv)
        (only (circuit http-server) run-server http-server-config-error?)
        (techo app)
        (techo cli)
        (techo config)
        (techo db)
        (techo migrations)
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

;; serve! : -> [does not return until the server stops]
;; Techo's settings, then the database check: a file that is not current and
;; in WAL is refused on standard error and exits 1. Then the server starts.
;; The server's host and port are chez-http-server's own variables,
;; CHEZ_HTTP_HOST and CHEZ_HTTP_PORT, which run-server reads. A value it
;; refuses is reported like one of Techo's own, and exits 2.
(define (serve!)
  (let* ((config (config!))
         (verdict (check-db (config-db-path config) migrations)))
    (unless (eq? verdict 'serve)
      (say (current-error-port) "techo: " (caddr verdict))
      (exit 1))
    (guard (e ((http-server-config-error? e)
               (say (current-error-port) "techo: " (server-config-refusal e))
               (exit 2)))
      (run-server (make-app)))))

(let ((command (parse-command (cdr (command-line)))))
  (cond ((eq? command 'serve) (serve!))
        ((eq? command 'migrate) (migrate-command!))
        ((eq? command 'version) (say (current-output-port) "techo " techo-version))
        (else (usage! (cadr command)))))
