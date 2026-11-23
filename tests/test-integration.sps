#!r6rs
;;; The integration suite: `techo serve` as a child process, called over
;;; loopback with chez-curl, and the program's command line.
;;;
;;;   serve    starts on CHEZ_HTTP_PORT=0, prints `listening <host> <port>`;
;;;            GET /health 200 JSON; GET /nope 404; SIGTERM: `stopped`, 0
;;;   cli      version, help, no arguments, an unknown command, and serve with a missing
;;;            or a relative TECHO_DB_PATH: each one's stream and exit status
;;;   migrate  `techo migrate` as a child on every kind of file; two at once;
;;;            children killed with `kill -9` inside a migration (clause 6)
;;;            and with a full `-wal` (clause 11); another program's file left
;;;            byte for byte the same; `techo serve` refused on a file that is
;;;            not current and in WAL (ADR-0012, layer 5)
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
                           library-directories file-length)
        (only (chez-sqlite3) open-database close-database! execute! query query-row)
        (techo-testing)
        (techo cli)
        (only (techo db) open-techo-db read-db-facts migrate!)
        (only (techo migrations) techo-application-id)
        (migrations-fixture)
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
;; A fresh directory under build/ (never /tmp), as an absolute path.
(define (make-temp-dir)
  (let* ((ports (process "mkdir -p build && mktemp -d \"$PWD/build/it.XXXXXX\""))
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

;; spawn-program : String String String (Listof String) (Listof String) (Listof String) -> Child
;; Runs the Scheme program PROG with ARGS in the background in DIR, as NAME:
;; with the variables in UNSET removed from its environment and those in SET
;; (NAME=value) added. Its pid is written to NAME.pid and, when it ends, its
;; status to NAME.status.
(define (spawn-program dir name prog unset set args)
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
                           "--program" (quote-word prog))
                     (map quote-word args))
                    " ")))
    (sh "( " cmd " >" out " 2>" err " </dev/null & echo $! >" pid
        "; wait $!; echo $? >" st ".tmp; mv " st ".tmp " st
        " ) >/dev/null 2>&1 &")
    c))

;; spawn : String String (Listof String) (Listof String) (Listof String) -> Child
;; Runs techo ARGS (techo.sps) as spawn-program does.
(define (spawn dir name unset set args)
  (spawn-program dir name "techo.sps" unset set args))

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

;; --- the database files the migrate rows need ----------------------------

;; Every observation is a value, or an `attempt`'s raised sentinel, under a name.
(define observations (make-hashtable string-hash string=?))
(define (obs-set! k v) (hashtable-set! observations k v))
(define (obs k) (hashtable-ref observations k 'unobserved))
(define-syntax observe
  (syntax-rules ()
    ((_ k e) (obs-set! k (attempt (lambda () e))))))

;; with-db : Database (Database -> A) -> A    closes it on the way out
(define (with-db db proc)
  (dynamic-wind (lambda () #f) (lambda () (proc db))
                (lambda () (guard (e (#t #f)) (close-database! db)))))

;; plain : String -> Database    (creates; nothing else set)
(define (plain p) (open-database p '((busy-timeout . 0))))

;; make-file! : String (Listof String) -> Void
;; A file made by plain calls and closed.
(define (make-file! p sqls)
  (with-db (plain p) (lambda (db) (for-each (lambda (q) (execute! db q)) sqls))))

(define T-id (number->string techo-application-id))

;; make-ahead! : String -> Void    Techo's id, version 5
(define (make-ahead! p)
  (make-file! p (list (string-append "PRAGMA application_id = " T-id)
                      "PRAGMA user_version = 5")))

;; make-foreign! : String -> Void    another program's id and a table
(define (make-foreign! p)
  (make-file! p '("PRAGMA application_id = 42" "CREATE TABLE t (x)" "INSERT INTO t VALUES (1)")))

;; facts-of : String -> DbFacts    (read-only)
(define (facts-of p) (with-db (open-techo-db p 'read-only) read-db-facts))

;; table-names : String -> (Listof String)
(define (table-names p)
  (with-db (open-techo-db p 'read-only)
    (lambda (db)
      (map (lambda (r) (vector-ref r 0))
           (query db "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")))))

;; count-rows : String String -> Integer
(define (count-rows p table)
  (with-db (open-techo-db p 'read-only)
    (lambda (db) (vector-ref (query-row db (string-append "SELECT count(*) FROM " table)) 0))))

;; read-bytes : String -> Bytevector
(define (read-bytes p)
  (let ((b (call-with-port (open-file-input-port p) get-bytevector-all)))
    (if (eof-object? b) (make-bytevector 0) b)))

;; file-size : String -> Nat    0 when it is not there
(define (file-size p)
  (guard (e (#t 0))
    (if (file-exists? p) (call-with-port (open-file-input-port p) file-length) 0)))

;; last-number : String -> (U Integer #f)    the report file's last whole line
(define (last-number p)
  (let loop ((ls (reverse (split-lines (file-text p)))))
    (cond ((null? ls) #f)
          ((string->number (car ls)) => (lambda (n) n))
          (else (loop (cdr ls))))))

;; techo-run : String String String (Listof String) -> (List Status String String)
;; Runs techo ARGS with TECHO_DB_PATH=DB and an ephemeral server port.
(define (techo-run dir name db args)
  (run-cli dir name '() (list "CHEZ_HTTP_PORT=0" (string-append "TECHO_DB_PATH=" db)) args))

(define (migrate-run dir name db) (techo-run dir name db '("migrate")))
(define (serve-run dir name db) (techo-run dir name db '("serve")))

;; serve-probe : String String String -> (List (U 'listening Any) (U (List ..) #f) Status)
;; Starts the server on DB, asks /health, stops it with SIGTERM.
(define (serve-probe dir name db)
  (let ((server (spawn dir name '() (list "CHEZ_HTTP_PORT=0" (string-append "TECHO_DB_PATH=" db))
                       '("serve"))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let* ((port (listening-port server))
               (h (and (integer? port) (get port "/health"))))
          (signal! server "TERM")
          (list (if (integer? port) 'listening port) h (await-status server deadline-ms))))
      (lambda () (kill! server)))))

;; sigkilled : Child -> Status
;; Kills the child as a crash would, and waits for its status.
(define (sigkilled c)
  (kill! c)
  (await-status c 10000))

;; two-at-once : String Integer -> (List Status Status DbFacts)
(define (two-at-once dir i)
  (let* ((db (string-append dir "/race" (number->string i) ".db"))
         (env (list (string-append "TECHO_DB_PATH=" db)))
         (a (spawn dir (string-append "race" (number->string i) "a") '() env '("migrate")))
         (b (spawn dir (string-append "race" (number->string i) "b") '() env '("migrate"))))
    (let* ((sa (await-status a 30000))
           (sb (await-status b 30000)))
      (kill! a) (kill! b)
      (list sa sb (facts-of db)))))

;; killed-in-migration : String -> (List Boolean Status DbFacts (Listof String) Result DbFacts (Listof String))
;; Clause 6. The child stops at the 2nd foreign-key-check: inside migration
;; 2, its statements run and not committed. It is killed there.
(define (killed-in-migration dir)
  (let* ((db (string-append dir "/clause6.db"))
         (ready (string-append dir "/clause6.ready"))
         (child (spawn-program dir "clause6" "tests/migrate-child.sps" '() '()
                               (list db ready "foreign-key-check" "2"))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let* ((reached (and (poll 30000 (lambda () (file-exists? ready))) #t))
               (status (sigkilled child))
               (facts (facts-of db))
               (tables (table-names db))
               (result (migrate! db fixture-migrations)))
          (list reached status facts tables
                (list (car result) (cadr result))
                (facts-of db) (table-names db))))
      (lambda () (kill! child)))))

;; killed-writer : String String Boolean -> (List ...)
;; Clause 11. A current file; a writer with auto-checkpoint off, killed once
;; its `-wal` is large; optionally the `-shm` deleted; `techo migrate`; the
;; rows; `techo serve`.
(define (killed-writer dir tag drop-shm?)
  (let* ((db (string-append dir "/" tag ".db"))
         (report (string-append dir "/" tag ".report"))
         (setup (migrate-run dir (string-append tag "-setup") db))
         (writer (spawn-program dir (string-append tag "-writer") "tests/writer-child.sps"
                                '() '() (list db report))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let* ((big (and (poll 60000 (lambda () (> (file-size (string-append db "-wal")) 524288))) #t))
               (status (sigkilled writer))
               (wal-size (file-size (string-append db "-wal")))
               (reported (last-number report))
               (dropped (and drop-shm?
                             (begin (delete-file (string-append db "-shm")) #t)))
               (mig (migrate-run dir (string-append tag "-migrate") db))
               (rows (count-rows db "writer_rows"))
               (facts (facts-of db))
               (served (serve-probe dir (string-append tag "-serve") db))
               ;; A migration applies on top of the recovered file, and the
               ;; rows are still there (after serve: the file is then ahead
               ;; of the shipped list).
               (on-top (let ((r (migrate! db fixture-migrations)))
                         (list (car r) (cadr r))))
               (rows-after (count-rows db "writer_rows")))
          (list (car setup) big (and (> wal-size 0) #t) (and (integer? reported) (> reported 0))
                (and drop-shm? dropped) (car mig)
                (and (integer? reported) (>= rows reported))
                (and (integer? reported) (= 0 (mod rows 100)))
                facts
                served
                on-top
                (and (integer? reported) (= rows-after rows)))))
      (lambda () (kill! writer)))))

;; foreign-left-alone : String String Boolean -> (List Boolean Boolean Boolean (List Status String String))
;; Another program's file, `techo migrate` run on it. With LEFTOVER? it is a
;; WAL file whose writer was killed, so a `-wal` holds commits. Answers
;; whether the main file is byte for byte as it was, and the run.
(define (foreign-left-alone dir tag leftover?)
  (let* ((db (string-append dir "/" tag ".db"))
         (report (string-append dir "/" tag ".report")))
    (make-foreign! db)
    (if leftover?
        (begin
          (make-file! db '("PRAGMA journal_mode = wal"))
          (let ((writer (spawn-program dir (string-append tag "-writer") "tests/writer-child.sps"
                                       '() '() (list db report))))
            (dynamic-wind
              (lambda () #f)
              (lambda ()
                (poll 60000 (lambda () (> (file-size (string-append db "-wal")) 262144)))
                (sigkilled writer))
              (lambda () (kill! writer))))))
    (let* ((wal? (> (file-size (string-append db "-wal")) 0))
           (before (read-bytes db))
           (run (migrate-run dir (string-append tag "-migrate") db))
           (after (read-bytes db)))
      (list (if leftover? wal? #t) (bytevector=? before after) (> (bytevector-length before) 0) run))))

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

;; observe-migrate! : String -> Void
;; The migrate and refusal rows, and the real-process rows.
(define (observe-migrate! dir)
  (define (at name) (string-append dir "/" name ".db"))
  ;; `techo migrate` on each kind of file.
  (make-ahead! (at "ahead"))
  (observe "migrate-ahead" (migrate-run dir "migahead" (at "ahead")))
  (make-foreign! (at "foreign"))
  (observe "migrate-foreign" (migrate-run dir "migforeign" (at "foreign")))
  (observe "migrate-backup-src" (migrate-run dir "migsrc" (at "src")))
  (observe "vacuum-into"
    (with-db (open-techo-db (at "src") 'read-only)
      (lambda (db)
        (execute! db (string-append "VACUUM INTO '" (at "backup") "'"))
        (execute! db (string-append "VACUUM INTO '" (at "backup2") "'"))
        #t)))
  (observe "backup-facts" (facts-of (at "backup")))
  (observe "migrate-backup" (migrate-run dir "migbackup" (at "backup")))
  (observe "migrate-nodir" (migrate-run dir "mignodir" (string-append dir "/nodir/x.db")))
  (observe "migrate-unset" (run-cli dir "migunset" '("TECHO_DB_PATH") '() '("migrate")))
  (observe "migrate-empty" (run-cli dir "migempty" '() '("TECHO_DB_PATH=") '("migrate")))
  ;; Two at once, five times: it is a race.
  (observe "two-at-once" (map (lambda (i) (two-at-once dir i)) '(1 2 3 4 5)))
  ;; Clause 6, clause 11.
  (observe "clause-6" (killed-in-migration dir))
  (observe "clause-11" (killed-writer dir "c11" #f))
  (observe "clause-11-no-shm" (killed-writer dir "c11s" #t))
  ;; Another program's file, left the same.
  (observe "foreign-clean" (foreign-left-alone dir "fclean" #f))
  (observe "foreign-leftover" (foreign-left-alone dir "fwal" #t))
  ;; `techo serve` refused.
  (observe "serve-missing" (serve-run dir "srvmissing" (at "nofile")))
  (observe "serve-missing-after"
           (map (lambda (x) (file-exists? (string-append (at "nofile") x))) '("" "-wal" "-shm")))
  (observe "zero-file" (call-with-output-file (at "zero") (lambda (p) #t)))
  (observe "serve-fresh" (serve-run dir "srvfresh" (at "zero")))
  (observe "serve-ahead" (serve-run dir "srvahead" (at "ahead")))
  (observe "serve-foreign" (serve-run dir "srvforeign" (at "foreign")))
  (observe "serve-backup" (serve-run dir "srvbackup" (at "backup2"))))

;; observe! : -> Void
(define (observe! dir)
  (let ((db (string-append dir "/techo.db")))
    ;; The server needs a current file: `techo migrate` makes it.
    (observe "migrate-fresh" (migrate-run dir "migfresh" db))
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
    (observe "migrate-again" (migrate-run dir "migagain" db))
    (observe-migrate! dir)
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


;; --- `techo migrate`, `techo serve`'s check, the real processes ----------

;; head, tail : (Listof A) Nat -> (Listof A)
(define (head l n) (if (= n 0) '() (cons (car l) (head (cdr l) (- n 1)))))
(define (tail l n) (if (= n 0) l (tail (cdr l) (- n 1))))

(define (nl . lines) (apply string-append (map (lambda (l) (string-append l "\n")) lines)))

(define (starts-with? s prefix)
  (and (string? s) (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

;; triple-shape : (U (List Status String String) Any) Nat -> Any
;; The status, stdout and whether stderr starts with PREFIX; else what was seen.
(define (shape-of r prefix)
  (if (and (pair? r) (= (length r) 3) (string? (cadr r)) (string? (caddr r)))
      (list (car r) (cadr r) (starts-with? (caddr r) prefix) (contains? (caddr r) "\n"))
      r))

(test-equal "migrate: a missing file is created and migrated"
  (list 0 (nl "converted the database to WAL" "applied migration 1" "the database is at version 1") "")
  (obs "migrate-fresh"))

(test-equal "migrate: a second run has nothing to do"
  (list 0 (nl "nothing to do: the database is at version 1") "")
  (obs "migrate-again"))

(test-equal "migrate: an ahead file is refused, exit 1, the line on stderr"
  (list 1 "" (nl "techo: refused: this binary is older than the database (version 5)"))
  (obs "migrate-ahead"))

(test-equal "migrate: another program's file is refused, exit 1, the line on stderr"
  (list 1 "" (nl "techo: refused: not Techo's database"))
  (obs "migrate-foreign"))

(test-equal "migrate: the VACUUM INTO backup is Techo's, version 1, not in WAL"
  (list techo-application-id 1 0 'delete)
  (obs "backup-facts"))

(test-equal "migrate: a restored backup is converted to WAL"
  (list 0 (nl "converted the database to WAL" "nothing to do: the database is at version 1") "")
  (obs "migrate-backup"))

(test-equal "migrate: a missing directory: cannot open, exit 1, stdout empty"
  (list 1 "" #t #t)
  (shape-of (obs "migrate-nodir") "techo: cannot open the database: "))

(test-equal "migrate without TECHO_DB_PATH: exit 2, stderr names it, stdout empty"
  '(2 "" #t)
  (let ((r (obs "migrate-unset")))
    (if (pair? r) (list (car r) (cadr r) (contains? (caddr r) "TECHO_DB_PATH")) r)))

(test-equal "migrate with an empty TECHO_DB_PATH: exit 2, stdout empty"
  '(2 "") (let ((r (obs "migrate-empty"))) (if (pair? r) (list (car r) (cadr r)) r)))

(test-equal "migrate: two at once on a missing file, five times: both exit 0, file current, in WAL"
  (let ((ok (list 0 0 (list techo-application-id 1 0 'wal))))
    (list ok ok ok ok ok))
  (obs "two-at-once"))

(test-equal "clause 6: a child killed inside migration 2, then the file is at version 1, none of 2"
  (list #t 137 (list techo-application-id 1 0 'wal) '())
  (let ((r (obs "clause-6"))) (if (and (list? r) (= (length r) 7)) (head r 4) r)))

(test-equal "clause 6: a normal migrate then applies 2 and 3 on the same file"
  (list '(applied (2 3)) (list techo-application-id 3 3 'wal) '("notes" "tags"))
  (let ((r (obs "clause-6"))) (if (and (list? r) (= (length r) 7)) (tail r 4) r)))

;; The two clause 11 runs: the writer was killed with a full -wal, and
;; `techo migrate` then finds every reported row.
(define (clause-11-tests label key)
  (test-equal (string-append label ": the setup migrate, the -wal large, non-empty at the kill, a report")
    '(0 #t #t #t)
    (let ((r (obs key))) (if (and (list? r) (= (length r) 12)) (head r 4) r)))
  (test-equal (string-append label ": techo migrate exits 0 and every reported row is there")
    '(0 #t #t)
    (let ((r (obs key))) (if (and (list? r) (= (length r) 12))
                             (list (list-ref r 5) (list-ref r 6) (list-ref r 7))
                             r)))
  (test-equal (string-append label ": the file is current and in WAL, and serve answers /health")
    (list (list techo-application-id 1 1 'wal)
          (list 'listening (list 200 "application/json" '(("status" . "ok"))) 0))
    (let ((r (obs key)))
      (if (and (list? r) (= (length r) 12))
          (list (list-ref r 8)
                (list-ref r 9))
          r)))

  (test-equal (string-append label ": a migration then applies on top, and the rows are still there")
    '((applied (2 3)) #t)
    (let ((r (obs key)))
      (if (and (list? r) (= (length r) 12)) (list (list-ref r 10) (list-ref r 11)) r))))

(clause-11-tests "clause 11" "clause-11")
(clause-11-tests "clause 11, -shm deleted" "clause-11-no-shm")
(test-equal "clause 11, -shm deleted: it was deleted"
  #t (let ((r (obs "clause-11-no-shm"))) (if (list? r) (list-ref r 4) r)))

(test-equal "another program's file, closed cleanly: refused and byte for byte the same"
  '(#t #t #t (1 "" "techo: refused: not Techo's database\n"))
  (obs "foreign-clean"))

(test-equal "another program's file with a leftover -wal: refused and its main file byte for byte the same"
  '(#t #t #t (1 "" "techo: refused: not Techo's database\n"))
  (obs "foreign-leftover"))

(define (refused-line line) (list 1 "" (string-append "techo: " line "\n")))

(test-equal "serve: a missing file is refused, exit 1, run techo migrate"
  (refused-line "the database file is missing: run `techo migrate`")
  (obs "serve-missing"))

(test-equal "serve: a missing file is still missing afterwards, with no -wal or -shm"
  '(#f #f #f) (obs "serve-missing-after"))

(test-equal "serve: a fresh file is refused"
  (refused-line "the database is empty: run `techo migrate`")
  (obs "serve-fresh"))

(test-equal "serve: an ahead file is refused"
  (refused-line "this binary is older than the database (version 5)")
  (obs "serve-ahead"))

(test-equal "serve: another program's file is refused"
  (refused-line "not Techo's database")
  (obs "serve-foreign"))

(test-equal "serve: a restored backup is refused: not in WAL"
  (refused-line "the database is not in WAL mode: run `techo migrate`")
  (obs "serve-backup"))

(test-end "integration")

(exit (suite-exit-status runner))
