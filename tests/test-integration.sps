#!r6rs
;;; The integration suite: `techo serve` as a child process, called over
;;; loopback with chez-curl, and the program's command line.
;;;
;;;   serve    starts on CHEZ_HTTP_PORT=0, prints `listening <host> <port>`;
;;;            GET /health 200 JSON; GET /nope 404; SIGTERM: `stopped`, 0
;;;   cli      version, help, no arguments, an unknown command, and serve with a missing
;;;            or a relative TECHO_DB_PATH: each one's stream and exit status
;;;
;;; One Chez process is single-threaded here, so the server is a child. A
;;; child is a shell command run in the background, its stdout and stderr
;;; sent to files in a fresh temporary directory, and its pid and exit
;;; status written there too. The suite polls those files against a
;;; deadline, so nothing it waits for can hang it. Every observation is made
;;; under `attempt` first; the tests compare what was seen. The child is
;;; killed and the directory removed however the observing ends.
;;;
;;; The Chez binary is $CHEZ (make exports it), else `scheme`; the library
;;; path is the one this process runs with, (library-directories).
(import (rnrs)
        (srfi :64)
        (only (chezscheme) system process getenv real-time sleep make-time
                           library-directories)
        (techo-testing)
        (techo cli)
        (http-client)
        (jsonparse easy))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; --- shell ---------------------------------------------------------------

;; quote : String -> String
;; One shell word: single-quoted.
(define (quote-word s)
  (string-append
   "'"
   (apply string-append
          (map (lambda (c) (if (char=? c #\') "'\\''" (string c)))
               (string->list s)))
   "'"))

;; join : (Listof String) String -> String
(define (join strs sep)
  (if (null? strs)
      ""
      (fold-left (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))

;; sh : String ... -> Integer
(define (sh . parts) (system (apply string-append parts)))

;; make-temp-dir : -> String
(define (make-temp-dir)
  (let* ((ports (process "mktemp -d"))
         (line (get-line (car ports))))
    (close-port (car ports))
    (close-port (cadr ports))
    (if (and (string? line) (> (string-length line) 1) (char=? (string-ref line 0) #\/))
        line
        (error 'make-temp-dir "mktemp -d answered no absolute path" line))))

;; file-text : String -> String
;; The file's text; "" when it is not there yet.
(define (file-text path)
  (guard (e (#t ""))
    (call-with-input-file path
      (lambda (p) (let ((s (get-string-all p))) (if (eof-object? s) "" s))))))

;; split-lines : String -> (Listof String)
(define (split-lines s)
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (cond ((null? cs) (reverse (if (null? cur) acc (cons (list->string (reverse cur)) acc))))
          ((char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

;; split-words : String -> (Listof String)
(define (split-words s)
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (define (flush) (if (null? cur) acc (cons (list->string (reverse cur)) acc)))
    (cond ((null? cs) (reverse (flush)))
          ((char=? (car cs) #\space) (loop (cdr cs) '() (flush)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

;; contains? : String String -> Boolean
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

;; poll : Nat (-> (U A #f)) -> (U A #f)
;; THUNK's first true answer, trying every 20 ms, or #f after MS.
(define (poll ms thunk)
  (let ((stop (+ (real-time) ms)))
    (let loop ()
      (or (thunk)
          (and (< (real-time) stop)
               (begin (sleep (make-time 'time-duration 20000000 0))
                      (loop)))))))

;; --- children ------------------------------------------------------------

;; chez : -> String
(define (chez)
  (let ((c (getenv "CHEZ")))
    (if (and c (> (string-length c) 0)) c "scheme")))

;; libdirs : -> String
(define (libdirs) (join (map car (library-directories)) ":"))

;; A child: where its files are.
(define-record-type child (fields dir name))

;; child-file : Child String -> String
(define (child-file c ext)
  (string-append (child-dir c) "/" (child-name c) "." ext))

;; spawn : String String (Listof String) (Listof String) (Listof String) -> Child
;; Runs techo ARGS in the background in DIR, as NAME: with the variables in
;; UNSET removed from its environment and those in SET (NAME=value) added.
;; Its pid is written to NAME.pid and, when it ends, its status to NAME.status.
(define (spawn dir name unset set args)
  (let* ((c (make-child dir name))
         (out (quote-word (child-file c "out")))
         (err (quote-word (child-file c "err")))
         (pid (quote-word (child-file c "pid")))
         (st (quote-word (child-file c "status")))
         (cmd (join (append
                     (list "env")
                     (apply append (map (lambda (v) (list "-u" v)) unset))
                     ;; The host first, so a CHEZ_HTTP_HOST from the caller's
                     ;; environment cannot move the server off 127.0.0.1.
                     (map quote-word (cons "CHEZ_HTTP_HOST=127.0.0.1" set))
                     (list (quote-word (chez)) "--libdirs" (quote-word (libdirs))
                           "--program" "techo.sps")
                     (map quote-word args))
                    " ")))
    (sh "( " cmd " >" out " 2>" err " </dev/null & echo $! >" pid
        "; wait $!; echo $? >" st ".tmp; mv " st ".tmp " st
        " ) >/dev/null 2>&1 &")
    c))

;; child-pid : Child -> (U String #f)
(define (child-pid c)
  (let ((s (file-text (child-file c "pid"))))
    (and (> (string-length s) 0) (car (split-lines s)))))

;; child-status : Child -> (U Integer #f)
(define (child-status c)
  (let ((s (file-text (child-file c "status"))))
    (and (> (string-length s) 0) (string->number (car (split-lines s))))))

;; await-status : Child Nat -> (U Integer 'no-exit)
(define (await-status c ms)
  (or (poll ms (lambda () (child-status c))) 'no-exit))

;; signal! : Child String -> Void
(define (signal! c sig)
  (let ((pid (poll 2000 (lambda () (child-pid c)))))
    (when pid (sh "kill -" sig " " pid " >/dev/null 2>&1"))))

;; kill! : Child -> Void
;; Whatever state it is in: no error when it has ended.
(define (kill! c)
  (let ((pid (child-pid c)))
    ;; Not once it has reported its status: the pid may be another's by now.
    (when (and pid (not (file-exists? (child-file c "status"))))
      (sh "kill -KILL " pid " >/dev/null 2>&1"))))

;; run-cli : String (Listof String) (Listof String) (Listof String)
;;           -> (List (U Integer 'no-exit) String String)
;; Status, stdout and stderr of a child that ends on its own, within 20 s.
(define (run-cli dir name unset set args)
  (let* ((c (spawn dir name unset set args))
         (status (await-status c 20000)))
    (unless (integer? status) (kill! c))
    (list status
          (file-text (child-file c "out"))
          (file-text (child-file c "err")))))

;; --- observing -----------------------------------------------------------

(define deadline-ms 20000)

;; listening-port : Child -> (U Nat 'no-listening-line)
(define (listening-port c)
  (or (poll deadline-ms
            (lambda ()
              (let loop ((ls (split-lines (file-text (child-file c "out")))))
                (cond ((null? ls) #f)
                      ((and (contains? (car ls) "listening ")
                            (= (length (split-words (car ls))) 3))
                       (string->number (caddr (split-words (car ls)))))
                      (else (loop (cdr ls)))))))
      'no-listening-line))

;; header-of : Response String -> (U String #f)
(define (header-of resp name) (http-response-header resp name))

;; get : Nat String -> (List Nat (U String #f) Any)
;; Status, content-type and the body parsed as JSON.
(define (get port path)
  (call-with-http-session 'timeout-ms 10000
    (lambda (session)
      (let ((r (http-get session (string-append "http://127.0.0.1:"
                                                (number->string port) path))))
        (list (http-response-status r)
              (header-of r "content-type")
              (string->json (http-response-text r)))))))

;; The observations. Each is a value, or an `attempt`'s raised sentinel.
(define serve-port #f)
(define health #f)
(define nope #f)
(define serve-exit #f)
(define serve-out #f)
(define serve-err #f)
(define cli-version #f)
(define cli-none #f)
(define cli-help #f)
(define cli-bogus #f)
(define cli-no-db #f)
(define cli-empty-db #f)
(define cli-relative-db #f)
(define cli-bad-port #f)

;; observe! : -> Void
(define (observe! dir)
  (let ((db (string-append dir "/techo.db")))
    ;; The server.
    (let ((server (spawn dir "serve" '() (list "CHEZ_HTTP_PORT=0"
                                               (string-append "TECHO_DB_PATH=" db))
                         '("serve"))))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (set! serve-port (attempt (lambda () (listening-port server))))
          (when (integer? serve-port)
            (set! health (attempt (lambda () (get serve-port "/health"))))
            (set! nope (attempt (lambda () (get serve-port "/nope")))))
          (signal! server "TERM")
          (set! serve-exit (attempt (lambda () (await-status server deadline-ms))))
          (set! serve-out (file-text (child-file server "out")))
          (set! serve-err (file-text (child-file server "err"))))
        (lambda () (kill! server))))
    ;; The command line.
    (set! cli-version (attempt (lambda () (run-cli dir "version" '() '() '("version")))))
    (set! cli-none (attempt (lambda () (run-cli dir "none" '() '() '()))))
    (set! cli-help (attempt (lambda () (run-cli dir "help" '() '() '("help")))))
    (set! cli-bogus (attempt (lambda () (run-cli dir "bogus" '() '() '("bogus")))))
    (set! cli-no-db (attempt (lambda () (run-cli dir "nodb" '("TECHO_DB_PATH") '() '("serve")))))
    (set! cli-empty-db (attempt (lambda () (run-cli dir "emptydb" '() '("TECHO_DB_PATH=") '("serve")))))
    (set! cli-relative-db
          (attempt (lambda ()
                     (run-cli dir "reldb" '() '("TECHO_DB_PATH=relative/techo.db") '("serve")))))
    (set! cli-bad-port
          (attempt (lambda ()
                     (run-cli dir "badport" '()
                              (list "CHEZ_HTTP_PORT=abc" (string-append "TECHO_DB_PATH=" db))
                              '("serve")))))))

;; The temporary directory goes however observing ends.
(let ((dir (attempt make-temp-dir)))
  (if (string? dir)
      (dynamic-wind
        (lambda () #f)
        (lambda () (guard (e (#t (set! serve-port (list 'raised (describe e))))) (observe! dir)))
        (lambda () (sh "rm -rf " (quote-word dir))))
      (set! serve-port dir)))

;; --- tests ---------------------------------------------------------------

;; status-of, out-of, err-of : (U (List ...) raised) -> Any
(define (status-of r) (if (and (pair? r) (not (eq? (car r) 'raised))) (car r) r))
(define (out-of r) (if (and (pair? r) (not (eq? (car r) 'raised))) (cadr r) r))
(define (err-of r) (if (and (pair? r) (not (eq? (car r) 'raised))) (caddr r) r))

;; port-ok : Any -> (U #t Any)
(define (port-ok p) (if (and (integer? p) (> p 0)) #t p))

(test-begin "integration")

(test-equal "serve: prints `listening <host> <port>` with a real port"
  #t (port-ok serve-port))

(test-equal "serve: GET /health is 200"
  200 (if (pair? health) (car health) health))

(test-equal "serve: GET /health content-type is application/json"
  "application/json" (if (pair? health) (cadr health) health))

(test-equal "serve: GET /health body is {\"status\":\"ok\"}"
  '(("status" . "ok")) (if (pair? health) (caddr health) health))

(test-equal "serve: GET /nope is 404"
  404 (if (pair? nope) (car nope) nope))

(test-equal "serve: GET /nope body is {\"error\":\"not_found\"}"
  '(("error" . "not_found")) (if (pair? nope) (caddr nope) nope))

(test-equal "serve: SIGTERM ends it with status 0 within the deadline"
  0 serve-exit)

(test-equal "serve: SIGTERM prints `draining 0` then `stopped`"
  '("draining 0" "stopped")
  (let ((ls (split-lines serve-out)))
    (filter (lambda (l) (or (string=? l "draining 0") (string=? l "stopped"))) ls)))

(test-equal "version: exit 0"
  0 (status-of cli-version))
(test-equal "version: stdout is `techo 0.0.0`"
  "techo 0.0.0\n" (out-of cli-version))
(test-equal "version: stderr is empty"
  "" (err-of cli-version))

(test-equal "no arguments: exit 2 (a refusal, as `bogus` is)"
  2 (status-of cli-none))
(test-equal "no arguments: stderr names the missing command and has the usage"
  '(#t #t) (let ((e (err-of cli-none)))
             (if (string? e)
                 (list (contains? e "no command given") (contains? e usage-text))
                 (list e e))))
(test-equal "no arguments: stdout is empty"
  "" (out-of cli-none))

(test-equal "help: exit 0 and usage on stdout"
  (list 0 usage-text) (list (status-of cli-help) (out-of cli-help)))

(test-equal "bogus: exit 2"
  2 (status-of cli-bogus))
(test-equal "bogus: stdout is empty"
  "" (out-of cli-bogus))
(test-equal "bogus: stderr has the usage"
  #t (let ((e (err-of cli-bogus))) (if (string? e) (contains? e usage-text) e)))

(test-equal "serve without TECHO_DB_PATH: exit 2"
  2 (status-of cli-no-db))
(test-equal "serve without TECHO_DB_PATH: stderr names TECHO_DB_PATH, stdout is empty"
  '(#t "") (let ((e (err-of cli-no-db)))
             (list (if (string? e) (contains? e "TECHO_DB_PATH") e) (out-of cli-no-db))))

(test-equal "serve with an empty TECHO_DB_PATH: exit 2, stderr names it"
  '(2 #t) (list (status-of cli-empty-db)
                (let ((e (err-of cli-empty-db)))
                  (if (string? e) (contains? e "TECHO_DB_PATH") e))))

(test-equal "serve with a relative TECHO_DB_PATH: exit 2"
  2 (status-of cli-relative-db))
(test-equal "serve with a relative TECHO_DB_PATH: stderr names it, stdout is empty"
  '(#t "") (let ((e (err-of cli-relative-db)))
             (list (if (string? e) (contains? e "TECHO_DB_PATH") e) (out-of cli-relative-db))))

(test-equal "serve with a relative TECHO_DB_PATH: stderr does not repeat the value"
  #f (let ((e (err-of cli-relative-db)))
       (if (string? e) (contains? e "relative/techo.db") e)))

(test-equal "serve with a bad CHEZ_HTTP_PORT: exit 2"
  2 (status-of cli-bad-port))
(test-equal "serve with a bad CHEZ_HTTP_PORT: a techo: line names it, stdout is empty"
  '(#t #t "") (let ((e (err-of cli-bad-port)))
                (list (if (string? e) (contains? e "techo: ") e)
                      (if (string? e) (contains? e "CHEZ_HTTP_PORT") e)
                      (out-of cli-bad-port))))

(test-end "integration")

(exit (suite-exit-status runner))
