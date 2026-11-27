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
                           library-directories file-length current-time time-second time-nanosecond)
        (only (chez-sqlite3) open-database close-database! execute! query query-row)
        (techo-testing)
        (techo cli)
        (only (techo keys) key-secret id->string)
        (only (techo auth) key-hash)
        (only (techo db) open-techo-db read-db-facts migrate!)
        (only (techo migrations) techo-application-id migrations latest-version)
        (migrations-fixture)
        (http-client)
        (jsonparse easy))

(define runner (test-runner-simple))
(test-runner-current runner)

;; A failing test shows what it expected and what it saw: these tests watch
;; processes, and a name alone does not say what happened. CI keeps no log
;; file, so this is all a failed run there leaves behind.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (memq (test-result-kind r) '(fail xpass))
        (let ((out (current-output-port)))
          (put-string out "  expected: ") (write (test-result-ref r 'expected-value) out) (newline out)
          (put-string out "  actual:   ") (write (test-result-ref r 'actual-value) out) (newline out)
          (flush-output-port out))))))

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

;; spawn-stdin : String
;; The file a child's standard input is read from: nothing, unless a caller
;; (run-cli-in) names one for the one call.
(define spawn-stdin "/dev/null")

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
    (sh "( " cmd " >" out " 2>" err " <" (quote-word spawn-stdin) " & echo $! >" pid
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

;; run-cli-in : String String String (Listof String) (Listof String) (Listof String)
;;              -> (List (U Integer 'no-exit) String String)
;; run-cli with INPUT on the child's standard input, as a pipe would give it.
(define (run-cli-in dir name input unset set args)
  (let ((f (string-append dir "/" name ".in")))
    (call-with-output-file f (lambda (p) (put-string p input)))
    (set! spawn-stdin f)
    (let ((r (attempt (lambda () (run-cli dir name unset set args)))))
      (set! spawn-stdin "/dev/null")
      r)))

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

;; make-ahead! : String -> Void
;; Techo's id, and a version one past the latest shipped one.
(define (make-ahead! p)
  (make-file! p (list (string-append "PRAGMA application_id = " T-id)
                      (string-append "PRAGMA user_version = "
                                     (number->string ahead-version)))))

;; make-foreign! : String -> Void    another program's id and a table
(define (make-foreign! p)
  (make-file! p '("PRAGMA application_id = 42" "CREATE TABLE t (x)" "INSERT INTO t VALUES (1)")))

;; The shipped schema, as the file's facts count it: accounts, api_keys, the
;; index, and the automatic indexes of the primary and unique keys, and migration 5's index.
(define shipped-latest (latest-version migrations))
(define shipped-objects 17)
;; A version no shipped migration reaches: what "a file from a newer Techo" holds.
(define ahead-version (+ shipped-latest 1))
(define shipped-tables '("accounts" "api_keys" "changes" "links" "nodes" "revisions"))

;; applied-lines : (Listof Natural) -> (Listof String)
;; The lines `techo migrate` prints for the versions it applied.
(define (applied-lines vs)
  (map (lambda (v) (string-append "applied migration " (number->string v))) vs))

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

;; password-hash-of : String String -> (U String #f)
;; The password hash the account with EMAIL holds in P, read-only.
(define (password-hash-of p email)
  (with-db (open-techo-db p 'read-only)
    (lambda (db)
      (let ((row (query-row db "SELECT password_hash FROM accounts WHERE email = ?" email)))
        (and row (vector-ref row 0))))))

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
;; Clause 6. The child stops at the foreign-key-check of the fixture's first
;; own migration (the n-th, n its version): its statements run and not committed. It is killed there.
(define (killed-in-migration dir)
  (let* ((db (string-append dir "/clause6.db"))
         (ready (string-append dir "/clause6.ready"))
         (child (spawn-program dir "clause6" "tests/migrate-child.sps" '() '()
                               (list db ready "foreign-key-check"
                                     (number->string fixture-notes-version)))))
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
               (report-lines (length (split-lines (file-text report))))
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
                (and (integer? reported) (= rows-after rows))
                ;; The report is appended to, never emptied: a kill between
                ;; an emptying open and its write would leave no number.
                (and (integer? reported) (= report-lines (div reported 100))))))
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
(define cli-port-used #f)
(define serve-leftovers #f)
(define bad-port-leftovers #f)
(define readers-zero #f)
(define readers-x #f)

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

;; --- the API over the wire (slice 3a) ------------------------------------
;;
;; One server on its own file. The server cannot make an account yet, so the
;; suite's own connection puts the rows in after `techo migrate`. Everything
;; after that is a request on the socket, in a fixed order; the server's
;; standard output is the request log. The run ends with D3/P1's search: no
;; secret the run presented or was given is anywhere the server wrote.

;; bv16 : Nat Nat -> Bytevector    an id: TAG sixteen times, the last byte N
(define (bv16 tag n)
  (let ((b (make-bytevector 16 tag))) (bytevector-u8-set! b 15 n) b))

(define account-a (bv16 #x0a 1))
(define account-b (bv16 #x0b 1))
(define (key-id-of tag n) (bv16 tag n))
(define a-keys (map (lambda (n) (key-id-of #x1a n)) '(1 2 3 4)))
(define b-key (key-id-of #x1b 1))

;; mk-secret : Nat -> String    a well-shaped secret, a different one for each N
(define (mk-secret n)
  (key-secret
   (let ((b (make-bytevector 32 0)))
     (do ((i 0 (+ i 1))) ((= i 32) b)
       (bytevector-u8-set! b i (mod (+ 5 (* n 37) (* i 11)) 256))))))

;; The secrets the run starts with: A's four keys, B's one, and one that no row holds.
(define s-a1 (mk-secret 1))
(define s-a2 (mk-secret 2))
(define s-a3 (mk-secret 3))
(define s-a4 (mk-secret 4))
(define s-b1 (mk-secret 5))
(define s-unknown (mk-secret 6))

;; every secret presented or returned in the run; the expected log, newest first
(define api-secrets '())
(define api-expect '())
(define (remember-secret! s) (unless (member s api-secrets) (set! api-secrets (cons s api-secrets))))

;; api-call : Nat Symbol String (U String #f) -> (List Status Headers Json)
;; Status, a lookup of the headers by name, and the body parsed (or 'unparsed).
(define (api-call port method target secret)
  (call-with-http-session 'timeout-ms 10000
    (lambda (session)
      (let* ((r (http-request session method
                              (string-append "http://127.0.0.1:" (number->string port) target)
                              'headers (if secret
                                           (list (cons "Authorization" (string-append "Bearer " secret)))
                                           '())))
             (hs (map (lambda (n) (cons n (header-of r n)))
                      '("content-type" "www-authenticate" "allow" "cache-control"))))
        (list (http-response-status r) hs
              (guard (e (#t 'unparsed)) (string->json (http-response-text r))))))))

(define (rsp-status r) (car r))
(define (rsp-header r name) (cdr (assoc name (cadr r))))
(define (rsp-json r) (caddr r))

;; jget : Json String -> Any    the member, or 'missing
(define (jget j k)
  (let ((p (and (list? j) (assoc k j)))) (if p (cdr p) 'missing)))
(define (jitems j)
  (let ((x (jget j "items"))) (cond ((vector? x) (vector->list x)) ((list? x) x) (else x))))

;; go! : Nat String Symbol String (U String #f) (U Bytevector #f) -> Void
;; One request, filed under NAME; the log line it should leave (method, path
;; without its query, the status the client got, the account) is remembered.
(define (go! port name method target secret account)
  (when secret (remember-secret! secret))
  (let ((r (attempt (lambda () (api-call port method target secret)))))
    (obs-set! name r)
    (when (and (pair? r) (not (eq? (car r) 'raised)))
      (let ((j (rsp-json r)))
        (let ((k (jget j "key"))) (when (string? k) (remember-secret! k))))
      (set! api-expect
            (cons (list (string-upcase (symbol->string method))
                        (let loop ((cs (string->list target)) (acc '()))
                          (if (or (null? cs) (char=? (car cs) #\?))
                              (list->string (reverse acc))
                              (loop (cdr cs) (cons (car cs) acc))))
                        (number->string (rsp-status r))
                        (if account (id->string account) "-"))
                  api-expect)))))

(define (url-of-key id verb) (string-append "/v1/keys/" (id->string id) "/" verb))

;; needles-of : String -> (Listof Bytevector)
;; The 70 characters, their 64 hex digits alone (both cases), and the 32 bytes.
(define (needles-of secret)
  (let* ((hex (substring secret 6 70))
         (raw (u8-list->bytevector
               (let loop ((i 0))
                 (if (= i 64) '()
                     (cons (string->number (substring hex i (+ i 2)) 16) (loop (+ i 2))))))))
    (list (string->utf8 secret) (string->utf8 hex) (string->utf8 (string-upcase hex)) raw)))

;; bytevector-append : Bytevector ... -> Bytevector
(define (bytevector-append . bs)
  (u8-list->bytevector (apply append (map bytevector->u8-list bs))))

;; bytes-contain? : Bytevector Bytevector -> Boolean
(define (bytes-contain? hay needle)
  (let ((n (bytevector-length hay)) (m (bytevector-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((and (= (bytevector-u8-ref hay i) (bytevector-u8-ref needle 0))
                  (let inner ((j 1))
                    (or (= j m)
                        (and (= (bytevector-u8-ref hay (+ i j)) (bytevector-u8-ref needle j))
                             (inner (+ j 1))))))
             #t)
            (else (loop (+ i 1)))))))

;; leaks : (Listof (Pair String Bytevector)) (Listof String) -> (Listof (List String Nat))
;; For each named haystack, the index of each secret that has a needle in it.
(define (leaks hays secrets)
  (apply append
         (map (lambda (h)
                (let loop ((ss secrets) (i 0) (acc '()))
                  (cond ((null? ss) (reverse acc))
                        ((exists (lambda (nd) (bytes-contain? (cdr h) nd)) (needles-of (car ss)))
                         (loop (cdr ss) (+ i 1) (cons (list (car h) i) acc)))
                        (else (loop (cdr ss) (+ i 1) acc)))))
              hays)))

(define (bv-or-empty p) (guard (e (#t (make-bytevector 0))) (if (file-exists? p) (read-bytes p) (make-bytevector 0))))

;; log-lines : String -> (Listof (List String String String String))
;; Method, path, status and account of each `request ` line, and, in a second
;; list, the whole lines.
(define (field-of line name)
  (let loop ((ws (split-words line)))
    (cond ((null? ws) #f)
          ((starts-with? (car ws) (string-append name "="))
           (substring (car ws) (+ 1 (string-length name)) (string-length (car ws))))
          (else (loop (cdr ws))))))
(define (request-lines text)
  (filter (lambda (l) (starts-with? l "request ")) (split-lines text)))
(define (line-key l)
  (list (field-of l "method") (field-of l "path") (field-of l "status") (field-of l "account")))

;; observe-api! : String -> Void
(define (observe-api! dir)
  (let* ((db (string-append dir "/api.db"))
         (setup (migrate-run dir "apimigrate" db)))
    (obs-set! "api:migrate" (car setup))
    ;; The rows, from this suite's own connection.
    (with-db (open-techo-db db 'read-write)
      (lambda (c)
        (execute! c "INSERT INTO accounts(id, username, email, password_hash, created) VALUES (?, ?, ?, ?, ?)"
                  account-a "ada" "ada@example.com" "not-a-hash" 1700000000000)
        (execute! c "INSERT INTO accounts(id, username, email, password_hash, created) VALUES (?, ?, ?, ?, ?)"
                  account-b "bob" "bob@example.com" "not-a-hash" 1700000000001)
        (for-each
         (lambda (id name secret acct created)
           (execute! c "INSERT INTO api_keys(id, account, name, key_hash, created) VALUES (?, ?, ?, ?, ?)"
                     id acct name (key-hash secret) created))
         (append a-keys (list b-key))
         (list "laptop" "phone" "tablet" "watch" "bobs laptop")
         (list s-a1 s-a2 s-a3 s-a4 s-b1)
         (list account-a account-a account-a account-a account-b)
         '(1700000000010 1700000000020 1700000000030 1700000000040 1700000000050))))
    (let ((server (spawn dir "api" '() (list "CHEZ_HTTP_PORT=0" (string-append "TECHO_DB_PATH=" db))
                         '("serve"))))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (let ((port (listening-port server)))
            (obs-set! "api:port" port)
            (when (integer? port)
              (let ((a1 (car a-keys)) (a2 (cadr a-keys)) (a3 (caddr a-keys)) (a4 (cadddr a-keys)))
                ;; the refusals that come before any key is looked up
                (go! port "api:no-key" 'get "/v1/account" #f #f)
                (go! port "api:unknown-key" 'get "/v1/account" s-unknown #f)
                (go! port "api:bad-limit" 'get "/v1/keys?limit=0" s-a1 #f)
                (go! port "api:bad-limit-text" 'get "/v1/keys?limit=many" s-a1 #f)
                (go! port "api:bad-after" 'get "/v1/keys?after=nope" s-a1 #f)
                (go! port "api:no-route" 'get "/v1/nothing" s-a1 #f)
                (go! port "api:wrong-method" 'post "/v1/account" s-a1 #f)
                (go! port "api:wrong-method-keys" 'delete "/v1/keys" s-a1 #f)
                ;; reads
                (go! port "api:account" 'get "/v1/account" s-a1 account-a)
                (go! port "api:keys" 'get "/v1/keys" s-a1 account-a)
                (go! port "api:keys-1" 'get "/v1/keys?limit=2" s-a1 account-a)
                (let ((next (jget (rsp-json (obs "api:keys-1")) "next")))
                  (go! port "api:keys-2" 'get
                       (string-append "/v1/keys?limit=2&after=" (if (string? next) next "x"))
                       s-a1 account-a))
                (go! port "api:keys-over" 'get "/v1/keys?limit=1000" s-a1 account-a)
                ;; a key that only reads, and another account's
                (go! port "api:reader" 'get "/v1/account" s-a2 account-a)
                (go! port "api:reader-4" 'get "/v1/account" s-a4 account-a)
                (go! port "api:b-keys" 'get "/v1/keys" s-b1 account-b)
                ;; another account's key looks like no key; a sibling is not mine to regenerate
                (go! port "api:other-revoke" 'post (url-of-key b-key "revoke") s-a1 account-a)
                (go! port "api:other-regenerate" 'post (url-of-key b-key "regenerate") s-a1 account-a)
                (go! port "api:sibling-regenerate" 'post (url-of-key a2 "regenerate") s-a1 account-a)
                (go! port "api:bad-id" 'post "/v1/keys/not-an-id/revoke" s-a1 #f)
                ;; a key revokes a sibling; the sibling then no longer opens
                (go! port "api:revoke" 'post (url-of-key a3 "revoke") s-a1 account-a)
                (go! port "api:revoke-again" 'post (url-of-key a3 "revoke") s-a1 account-a)
                (go! port "api:revoked-key" 'get "/v1/account" s-a3 #f)
                (go! port "api:keys-after" 'get "/v1/keys" s-a1 account-a)
                ;; regenerate itself: the new secret works, the old one does not
                (go! port "api:regenerate" 'post (url-of-key a1 "regenerate") s-a1 account-a)
                (let* ((new (jget (rsp-json (obs "api:regenerate")) "key"))
                       (new (if (string? new) new "techo_missing")))
                  (obs-set! "api:new-secret" new)
                  (go! port "api:old-secret" 'get "/v1/account" s-a1 #f)
                  (go! port "api:new-account" 'get "/v1/account" new account-a)
                  ;; a forced failure inside the write: the trigger comes from this
                  ;; suite's own connection while the server runs
                  (with-db (open-techo-db db 'read-write)
                    (lambda (c)
                      (execute! c "CREATE TRIGGER force_failure BEFORE UPDATE ON api_keys BEGIN SELECT RAISE(ABORT, 'forced'); END")))
                  ;; The key was checked before the write failed, so by the plan's
                  ;; L8 the log names the account on these 500s (it was `-`).
                  (go! port "api:forced-500" 'post (url-of-key a1 "regenerate") new account-a)
                  (go! port "api:forced-500-revoke" 'post (url-of-key a4 "revoke") new account-a)
                  (with-db (open-techo-db db 'read-write)
                    (lambda (c) (execute! c "DROP TRIGGER force_failure")))
                  (go! port "api:after-trigger" 'post (url-of-key a4 "revoke") new account-a)
                  ;; a read while another program holds the write lock: the
                  ;; program's reader must be a read job, which never waits on it
                  (with-db (open-techo-db db 'read-write)
                    (lambda (c)
                      (execute! c "BEGIN IMMEDIATE")
                      (let ((t0 (real-time)))
                        (go! port "api:read-under-lock" 'get "/v1/account" new account-a)
                        (obs-set! "api:read-under-lock-ms" (- (real-time) t0)))
                      (execute! c "ROLLBACK")))
                  ;; a second key regenerates itself: the program's random
                  ;; bytes must give another secret, not the same one again
                  (go! port "api:regenerate-2" 'post (url-of-key a2 "regenerate") s-a2 account-a)
                  (let ((new2 (jget (rsp-json (obs "api:regenerate-2")) "key")))
                    (obs-set! "api:new-secret-2" (if (string? new2) new2 "techo_missing")))))
              ;; what is on disk while the server is up
              (obs-set! "api:live-files"
                        (list (cons "db (running)" (bv-or-empty db))
                              (cons "wal (running)" (bv-or-empty (string-append db "-wal"))))))
            (signal! server "TERM")
            (obs-set! "api:exit" (await-status server deadline-ms))
            (let ((out (read-bytes (child-file server "out"))))
              (obs-set! "api:out" (utf8->string out))
              (obs-set! "api:err" (file-text (child-file server "err")))
              (obs-set! "api:leaks"
                        (leaks (append (or (obs "api:live-files") '())
                                       (list (cons "stdout" out)
                                             (cons "stderr" (read-bytes (child-file server "err")))
                                             (cons "db" (bv-or-empty db))
                                             (cons "wal" (bv-or-empty (string-append db "-wal")))))
                               (reverse api-secrets)))
              (obs-set! "api:secret-count" (length api-secrets)))))
        (lambda () (kill! server))))))

;; --- login, the users commands and the proxy count (slice 3b) ------------
;;
;; Accounts are made by the real `techo user add`, with the password piped on
;; standard input. Then a real server (no proxy count), logins by HTTP, a
;; `techo user password` while it runs; then a second server with
;; TECHO_BEHIND_PROXY=1. Every password, every secret and every response
;; and output is kept, and searched at the end (Q3).

(define pw-ada "correct horse battery")
(define pw-ada-new "new horse staple")
(define pw-sam "  spaced out  ")
(define pw-wrong "not-the-pw-7731")
(define lg-passwords (list pw-ada pw-ada-new pw-sam pw-wrong))

;; what each command and each response said: (label . bytes), and whether
;; the response is a login answer that holds a secret on purpose
(define lg-outputs '())
(define lg-bodies '())          ; (label . bytes), every response but a 201 login's
(define lg-bodies-201 '())      ; the 201 logins' bodies
(define lg-secrets '())
(define lg-expect '())          ; each login's (status account), newest first

;; cli! : String String String (Listof String) (Listof String) (Listof String) -> Result
;; run-cli-in, with what the command wrote kept for the search.
(define (cli! dir name input unset set args)
  (let ((r (run-cli-in dir name input unset set args)))
    (when (and (pair? r) (not (eq? (car r) 'raised)))
      (set! lg-outputs (cons (cons (string-append name " stdout") (string->utf8 (cadr r)))
                             (cons (cons (string-append name " stderr") (string->utf8 (caddr r)))
                                   lg-outputs))))
    r))

;; hcall : Nat Symbol String (U String #f) String (Listof (Pair String String))
;;         -> (List Status (Listof (Pair String String)) String)
;; One request: the status, the headers (names in lower case, Date left
;; out) and the body's text. CTYPE #f sends no Content-Type at all.
(define (hcall port method path ctype body headers)
  (call-with-http-session 'timeout-ms 20000
    (lambda (session)
      (let* ((hs (append (if ctype
                             (list (cons "Content-Type" ctype))
                             (list (cons "Content-Type" "")))
                         headers))
             (r (if (eq? method 'get)
                    (http-request session method
                                  (string-append "http://127.0.0.1:" (number->string port) path)
                                  'headers headers)
                    (http-request session method
                                  (string-append "http://127.0.0.1:" (number->string port) path)
                                  'headers hs 'body (string->utf8 body)))))
        (list (http-response-status r)
              (filter (lambda (h) (not (string=? (car h) "date")))
                      (map (lambda (h) (cons (string-downcase (car h)) (cdr h)))
                           (http-response-headers r)))
              (http-response-text r))))))

(define (lg-status r) (car r))
(define (lg-headers r) (cadr r))
(define (lg-text r) (caddr r))
(define (lg-json r) (guard (e (#t 'unparsed)) (string->json (lg-text r))))
(define (lg-header r name) (let ((p (assoc name (lg-headers r)))) (and p (cdr p))))

;; lcall! : String Nat Symbol String (U String #f) String Headers (U String #f) -> Void
;; One request, filed under NAME and kept for the search. For a login,
;; the log line it should leave is remembered: ACCT where it answered 201.
(define (lcall! name port method path ctype body headers acct)
  (let ((r (attempt (lambda () (hcall port method path ctype body headers)))))
    (obs-set! name r)
    (when (and (pair? r) (not (eq? (car r) 'raised)))
      (let* ((j (lg-json r)) (k (jget j "key")))
        (if (and (= (lg-status r) 201) (string? k))
            (begin (set! lg-secrets (cons k lg-secrets))
                   (set! lg-bodies-201 (cons (cons name (string->utf8 (lg-text r))) lg-bodies-201)))
            (set! lg-bodies (cons (cons name (string->utf8 (lg-text r))) lg-bodies))))
      (when (string=? path "/v1/login")
        (set! lg-expect (cons (list (number->string (lg-status r))
                                    (if (= (lg-status r) 201) (or acct "?") "-"))
                              lg-expect))))))

(define (login-json email password name)
  (string-append "{\"email\":\"" email "\",\"password\":\"" password "\",\"name\":\"" name "\"}"))

(define (login! name port email password key-name acct . headers)
  (lcall! name port 'post "/v1/login" "application/json"
          (login-json email password key-name) (if (pair? headers) (car headers) '()) acct))

(define (bearer key) (list (cons "Authorization" (string-append "Bearer " key))))
(define (secret-of name)
  (let ((r (obs name))) (if (and (pair? r) (integer? (car r))) (let ((k (jget (lg-json r) "key"))) (if (string? k) k "techo_missing")) "techo_missing")))

;; id-of-added : (List Status String String) -> String    the id on `added NAME EMAIL ID`
(define (id-of-added r)
  (if (and (pair? r) (string? (cadr r)))
      (let ((ws (split-words (car (split-lines (cadr r)))))) (if (= (length ws) 4) (cadddr ws) "no-id"))
      "no-id"))

(define (leftover-files p) (map (lambda (x) (file-exists? (string-append p x))) '("" "-wal" "-shm")))

;; A server on DB with the proxy count PROXY (#f: the variable unset).
;; Calls BODY with its port; always stops it with SIGTERM and files the
;; exit status, the output and the error under TAG.
(define (with-server dir tag db proxy body)
  (let ((server (spawn dir tag (if proxy '() '("TECHO_BEHIND_PROXY"))
                       (append (list "CHEZ_HTTP_PORT=0" (string-append "TECHO_DB_PATH=" db))
                               (if proxy (list (string-append "TECHO_BEHIND_PROXY=" proxy)) '()))
                       '("serve"))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let ((port (listening-port server)))
          (obs-set! (string-append tag ":port") port)
          (when (integer? port) (guard (e (#t (obs-set! (string-append tag ":raised") (describe e)))) (body port)))
          (signal! server "TERM")
          (obs-set! (string-append tag ":exit") (await-status server deadline-ms))
          (obs-set! (string-append tag ":out") (file-text (child-file server "out")))
          (obs-set! (string-append tag ":err") (file-text (child-file server "err")))
          (set! lg-outputs
                (append (list (cons (string-append tag " stdout") (read-bytes (child-file server "out")))
                              (cons (string-append tag " stderr") (read-bytes (child-file server "err"))))
                        lg-outputs))))
      (lambda () (kill! server)))))

;; observe-login! : String -> Void
(define (observe-login! dir)
  (define db (string-append dir "/login.db"))
  (define env (list (string-append "TECHO_DB_PATH=" db)))
  (define (add! name input args) (cli! dir name input '() env args))
  (obs-set! "lg:migrate" (car (cli! dir "lgmigrate" "" '() env '("migrate"))))
  ;; `techo user add`, the password on standard input
  (let ((ada (add! "lg-add-ada" (string-append pw-ada "\n") '("user" "add" "--username" "ada" "--email" "Ada@Example.com"))))
    (obs-set! "lg:add-ada" ada)
    (obs-set! "lg:ada-id" (id-of-added ada)))
  (let ((sam (add! "lg-add-sam" (string-append pw-sam "\r\n") '("user" "add" "--username" "sam" "--email" "sam@example.com"))))
    (obs-set! "lg:add-sam" sam)
    (obs-set! "lg:sam-id" (id-of-added sam)))
  (obs-set! "lg:add-dup-username"
            (add! "lg-dupu" (string-append pw-ada "\n") '("user" "add" "--username" "ada" "--email" "other@example.com")))
  (obs-set! "lg:add-dup-email"
            (add! "lg-dupe" (string-append pw-ada "\n") '("user" "add" "--username" "ada2" "--email" "ADA@example.com")))
  (obs-set! "lg:add-short"
            (add! "lg-short" "short\n" '("user" "add" "--username" "bo" "--email" "bo@example.com")))
  (obs-set! "lg:add-bad-username"
            (add! "lg-badu" (string-append pw-ada "\n") '("user" "add" "--username" "Bad Name" "--email" "bo@example.com")))
  (obs-set! "lg:add-empty-stdin"
            (add! "lg-empty" "" '("user" "add" "--username" "bo" "--email" "bo@example.com")))
  (obs-set! "lg:user-bare" (add! "lg-user" "" '("user")))
  (obs-set! "lg:user-add-bare" (add! "lg-addbare" "" '("user" "add")))
  (obs-set! "lg:user-unknown-option"
            (add! "lg-unkopt" "" '("user" "add" "--username" "bo" "--email" "b@e.c" "--password" "hunter2hunter2")))
  (obs-set! "lg:accounts-after-refusals" (count-rows db "accounts"))
  (obs-set! "lg:ada-hash" (attempt (lambda () (password-hash-of db "ada@example.com"))))
  ;; a missing file and a file that was never migrated: refused, nothing made
  (let ((missing (string-append dir "/missing.db"))
        (blank (string-append dir "/blank.db")))
    (call-with-output-file blank (lambda (p) #t))
    (obs-set! "lg:add-missing"
              (cli! dir "lg-missing" (string-append pw-ada "\n") '()
                    (list (string-append "TECHO_DB_PATH=" missing))
                    '("user" "add" "--username" "ada" "--email" "ada@example.com")))
    (obs-set! "lg:add-missing-files" (leftover-files missing))
    (obs-set! "lg:add-blank"
              (cli! dir "lg-blank" (string-append pw-ada "\n") '()
                    (list (string-append "TECHO_DB_PATH=" blank))
                    '("user" "add" "--username" "ada" "--email" "ada@example.com")))
    (obs-set! "lg:add-blank-files" (list (file-size blank) (file-exists? (string-append blank "-wal"))
                                         (file-exists? (string-append blank "-shm")))))
  ;; the real server, no proxy count
  (let ((ada-id (obs "lg:ada-id")) (sam-id (obs "lg:sam-id")))
    (with-server dir "lgsrv" db #f
      (lambda (port)
        (login! "lg:good" port "Ada@Example.com" pw-ada "laptop" ada-id)
        (let ((k (secret-of "lg:good")))
          (lcall! "lg:account" port 'get "/v1/account" #f "" (bearer k) #f)
          (lcall! "lg:keys" port 'get "/v1/keys" #f "" (bearer k) #f))
        (login! "lg:sam" port "sam@example.com" pw-sam "phone" sam-id)
        ;; Q1
        (login! "lg:wrong-pw" port "ada@example.com" pw-wrong "x" #f)
        (login! "lg:wrong-email" port "nobody@example.com" pw-wrong "x" #f)
        ;; L2's refusals, none of them a try
        (lcall! "lg:no-ctype" port 'post "/v1/login" #f (login-json "ada@example.com" pw-wrong "x") '() #f)
        (lcall! "lg:bad-json" port 'post "/v1/login" "application/json" "{\"email\":" '() #f)
        (lcall! "lg:twice" port 'post "/v1/login" "application/json"
                (string-append "{\"email\":\"a@b.c\",\"email\":\"a@b.c\",\"password\":\"" pw-wrong "\",\"name\":\"x\"}") '() #f)
        (lcall! "lg:unknown-field" port 'post "/v1/login" "application/json"
                (string-append "{\"email\":\"a@b.c\",\"password\":\"" pw-wrong "\",\"name\":\"x\",\"admin\":true}") '() #f)
        (lcall! "lg:too-big" port 'post "/v1/login" "application/json"
                (make-string 20000 #\a) '() #f)
        ;; the rate limit, for one email: five tries, then the sixth
        (for-each (lambda (i) (login! (string-append "lg:rl-" (number->string i)) port "z@example.com" pw-wrong "x" #f))
                  '(1 2 3 4 5))
        (login! "lg:rl-6" port "z@example.com" pw-wrong "x" #f)
        (login! "lg:rl-other" port "y@example.com" pw-wrong "x" #f)
        ;; Q5: `techo user password` beside the running server
        (login! "lg:second" port "ada@example.com" pw-ada "tablet" ada-id)
        (obs-set! "lg:passwd"
                  (cli! dir "lg-passwd" (string-append pw-ada-new "\n") '() env
                        '("user" "password" "--email" "ADA@example.com")))
        (obs-set! "lg:passwd-unknown"
                  (cli! dir "lg-passwd-no" (string-append pw-ada-new "\n") '() env
                        '("user" "password" "--email" "nobody@example.com")))
        (lcall! "lg:old-key-1" port 'get "/v1/account" #f "" (bearer (secret-of "lg:good")) #f)
        (lcall! "lg:old-key-2" port 'get "/v1/account" #f "" (bearer (secret-of "lg:second")) #f)
        (login! "lg:old-password" port "ada@example.com" pw-ada "again" #f)
        (login! "lg:new-password" port "ada@example.com" pw-ada-new "fresh" ada-id)
        (lcall! "lg:new-key" port 'get "/v1/account" #f "" (bearer (secret-of "lg:new-password")) #f)
        ;; with TECHO_BEHIND_PROXY unset the header is ignored: tries with a
        ;; different last entry each still reach the one address's limit
        (let loop ((i 1) (seen '()))
          (if (> i 25)
              (obs-set! "lg:unset-proxy" (reverse seen))
              (let ((name (string-append "lg:ign-" (number->string i))))
                (login! name port (string-append "ign" (number->string i) "@example.com") pw-wrong "x" #f
                        (list (cons "X-Forwarded-For" (string-append "203.0.113." (number->string i)))))
                (let ((st (lg-status (obs name))))
                  (if (= st 429)
                      (obs-set! "lg:unset-proxy" (reverse (cons st seen)))
                      (loop (+ i 1) (cons st seen)))))))))
    (obs-set! "lg:expect" (reverse lg-expect)))
  ;; the second server: one proxy in front. The address is the LAST entry.
  (let ((pdb (string-append dir "/proxy.db")))
    (cli! dir "lgpmigrate" "" '() (list (string-append "TECHO_DB_PATH=" pdb)) '("migrate"))
    (with-server dir "lgproxy" pdb "1"
      (lambda (port)
        (define (xff first last) (list (cons "X-Forwarded-For" (string-append first ", " last))))
        ;; 20 tries over four emails from one client; its first entry (the
        ;; part a client writes) changes every time and counts for nothing
        (let loop ((i 0))
          (when (< i 20)
            (login! (string-append "lg:px-" (number->string i)) port
                    (string-append "px" (number->string (div i 5)) "@example.com") pw-wrong "x" #f
                    (xff (string-append "203.0.113." (number->string i)) "198.51.100.1"))
            (loop (+ i 1))))
        (login! "lg:px-21-same" port "px9@example.com" pw-wrong "x" #f (xff "203.0.113.200" "198.51.100.1"))
        (login! "lg:px-21-other" port "px9@example.com" pw-wrong "x" #f (xff "203.0.113.200" "198.51.100.2"))))
    (obs-set! "lg:px-statuses"
              (map (lambda (i) (lg-status (obs (string-append "lg:px-" (number->string i)))))
                   (let loop ((i 19) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))))
  ;; the settings it refuses
  (for-each
   (lambda (v)
     (obs-set! (string-append "lg:proxy-" v)
               (cli! dir (string-append "lgbad" v) "" '()
                     (list (string-append "TECHO_DB_PATH=" db) "CHEZ_HTTP_PORT=0"
                           (string-append "TECHO_BEHIND_PROXY=" v))
                     '("serve"))))
   '("x" "9" "zzq7")))

;; --- nodes over the wire (slice 4) ----------------------------------------
;;
;; A server on a fresh file made by `techo migrate`; two accounts made by
;; `techo user add`; a key each from POST /v1/login. Then the seven routes as
;; a client calls them, in a fixed order. Each call is filed under a name, and
;; the log line it should leave is remembered. The title's and the body's
;; marker words are searched for in the server's standard output, and the
;; file is read when the server has stopped.

(define nd-pw-a "nodes pw of the first")
(define nd-pw-b "nodes pw of the second")
(define nd-n1 "0190b3a4-5c6d-7e8f-9a0b-000000000001")
(define nd-n2 "0190b3a4-5c6d-7e8f-9a0b-000000000002")
(define nd-n3 "0190b3a4-5c6d-7e8f-9a0b-000000000003")
(define nd-n5 "0190b3a4-5c6d-7e8f-9a0b-000000000005")
(define nd-v4 "0190b3a4-5c6d-4e8f-9a0b-000000000004")
(define nd-n6 "0190b3a4-5c6d-7e8f-9a0b-000000000006")
;; nd-unknown-key : String    a key of the right shape that no row holds
(define nd-unknown-key (string-append "techo_" (make-string 64 #\7)))
;; nd-hostile : String
;; An array of 2,000 integers of 1,000 digits, about 2 MB: under the
;; request's cap of 2 MiB, and about 260 ms of the loop's time to parse.
(define nd-hostile
  (call-with-string-output-port
   (lambda (p)
     (put-string p "[")
     (let loop ((i 0))
       (when (< i 2000)
         (put-string p (make-string 1000 #\7))
         (put-string p ",")
         (loop (+ i 1))))
     (put-string p "1]"))))
(define nd-title-word "zebratitle")
(define nd-body-word "quokkabody")
(define nd-body-cap 1048576)

;; the expected request log, newest first: (METHOD path status who)
(define nd-calls '())

;; nd-json : String String -> String    a create's or a replace's content
(define (nd-json title body)
  (string-append "{\"kind\":\"note\",\"title\":\"" title "\",\"body\":\"" body
                 "\",\"content_type\":\"text/plain\"}"))

;; nd-big : Nat -> String    N characters that start with the body marker
(define (nd-big n)
  (let ((m (string-length nd-body-word)))
    (string-append nd-body-word
                   (list->string
                    (let loop ((i (- n 1)) (acc '()))
                      (if (< i m)
                          acc
                          (loop (- i 1) (cons (integer->char (+ 97 (mod (* i 7) 26))) acc))))))))

;; nd-call! : Nat String Symbol String String Headers (U String #f) Symbol -> Void
;; One request with KEY, filed under NAME. BODY, when there is one, is sent as JSON.
(define (nd-call! port name method path key headers body who)
  (let ((r (attempt (lambda ()
                      (hcall port method path (and body "application/json") (or body "")
                             (append (bearer key) headers))))))
    (obs-set! name r)
    (when (and (pair? r) (not (eq? (car r) 'raised)))
      (set! nd-calls (cons (list (string-upcase (symbol->string method)) path
                                 (number->string (lg-status r)) who)
                           nd-calls)))))

(define nd-create (list (cons "If-None-Match" "*")))
(define (nd-match n) (list (cons "If-Match" (string-append "\"" (number->string n) "\""))))

;; observe-nodes! : String -> Void
(define (observe-nodes! dir)
  (define db (string-append dir "/nodes.db"))
  (define env (list (string-append "TECHO_DB_PATH=" db)))
  (define (add! name pw user)
    (id-of-added (run-cli-in dir name (string-append pw "\n") '() env
                             (list "user" "add" "--username" user "--email" (string-append user "@example.com")))))
  (obs-set! "nd:migrate" (car (run-cli-in dir "ndmigrate" "" '() env '("migrate"))))
  (obs-set! "nd:a-id" (add! "nd-add-a" nd-pw-a "nodea"))
  (obs-set! "nd:b-id" (add! "nd-add-b" nd-pw-b "nodeb"))
  (with-server dir "ndsrv" db #f
    (lambda (port)
      (define (key-of email pw)
        (let* ((r (hcall port 'post "/v1/login" "application/json" (login-json email pw "nodes") '()))
               (k (jget (lg-json r) "key")))
          (if (string? k) k "techo_missing")))
      (let* ((ka (key-of "nodea@example.com" nd-pw-a))
            (kb (key-of "nodeb@example.com" nd-pw-b))
            (p1 (string-append "/v1/nodes/" nd-n1))
            (p2 (string-append "/v1/nodes/" nd-n2))
            (p3 (string-append "/v1/nodes/" nd-n3))
            (uni (string-append "quokkabody \x3053;\x3093;\x306b;\x3061;\x306f; \x1F38C; na\xEF;ve \x65E5;\x672C;\x8A9E;"))
            (big (nd-big nd-body-cap)))
        (define (a! name method path headers body) (nd-call! port name method path ka headers body 'a))
        (define (b! name method path headers body) (nd-call! port name method path kb headers body 'b))
        (a! "nd:create" 'put p1 nd-create (nd-json (string-append nd-title-word " one") (string-append nd-body-word " first")) )
        (a! "nd:get" 'get p1 '() #f)
        (a! "nd:replace" 'put p1 (nd-match 1) (nd-json (string-append nd-title-word " two") (string-append nd-body-word " second")))
        (a! "nd:replace-again" 'put p1 (nd-match 1) (nd-json (string-append nd-title-word " three") (string-append nd-body-word " third")))
        (a! "nd:get-after" 'get p1 '() #f)
        (a! "nd:no-header" 'put p1 '() (nd-json (string-append nd-title-word " four") (string-append nd-body-word " fourth")))
        (a! "nd:create-again" 'put p1 nd-create (nd-json (string-append nd-title-word " five") (string-append nd-body-word " fifth")))
        (a! "nd:revisions" 'get (string-append p1 "/revisions") '() #f)
        (a! "nd:revision-1" 'get (string-append p1 "/revisions/1") '() #f)
        (a! "nd:restore" 'post (string-append p1 "/revisions/1/restore") (nd-match 2) #f)
        (b! "nd:b-get" 'get p1 '() #f)
        (b! "nd:b-replace" 'put p1 (nd-match 3) (nd-json (string-append nd-title-word " six") (string-append nd-body-word " sixth")))
        (b! "nd:b-restore" 'post (string-append p1 "/revisions/1/restore") (nd-match 3) #f)
        (b! "nd:b-revisions" 'get (string-append p1 "/revisions") '() #f)
        (b! "nd:b-list" 'get "/v1/nodes" '() #f)
        (b! "nd:b-create" 'put p1 nd-create (nd-json (string-append nd-title-word " seven") (string-append nd-body-word " seventh")))
        (a! "nd:a-list" 'get "/v1/nodes" '() #f)
        (a! "nd:uni-create" 'put p2 nd-create (nd-json (string-append nd-title-word " \x65E5;\x672C;") uni))
        (a! "nd:uni-get" 'get p2 '() #f)
        (obs-set! "nd:uni-sent" uni)
        (a! "nd:big-create" 'put p3 nd-create (nd-json (string-append nd-title-word " big") big))
        (a! "nd:big-get" 'get p3 '() #f)
        (obs-set! "nd:big-sent" big)
        (a! "nd:over" 'put (string-append "/v1/nodes/" nd-n5) nd-create
            (nd-json (string-append nd-title-word " over") (string-append big "a")))
        (a! "nd:v4" 'put (string-append "/v1/nodes/" nd-v4) nd-create
            (nd-json (string-append nd-title-word " v4") (string-append nd-body-word " v4")))
        (nd-call! port "nd:hostile" 'put (string-append "/v1/nodes/" nd-n6) nd-unknown-key
                  nd-create nd-hostile 'none))))
  (obs-set! "nd:expect" (reverse nd-calls))
  (obs-set! "nd:db"
    (attempt
     (lambda ()
       (with-db (open-techo-db db 'read-only)
         (lambda (c)
           (define (n sql) (vector-ref (query-row c sql) 0))
           (define (seqs who)
             (map (lambda (r) (vector-ref r 0))
                  (query c (string-append "SELECT seq FROM changes WHERE owner = (SELECT id FROM accounts WHERE username = '"
                                          who "') ORDER BY seq"))))
           (list (n "SELECT count(*) FROM nodes")
                 (n "SELECT count(*) FROM revisions")
                 (n "SELECT count(*) FROM changes")
                 (seqs "nodea") (seqs "nodeb")
                 (map (lambda (r) (vector-ref r 0))
                      (query c "SELECT op FROM changes ORDER BY seq"))
                 (map (lambda (r) (vector-ref r 0))
                      (query c "SELECT revision FROM nodes ORDER BY revision")))))))))

;; --- the node lifecycle over the wire (slice 4b) ---------------------------
;;
;; A second server on a fresh file, two accounts. One node (lc-n1) lives the
;; whole story: archive, replace while archived, unarchive, trash, the
;; refusals, untrash, a purge. A second node stays live for the other
;; account's attempts; a third is trashed and purged with bodies on the
;; requests. Each call is filed under a name, and the log line it should
;; leave is remembered in lc-calls.

(define lc-n1 "0190b3a4-5c6d-7e8f-9a0b-0000000000a1")
(define lc-n2 "0190b3a4-5c6d-7e8f-9a0b-0000000000a2")
(define lc-n3 "0190b3a4-5c6d-7e8f-9a0b-0000000000a3")
(define lc-title-word "narwhaltitle")
(define lc-body-word "pangolinbody")
(define lc-calls '())

;; lc-path-of : String -> String    the target without its query
(define (lc-path-of target)
  (let loop ((i 0))
    (cond ((= i (string-length target)) target)
          ((char=? (string-ref target i) #\?) (substring target 0 i))
          (else (loop (+ i 1))))))

;; lc-call! : Nat String Symbol String String Headers (U String #f) Symbol -> Void
;; One request with KEY, filed under NAME; its expected log line is kept.
(define (lc-call! port name method target key headers body who)
  (let ((r (attempt (lambda ()
                      (hcall port method target (and body "application/json") (or body "")
                             (append (bearer key) headers))))))
    (obs-set! name r)
    (when (and (pair? r) (not (eq? (car r) 'raised)))
      (set! lc-calls (cons (list (string-upcase (symbol->string method)) (lc-path-of target)
                                 (number->string (lg-status r)) who)
                           lc-calls)))))

;; observe-lifecycle! : String -> Void
(define (observe-lifecycle! dir)
  (define db (string-append dir "/lifecycle.db"))
  (define env (list (string-append "TECHO_DB_PATH=" db)))
  (define (add! name pw user)
    (id-of-added (run-cli-in dir name (string-append pw "\n") '() env
                             (list "user" "add" "--username" user "--email" (string-append user "@example.com")))))
  (set! lc-calls '())
  (obs-set! "lc:migrate" (car (run-cli-in dir "lcmigrate" "" '() env '("migrate"))))
  (obs-set! "lc:a-id" (add! "lc-add-a" nd-pw-a "lifea"))
  (obs-set! "lc:b-id" (add! "lc-add-b" nd-pw-b "lifeb"))
  (with-server dir "lcsrv" db #f
    (lambda (port)
      (define (key-of email pw)
        (let* ((r (hcall port 'post "/v1/login" "application/json" (login-json email pw "life") '()))
               (k (jget (lg-json r) "key")))
          (if (string? k) k "techo_missing")))
      (let* ((ka (key-of "lifea@example.com" nd-pw-a))
             (kb (key-of "lifeb@example.com" nd-pw-b))
             (p1 (string-append "/v1/nodes/" lc-n1))
             (p2 (string-append "/v1/nodes/" lc-n2))
             (p3 (string-append "/v1/nodes/" lc-n3))
             (doc (lambda (n) (nd-json (string-append lc-title-word " " n) (string-append lc-body-word " " n)))))
        (define (a! name method path headers body) (lc-call! port name method path ka headers body 'a))
        (define (b! name method path headers body) (lc-call! port name method path kb headers body 'b))
        ;; the story of the first node: revisions 1 (create), 2 (archive),
        ;; 3 (replace), 4 (unarchive), 5 (trash), 6 (untrash), 7 (trash), 8 (purge)
        (a! "lc:create" 'put p1 nd-create (doc "one"))
        (a! "lc:unarchive-active" 'post (string-append p1 "/unarchive") (nd-match 1) #f)
        (a! "lc:archive" 'post (string-append p1 "/archive") (nd-match 1) #f)
        (a! "lc:list-active-1" 'get "/v1/nodes" '() #f)
        (a! "lc:list-archived" 'get "/v1/nodes?state=archived" '() #f)
        (a! "lc:get-archived" 'get p1 '() #f)
        (a! "lc:replace-archived" 'put p1 (nd-match 2) (doc "three"))
        (a! "lc:unarchive" 'post (string-append p1 "/unarchive") (nd-match 3) #f)
        (a! "lc:get-active" 'get p1 '() #f)
        (a! "lc:trash" 'post (string-append p1 "/trash") (nd-match 4) #f)
        (a! "lc:replace-trashed" 'put p1 (nd-match 5) (doc "x"))
        (a! "lc:restore-trashed" 'post (string-append p1 "/revisions/1/restore") (nd-match 5) #f)
        (a! "lc:archive-trashed" 'post (string-append p1 "/archive") (nd-match 5) #f)
        (a! "lc:list-active-2" 'get "/v1/nodes" '() #f)
        (a! "lc:list-archived-2" 'get "/v1/nodes?state=archived" '() #f)
        (a! "lc:list-trashed" 'get "/v1/nodes?state=trashed" '() #f)
        (a! "lc:get-trashed" 'get p1 '() #f)
        (a! "lc:stale-trash" 'post (string-append p1 "/trash") (nd-match 4) #f)
        (a! "lc:stale-untrash" 'post (string-append p1 "/untrash") (nd-match 4) #f)
        (a! "lc:untrash-bare" 'post (string-append p1 "/untrash") '() #f)
        (a! "lc:untrash-none-match" 'post (string-append p1 "/untrash") (list (cons "If-None-Match" "*")) #f)
        (a! "lc:list-purged" 'get "/v1/nodes?state=purged" '() #f)
        (a! "lc:list-nonsense" 'get "/v1/nodes?state=nonsense" '() #f)
        (a! "lc:untrash" 'post (string-append p1 "/untrash") (nd-match 5) #f)
        (a! "lc:revisions" 'get (string-append p1 "/revisions") '() #f)
        (a! "lc:revision-gap" 'get (string-append p1 "/revisions/2") '() #f)
        (a! "lc:revision-3" 'get (string-append p1 "/revisions/3") '() #f)
        (a! "lc:delete-active" 'delete p1 (nd-match 6) #f)
        (a! "lc:trash-again" 'post (string-append p1 "/trash") (nd-match 6) #f)
        (a! "lc:delete-bare" 'delete p1 '() #f)
        (a! "lc:delete" 'delete p1 (nd-match 7) #f)
        ;; after the purge
        (a! "lc:p-get" 'get p1 '() #f)
        (a! "lc:p-revisions" 'get (string-append p1 "/revisions") '() #f)
        (a! "lc:p-revision" 'get (string-append p1 "/revisions/1") '() #f)
        (a! "lc:p-replace" 'put p1 (nd-match 8) (doc "y"))
        (a! "lc:p-delete" 'delete p1 (nd-match 8) #f)
        (a! "lc:p-trash" 'post (string-append p1 "/trash") (nd-match 8) #f)
        (a! "lc:p-create" 'put p1 nd-create (doc "z"))
        (b! "lc:p-b-create" 'put p1 nd-create (doc "z"))
        ;; the second node stays live; the other account tries every new route on it
        (a! "lc:n2-create" 'put p2 nd-create (doc "two"))
        (b! "lc:b-archive" 'post (string-append p2 "/archive") (nd-match 1) #f)
        (b! "lc:b-unarchive" 'post (string-append p2 "/unarchive") (nd-match 1) #f)
        (b! "lc:b-trash" 'post (string-append p2 "/trash") (nd-match 1) #f)
        (b! "lc:b-untrash" 'post (string-append p2 "/untrash") (nd-match 1) #f)
        (b! "lc:b-delete" 'delete p2 (nd-match 1) #f)
        (a! "lc:n2-get" 'get p2 '() #f)
        (a! "lc:list-active-3" 'get "/v1/nodes" '() #f)
        (a! "lc:list-archived-3" 'get "/v1/nodes?state=archived" '() #f)
        (a! "lc:list-trashed-3" 'get "/v1/nodes?state=trashed" '() #f)
        ;; a body on a state change is not read
        (a! "lc:n3-create" 'put p3 nd-create (doc "three"))
        (a! "lc:n3-trash-body" 'post (string-append p3 "/trash") (nd-match 1) "{\"not\": json")
        (a! "lc:n3-delete-body" 'delete p3 (nd-match 2) "[1, 2, oops")
        (a! "lc:n3-after" 'get "/v1/nodes" '() #f))))
  (obs-set! "lc:expect" (reverse lc-calls))
  (obs-set! "lc:db"
    (attempt
     (lambda ()
       (with-db (open-techo-db db 'read-only)
         (lambda (c)
           (define (n sql) (vector-ref (query-row c sql) 0))
           (define (col sql) (map (lambda (r) (vector-ref r 0)) (query c sql)))
           (list (col "SELECT state FROM nodes ORDER BY num")
                 (col "SELECT revision FROM nodes ORDER BY num")
                 (col "SELECT title FROM nodes ORDER BY num")
                 (col "SELECT revision FROM revisions WHERE node = (SELECT id FROM nodes ORDER BY num LIMIT 1) ORDER BY revision")
                 (n "SELECT count(*) FROM revisions WHERE node = (SELECT id FROM nodes ORDER BY num DESC LIMIT 1)")
                 (col "SELECT op FROM changes ORDER BY seq")
                 (col "SELECT seq FROM changes ORDER BY seq"))))))))

;; --- the tree over the wire (slice 5a) -------------------------------------
;;
;; A third server on a fresh file, two accounts. A project (tr-p), a note in
;; it, a journal and a task at the top level; the lists by parent; the moves
;; and every refusal; the project trashed and emptied with a bulk move, then
;; purged; a second project holding a note and a task, emptied into the
;; journal; the other account's attempts. Each call is filed under a name,
;; and the log line it should leave is remembered in tr-calls.

(define (tr-id n)
  (string-append "0190b3a4-5c6d-7e8f-9a0b-000000000" (if (< n 16) "0" "") "b" (number->string n 16)))
(define tr-p (tr-id 1))    ; project
(define tr-n (tr-id 2))    ; note, made in the project
(define tr-j (tr-id 3))    ; journal
(define tr-t (tr-id 4))    ; task
(define tr-q (tr-id 5))    ; project in the project
(define tr-m (tr-id 6))    ; note in the project, made before it is trashed
(define tr-p2 (tr-id 7))   ; second project
(define tr-n2 (tr-id 8))   ; its note
(define tr-t2 (tr-id 9))   ; its task
(define tr-nb (tr-id 10))  ; the second account's note
(define tr-nobody (tr-id 11)) ; an id nobody holds
(define tr-x1 (tr-id 12))  ; ids of creates and moves that are refused
(define tr-x2 (tr-id 13))
(define tr-x3 (tr-id 14))
(define tr-x4 (tr-id 15))
(define tr-n3 (tr-id 16))  ; a trashed note in the second project
(define tr-n4 (tr-id 17))  ; an archived note in the second project
(define tr-title-word "gannettitle")
(define tr-body-word "wombatbody")
(define tr-calls '())

;; tr-doc : String String (U String 'none 'null) -> String
;; A note's create or replace: PARENT is an id, 'null, or 'none (no member).
(define (tr-doc kind n parent)
  (string-append "{\"kind\":\"" kind "\",\"title\":\"" tr-title-word " " n "\",\"body\":\"" tr-body-word " " n
                 "\",\"content_type\":\"text/plain\""
                 (cond ((string? parent) (string-append ",\"parent\":\"" parent "\""))
                       ((eq? parent 'null) ",\"parent\":null")
                       (else ""))
                 "}"))

;; tr-to : (U String #f) -> String    a move's body: the parent, or null
(define (tr-to p)
  (if p (string-append "{\"parent\":\"" p "\"}") "{\"parent\":null}"))

;; tr-call! : Nat String Symbol String String Headers (U String #f) (U String #f) Symbol -> Void
;; One request with KEY, filed under NAME; its expected log line is kept.
;; CTYPE #f: application/json when there is a body.
(define (tr-call! port name method target key headers body ctype who)
  (let ((r (attempt (lambda ()
                      (hcall port method target (or ctype (and body "application/json")) (or body "")
                             (append (bearer key) headers))))))
    (obs-set! name r)
    (when (and (pair? r) (not (eq? (car r) 'raised)))
      (set! tr-calls (cons (list (string-upcase (symbol->string method)) (lc-path-of target)
                                 (number->string (lg-status r))
                                 (if (or (= (lg-status r) 428)
                                         (and (= (lg-status r) 400)
                                              (or (string=? name "tr:none-match") (and (> (string-length name) 8) (string=? (substring name 0 8) "tr:list-")))))
                                     '- who))
                           tr-calls)))))

;; observe-tree! : String -> Void
(define (observe-tree! dir)
  (define db (string-append dir "/tree.db"))
  (define env (list (string-append "TECHO_DB_PATH=" db)))
  (define (add! name pw user)
    (id-of-added (run-cli-in dir name (string-append pw "\n") '() env
                             (list "user" "add" "--username" user "--email" (string-append user "@example.com")))))
  (set! tr-calls '())
  (obs-set! "tr:migrate" (car (run-cli-in dir "trmigrate" "" '() env '("migrate"))))
  (obs-set! "tr:a-id" (add! "tr-add-a" nd-pw-a "treea"))
  (obs-set! "tr:b-id" (add! "tr-add-b" nd-pw-b "treeb"))
  (with-server dir "trsrv" db #f
    (lambda (port)
      (define (key-of email pw)
        (let* ((r (hcall port 'post "/v1/login" "application/json" (login-json email pw "tree") '()))
               (k (jget (lg-json r) "key")))
          (if (string? k) k "techo_missing")))
      (let* ((ka (key-of "treea@example.com" nd-pw-a))
             (kb (key-of "treeb@example.com" nd-pw-b))
             (path (lambda (id) (string-append "/v1/nodes/" id)))
             (mv (lambda (id) (string-append "/v1/nodes/" id "/move")))
             (mc (lambda (id) (string-append "/v1/nodes/" id "/move-children")))
             (kids (lambda (id) (string-append "/v1/nodes?parent=" id))))
        (define (a! name method target headers body) (tr-call! port name method target ka headers body #f 'a))
        (define (b! name method target headers body) (tr-call! port name method target kb headers body #f 'b))
        ;; the first nodes and the lists
        (a! "tr:p-create" 'put (path tr-p) nd-create (tr-doc "project" "p" 'none))
        (a! "tr:n-create" 'put (path tr-n) nd-create (tr-doc "note" "n" tr-p))
        (a! "tr:j-create" 'put (path tr-j) nd-create (tr-doc "journal" "j" 'null))
        (a! "tr:t-create" 'put (path tr-t) nd-create (tr-doc "task" "t" 'none))
        (a! "tr:list-top" 'get "/v1/nodes?parent=null" '() #f)
        (a! "tr:list-p" 'get (kids tr-p) '() #f)
        (a! "tr:list-flat" 'get "/v1/nodes" '() #f)
        ;; moves, and the kinds a parent holds
        (a! "tr:t-to-p" 'post (mv tr-t) (nd-match 1) (tr-to tr-p))
        (a! "tr:t-to-j" 'post (mv tr-t) (nd-match 2) (tr-to tr-j))
        (a! "tr:n-to-j" 'post (mv tr-n) (nd-match 1) (tr-to tr-j))
        (a! "tr:n-under-t" 'post (mv tr-n) (nd-match 2) (tr-to tr-t))
        (a! "tr:list-j" 'get (kids tr-j) '() #f)
        (a! "tr:list-p-2" 'get (kids tr-p) '() #f)
        ;; loops
        (a! "tr:q-create" 'put (path tr-q) nd-create (tr-doc "project" "q" tr-p))
        (a! "tr:p-under-q" 'post (mv tr-p) (nd-match 1) (tr-to tr-q))
        (a! "tr:p-under-p" 'post (mv tr-p) (nd-match 1) (tr-to tr-p))
        ;; the shape of a move request
        (a! "tr:stale" 'post (mv tr-t) (nd-match 1) (tr-to #f))
        (a! "tr:no-match" 'post (mv tr-t) '() (tr-to #f))
        (a! "tr:none-match" 'post (mv tr-t) (list (cons "If-None-Match" "*")) (tr-to #f))
        (tr-call! port "tr:text-plain" 'post (mv tr-t) ka (nd-match 2) (tr-to #f) "text/plain" 'a)
        (a! "tr:empty-object" 'post (mv tr-t) (nd-match 2) "{}")
        (a! "tr:extra-member" 'post (mv tr-t) (nd-match 2) "{\"parent\":null,\"x\":1}")
        (a! "tr:replace-parent" 'put (path tr-n) (nd-match 2) (tr-doc "note" "n" tr-j))
        (a! "tr:t-after-refusals" 'get (path tr-t) '() #f)
        ;; to the top level
        (a! "tr:t-to-top" 'post (mv tr-t) (nd-match 2) (tr-to #f))
        (a! "tr:list-top-2" 'get "/v1/nodes?parent=null" '() #f)
        ;; the project is trashed; its children keep their state
        (a! "tr:m-create" 'put (path tr-m) nd-create (tr-doc "note" "m" tr-p))
        (a! "tr:p-trash" 'post (string-append (path tr-p) "/trash") (nd-match 1) #f)
        (a! "tr:q-after-trash" 'get (path tr-q) '() #f)
        (a! "tr:list-flat-2" 'get "/v1/nodes" '() #f)
        (a! "tr:list-p-3" 'get (kids tr-p) '() #f)
        (a! "tr:create-in-trashed" 'put (path tr-x1) nd-create (tr-doc "note" "x" tr-p))
        (a! "tr:t-into-trashed" 'post (mv tr-t) (nd-match 3) (tr-to tr-p))
        (a! "tr:p-move-trashed" 'post (mv tr-p) (nd-match 2) (tr-to #f))
        ;; purge refused, the children moved out, then the purge
        (a! "tr:p-delete-full" 'delete (path tr-p) (nd-match 2) #f)
        (a! "tr:p-move-children" 'post (mc tr-p) (nd-match 2) (tr-to #f))
        (a! "tr:p-get" 'get (path tr-p) '() #f)
        (a! "tr:q-get" 'get (path tr-q) '() #f)
        (a! "tr:m-get" 'get (path tr-m) '() #f)
        (a! "tr:p-delete" 'delete (path tr-p) (nd-match 2) #f)
        (a! "tr:p-get-purged" 'get (path tr-p) '() #f)
        ;; a bulk move that leaves a task behind
        (a! "tr:p2-create" 'put (path tr-p2) nd-create (tr-doc "project" "p2" 'none))
        (a! "tr:n2-create" 'put (path tr-n2) nd-create (tr-doc "note" "n2" tr-p2))
        (a! "tr:t2-create" 'put (path tr-t2) nd-create (tr-doc "task" "t2" tr-p2))
        (a! "tr:n3-create" 'put (path tr-n3) nd-create (tr-doc "note" "n3" tr-p2))
        (a! "tr:n3-trash" 'post (string-append (path tr-n3) "/trash") (nd-match 1) #f)
        (a! "tr:n4-create" 'put (path tr-n4) nd-create (tr-doc "note" "n4" tr-p2))
        (a! "tr:n4-archive" 'post (string-append (path tr-n4) "/archive") (nd-match 1) #f)
        (a! "tr:p2-into-p2" 'post (mc tr-p2) (nd-match 1) (tr-to tr-p2))
        (a! "tr:p2-into-j" 'post (mc tr-p2) (nd-match 1) (tr-to tr-j))
        (a! "tr:p2-get" 'get (path tr-p2) '() #f)
        (a! "tr:list-p2" 'get (kids tr-p2) '() #f)
        (a! "tr:list-j-2" 'get (kids tr-j) '() #f)
        (a! "tr:list-p2-trashed" 'get (string-append (kids tr-p2) "&state=trashed") '() #f)
        (a! "tr:list-j-archived" 'get (string-append (kids tr-j) "&state=archived") '() #f)
        ;; the other account
        (b! "tr:b-move" 'post (mv tr-p2) (nd-match 1) (tr-to #f))
        (b! "tr:b-move-children" 'post (mc tr-p2) (nd-match 1) (tr-to #f))
        (a! "tr:p2-get-after-b" 'get (path tr-p2) '() #f)
        (a! "tr:list-p2-after-b" 'get (kids tr-p2) '() #f)
        (b! "tr:b-create-under-a" 'put (path tr-x2) nd-create (tr-doc "note" "bx" tr-p2))
        (b! "tr:b-create-under-nobody" 'put (path tr-x2) nd-create (tr-doc "note" "bx" tr-nobody))
        (b! "tr:nb-create" 'put (path tr-nb) nd-create (tr-doc "note" "nb" 'none))
        (b! "tr:b-move-under-a" 'post (mv tr-nb) (nd-match 1) (tr-to tr-p2))
        (b! "tr:b-move-under-nobody" 'post (mv tr-nb) (nd-match 1) (tr-to tr-nobody))
        (b! "tr:b-list-a-project" 'get (kids tr-p2) '() #f)
        (b! "tr:b-list-nobody" 'get (kids tr-nobody) '() #f)
        ;; bad spellings and a missing id
        (a! "tr:list-empty" 'get "/v1/nodes?parent=" '() #f)
        (a! "tr:list-NULL" 'get "/v1/nodes?parent=NULL" '() #f)
        (a! "tr:list-twice" 'get (string-append "/v1/nodes?parent=" tr-j "&parent=" tr-j) '() #f)
        (a! "tr:list-junk" 'get "/v1/nodes?parent=junk" '() #f)
        (a! "tr:list-missing" 'get (kids tr-nobody) '() #f)
        (a! "tr:move-missing" 'post (mv tr-nobody) (nd-match 1) (tr-to #f))
        (a! "tr:move-children-missing" 'post (mc tr-nobody) (nd-match 1) (tr-to #f))
        (a! "tr:list-purged-parent" 'get (kids tr-p) '() #f)
        ;; a bulk move to the top level leaves a trashed child
        (a! "tr:p2-to-top" 'post (mc tr-p2) (nd-match 1) (tr-to #f))
        (a! "tr:t2-get" 'get (path tr-t2) '() #f)
        (a! "tr:list-p2-trashed-2" 'get (string-append (kids tr-p2) "&state=trashed") '() #f))))
  (obs-set! "tr:expect" (reverse tr-calls))
  (obs-set! "tr:db"
    (attempt
     (lambda ()
       (with-db (open-techo-db db 'read-only)
         (lambda (c)
           (define (col sql) (map (lambda (r) (vector-ref r 0)) (query c sql)))
           (list (col "SELECT state FROM nodes ORDER BY num")
                 (col "SELECT revision FROM nodes ORDER BY num")
                 (col "SELECT lower(hex(id)) FROM nodes ORDER BY num")
                 (col "SELECT lower(hex(parent)) FROM nodes ORDER BY num")
                 (col "SELECT count(*) FROM nodes WHERE parent = (SELECT id FROM nodes ORDER BY num LIMIT 1)")
                 (col "SELECT op FROM changes WHERE owner = (SELECT owner FROM nodes ORDER BY num LIMIT 1) ORDER BY seq")
                 (col "SELECT lower(hex(node)) || ':' || revision FROM changes WHERE op = 'move' AND owner = (SELECT owner FROM nodes ORDER BY num LIMIT 1) ORDER BY seq"))))))))


;; --- links over the wire (slice 5b): the observing ---------------------------

(define (ln-id n)
  (string-append "0190b3a4-5c6d-7e8f-9a0b-0000000000" (if (< n 16) "0" "") (number->string n 16)))
(define ln-x (ln-id 1))
(define ln-y (ln-id 2))
(define ln-z (ln-id 3))
(define ln-t (ln-id 4))
(define ln-s (ln-id 5))
(define ln-h (ln-id 6))
(define ln-a (ln-id 7))
(define ln-bn (ln-id 8))
(define ln-nobody (ln-id 9))
(define ln-nobody2 (ln-id 10))
(define ln-v4 "0190b3a4-5c6d-4e8f-9a0b-00000000000b")
(define ln-title-word "ocelottitle")

;; ln-doc : String String -> String
(define (ln-doc kind n)
  (string-append "{\"kind\":\"" kind "\",\"title\":\"" ln-title-word " " n
                 "\",\"body\":\"ocelotbody " n "\",\"content_type\":\"text/plain\"}"))

;; ln-url : String String String -> String
(define (ln-url src type tgt) (string-append "/v1/nodes/" src "/links/" type "/" tgt))
(define (ln-list id query) (string-append "/v1/nodes/" id "/links" query))

;; ln-summary : Json -> (List String String)    an item's type and its node's id
(define (ln-summary i) (list (jget i "type") (jget (jget i "node") "id")))

;; ln-pages : Nat String String String -> (Listof (List Status (Listof (List String String)) Next))
;; Follows `next` from BASE (a path with its query) with KEY until it is null,
;; at most 12 pages.
(define (ln-pages port key base)
  (let loop ((after #f) (n 0) (acc '()))
    (let* ((r (hcall port 'get (if after (string-append base "&after=" after) base) #f ""
                     (bearer key)))
           (j (lg-json r))
           (next (jget j "next"))
           (page (list (lg-status r)
                       (if (= (lg-status r) 200) (map ln-summary (jitems j)) 'none)
                       next)))
      (if (and (string? next) (< n 12))
          (loop next (+ n 1) (cons page acc))
          (reverse (cons page acc))))))

;; observe-links! : String -> Void
(define (observe-links! dir)
  (define db (string-append dir "/links.db"))
  (define env (list (string-append "TECHO_DB_PATH=" db)))
  (define (add! name pw user)
    (id-of-added (run-cli-in dir name (string-append pw "\n") '() env
                             (list "user" "add" "--username" user "--email" (string-append user "@example.com")))))
  (obs-set! "ln:migrate" (car (run-cli-in dir "lnmigrate" "" '() env '("migrate"))))
  (obs-set! "ln:a-id" (add! "ln-add-a" nd-pw-a "linka"))
  (obs-set! "ln:b-id" (add! "ln-add-b" nd-pw-b "linkb"))
  (with-server dir "lnsrv" db #f
    (lambda (port)
      (define (key-of email pw)
        (let* ((r (hcall port 'post "/v1/login" "application/json" (login-json email pw "links") '()))
               (k (jget (lg-json r) "key")))
          (if (string? k) k "techo_missing")))
      (let* ((ka (key-of "linka@example.com" nd-pw-a))
             (kb (key-of "linkb@example.com" nd-pw-b))
             (path (lambda (id) (string-append "/v1/nodes/" id)))
             (pause (lambda () (sleep (make-time 'time-duration 30000000 0)))))
        (define (call! key name method target headers body ctype)
          (obs-set! name (attempt (lambda ()
                                    (hcall port method target ctype (or body "")
                                           (append (if key (bearer key) '()) headers))))))
        (define (a! name method target) (call! ka name method target '() #f #f))
        (define (ah! name method target headers) (call! ka name method target headers #f #f))
        (define (b! name method target) (call! kb name method target '() #f #f))
        (define (pages! name key base) (obs-set! name (attempt (lambda () (ln-pages port key base)))))
        ;; the nodes
        (for-each (lambda (spec)
                    (call! ka (string-append "ln:create-" (cadr spec)) 'put (path (car spec)) nd-create
                           (ln-doc "note" (cadr spec)) "application/json"))
                  (list (list ln-x "x") (list ln-y "y") (list ln-z "z") (list ln-t "t")
                        (list ln-s "s") (list ln-h "h") (list ln-a "a")))
        (call! kb "ln:create-bn" 'put (path ln-bn) nd-create (ln-doc "note" "bn") "application/json")
        ;; a link, twice; the nodes as they were
        (a! "ln:x-0" 'get (path ln-x))
        (a! "ln:y-0" 'get (path ln-y))
        (a! "ln:put-1" 'put (ln-url ln-x "related" ln-y))
        (pause)
        (a! "ln:put-2" 'put (ln-url ln-x "related" ln-y))
        (a! "ln:x-1" 'get (path ln-x))
        (a! "ln:y-1" 'get (path ln-y))
        (a! "ln:out-x-1" 'get (ln-list ln-x ""))
        (a! "ln:in-y-1" 'get (ln-list ln-y "?direction=in"))
        (a! "ln:nodes-list" (quote get) "/v1/nodes")
        (a! "ln:out-y-0" 'get (ln-list ln-y "?direction=out"))
        ;; three types between the same two nodes, the reverse, a second source
        (a! "ln:put-m" 'put (ln-url ln-x "mentions" ln-y))
        (a! "ln:put-b" 'put (ln-url ln-x "blocks" ln-y))
        (a! "ln:put-rev" 'put (ln-url ln-y "related" ln-x))
        (a! "ln:put-z" 'put (ln-url ln-z "related" ln-y))
        (a! "ln:out-x-3" 'get (ln-list ln-x "?direction=out"))
        (a! "ln:in-y-4" 'get (ln-list ln-y "?direction=in"))
        (a! "ln:out-y-1" 'get (ln-list ln-y ""))
        (a! "ln:in-x-1" 'get (ln-list ln-x "?direction=in"))
        (a! "ln:out-x-mentions" 'get (ln-list ln-x "?type=mentions"))
        (a! "ln:in-y-related" 'get (ln-list ln-y "?direction=in&type=related"))
        (a! "ln:in-x-blocks" 'get (ln-list ln-x "?direction=in&type=blocks"))
        ;; paging
        (pages! "ln:pg-out-x" ka (ln-list ln-x "?limit=1"))
        (pages! "ln:pg-in-y" ka (ln-list ln-y "?direction=in&limit=1"))
        (pages! "ln:pg-in-y-2" ka (ln-list ln-y "?direction=in&limit=2"))
        (pages! "ln:pg-in-y-related" ka (ln-list ln-y "?direction=in&type=related&limit=1"))
        (pages! "ln:pg-out-x-100" ka (ln-list ln-x "?limit=100"))
        (a! "ln:after-typed" 'get (ln-list ln-y (string-append "?direction=in&type=related&after=related:" ln-x)))
        (a! "ln:after-untyped" 'get (ln-list ln-y (string-append "?direction=in&after=mentions:" ln-x)))
        ;; a link removed
        (a! "ln:del-1" 'delete (ln-url ln-x "related" ln-y))
        (a! "ln:del-2" 'delete (ln-url ln-x "related" ln-y))
        (a! "ln:out-x-del" 'get (ln-list ln-x ""))
        (a! "ln:in-y-del" 'get (ln-list ln-y "?direction=in"))
        (a! "ln:out-y-del" 'get (ln-list ln-y ""))
        (a! "ln:x-del" 'get (path ln-x))
        (a! "ln:y-del" 'get (path ln-y))
        ;; a trashed target
        (a! "ln:put-t" 'put (ln-url ln-x "related" ln-t))
        (pause)
        (ah! "ln:t-trash" 'post (string-append (path ln-t) "/trash") (nd-match 1))
        (a! "ln:put-t-new" 'put (ln-url ln-x "mentions" ln-t))
        (a! "ln:put-from-t" 'put (ln-url ln-t "mentions" ln-x))
        (a! "ln:put-from-t-to-nobody" 'put (ln-url ln-t "mentions" ln-nobody))
        (a! "ln:put-t-again" 'put (ln-url ln-x "related" ln-t))
        (a! "ln:out-x-t" 'get (ln-list ln-x "?type=related"))
        (a! "ln:in-t" 'get (ln-list ln-t "?direction=in"))
        (a! "ln:out-t" 'get (ln-list ln-t ""))
        (a! "ln:del-t" 'delete (ln-url ln-x "related" ln-t))
        (a! "ln:out-x-t-del" 'get (ln-list ln-x "?type=related"))
        ;; a trashed source
        (a! "ln:put-s" 'put (ln-url ln-s "related" ln-x))
        (ah! "ln:s-trash" 'post (string-append (path ln-s) "/trash") (nd-match 1))
        (a! "ln:out-s" 'get (ln-list ln-s ""))
        (a! "ln:del-s" 'delete (ln-url ln-s "related" ln-x))
        (a! "ln:out-s-del" 'get (ln-list ln-s ""))
        ;; an archived target
        (ah! "ln:a-archive" 'post (string-append (path ln-a) "/archive") (nd-match 1))
        (a! "ln:put-a" 'put (ln-url ln-x "related" ln-a))
        (a! "ln:out-x-a" 'get (ln-list ln-x "?type=related"))
        ;; a body on a PUT
        (call! ka "ln:put-body" 'put (ln-url ln-x "related" ln-z) '() "{\"note\":\"ignored\"}" "application/json")
        (call! ka "ln:put-body-2" 'put (ln-url ln-x "related" ln-z) '() "{\"note\":\"ignored\"}" "application/json")
        (call! ka "ln:put-body-text" 'put (ln-url ln-z "mentions" ln-x) '() "not json" "text/plain")
        ;; a node linked both ways, trashed, purged
        (a! "ln:h-1" 'put (ln-url ln-h "related" ln-x))
        (a! "ln:h-2" 'put (ln-url ln-x "mentions" ln-h))
        (a! "ln:h-3" 'put (ln-url ln-z "blocks" ln-h))
        (a! "ln:h-4" 'put (ln-url ln-h "blocks" ln-z))
        (a! "ln:x-pre" 'get (path ln-x))
        (a! "ln:z-pre" 'get (path ln-z))
        (a! "ln:out-x-pre" 'get (ln-list ln-x ""))
        (a! "ln:in-x-pre" 'get (ln-list ln-x "?direction=in"))
        (a! "ln:out-z-pre" 'get (ln-list ln-z ""))
        (a! "ln:in-z-pre" 'get (ln-list ln-z "?direction=in"))
        (a! "ln:out-h-pre" 'get (ln-list ln-h ""))
        (ah! "ln:h-trash" 'post (string-append (path ln-h) "/trash") (nd-match 1))
        (a! "ln:out-h-trashed" 'get (ln-list ln-h ""))
        (a! "ln:in-h-trashed" 'get (ln-list ln-h "?direction=in"))
        (ah! "ln:h-purge" 'delete (path ln-h) (nd-match 2))
        (a! "ln:h-get" 'get (path ln-h))
        (a! "ln:out-h-purged" 'get (ln-list ln-h ""))
        (a! "ln:put-to-h" 'put (ln-url ln-x "related" ln-h))
        (a! "ln:put-from-h" 'put (ln-url ln-h "related" ln-x))
        (a! "ln:del-to-h" 'delete (ln-url ln-x "mentions" ln-h))
        (a! "ln:out-x-post" 'get (ln-list ln-x ""))
        (a! "ln:in-x-post" 'get (ln-list ln-x "?direction=in"))
        (a! "ln:out-z-post" 'get (ln-list ln-z ""))
        (a! "ln:in-z-post" 'get (ln-list ln-z "?direction=in"))
        (a! "ln:x-post" 'get (path ln-x))
        (a! "ln:z-post" 'get (path ln-z))
        ;; the other account
        (b! "ln:b-put-src" 'put (ln-url ln-x "related" ln-bn))
        (b! "ln:b-put-src-nobody" 'put (ln-url ln-nobody "related" ln-bn))
        (b! "ln:b-put-tgt" 'put (ln-url ln-bn "related" ln-x))
        (b! "ln:b-put-tgt-nobody" 'put (ln-url ln-bn "related" ln-nobody))
        (b! "ln:b-del" 'delete (ln-url ln-x "mentions" ln-y))
        (b! "ln:b-del-nobody" 'delete (ln-url ln-nobody "mentions" ln-y))
        (b! "ln:b-get" 'get (ln-list ln-x ""))
        (b! "ln:b-get-in" 'get (ln-list ln-y "?direction=in"))
        (b! "ln:b-get-nobody" 'get (ln-list ln-nobody ""))
        (a! "ln:a-put-bn" 'put (ln-url ln-x "related" ln-bn))
        (a! "ln:a-put-nobody" 'put (ln-url ln-x "related" ln-nobody))
        (a! "ln:out-x-after-b" 'get (ln-list ln-x ""))
        (a! "ln:in-y-after-b" 'get (ln-list ln-y "?direction=in"))
        (b! "ln:out-bn" 'get (ln-list ln-bn ""))
        ;; refused before anything is read
        (a! "ln:bad-type" 'put (ln-url ln-x "friend" ln-y))
        (a! "ln:bad-type-case" 'put (ln-url ln-x "Related" ln-y))
        (a! "ln:bad-type-del" 'delete (ln-url ln-x "friend" ln-y))
        (a! "ln:bad-type-nobody" 'put (ln-url ln-nobody "friend" ln-nobody2))
        (a! "ln:bad-source" 'put (ln-url "junk" "related" ln-y))
        (a! "ln:bad-target" 'put (ln-url ln-x "related" "junk"))
        (a! "ln:bad-target-del" 'delete (ln-url ln-x "related" "junk"))
        (a! "ln:v4-source" 'put (ln-url ln-v4 "related" ln-y))
        (a! "ln:v4-target" 'put (ln-url ln-x "related" ln-v4))
        (a! "ln:self-put" 'put (ln-url ln-x "related" ln-x))
        (a! "ln:self-del" 'delete (ln-url ln-x "related" ln-x))
        (ah! "ln:if-match-put" 'put (ln-url ln-x "related" ln-y) (nd-match 1))
        (ah! "ln:if-match-del" 'delete (ln-url ln-x "mentions" ln-y) (nd-match 1))
        (ah! "ln:if-none-match-put" 'put (ln-url ln-x "related" ln-y) nd-create)
        (ah! "ln:if-none-match-del" 'delete (ln-url ln-x "mentions" ln-y) nd-create)
        (ah! "ln:if-match-get" 'get (ln-list ln-x "?type=mentions") (nd-match 7))
        (a! "ln:q-direction" 'get (ln-list ln-x "?direction=sideways"))
        (a! "ln:q-direction-upper" 'get (ln-list ln-x "?direction=OUT"))
        (a! "ln:q-direction-twice" 'get (ln-list ln-x "?direction=out&direction=in"))
        (a! "ln:q-direction-empty" 'get (ln-list ln-x "?direction="))
        (a! "ln:q-type" 'get (ln-list ln-x "?type=friend"))
        (a! "ln:q-type-upper" 'get (ln-list ln-x "?type=Related"))
        (a! "ln:q-type-twice" 'get (ln-list ln-x "?type=related&type=blocks"))
        (a! "ln:q-type-empty" 'get (ln-list ln-x "?type="))
        (a! "ln:q-limit-0" 'get (ln-list ln-x "?limit=0"))
        (a! "ln:q-limit-twice" 'get (ln-list ln-x "?limit=1&limit=2"))
        (a! "ln:q-limit-empty" 'get (ln-list ln-x "?limit="))
        (a! "ln:q-after-junk" 'get (ln-list ln-x "?after=junk"))
        (a! "ln:q-after-no-colon" 'get (ln-list ln-x (string-append "?after=blocks" ln-y)))
        (a! "ln:q-after-type" 'get (ln-list ln-x "?after=friend:" ))
        (a! "ln:q-after-v4" 'get (ln-list ln-x (string-append "?after=blocks:" ln-v4)))
        (a! "ln:q-after-extra" 'get (ln-list ln-x (string-append "?after=blocks:" ln-y "x")))
        (a! "ln:q-after-other-type" 'get (ln-list ln-x (string-append "?type=related&after=blocks:" ln-y)))
        (a! "ln:q-after-twice" 'get (ln-list ln-x (string-append "?after=blocks:" ln-y "&after=blocks:" ln-y)))
        (a! "ln:q-after-empty" 'get (ln-list ln-x "?after="))
        (a! "ln:q-bad-id" 'get "/v1/nodes/junk/links")
        (call! #f "ln:no-key" 'put (ln-url ln-x "related" ln-y) '() #f #f)
        ;; no route
        (call! ka "ln:post-link" 'post (ln-url ln-x "related" ln-y) '() "" #f)
        (a! "ln:get-link" 'get (ln-url ln-x "related" ln-y))
        (call! ka "ln:post-list" 'post (ln-list ln-x "") '() "" #f))))
  (obs-set! "ln:db"
    (attempt
     (lambda ()
       (with-db (open-techo-db db 'read-only)
         (lambda (c)
           (define (col sql) (map (lambda (r) (vector-ref r 0)) (query c sql)))
           (list (col "SELECT count(*) FROM links")
                 (col "SELECT count(DISTINCT owner) FROM links")
                 (col "SELECT op FROM changes WHERE owner = (SELECT owner FROM nodes ORDER BY num LIMIT 1) ORDER BY seq")
                 (col "SELECT lower(hex(node)) || ':' || revision || ':' || op FROM changes WHERE op IN ('link','unlink') ORDER BY seq")
                 (col "SELECT revision FROM nodes ORDER BY num")
                 (col "SELECT state FROM nodes ORDER BY num")
                 (col "SELECT count(*) FROM revisions"))))))))
;; --- props and tasks over the wire (slice 6): the observing -----------------

(define (pw-id n)
  (string-append "0190b3a4-5c6d-7e8f-9a0b-0000000100" (if (< n 16) "0" "") (string-downcase (number->string n 16))))

;; pw-q : String -> String    single quotes become double ones: JSON written readably
(define (pw-q s) (list->string (map (lambda (c) (if (char=? c #\') #\" c)) (string->list s))))

;; pw-doc : (U String #f) String (U String #f) -> String
;; A node's JSON: KIND (none for a replace that names none), a title, the
;; props (single-quoted JSON text) when there are any.
(define (pw-doc kind title props)
  (string-append "{" (if kind (string-append "\"kind\":\"" kind "\",") "")
                 "\"title\":\"" title "\",\"body\":\"b\",\"content_type\":\"text/plain\""
                 (if props (string-append ",\"props\":" (pw-q props)) "") "}"))

;; pw-iota : Nat -> (Listof Nat)
(define (pw-iota n) (let loop ((i (- n 1)) (acc (quote ()))) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

;; pw-now-ms : -> Nat    the clock, in milliseconds since 1970
(define (pw-now-ms)
  (let ((t (current-time)))
    (+ (* 1000 (time-second t)) (div (time-nanosecond t) 1000000))))

(define pw-guide-contact
  "{'name':{'components':[{'kind':'given','value':'Ada'},{'kind':'surname','value':'Lovelace'}]},'emails':{'e1':{'address':'ada@example.com','contexts':{'work':true},'pref':1}},'phones':{'p1':{'number':'+44 20 7946 0000','features':{'mobile':true}}},'speakToAs':{'pronouns':{'k1':{'pronouns':'she/her'}}}}")

(define pw-rich-contact
  (string-append
   "{'name':{'components':[{'kind':'title','value':'Dr'},{'kind':'given','value':'Ada'},{'kind':'given2','value':'Augusta'},{'kind':'surname','value':'Lovelace'}],'isOrdered':true},"
   "'organizations':{'o1':{'name':'Analytical Engines Ltd','units':[{'name':'Research'}],'contexts':{'work':true}}},"
   "'titles':{'t1':{'name':'Programmer','kind':'role','organizationId':'o1'}},"
   "'emails':{'e1':{'address':'ada@example.com','contexts':{'work':true},'pref':1,'label':'main'},'e2':{'address':'ada@home.example','contexts':{'private':true},'pref':2},'e3':{'address':'lovelace@example.org'}},"
   "'phones':{'p1':{'number':'+44 20 7946 0000','features':{'mobile':true,'voice':true},'contexts':{'work':true},'pref':1},'p2':{'number':'+44 20 7946 0001'},'p3':{'number':'020 7946 0002','features':{'fax':true},'label':'fax'}},"
   "'addresses':{'a1':{'components':[{'kind':'number','value':'12'},{'kind':'name','value':'St James Square'},{'kind':'locality','value':'London'},{'kind':'postcode','value':'SW1Y 4JH'}],'isOrdered':true,'countryCode':'GB','full':'12 St James Square\\nLondon','contexts':{'work':true,'billing':true},'pref':1},'a2':{'full':'Ockham Park, Surrey','countryCode':'GB'}},"
   "'anniversaries':{'b1':{'kind':'birth','date':{'year':1815,'month':12,'day':10}}},"
   "'links':{'l1':{'uri':'https://example.com/ada','kind':'contact','contexts':{'work':true},'pref':1,'label':'site'},'l2':{'uri':'mailto:ada@example.com'}},"
   "'onlineServices':{'s1':{'service':'Mastodon','uri':'https://social.example/@ada','user':'ada','contexts':{'private':true},'pref':1}},"
   "'speakToAs':{'grammaticalGender':'feminine','pronouns':{'k1':{'pronouns':'she/her','contexts':{'private':true},'pref':1}}}}"))

;; the same emails, in two orders
(define pw-order-1
  "{'emails':{'e1':{'address':'a@b.com','pref':1},'e2':{'address':'c@d.com'},'e10':{'address':'e@f.com'}},'phones':{'p2':{'number':'2'},'p1':{'number':'1','pref':3}}}")
(define pw-order-2
  "{'phones':{'p1':{'pref':3,'number':'1'},'p2':{'number':'2'}},'emails':{'e10':{'address':'e@f.com'},'e2':{'address':'c@d.com'},'e1':{'pref':1,'address':'a@b.com'}}}")

(define pw-defaults-contact
  "{'kind':'individual','name':{'@type':'Name','components':[{'@type':'NameComponent','kind':'given','value':'Ada'}],'isOrdered':false},'titles':{'t1':{'@type':'Title','name':'Mathematician','kind':'title'}}}")
(define pw-defaults-read
  "{'name':{'components':[{'kind':'given','value':'Ada'}]},'titles':{'t1':{'name':'Mathematician'}}}")

;; (name . props) : each is a create the server must refuse, 400
(define pw-bad-contacts
  (list (cons "unknown" "{'nickname':'Ada'}")
        (cons "unknown-nested" "{'emails':{'e1':{'address':'a@b.com','colour':'red'}}}")
        (cons "empty-string" "{'emails':{'e1':{'address':'a@b.com','label':''}}}")
        (cons "empty-map" "{'emails':{}}")
        (cons "control" "{'emails':{'e1':{'address':'a@b.com','label':'a\\u0001b'}}}")
        (cons "pref-float" "{'emails':{'e1':{'address':'a@b.com','pref':1.0}}}")
        (cons "pref-0" "{'emails':{'e1':{'address':'a@b.com','pref':0}}}")
        (cons "uri-scheme" "{'links':{'l1':{'uri':'hello'}}}")
        (cons "email-at" "{'emails':{'e1':{'address':'a@'}}}")
        (cons "dangling-org" "{'titles':{'t1':{'name':'x','organizationId':'o9'}}}")
        (cons "wrong-type" "{'name':{'@type':'Address','components':[{'kind':'given','value':'A'}]}}")
        (cons "top-type" "{'@type':'Card'}")
        (cons "empty-contexts" "{'emails':{'e1':{'address':'a@b.com','contexts':{}}}}")
        (cons "country-lower" "{'addresses':{'a1':{'countryCode':'gb'}}}")
        (cons "kind-bad" "{'kind':'company'}")))

;; pw-many-emails : -> String    300 emails: over 4,096 bytes as stored
(define (pw-many-emails)
  (string-append
   "{'emails':{"
   (join (map (lambda (i) (string-append "'e" (number->string i) "':{'address':'a" (number->string i) "@example.com'}"))
              (pw-iota 300))
         ",")
   "}}"))

;; observe-props! : String -> Void
;; pw-oj : String -> Json    an observed answer's JSON, as the observing needs it (nd-j is defined later)
(define (pw-oj k) (let ((r (obs k))) (if (and (pair? r) (integer? (car r))) (lg-json r) 'unobserved)))

(define (observe-props! dir)
  (define db (string-append dir "/props.db"))
  (define env (list (string-append "TECHO_DB_PATH=" db)))
  (define (add! name pw user)
    (id-of-added (run-cli-in dir name (string-append pw "\n") '() env
                             (list "user" "add" "--username" user "--email" (string-append user "@example.com")))))
  (obs-set! "pw:migrate" (car (run-cli-in dir "pwmigrate" "" '() env '("migrate"))))
  (obs-set! "pw:a-id" (add! "pw-add-a" nd-pw-a "propa"))
  (obs-set! "pw:b-id" (add! "pw-add-b" nd-pw-b "propb"))
  (with-server dir "pwsrv" db #f
    (lambda (port)
      (define (key-of email pw)
        (let* ((r (hcall port 'post "/v1/login" "application/json" (login-json email pw "props") '()))
               (k (jget (lg-json r) "key")))
          (if (string? k) k "techo_missing")))
      (let* ((ka (key-of "propa@example.com" nd-pw-a))
             (kb (key-of "propb@example.com" nd-pw-b))
             (path (lambda (id) (string-append "/v1/nodes/" id)))
             (pause (lambda () (sleep (make-time 'time-duration 30000000 0)))))
        (define (call! key name method target headers body)
          (obs-set! name (attempt (lambda ()
                                    (hcall port method target (and body "application/json") (or body "")
                                           (append (if key (bearer key) '()) headers))))))
        (define (g! name id) (call! ka name 'get (path id) '() #f))
        (define (gs! name id suffix) (call! ka name 'get (string-append (path id) suffix) '() #f))
        (define (mk! name id doc) (call! ka name 'put (path id) nd-create doc))
        (define (rp! name id rev doc) (call! ka name 'put (path id) (nd-match rev) doc))
        (define (cmd! name id verb rev)
          (call! ka name 'post (string-append (path id) "/" verb) (if rev (nd-match rev) '()) #f))
        (define (stamp! name) (obs-set! name (pw-now-ms)))
        ;; --- A Task's life
        (mk! "pw:a-create" (pw-id 1) (pw-doc "task" "A" #f))
        (g! "pw:a-get1" (pw-id 1))
        (rp! "pw:a-rep" (pw-id 1) 1
             (pw-doc #f "A" "{'deadline':'2026-12-01','scheduled':'2026-11-30T09:00'}"))
        (g! "pw:a-get2" (pw-id 1))
        (pause)
        (stamp! "pw:a-t0")
        (cmd! "pw:a-done" (pw-id 1) "done" 2)
        (stamp! "pw:a-t1")
        (g! "pw:a-get3" (pw-id 1))
        (cmd! "pw:a-done-again" (pw-id 1) "done" 3)
        (pause)
        (cmd! "pw:a-wont" (pw-id 1) "wontdo" 3)
        (g! "pw:a-get4" (pw-id 1))
        (pause)
        (cmd! "pw:a-reopen" (pw-id 1) "reopen" 4)
        (g! "pw:a-get5" (pw-id 1))
        (gs! "pw:a-revs" (pw-id 1) "/revisions")
        (gs! "pw:a-rev1" (pw-id 1) "/revisions/1")
        (gs! "pw:a-rev3" (pw-id 1) "/revisions/3")
        (gs! "pw:a-rev4" (pw-id 1) "/revisions/4")
        (gs! "pw:a-rev5" (pw-id 1) "/revisions/5")
        (rp! "pw:a-rep2" (pw-id 1) 5 (pw-doc #f "A" "{'deadline':'2027-02-02'}"))
        (pause)
        (cmd! "pw:a-done2" (pw-id 1) "done" 6)
        (g! "pw:a-get7" (pw-id 1))
        (call! ka "pw:a-restore" 'post (string-append (path (pw-id 1)) "/revisions/2/restore") (nd-match 7) #f)
        (g! "pw:a-get8" (pw-id 1))
        (gs! "pw:a-rev8" (pw-id 1) "/revisions/8")
        ;; --- a replace cannot change the status
        (mk! "pw:c-create" (pw-id 2) (pw-doc "task" "C" "{'deadline':'2026-12-01'}"))
        (rp! "pw:c-same" (pw-id 2) 1 (pw-doc #f "C" "{'status':'TODO','deadline':'2026-12-01'}"))
        (rp! "pw:c-done-by-put" (pw-id 2) 2 (pw-doc #f "C" "{'status':'DONE'}"))
        (rp! "pw:c-wont-by-put" (pw-id 2) 2 (pw-doc #f "C" "{'status':'WONTDO'}"))
        (rp! "pw:c-closed-by-put" (pw-id 2) 2 (pw-doc #f "C" "{'status':'TODO','closed':5}"))
        (g! "pw:c-get2" (pw-id 2))
        (rp! "pw:c-left-out" (pw-id 2) 2 (pw-doc #f "C" "{'deadline':'2026-12-02'}"))
        (rp! "pw:c-no-props" (pw-id 2) 3 (pw-doc #f "C2" #f))
        (g! "pw:c-get4" (pw-id 2))
        (cmd! "pw:c-done" (pw-id 2) "done" 4)
        (g! "pw:c-get5" (pw-id 2))
        (rp! "pw:c-reopen-by-put" (pw-id 2) 5 (pw-doc #f "C2" "{'status':'TODO','deadline':'2026-12-02'}"))
        (rp! "pw:c-back" (pw-id 2) 5
             (pw-doc #f "C2" (string-append "{'status':'DONE','closed':"
                                            (let ((c (jget (jget (pw-oj "pw:c-get5") "props") "closed")))
                                              (if (integer? c) (number->string c) "0"))
                                            ",'deadline':'2026-12-02'}")))
        (rp! "pw:c-empty" (pw-id 2) 6 (pw-doc #f "C2" "{}"))
        (g! "pw:c-get7" (pw-id 2))
        ;; --- an import
        (stamp! "pw:e-t0")
        (mk! "pw:d-create" (pw-id 3) (pw-doc "task" "D" "{'status':'DONE','closed':1700000000000}"))
        (mk! "pw:e-create" (pw-id 4) (pw-doc "task" "E" "{'status':'DONE'}"))
        (stamp! "pw:e-t1")
        (mk! "pw:f-create" (pw-id 5) (pw-doc "task" "F" "{'status':'WONTDO','closed':1700000000001}"))
        (mk! "pw:g-create" (pw-id 6) (pw-doc "task" "G" "{'status':'TODO','closed':1700000000000}"))
        (mk! "pw:h-create" (pw-id 7) (pw-doc "task" "H" "{'closed':1700000000000}"))
        (mk! "pw:i-create" (pw-id 8) (pw-doc "task" "I" "{'status':'DONE','closed':1.5}"))
        (mk! "pw:j-create" (pw-id 9) (pw-doc "task" "J" "{'status':'DONE','closed':null}"))
        (mk! "pw:k-create" (pw-id 10) (pw-doc "task" "K" "{'status':'MAYBE'}"))
        (g! "pw:d-get" (pw-id 3))
        (g! "pw:e-get" (pw-id 4))
        (g! "pw:f-get" (pw-id 5))
        (g! "pw:g-get" (pw-id 6))
        (g! "pw:h-get" (pw-id 7))
        ;; --- commands on the wrong thing
        (mk! "pw:n-create" (pw-id 11) (pw-doc "note" "N" #f))
        (cmd! "pw:n-done" (pw-id 11) "done" 1)
        (cmd! "pw:n-wontdo" (pw-id 11) "wontdo" 1)
        (cmd! "pw:n-reopen" (pw-id 11) "reopen" 1)
        (mk! "pw:t-create" (pw-id 12) (pw-doc "task" "T" #f))
        (cmd! "pw:t-trash" (pw-id 12) "trash" 1)
        (cmd! "pw:t-done" (pw-id 12) "done" 2)
        (cmd! "pw:t-wontdo" (pw-id 12) "wontdo" 2)
        (g! "pw:t-get" (pw-id 12))
        (mk! "pw:ar-create" (pw-id 13) (pw-doc "task" "AR" #f))
        (cmd! "pw:ar-archive" (pw-id 13) "archive" 1)
        (cmd! "pw:ar-done" (pw-id 13) "done" 2)
        (mk! "pw:s-create" (pw-id 14) (pw-doc "task" "S" #f))
        (cmd! "pw:s-stale" (pw-id 14) "done" 7)
        (cmd! "pw:s-none" (pw-id 14) "done" #f)
        (call! ka "pw:s-inm" 'post (string-append (path (pw-id 14)) "/done") nd-create #f)
        (call! ka "pw:s-get" 'get (string-append (path (pw-id 14)) "/done") '() #f)
        (call! ka "pw:s-get-wontdo" 'get (string-append (path (pw-id 14)) "/wontdo") '() #f)
        (cmd! "pw:s-reopen" (pw-id 14) "reopen" 1)
        (cmd! "pw:s-missing" (pw-id 90) "done" 1)
        (call! kb "pw:s-other" 'post (string-append (path (pw-id 14)) "/done") (nd-match 1) #f)
        (call! kb "pw:s-other-reopen" 'post (string-append (path (pw-id 14)) "/reopen") (nd-match 1) #f)
        (cmd! "pw:s-bad-id" "junk" "done" 1)
        (call! #f "pw:s-no-key" 'post (string-append (path (pw-id 14)) "/done") (nd-match 1) #f)
        (g! "pw:s-get-after" (pw-id 14))
        ;; --- a Note
        (mk! "pw:at-date" (pw-id 15) (pw-doc "note" "D" "{'at':'2026-12-01'}"))
        (mk! "pw:at-local" (pw-id 16) (pw-doc "note" "L" "{'at':'2026-12-01T15:00'}"))
        (mk! "pw:at-moment" (pw-id 17) (pw-doc "note" "M" "{'at':'2026-12-01T20:00:00Z'}"))
        (g! "pw:at-date-get" (pw-id 15))
        (g! "pw:at-local-get" (pw-id 16))
        (g! "pw:at-moment-get" (pw-id 17))
        (mk! "pw:at-bad-day" (pw-id 18) (pw-doc "note" "x" "{'at':'2026-02-30'}"))
        (mk! "pw:at-bad-24" (pw-id 19) (pw-doc "note" "x" "{'at':'2026-12-01T24:00'}"))
        (mk! "pw:at-bad-t" (pw-id 20) (pw-doc "note" "x" "{'at':'2026-12-01t15:00'}"))
        (mk! "pw:at-bad-num" (pw-id 21) (pw-doc "note" "x" "{'at':20261201}"))
        (mk! "pw:at-bad-offset" (pw-id 22) (pw-doc "note" "x" "{'at':'2026-12-01T20:00:00+01:00'}"))
        (mk! "pw:at-bad-deadline" (pw-id 23) (pw-doc "task" "x" "{'deadline':'2026-13-01'}"))
        (mk! "pw:at-bad-sched" (pw-id 24) (pw-doc "task" "x" "{'scheduled':'tomorrow'}"))
        ;; --- a Contact
        (mk! "pw:ct-guide" (pw-id 30) (pw-doc "contact" "Ada" pw-guide-contact))
        (g! "pw:ct-guide-get" (pw-id 30))
        (mk! "pw:ct-rich" (pw-id 31) (pw-doc "contact" "Ada Lovelace" pw-rich-contact))
        (g! "pw:ct-rich-get" (pw-id 31))
        (rp! "pw:ct-rich-put" (pw-id 31) 1
             (pw-doc #f "Ada Lovelace" (let ((p (jget (pw-oj "pw:ct-rich-get") "props")))
                                         (if (list? p) (json->string p) "{}"))))
        (g! "pw:ct-rich-get2" (pw-id 31))
        (mk! "pw:ct-ord1" (pw-id 32) (pw-doc "contact" "O1" pw-order-1))
        (mk! "pw:ct-ord2" (pw-id 33) (pw-doc "contact" "O2" pw-order-2))
        (g! "pw:ct-ord1-get" (pw-id 32))
        (g! "pw:ct-ord2-get" (pw-id 33))
        (mk! "pw:ct-def" (pw-id 34) (pw-doc "contact" "Def" pw-defaults-contact))
        (g! "pw:ct-def-get" (pw-id 34))
        (mk! "pw:ct-nl" (pw-id 35) (pw-doc "contact" "Nl" "{'addresses':{'a1':{'full':'1 Main St\\nTown'}}}"))
        (g! "pw:ct-nl-get" (pw-id 35))
        (mk! "pw:ct-empty" (pw-id 36) (pw-doc "contact" "Empty" "{}"))
        (g! "pw:ct-empty-get" (pw-id 36))
        (for-each (lambda (bc i)
                    (mk! (string-append "pw:ctbad-" (car bc)) (pw-id (+ 40 i)) (pw-doc "contact" "Bad" (cdr bc))))
                  pw-bad-contacts (pw-iota (length pw-bad-contacts)))
        (mk! "pw:ct-big" (pw-id 60) (pw-doc "contact" "Big" (pw-many-emails)))
        (g! "pw:ct-big-get" (pw-id 60))
        ;; --- kinds do not mix
        (mk! "pw:k-note-status" (pw-id 61) (pw-doc "note" "x" "{'status':'TODO'}"))
        (mk! "pw:k-task-emails" (pw-id 62) (pw-doc "task" "x" "{'emails':{'e1':{'address':'a@b.com'}}}"))
        (mk! "pw:k-project-at" (pw-id 63) (pw-doc "project" "x" "{'at':'2026-12-01'}"))
        (mk! "pw:k-project-status" (pw-id 64) (pw-doc "project" "x" "{'status':'TODO'}"))
        (mk! "pw:k-project-x" (pw-id 65) (pw-doc "project" "x" "{'x':1}"))
        (mk! "pw:k-project-ok" (pw-id 66) (pw-doc "project" "x" "{}"))
        (mk! "pw:k-note" (pw-id 67) (pw-doc "note" "KN" "{'at':'2026-12-01'}"))
        (mk! "pw:k-task" (pw-id 68) (pw-doc "task" "KT" "{'deadline':'2026-12-01'}"))
        (mk! "pw:k-contact" (pw-id 69) (pw-doc "contact" "KC" "{'kind':'org'}"))
        (rp! "pw:k-note-as-task" (pw-id 67) 1 (pw-doc #f "KN" "{'status':'DONE'}"))
        (rp! "pw:k-note-emails" (pw-id 67) 1 (pw-doc #f "KN" "{'emails':{'e1':{'address':'a@b.com'}}}"))
        (rp! "pw:k-task-as-note" (pw-id 68) 1 (pw-doc #f "KT" "{'at':'2026-12-01'}"))
        (rp! "pw:k-task-emails-put" (pw-id 68) 1 (pw-doc #f "KT" "{'emails':{'e1':{'address':'a@b.com'}}}"))
        (rp! "pw:k-contact-at" (pw-id 69) 1 (pw-doc #f "KC" "{'at':'2026-12-01'}"))
        (rp! "pw:k-project-put" (pw-id 66) 1 (pw-doc #f "x" "{'at':'2026-12-01'}"))
        (rp! "pw:k-note-named-task" (pw-id 67) 1 (pw-doc "task" "KN" "{'status':'TODO'}"))
        (rp! "pw:k-note-named-task-at" (pw-id 67) 1 (pw-doc "task" "KN" "{'at':'2026-12-01'}"))
        (rp! "pw:k-note-ok" (pw-id 67) 1 (pw-doc #f "KN" "{'at':'2026-12-02'}"))
        (rp! "pw:k-contact-ok" (pw-id 69) 1 (pw-doc #f "KC" "{'emails':{'e1':{'address':'a@b.com'}}}"))
        (rp! "pw:k-task-ok" (pw-id 68) 1 (pw-doc #f "KT" "{'status':'TODO','deadline':'2026-12-05'}"))
        ;; --- a link page's item and a list's item
        (mk! "pw:l-note" (pw-id 70) (pw-doc "note" "LN" #f))
        (call! ka "pw:l-put-s" 'put (string-append (path (pw-id 70)) "/links/related/" (pw-id 14)) '() #f)
        (call! ka "pw:l-put-a" 'put (string-append (path (pw-id 70)) "/links/related/" (pw-id 1)) '() #f)
        (call! ka "pw:l-out" 'get (string-append (path (pw-id 70)) "/links") '() #f)
        (call! ka "pw:l-in-s" 'get (string-append (path (pw-id 14)) "/links?direction=in") '() #f)
        (call! ka "pw:l-list" 'get "/v1/nodes?limit=100" '() #f)))))

;; leftovers : String -> (Listof Boolean)
;; Whether DB's `-wal` and `-shm` exist.
(define (leftovers db)
  (map (lambda (x) (file-exists? (string-append db x))) '("-wal" "-shm")))

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
            (set! nope (attempt (lambda () (get serve-port "/nope"))))
            ;; A second server on the port the first holds.
            (set! cli-port-used
                  (attempt (lambda ()
                             (run-cli dir "portused" '()
                                      (list (string-append "CHEZ_HTTP_PORT="
                                                           (number->string serve-port))
                                            (string-append "TECHO_DB_PATH=" db))
                                      '("serve"))))))
          (signal! server "TERM")
          (set! serve-exit (attempt (lambda () (await-status server deadline-ms))))
          ;; Looked for before any connection is opened on the file again: a
          ;; read-only open makes a `-wal` of its own.
          (set! serve-leftovers (leftovers db))
          (set! serve-out (file-text (child-file server "out")))
          (set! serve-err (file-text (child-file server "err"))))
        (lambda () (kill! server))))
    (observe "migrate-again" (migrate-run dir "migagain" db))
    (observe-migrate! dir)
    (observe "api-run" (observe-api! dir))
    (observe "login-run" (observe-login! dir))
    (observe "nodes-run" (observe-nodes! dir))
    (observe "lifecycle-run" (observe-lifecycle! dir))
    (observe "tree-run" (observe-tree! dir))
    (observe "links-run" (observe-links! dir))
    (observe "props-run" (observe-props! dir))
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
                              '("serve")))))
    ;; The server refused the port after the workers were opened, and still
    ;; stopped them: no `-wal` or `-shm`.
    (set! bad-port-leftovers (leftovers db))
    (set! readers-zero
          (attempt (lambda ()
                     (run-cli dir "readers0" '()
                              (list "TECHO_DB_READERS=0" (string-append "TECHO_DB_PATH=" db))
                              '("serve")))))
    (set! readers-x
          (attempt (lambda ()
                     (run-cli dir "readersx" '()
                              (list "TECHO_DB_READERS=x" (string-append "TECHO_DB_PATH=" db))
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

(test-equal "serve: GET /nope body is the not_found problem (D7)"
  '(("type" . "about:blank") ("title" . "Not Found") ("status" . 404)
    ("code" . "not_found") ("detail" . "There is no such thing here."))
  (if (pair? nope) (caddr nope) nope))

(test-equal "serve: SIGTERM ends it with status 0 within the deadline"
  0 serve-exit)

(test-equal "serve: SIGTERM prints `draining 0` then `stopped`"
  '("draining 0" "stopped")
  (let ((ls (split-lines serve-out)))
    (filter (lambda (l) (or (string=? l "draining 0") (string=? l "stopped"))) ls)))

(test-equal "serve: SIGTERM leaves no -wal and no -shm (the readers stop before the writer)"
  '(#f #f) serve-leftovers)

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

(test-equal "serve on a port in use: exit 1, and a techo: line says so"
  '(1 #t #t) (let ((e (err-of cli-port-used)))
               (list (status-of cli-port-used)
                     (if (string? e) (contains? e "techo: ") e)
                     (if (string? e) (contains? e "in use") e))))

(test-equal "serve with a bad CHEZ_HTTP_PORT: no -wal and no -shm are left (the workers were stopped)"
  '(#f #f) bad-port-leftovers)

(for-each
 (lambda (value result)
   (test-equal (string-append "serve with TECHO_DB_READERS=" value
                              ": refused, exit 2, stderr names the variable, stdout is empty")
     '(2 #t "")
     (list (status-of result)
           (let ((e (err-of result))) (if (string? e) (contains? e "TECHO_DB_READERS") e))
           (out-of result))))
 '("0" "x") (list readers-zero readers-x))


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
  (list 0 (apply nl (append '("converted the database to WAL")
                            (applied-lines (map car migrations))
                            (list (string-append "the database is at version "
                                                 (number->string shipped-latest)))))
        "")
  (obs "migrate-fresh"))

(test-equal "migrate: a second run has nothing to do"
  (list 0 (nl (string-append "nothing to do: the database is at version "
                             (number->string shipped-latest)))
        "")
  (obs "migrate-again"))

(test-equal "migrate: an ahead file is refused, exit 1, the line on stderr"
  (list 1 "" (nl (string-append "techo: refused: this binary is older than the database (version "
                     (number->string ahead-version) ")")))
  (obs "migrate-ahead"))

(test-equal "migrate: another program's file is refused, exit 1, the line on stderr"
  (list 1 "" (nl "techo: refused: not Techo's database"))
  (obs "migrate-foreign"))

(test-equal "migrate: the VACUUM INTO backup is Techo's, at the shipped version, not in WAL"
  (list techo-application-id shipped-latest shipped-objects 'delete)
  (obs "backup-facts"))

(test-equal "migrate: a restored backup is converted to WAL"
  (list 0 (nl "converted the database to WAL"
              (string-append "nothing to do: the database is at version "
                             (number->string shipped-latest)))
        "")
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
  (let ((ok (list 0 0 (list techo-application-id shipped-latest shipped-objects 'wal))))
    (list ok ok ok ok ok))
  (obs "two-at-once"))

(test-equal "clause 6: a child killed inside the fixture's first own migration, then the file is at the shipped version, none of the fixture's"
  (list #t 137 (list techo-application-id shipped-latest shipped-objects 'wal) shipped-tables)
  (let ((r (obs "clause-6"))) (if (and (list? r) (= (length r) 7)) (head r 4) r)))

(test-equal "clause 6: a normal migrate then applies the fixture's two on the same file"
  (list (list 'applied (list fixture-notes-version fixture-tags-version))
        (list techo-application-id fixture-latest-version (+ shipped-objects 3) 'wal)
        (list-sort string<? (append shipped-tables '("notes" "tags"))))
  (let ((r (obs "clause-6"))) (if (and (list? r) (= (length r) 7)) (tail r 4) r)))

;; The two clause 11 runs: the writer was killed with a full -wal, and
;; `techo migrate` then finds every reported row.
(define (clause-11-tests label key)
  (test-equal (string-append label ": the setup migrate, the -wal large, non-empty at the kill, a report")
    '(0 #t #t #t)
    (let ((r (obs key))) (if (and (list? r) (= (length r) 13)) (head r 4) r)))
  (test-equal (string-append label ": techo migrate exits 0 and every reported row is there")
    '(0 #t #t)
    (let ((r (obs key))) (if (and (list? r) (= (length r) 13))
                             (list (list-ref r 5) (list-ref r 6) (list-ref r 7))
                             r)))
  (test-equal (string-append label ": the file is current and in WAL, and serve answers /health")
    (list (list techo-application-id shipped-latest (+ shipped-objects 1) 'wal)
          (list 'listening (list 200 "application/json" '(("status" . "ok"))) 0))
    (let ((r (obs key)))
      (if (and (list? r) (= (length r) 13))
          (list (list-ref r 8)
                (list-ref r 9))
          r)))

  (test-equal (string-append label ": a migration then applies on top, and the rows are still there")
    (list (list 'applied (list fixture-notes-version fixture-tags-version)) #t)
    (let ((r (obs key)))
      (if (and (list? r) (= (length r) 13)) (list (list-ref r 10) (list-ref r 11)) r)))

  (test-equal (string-append label ": the writer's report holds a line for every batch, so a kill at any moment leaves the last one")
    #t
    (let ((r (obs key))) (if (and (list? r) (= (length r) 13)) (list-ref r 12) r))))

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
  (refused-line (string-append "this binary is older than the database (version "
                               (number->string ahead-version) ")"))
  (obs "serve-ahead"))

(test-equal "serve: another program's file is refused"
  (refused-line "not Techo's database")
  (obs "serve-foreign"))

(test-equal "serve: a restored backup is refused: not in WAL"
  (refused-line "the database is not in WAL mode: run `techo migrate`")
  (obs "serve-backup"))

;; --- the API over the wire (slice 3a) ------------------------------------

(define (ok-obs? k) (let ((r (obs k))) (and (pair? r) (integer? (car r)))))

;; refusal : Nat String String String [(U String #f)] -> List
;; What a refusal shows: status, content-type, the body in D7's five members,
;; and the www-authenticate and allow headers.
(define (refusal status title code detail www allow)
  (list status "application/problem+json"
        (list (cons "type" "about:blank") (cons "title" title) (cons "status" status)
              (cons "code" code) (cons "detail" detail))
        www allow))
(define (refusal-of k)
  (let ((r (obs k)))
    (if (and (pair? r) (integer? (car r)))
        (list (rsp-status r) (rsp-header r "content-type") (rsp-json r)
              (rsp-header r "www-authenticate") (rsp-header r "allow"))
        r)))

(test-equal "api: the server started on a migrated file and listens"
  '(0 #t) (list (obs "api:migrate") (port-ok (obs "api:port"))))

(define unauthorized-detail "A valid API key is needed.")
(test-equal "api: no key is 401 in the problem format, with www-authenticate: Bearer"
  (refusal 401 "Unauthorized" "unauthorized" unauthorized-detail "Bearer" #f)
  (refusal-of "api:no-key"))
(test-equal "api: a well-shaped key no row holds is 401, the same answer"
  (refusal 401 "Unauthorized" "unauthorized" unauthorized-detail "Bearer" #f)
  (refusal-of "api:unknown-key"))
(test-equal "api: a revoked key is 401, the same answer"
  (refusal 401 "Unauthorized" "unauthorized" unauthorized-detail "Bearer" #f)
  (refusal-of "api:revoked-key"))
(test-equal "api: the key that regenerated itself no longer opens: 401"
  (refusal 401 "Unauthorized" "unauthorized" unauthorized-detail "Bearer" #f)
  (refusal-of "api:old-secret"))

(define invalid-detail "The request is not valid.")
(test-equal "api: a limit of 0, a limit that is not a number, an after and an id that are no ids: 400"
  (let ((e (refusal 400 "Bad Request" "invalid_request" invalid-detail #f #f)))
    (list e e e e))
  (map refusal-of '("api:bad-limit" "api:bad-limit-text" "api:bad-after" "api:bad-id")))

(test-equal "api: an unknown route is 404 in the format"
  (refusal 404 "Not Found" "not_found" "There is no such thing here." #f #f)
  (refusal-of "api:no-route"))
(test-equal "api: another account's key looks like no key: revoke and regenerate are 404"
  (let ((e (refusal 404 "Not Found" "not_found" "There is no such thing here." #f #f)))
    (list e e))
  (map refusal-of '("api:other-revoke" "api:other-regenerate")))
(test-equal "api: regenerating a sibling key is 403"
  (refusal 403 "Forbidden" "forbidden" "A key can only regenerate itself." #f #f)
  (refusal-of "api:sibling-regenerate"))
(test-equal "api: a wrong method is 405 in the format, with allow"
  (let ((e (refusal 405 "Method Not Allowed" "method_not_allowed"
                    "That method is not allowed here." #f "GET, HEAD")))
    (list e e))
  (map refusal-of '("api:wrong-method" "api:wrong-method-keys")))

(define key-members '("id" "name" "created" "last_used" "revoked"))
(define (members j) (if (list? j) (map car j) j))
(define (key-by-name items name)
  (let loop ((is items))
    (cond ((not (pair? is)) #f)
          ((equal? (jget (car is) "name") name) (car is))
          (else (loop (cdr is))))))
(define (ok-json k)
  (let ((r (obs k)))
    (if (and (pair? r) (integer? (car r)))
        (list (rsp-status r) (rsp-header r "content-type") (rsp-json r))
        r)))
(define (ids-of k) (let ((r (obs k))) (if (ok-obs? k) (map (lambda (i) (jget i "id")) (jitems (rsp-json r))) r)))
(define id-a1 (id->string (car a-keys)))
(define id-a2 (id->string (cadr a-keys)))
(define id-a3 (id->string (caddr a-keys)))
(define id-a4 (id->string (cadddr a-keys)))

(test-equal "api: GET /v1/account answers who the key belongs to"
  (list 200 "application/json"
        (list (cons "id" (id->string account-a)) (cons "username" "ada")
              (cons "email" "ada@example.com") (cons "created" 1700000000000)))
  (ok-json "api:account"))

(test-equal "api: GET /v1/keys lists the account's keys by id, none of another's, no more members than the five"
  (list (list id-a1 id-a2 id-a3 id-a4) 'null
        (list key-members key-members key-members key-members))
  (let ((r (obs "api:keys")))
    (if (ok-obs? "api:keys")
        (list (ids-of "api:keys") (jget (rsp-json r) "next") (map members (jitems (rsp-json r))))
        r)))

(test-equal "api: another account's keys list is its own one key"
  (list (id->string b-key)) (ids-of "api:b-keys"))

(test-equal "api: limit and after page through: next is the last id shown, null at the end"
  (list (list id-a1 id-a2) id-a2 (list id-a3 id-a4) 'null)
  (let ((p1 (obs "api:keys-1")) (p2 (obs "api:keys-2")))
    (if (and (ok-obs? "api:keys-1") (ok-obs? "api:keys-2"))
        (list (ids-of "api:keys-1") (jget (rsp-json p1) "next")
              (ids-of "api:keys-2") (jget (rsp-json p2) "next"))
        (list p1 p2))))

(test-equal "api: a limit over 100 is read as 100"
  200 (let ((r (obs "api:keys-over"))) (if (ok-obs? "api:keys-over") (rsp-status r) r)))

(test-equal "api: reading sets no last_used: after reads, every key's is null"
  '(null null null null)
  (let ((r (obs "api:keys")))
    (if (ok-obs? "api:keys") (map (lambda (i) (jget i "last_used")) (jitems (rsp-json r))) r)))

(test-equal "api: revoke answers the key with the time it was revoked, and again it answers the same"
  '(#t #t #t)
  (let ((a (obs "api:revoke")) (b (obs "api:revoke-again")))
    (if (and (ok-obs? "api:revoke") (ok-obs? "api:revoke-again"))
        (let ((t (jget (rsp-json a) "revoked")))
          (list (and (= 200 (rsp-status a)) (equal? id-a3 (jget (rsp-json a) "id"))
                     (equal? (members (rsp-json a)) key-members))
                (and (integer? t) (> t 1700000000000))
                (equal? t (jget (rsp-json b) "revoked"))))
        (list a b))))

(test-equal "api: the key that wrote has a last_used (a whole millisecond time); the one that only read has none"
  '(#t null #t)
  (let ((r (obs "api:keys-after")))
    (if (ok-obs? "api:keys-after")
        (let ((is (jitems (rsp-json r))))
          (list (integer? (jget (key-by-name is "laptop") "last_used"))
                (jget (key-by-name is "phone") "last_used")
                (integer? (jget (key-by-name is "tablet") "revoked"))))
        r)))

(test-equal "api: regenerate answers the key and a new secret, once, with Cache-Control: no-store"
  (list 200 "no-store" #t key-members id-a1)
  (let ((r (obs "api:regenerate")))
    (if (ok-obs? "api:regenerate")
        (let ((k (jget (rsp-json r) "key")))
          (list (rsp-status r) (rsp-header r "cache-control")
                (and (string? k) (= (string-length k) 70) (starts-with? k "techo_"))
                (filter (lambda (m) (not (equal? m "key"))) (members (rsp-json r)))
                (jget (rsp-json r) "id")))
        r)))

;; hex-pairs : String -> (Listof String)    the 32 two-digit pairs after techo_
(define (hex-pairs secret)
  (let loop ((i 6) (acc '()))
    (if (>= (+ i 2) (+ 1 (string-length secret)))
        (reverse acc)
        (loop (+ i 2) (cons (substring secret i (+ i 2)) acc)))))
(define (distinct-count xs)
  (let loop ((xs xs) (seen '()))
    (cond ((null? xs) (length seen))
          ((member (car xs) seen) (loop (cdr xs) seen))
          (else (loop (cdr xs) (cons (car xs) seen))))))

;; techo.sps hands the app chez-sodium's random-bytes. Nothing else holds
;; that: a constant in its place gave every key one secret and passed.
(test-equal "api: two regenerated secrets differ, are no secret the run began with, and each has many different bytes"
  '(#t #t #t #t)
  (let ((a (obs "api:new-secret")) (b (obs "api:new-secret-2")))
    (if (and (string? a) (string? b) (= (string-length a) 70) (= (string-length b) 70))
        (list (not (equal? a b))
              (not (or (member a (list s-a1 s-a2 s-a3 s-a4 s-b1 s-unknown))
                       (member b (list s-a1 s-a2 s-a3 s-a4 s-b1 s-unknown))))
              (> (distinct-count (hex-pairs a)) 8)
              (> (distinct-count (hex-pairs b)) 8))
        (list a b))))

;; techo.sps makes the reader from db-read. Made from db-write by mistake,
;; this read would wait out the lock and answer 503.
(test-equal "api: a read answers at once while another program holds the write lock"
  '(200 #t)
  (let ((r (obs "api:read-under-lock")) (ms (obs "api:read-under-lock-ms")))
    (if (and (ok-obs? "api:read-under-lock") (number? ms))
        (list (rsp-status r) (< ms 3000))
        (list r ms))))

(test-equal "api: the new secret works: it opens the same account"
  (list 200 (id->string account-a))
  (let ((r (obs "api:new-account")))
    (if (ok-obs? "api:new-account") (list (rsp-status r) (jget (rsp-json r) "id")) r)))

(test-equal "api: no list of keys, and no other answer, shows a key's hash or a secret"
  '()
  (filter (lambda (k) (let ((r (obs k)))
                        (and (ok-obs? k) (not (equal? k "api:regenerate"))
                             (exists (lambda (m) (member m '("key" "key_hash" "password_hash")))
                                     (let ((m (members (rsp-json r)))) (if (list? m) m '()))))))
          '("api:account" "api:keys" "api:keys-1" "api:revoke" "api:b-keys")))

;; The forced 500, from a trigger this suite's own connection added while the
;; server ran: user_version is unchanged, so the server did not notice.
(test-equal "api: a forced failure inside a write is 500 in the format, for regenerate and for revoke"
  (let ((e (refusal 500 "Internal Server Error" "internal" "Something went wrong on the server."
                    #f #f)))
    (list e e))
  (map refusal-of '("api:forced-500" "api:forced-500-revoke")))

(test-equal "api: after the trigger is dropped the same server writes again"
  (list 200 id-a4 #t)
  (let ((r (obs "api:after-trigger")))
    (if (ok-obs? "api:after-trigger")
        (list (rsp-status r) (jget (rsp-json r) "id") (integer? (jget (rsp-json r) "revoked")))
        r)))

(test-equal "api: SIGTERM ends the server with status 0"
  0 (obs "api:exit"))

;; The request log (D10): one line for each request, in order, with the
;; status the client got, the account on those that had one.
(test-equal "api log: one line for each request: method, path (no query), status, account (- when none)"
  (reverse api-expect)
  (let ((o (obs "api:out"))) (if (string? o) (map line-key (request-lines o)) o)))

(test-equal "api log: every line has ending=written, whole-number ms, db_ms a number or -, and the client's address"
  '()
  (let ((o (obs "api:out")))
    (if (string? o)
        (filter
         (lambda (l)
           (not (and (equal? (field-of l "ending") "written")
                     (string->number (or (field-of l "ms") "x"))
                     (let ((d (field-of l "db_ms"))) (or (equal? d "-") (string->number (or d "x"))))
                     (equal? (field-of l "address") "127.0.0.1"))))
         (request-lines o))
        o)))

(test-equal "api log: a request the database did not see has db_ms - (no key, bad limit, no route, 405)"
  '(#t #t #t #t #t)
  (let ((o (obs "api:out")))
    (if (string? o)
        (map (lambda (path status)
               (and (exists (lambda (l) (and (equal? (field-of l "path") path)
                                             (equal? (field-of l "status") status)
                                             (equal? (field-of l "db_ms") "-")))
                            (request-lines o))
                    #t))
             '("/v1/account" "/v1/keys" "/v1/nothing" "/v1/account" "/v1/keys")
             '("401" "400" "404" "405" "405"))
        o)))

(test-equal "api log: no line holds a query string, a header or a secret"
  '()
  (let ((o (obs "api:out")))
    (if (string? o)
        (filter (lambda (l) (or (contains? l "?") (contains? l "limit") (contains? l "uthorization")
                                (contains? l "techo_") (contains? l "Bearer")))
                (request-lines o))
        o)))

(test-equal "api: the forced failures leave a handler-failed line each, and the server's standard error is empty"
  '(2 "")
  (let ((o (obs "api:out")))
    (if (string? o)
        (list (length (filter (lambda (l) (and (starts-with? l "handler-failed ")
                                               (contains? l "forced")))
                              (split-lines o)))
              (obs "api:err"))
        o)))

;; P1: no secret is kept or logged. The search itself is shown to find.
(test-equal "P1: the search finds each needle's form in bytes that hold it, and none in bytes that do not"
  '((#t #t #t #t) (#f #f #f #f))
  (let* ((s (mk-secret 99))
         (ns (needles-of s)))
    (list (map (lambda (n) (bytes-contain? (bytevector-append (string->utf8 "xx") n (string->utf8 "yy")) n)) ns)
          (map (lambda (n) (bytes-contain? (string->utf8 "nothing to see; techo_ and 00ff") n)) ns))))

(test-equal "P1: the needles are the 70 characters, the 64 digits in both cases, and 32 raw bytes"
  '(70 64 64 32)
  (map bytevector-length (needles-of (mk-secret 1))))

(test-equal "P1: the run presented or was given eight secrets, and the files searched are not empty"
  '(8 #t #t #t)
  (list (obs "api:secret-count")
        (let ((h (obs "api:live-files"))) (and (pair? h) (> (bytevector-length (cdar h)) 0)))
        (let ((o (obs "api:out"))) (and (string? o) (> (string-length o) 0)))
        (= 4 (length (needles-of (mk-secret 1))))))

(test-equal "P1: no secret is in the server's output or error, nor the database file or its -wal, while it ran or after"
  '()
  (obs "api:leaks"))

;; --- login, the users commands and the proxy count (slice 3b) ------------

(define (last-of l) (if (null? (cdr l)) (car l) (last-of (cdr l))))
(define (butlast l) (if (null? (cdr l)) '() (cons (car l) (butlast (cdr l)))))
(define (lg-ok? k) (let ((r (obs k))) (and (pair? r) (integer? (car r)))))
(define (lg-code k) (if (lg-ok? k) (jget (lg-json (obs k)) "code") (obs k)))
(define (lg-st k) (if (lg-ok? k) (lg-status (obs k)) (obs k)))
(define ada-id (obs "lg:ada-id"))
(define sam-id (obs "lg:sam-id"))
(define (stderr-of k) (let ((r (obs k))) (if (and (pair? r) (string? (caddr r))) (caddr r) r)))

(test-equal "login run: the migrate and the servers' ports"
  '(0 #t #t) (list (obs "lg:migrate") (port-ok (obs "lgsrv:port")) (port-ok (obs "lgproxy:port"))))

(test-equal "user add: the password on standard input makes the account; the line is `added NAME EMAIL ID`"
  (list (list 0 (nl (string-append "added ada ada@example.com " ada-id)) "")
        #t)
  (list (obs "lg:add-ada")
        (and (= 36 (string-length ada-id)) (not (equal? ada-id sam-id)))))

(test-equal "user add: a CRLF line ending is dropped and the spaces at either end are kept (sam logs in with them)"
  (list (list 0 (nl (string-append "added sam sam@example.com " sam-id)) "") 201)
  (list (obs "lg:add-sam") (lg-st "lg:sam")))

(test-equal "user add: a taken username, a taken email (any case), a short password, a bad username, an empty standard input: status 1, one line"
  (list (list 1 "" (nl "techo: the username ada is taken"))
        (list 1 "" (nl "techo: the email ada@example.com is taken"))
        (list 1 "" (nl "techo: the password is shorter than 8 characters"))
        (list 1 "" (nl "techo: the username must start with a lowercase letter or a digit"))
        (list 1 "" (nl "techo: no password was given")))
  (map obs '("lg:add-dup-username" "lg:add-dup-email" "lg:add-short" "lg:add-bad-username" "lg:add-empty-stdin")))

(test-equal "user add: none of those refusals made an account (two accounts)"
  2 (obs "lg:accounts-after-refusals"))

;; pinned : String     how a hash at 'interactive starts: 64 MiB, 2 passes, 1 lane
(define pinned "$argon2id$v=19$m=65536,t=2,p=1$")

(test-equal "user add: the hash it stored is made at the pinned limits"
  pinned
  (let ((h (obs "lg:ada-hash")))
    (if (and (string? h) (>= (string-length h) (string-length pinned)))
        (substring h 0 (string-length pinned))
        h)))

;; version-of : Any -> (U Char Any)     a UUID text's 15th character, its version
(define (version-of id)
  (if (and (string? id) (= (string-length id) 36)) (string-ref id 14) id))

(test-equal "user: `techo user`, `user add` with no options, an unknown option: status 2, stdout empty, the usage on stderr"
  (list (list 2 "" #t) (list 2 "" #t) (list 2 "" #t))
  (map (lambda (k) (let ((r (obs k)))
                     (if (and (pair? r) (string? (caddr r)))
                         (list (car r) (cadr r) (contains? (caddr r) usage-text))
                         r)))
       '("lg:user-bare" "lg:user-add-bare" "lg:user-unknown-option")))

(test-equal "user: the refusals name the fault"
  '(#t #t #t)
  (list (contains? (stderr-of "lg:user-bare") "no user command given")
        (contains? (stderr-of "lg:user-add-bare") "user add needs --username")
        (contains? (stderr-of "lg:user-unknown-option") "unknown option for user add: --password")))

(test-equal "user add on a missing file: status 1, the database's line, no file made"
  (list (list 1 "" (nl "techo: the database file is missing: run `techo migrate`")) '(#f #f #f))
  (list (obs "lg:add-missing") (obs "lg:add-missing-files")))

(test-equal "user add on a file that was never migrated: status 1, the database's line, the file untouched"
  (list (list 1 "" (nl "techo: the database is empty: run `techo migrate`")) '(0 #f #f))
  (list (obs "lg:add-blank") (obs "lg:add-blank-files")))

;; --- login over the wire

(define login-members (append key-members '("key")))
(test-equal "login: 201, the key's fields and the key, cache-control: no-store, JSON; the email is case-insensitive"
  (list 201 "no-store" "application/json" (list login-members "laptop" #t))
  (let ((r (obs "lg:good")))
    (if (lg-ok? "lg:good")
        (let ((j (lg-json r)) (k (jget (lg-json r) "key")))
          (list (lg-status r) (lg-header r "cache-control") (lg-header r "content-type")
                (list (members j) (jget j "name")
                      (and (string? k) (= 70 (string-length k)) (starts-with? k "techo_")))))
        r)))

(test-equal "ids: the accounts `user add` printed and the keys four logins made are UUIDs of version 7"
  '(#\7 #\7 #\7 #\7 #\7 #\7)
  (map version-of
       (append (list ada-id sam-id)
               (map (lambda (k) (if (lg-ok? k) (jget (lg-json (obs k)) "id") (obs k)))
                    '("lg:good" "lg:sam" "lg:second" "lg:new-password")))))

(test-equal "login: the returned key works as a Bearer key on GET /v1/account (the account, email as stored)"
  (list 200 ada-id "ada@example.com")
  (if (lg-ok? "lg:account")
      (let ((j (lg-json (obs "lg:account"))))
        (list (lg-status (obs "lg:account")) (jget j "id") (jget j "email")))
      (obs "lg:account")))

(test-equal "login: GET /v1/keys lists the new key by its name and id"
  (list 200 (list "laptop") #t)
  (if (lg-ok? "lg:keys")
      (let* ((j (lg-json (obs "lg:keys"))) (is (jitems j)))
        (list (lg-status (obs "lg:keys")) (map (lambda (i) (jget i "name")) is)
              (equal? (map (lambda (i) (jget i "id")) is)
                      (list (jget (lg-json (obs "lg:good")) "id")))))
      (obs "lg:keys")))

(test-equal "Q1: a wrong password and an unknown email answer 401 invalid_credentials with the same body and headers (Date aside)"
  (list 401 "invalid_credentials" "Bearer" #t)
  (if (and (lg-ok? "lg:wrong-pw") (lg-ok? "lg:wrong-email"))
      (let ((a (obs "lg:wrong-pw")) (b (obs "lg:wrong-email")))
        (list (lg-status a) (jget (lg-json a) "code") (lg-header a "www-authenticate")
              (and (= (lg-status a) (lg-status b))
                   (equal? (lg-text a) (lg-text b))
                   (equal? (lg-headers a) (lg-headers b)))))
      (list (obs "lg:wrong-pw") (obs "lg:wrong-email") #f #f)))

(test-equal "login: a missing Content-Type is 415, bad JSON 400 invalid_json, a field twice and an unknown field 400 invalid_request, over 16 KiB 413"
  '((415 "unsupported_media_type") (400 "invalid_json") (400 "invalid_request")
    (400 "invalid_request") (413 "payload_too_large"))
  (map (lambda (k) (list (lg-st k) (lg-code k)))
       '("lg:no-ctype" "lg:bad-json" "lg:twice" "lg:unknown-field" "lg:too-big")))

(define (retry-after-of k) (and (lg-ok? k) (string->number (or (lg-header (obs k) "retry-after") "x"))))
(test-equal "rate limit: five wrong tries for one email are 401; the sixth is 429 rate_limited with a Retry-After of 890 to 900 whole seconds (the window is 15 minutes, the tries take seconds)"
  (list '(401 401 401 401 401) 429 "rate_limited" #t)
  (list (map (lambda (i) (lg-st (string-append "lg:rl-" (number->string i)))) '(1 2 3 4 5))
        (lg-st "lg:rl-6") (lg-code "lg:rl-6")
        (let ((n (retry-after-of "lg:rl-6"))) (and (integer? n) (exact? n) (<= 890 n 900)))))

(test-equal "rate limit: another email from the same address still gets 401"
  401 (lg-st "lg:rl-other"))

(test-equal "user password beside the running server: status 0, the line says how many keys it revoked"
  (list 0 (nl "password set for ada@example.com; 2 keys revoked") "")
  (obs "lg:passwd"))

(test-equal "user password: an unknown email is status 1 and the line says so"
  (list 1 "" (nl "techo: no account has the email nobody@example.com"))
  (obs "lg:passwd-unknown"))

(test-equal "Q5: both old keys answer 401, the old password 401, the new password 201, and the new key works"
  '(401 401 401 201 200)
  (map lg-st '("lg:old-key-1" "lg:old-key-2" "lg:old-password" "lg:new-password" "lg:new-key")))

(test-equal "TECHO_BEHIND_PROXY unset: X-Forwarded-For is ignored: tries with a different last entry each hit one address limit (401s, then a 429)"
  #t
  (let ((r (obs "lg:unset-proxy")))
    (and (list? r) (pair? r)
         (equal? (last-of r) 429)
         (for-all (lambda (s) (= s 401)) (butlast r))
         (< (length r) 22))))

(test-equal "TECHO_BEHIND_PROXY=1: twenty tries by one client are 401, though each carried another first entry"
  (vector->list (make-vector 20 401)) (obs "lg:px-statuses"))

(test-equal "TECHO_BEHIND_PROXY=1: the 21st try from the same last entry is 429 rate_limited; the same request with another last entry is 401"
  '((429 "rate_limited") (401 "invalid_credentials"))
  (list (list (lg-st "lg:px-21-same") (lg-code "lg:px-21-same"))
        (list (lg-st "lg:px-21-other") (lg-code "lg:px-21-other"))))

(for-each
 (lambda (v)
   (test-equal (string-append "TECHO_BEHIND_PROXY=" v ": the server refuses to start, status 2, stderr names the variable and not the value, stdout empty")
     '(2 #t #f "")
     (let ((r (obs (string-append "lg:proxy-" v))))
       (if (and (pair? r) (string? (caddr r)))
           (list (car r) (contains? (caddr r) "TECHO_BEHIND_PROXY")
                 (and (> (string-length v) 1) (contains? (caddr r) v))
                 (cadr r))
           r))))
 '("x" "9" "zzq7"))

(test-equal "login servers: SIGTERM ends each with status 0 and `stopped` (the hasher stops with them)"
  '(0 0 #t #t)
  (list (obs "lgsrv:exit") (obs "lgproxy:exit")
        (and (string? (obs "lgsrv:out")) (contains? (obs "lgsrv:out") "stopped\n"))
        (and (string? (obs "lgproxy:out")) (contains? (obs "lgproxy:out") "stopped\n"))))

;; The request log's address (the owner, 2026-11-25): the client's when the
;; proxy count finds one, else the peer's.
(test-equal "request log: behind one proxy the address is the last X-Forwarded-For entry, never the proxy's own or the client's forgery"
  '(#t #t #f #f)
  (let ((out (obs "lgproxy:out")))
    (if (string? out)
        (list (contains? out " address=198.51.100.1\n")
              (contains? out " address=198.51.100.2\n")
              (contains? out "path=/v1/login status=401 ending=written ms=0 db_ms=- account=- address=127.0.0.1")
              (contains? out " address=203.0.113."))
        out)))

(test-equal "request log: with TECHO_BEHIND_PROXY unset the address is the peer's, whatever X-Forwarded-For says"
  '(#t #f)
  (let ((out (obs "lgsrv:out")))
    (if (string? out)
        (list (contains? out " address=127.0.0.1\n")
              (contains? out " address=203.0.113."))
        out)))

(test-equal "login servers: no raise while observing them"
  '(unobserved unobserved) (list (obs "lgsrv:raised") (obs "lgproxy:raised")))

(test-equal "login log: each login's line shows the account when it answered 201 and `-` when it did not"
  (obs "lg:expect")
  (let ((o (obs "lgsrv:out")))
    (if (string? o)
        (let ((mine (filter (lambda (l) (equal? (field-of l "path") "/v1/login")) (request-lines o))))
          (map (lambda (l) (list (field-of l "status") (field-of l "account"))) mine))
        o)))

;; Q3: no password, no hash and no secret is anywhere the run wrote
(define (string-leaks hays needles)
  (apply append
         (map (lambda (h)
                (let loop ((ns needles) (i 0) (acc '()))
                  (cond ((null? ns) (reverse acc))
                        ((bytes-contain? (cdr h) (string->utf8 (car ns))) (loop (cdr ns) (+ i 1) (cons (list (car h) i) acc)))
                        (else (loop (cdr ns) (+ i 1) acc)))))
              hays)))

(define lg-all-hays (append lg-outputs lg-bodies lg-bodies-201))
(define lg-no-secret-hays (append lg-outputs lg-bodies))

(test-equal "Q3: the search finds a password and `$argon2` in bytes that hold them, and not in bytes that do not"
  '(((x 0) (x 1)) ())
  (list (map (lambda (r) (list 'x (cadr r)))
             (string-leaks (list (cons "h" (string->utf8 "..$argon2id$v=19.. correct horse battery ..")))
                           (list "correct horse battery" "$argon2")))
        (string-leaks (list (cons "h" (string->utf8 "nothing here"))) (list "correct horse battery" "$argon2"))))

(test-equal "Q3: the run's outputs and answers are not empty, and it made four keys"
  '(#t #t #t)
  (list (> (length lg-outputs) 20) (> (length lg-bodies) 20) (= (length lg-secrets) 4)))

(test-equal "Q3: no password and no `$argon2` in any server output, command output or response body"
  '() (string-leaks lg-all-hays (append lg-passwords '("$argon2"))))

(test-equal "Q3: no key secret in any output or response body but the login answer that made it"
  '() (leaks lg-no-secret-hays (reverse lg-secrets)))

(test-equal "Q3: each secret is in the 201 body that made it"
  #t (let ((bodies (map cdr lg-bodies-201)))
       (for-all (lambda (s) (exists (lambda (b) (bytes-contain? b (string->utf8 s))) bodies)) lg-secrets)))

;; --- nodes over the wire (slice 4) ----------------------------------------

(define (nd-j k) (if (lg-ok? k) (lg-json (obs k)) (obs k)))
(define (nd-h k name) (if (lg-ok? k) (lg-header (obs k) name) (obs k)))
(define node-members '("id" "kind" "state" "parent" "title" "body" "content_type" "props" "revision" "created" "updated"))
(define nd-problem "application/problem+json")

(test-equal "nodes: the run's setup worked: migrated, two accounts, the server stopped with 0 and raised nothing"
  '(0 #t #t 0 unobserved)
  (list (obs "nd:migrate")
        (and (string? (obs "nd:a-id")) (= 36 (string-length (obs "nd:a-id"))))
        (and (string? (obs "nd:b-id")) (not (equal? (obs "nd:a-id") (obs "nd:b-id"))))
        (obs "ndsrv:exit") (obs "ndsrv:raised")))

(test-equal "nodes: PUT with If-None-Match: * is 201, ETag \"1\", Location, the whole node"
  (list 201 "\"1\"" (string-append "/v1/nodes/" nd-n1) node-members
        (list nd-n1 "note" "zebratitle one" "quokkabody first" "text/plain" '() 1))
  (let ((j (nd-j "nd:create")))
    (list (lg-st "nd:create") (nd-h "nd:create" "etag") (nd-h "nd:create" "location") (members j)
          (map (lambda (k) (jget j k)) '("id" "kind" "title" "body" "content_type" "props" "revision")))))

(test-equal "nodes: GET answers the same content and ETag \"1\""
  (list 200 "\"1\"" #t)
  (list (lg-st "nd:get") (nd-h "nd:get" "etag") (equal? (nd-j "nd:get") (nd-j "nd:create"))))

(test-equal "nodes: replace with If-Match \"1\" is 200, ETag \"2\", revision 2 and the new content"
  (list 200 "\"2\"" 2 "zebratitle two" "quokkabody second")
  (let ((j (nd-j "nd:replace")))
    (list (lg-st "nd:replace") (nd-h "nd:replace" "etag") (jget j "revision") (jget j "title") (jget j "body"))))

(test-equal "nodes: the same replace again is 412 precondition_failed, a problem document"
  (list 412 nd-problem "precondition_failed")
  (list (lg-st "nd:replace-again") (nd-h "nd:replace-again" "content-type") (lg-code "nd:replace-again")))

(test-equal "nodes: the GET after the 412 still shows revision 2, with the second write's content"
  (list 200 "\"2\"" 2 "quokkabody second")
  (list (lg-st "nd:get-after") (nd-h "nd:get-after" "etag")
        (jget (nd-j "nd:get-after") "revision") (jget (nd-j "nd:get-after") "body")))

(test-equal "nodes: a write with neither header is 428 precondition_required"
  (list 428 nd-problem "precondition_required")
  (list (lg-st "nd:no-header") (nd-h "nd:no-header" "content-type") (lg-code "nd:no-header")))

(test-equal "nodes: a create on an id that exists is 412 precondition_failed"
  (list 412 nd-problem "precondition_failed")
  (list (lg-st "nd:create-again") (nd-h "nd:create-again" "content-type") (lg-code "nd:create-again")))

(test-equal "nodes: the revisions list shows 2 then 1, an item has no body member"
  (list 200 '(2 1) '(("revision" "title" "content_type" "props" "created")
                     ("revision" "title" "content_type" "props" "created")))
  (let ((is (jitems (nd-j "nd:revisions"))))
    (list (lg-st "nd:revisions")
          (if (list? is) (map (lambda (i) (jget i "revision")) is) is)
          (if (list? is) (map members is) is))))

(test-equal "nodes: GET .../revisions/1 is the first body"
  (list 200 1 "zebratitle one" "quokkabody first")
  (let ((j (nd-j "nd:revision-1")))
    (list (lg-st "nd:revision-1") (jget j "revision") (jget j "title") (jget j "body"))))

(test-equal "nodes: restore of revision 1 with If-Match \"2\" is 200, ETag \"3\", the first body"
  (list 200 "\"3\"" 3 "quokkabody first" "zebratitle one")
  (let ((j (nd-j "nd:restore")))
    (list (lg-st "nd:restore") (nd-h "nd:restore" "etag") (jget j "revision") (jget j "body") (jget j "title"))))

(test-equal "nodes: the second account sees the first's node as missing: GET, replace, restore and the revisions list are 404 not_found"
  '((404 "not_found") (404 "not_found") (404 "not_found") (404 "not_found"))
  (map (lambda (k) (list (lg-st k) (lg-code k)))
       '("nd:b-get" "nd:b-replace" "nd:b-restore" "nd:b-revisions")))

(test-equal "nodes: the second account's list is empty, and a create on the first's id is 412 (D8's one leak)"
  (list 200 '() 412 "precondition_failed")
  (list (lg-st "nd:b-list") (jitems (nd-j "nd:b-list")) (lg-st "nd:b-create") (lg-code "nd:b-create")))

(test-equal "nodes: the first account's list holds the node at revision 3, with no body member"
  (list 200 (list nd-n1) '("id" "kind" "state" "parent" "title" "content_type" "props" "revision" "created" "updated") '(3))
  (let ((is (jitems (nd-j "nd:a-list"))))
    (list (lg-st "nd:a-list")
          (if (list? is) (map (lambda (i) (jget i "id")) is) is)
          (if (and (list? is) (pair? is)) (members (car is)) is)
          (if (list? is) (map (lambda (i) (jget i "revision")) is) is))))

(test-equal "nodes: Japanese, an emoji and an accent sent as UTF-8 come back byte for byte, in the create's answer and the GET's"
  (list '(201 200) #t #t #t)
  (let ((sent (string->utf8 (obs "nd:uni-sent")))
        (title (string->utf8 (string-append nd-title-word " \x65E5;\x672C;"))))
    (list (list (lg-st "nd:uni-create") (lg-st "nd:uni-get"))
          (and (string? (jget (nd-j "nd:uni-create") "body")) (equal? sent (string->utf8 (jget (nd-j "nd:uni-create") "body"))))
          (and (string? (jget (nd-j "nd:uni-get") "body")) (equal? sent (string->utf8 (jget (nd-j "nd:uni-get") "body"))))
          (and (string? (jget (nd-j "nd:uni-get") "title")) (equal? title (string->utf8 (jget (nd-j "nd:uni-get") "title")))))))

(test-equal "nodes: a body of exactly 1,048,576 characters is stored and read back whole"
  (list '(201 200) nd-body-cap #t #t)
  (let ((sent (obs "nd:big-sent")) (got (jget (nd-j "nd:big-get") "body")))
    (list (list (lg-st "nd:big-create") (lg-st "nd:big-get"))
          (if (string? got) (string-length got) got)
          (and (string? got) (string=? sent got))
          (let ((c (jget (nd-j "nd:big-create") "body")))
            (and (string? c) (string=? sent c))))))

(test-equal "nodes: a body of one character more is 413 payload_too_large"
  (list 413 nd-problem "payload_too_large")
  (list (lg-st "nd:over") (nd-h "nd:over" "content-type") (lg-code "nd:over")))

(test-equal "nodes: an id of version 4 is 400 invalid_request"
  (list 400 nd-problem "invalid_request")
  (list (lg-st "nd:v4") (nd-h "nd:v4" "content-type") (lg-code "nd:v4")))

;; The request log: one line a request, naming the path and the account. A
;; refusal before the key is looked at (a bad id's 400, a 428) names no
;; account, and nor does a key no row holds. A PUT's body is read only once
;; its key has passed, so a 413 names the account.
(define (nd-log-lines)
  (let ((o (obs "ndsrv:out")))
    (if (string? o)
        (filter (lambda (l) (starts-with? (or (field-of l "path") "") "/v1/nodes")) (request-lines o))
        '())))

(test-equal "nodes log: one line a request, in order, each with its method, path, status and account (`-` when the key was not yet looked at, or no row holds it)"
  (map (lambda (e)
         (list (car e) (cadr e) (caddr e)
               (cond ((member (caddr e) '("400" "428")) "-")
                     ((eq? (cadddr e) 'a) (obs "nd:a-id"))
                     ((eq? (cadddr e) 'b) (obs "nd:b-id"))
                     (else "-"))))
       (obs "nd:expect"))
  (map line-key (nd-log-lines)))

(test-equal "nodes log: the run made 24 requests, and the log has 24 lines for them"
  '(24 24) (list (length (obs "nd:expect")) (length (nd-log-lines))))

(test-equal "nodes log: the body's 413 is answered after the key's read job, so its line names the account"
  (list "413" (obs "nd:a-id"))
  (let ((line (find (lambda (l) (equal? (field-of l "path") (string-append "/v1/nodes/" nd-n5)))
                    (nd-log-lines))))
    (if line (list (field-of line "status") (field-of line "account")) 'no-line)))

(test-equal "nodes: a 2 MB body of 1000-digit integers with a well-shaped key no row holds is 401, answered before the body is parsed: its line's ms is under 150 (about 260 when parsed), account -"
  (list #t 401 nd-problem "unauthorized" (list "PUT" (string-append "/v1/nodes/" nd-n6) "401" "-")
        'under-150)
  (let ((line (find (lambda (l) (equal? (field-of l "path") (string-append "/v1/nodes/" nd-n6)))
                    (nd-log-lines))))
    (list (< (bytevector-length (string->utf8 nd-hostile)) 2097152)
          (lg-st "nd:hostile") (nd-h "nd:hostile" "content-type") (lg-code "nd:hostile")
          (and line (line-key line))
          (let ((ms (and line (string->number (or (field-of line "ms") "x")))))
            (if (and ms (< ms 150)) 'under-150 (list 'ms ms))))))

(test-equal "nodes log: no title word and no body word anywhere in the server's output or error stream, both read, the output holding the node requests' lines"
  '(#t #t #f #f #f #f)
  (let ((o (obs "ndsrv:out")) (e (obs "ndsrv:err")))
    (list (and (string? o) (contains? o "path=/v1/nodes/")) (string? e)
          (and (string? o) (contains? o nd-title-word)) (and (string? o) (contains? o nd-body-word))
          (and (string? e) (contains? e nd-title-word)) (and (string? e) (contains? e nd-body-word)))))

(test-equal "nodes: the file after the server stops: 3 nodes, 5 revisions, 5 changes; account one's seq is 1..5 and account two has none; the ops and the nodes' revisions"
  (list 3 5 5 '(1 2 3 4 5) '() '("create" "update" "restore" "create" "create") '(1 1 3))
  (obs "nd:db"))

;; --- the node lifecycle over the wire (slice 4b) ---------------------------

(define state-less-members '("id" "kind" "state" "parent" "title" "content_type" "props" "revision" "created" "updated"))
(define (lc-ids k)
  (let ((is (jitems (nd-j k)))) (if (list? is) (map (lambda (i) (jget i "id")) is) is)))
(define (lc-problem status code)
  (list status nd-problem code))
(define (lc-got k) (list (lg-st k) (nd-h k "content-type") (lg-code k)))
;; lc-change : String -> (List Status ETag State Revision (Listof String))
;; A state change's answer: its status, ETag, state, revision and members.
(define (lc-change k)
  (let ((j (nd-j k)))
    (list (lg-st k) (nd-h k "etag") (jget j "state") (jget j "revision") (members j))))

(test-equal "lifecycle: the run's setup worked: migrated, two accounts, the server stopped with 0 and raised nothing"
  '(0 #t #t 0 unobserved)
  (list (obs "lc:migrate")
        (and (string? (obs "lc:a-id")) (= 36 (string-length (obs "lc:a-id"))))
        (and (string? (obs "lc:b-id")) (not (equal? (obs "lc:a-id") (obs "lc:b-id"))))
        (obs "lcsrv:exit") (obs "lcsrv:raised")))

(test-equal "lifecycle: a new node is 201, state active"
  (list 201 "\"1\"" "active")
  (list (lg-st "lc:create") (nd-h "lc:create" "etag") (jget (nd-j "lc:create") "state")))

(test-equal "lifecycle: unarchive of an active node is 409 wrong_state"
  (lc-problem 409 "wrong_state")
  (lc-got "lc:unarchive-active"))

(test-equal "lifecycle: archive with If-Match \"1\" is 200, ETag \"2\", state archived, revision 2, and no body member"
  (list 200 "\"2\"" "archived" 2 state-less-members)
  (lc-change "lc:archive"))

(test-equal "lifecycle: an archived node is not in the default list, and is under ?state=archived"
  (list 200 '() 200 (list lc-n1))
  (list (lg-st "lc:list-active-1") (lc-ids "lc:list-active-1")
        (lg-st "lc:list-archived") (lc-ids "lc:list-archived")))

(test-equal "lifecycle: GET of an archived node shows its state and its body"
  (list 200 "\"2\"" "archived" "pangolinbody one" "narwhaltitle one")
  (let ((j (nd-j "lc:get-archived")))
    (list (lg-st "lc:get-archived") (nd-h "lc:get-archived" "etag") (jget j "state") (jget j "body") (jget j "title"))))

(test-equal "lifecycle: a replace of an archived node is 200, revision 3, and the node stays archived"
  (list 200 "\"3\"" "archived" 3 "pangolinbody three")
  (let ((j (nd-j "lc:replace-archived")))
    (list (lg-st "lc:replace-archived") (nd-h "lc:replace-archived" "etag") (jget j "state")
          (jget j "revision") (jget j "body"))))

(test-equal "lifecycle: unarchive is 200, ETag \"4\", active again, and the body is the replace's"
  (list (list 200 "\"4\"" "active" 4 state-less-members) 200 "active" "pangolinbody three")
  (list (lc-change "lc:unarchive") (lg-st "lc:get-active")
        (jget (nd-j "lc:get-active") "state") (jget (nd-j "lc:get-active") "body")))

(test-equal "lifecycle: trash with If-Match \"4\" is 200, ETag \"5\", state trashed"
  (list 200 "\"5\"" "trashed" 5 state-less-members)
  (lc-change "lc:trash"))

(test-equal "lifecycle: on a trashed node a replace, a revision restore and an archive are each 409 wrong_state"
  (list (lc-problem 409 "wrong_state") (lc-problem 409 "wrong_state") (lc-problem 409 "wrong_state"))
  (map lc-got '("lc:replace-trashed" "lc:restore-trashed" "lc:archive-trashed")))

(test-equal "lifecycle: a trashed node is in no list but ?state=trashed, and GET still shows it with its body"
  (list '() '() (list lc-n1) 200 "trashed" 5 "pangolinbody three")
  (list (lc-ids "lc:list-active-2") (lc-ids "lc:list-archived-2") (lc-ids "lc:list-trashed")
        (lg-st "lc:get-trashed") (jget (nd-j "lc:get-trashed") "state")
        (jget (nd-j "lc:get-trashed") "revision") (jget (nd-j "lc:get-trashed") "body")))

(test-equal "lifecycle: a stale trash and a stale untrash are 412 precondition_failed, not 409"
  (list (lc-problem 412 "precondition_failed") (lc-problem 412 "precondition_failed"))
  (map lc-got '("lc:stale-trash" "lc:stale-untrash")))

(test-equal "lifecycle: a state change with no If-Match is 428, with If-None-Match: * is 400"
  (list (lc-problem 428 "precondition_required") (lc-problem 400 "invalid_request"))
  (map lc-got '("lc:untrash-bare" "lc:untrash-none-match")))

(test-equal "lifecycle: ?state=purged and ?state=nonsense are 400 invalid_request"
  (list (lc-problem 400 "invalid_request") (lc-problem 400 "invalid_request"))
  (map lc-got '("lc:list-purged" "lc:list-nonsense")))

(test-equal "lifecycle: untrash is 200, ETag \"6\", active"
  (list 200 "\"6\"" "active" 6 state-less-members)
  (lc-change "lc:untrash"))

(test-equal "lifecycle: the revisions list shows only the revisions that wrote content (3, 1), and a gap's revision is 404 not_found"
  (list 200 '(3 1) (lc-problem 404 "not_found") 200 "narwhaltitle three")
  (list (lg-st "lc:revisions")
        (let ((is (jitems (nd-j "lc:revisions")))) (if (list? is) (map (lambda (i) (jget i "revision")) is) is))
        (lc-got "lc:revision-gap")
        (lg-st "lc:revision-3") (jget (nd-j "lc:revision-3") "title")))

(test-equal "lifecycle: DELETE of an active node is 409 wrong_state; with no If-Match it is 428"
  (list (lc-problem 409 "wrong_state") (lc-problem 428 "precondition_required"))
  (map lc-got '("lc:delete-active" "lc:delete-bare")))

(test-equal "lifecycle: trash again is 200, ETag \"7\"; the DELETE is 204 with an empty body and no ETag"
  (list (list 200 "\"7\"" "trashed" 7 state-less-members) 204 "" #f)
  (list (lc-change "lc:trash-again") (lg-st "lc:delete") (lg-text (obs "lc:delete")) (nd-h "lc:delete" "etag")))

(test-equal "lifecycle: after the purge a GET, the revisions list, a revision and every write are 404 not_found"
  (map (lambda (k) (lc-problem 404 "not_found"))
       '("lc:p-get" "lc:p-revisions" "lc:p-revision" "lc:p-replace" "lc:p-delete" "lc:p-trash"))
  (map lc-got '("lc:p-get" "lc:p-revisions" "lc:p-revision" "lc:p-replace" "lc:p-delete" "lc:p-trash")))

(test-equal "lifecycle: after the purge a create on the id is 412 precondition_failed, for the owner and for another account"
  (list (lc-problem 412 "precondition_failed") (lc-problem 412 "precondition_failed"))
  (map lc-got '("lc:p-create" "lc:p-b-create")))

(test-equal "lifecycle: the other account's archive, unarchive, trash, untrash and DELETE of a live node, each at its revision, are 404 not_found"
  (map (lambda (k) (lc-problem 404 "not_found")) '(1 2 3 4 5))
  (map lc-got '("lc:b-archive" "lc:b-unarchive" "lc:b-trash" "lc:b-untrash" "lc:b-delete")))

(test-equal "lifecycle: the node they tried is unchanged: active, revision 1, ETag \"1\", its body"
  (list 200 "\"1\"" "active" 1 "pangolinbody two")
  (let ((j (nd-j "lc:n2-get")))
    (list (lg-st "lc:n2-get") (nd-h "lc:n2-get" "etag") (jget j "state") (jget j "revision") (jget j "body"))))

(test-equal "lifecycle: after the purge no list shows the purged node: active shows the live one, archived and trashed are empty"
  (list (list lc-n2) '() '())
  (list (lc-ids "lc:list-active-3") (lc-ids "lc:list-archived-3") (lc-ids "lc:list-trashed-3")))

(test-equal "lifecycle: a trash and a DELETE sent with a body (invalid JSON too) answer as with none, and the next request works"
  (list 201 (list 200 "\"2\"" "trashed" 2 state-less-members) 204 "" #f 200 (list lc-n2))
  (list (lg-st "lc:n3-create") (lc-change "lc:n3-trash-body")
        (lg-st "lc:n3-delete-body") (lg-text (obs "lc:n3-delete-body")) (nd-h "lc:n3-delete-body" "etag")
        (lg-st "lc:n3-after") (lc-ids "lc:n3-after")))

(define (lc-log-lines)
  (let ((o (obs "lcsrv:out")))
    (if (string? o)
        (filter (lambda (l) (starts-with? (or (field-of l "path") "") "/v1/nodes")) (request-lines o))
        '())))

(test-equal "lifecycle log: one line a request, in order, each with its method, path (no query), status and account (`-` for a 400 or a 428, answered before the key)"
  (map (lambda (e)
         (list (car e) (cadr e) (caddr e)
               (cond ((member (caddr e) '("400" "428")) "-")
                     ((eq? (cadddr e) 'a) (obs "lc:a-id"))
                     ((eq? (cadddr e) 'b) (obs "lc:b-id"))
                     (else "-"))))
       (obs "lc:expect"))
  (map line-key (lc-log-lines)))

(test-equal "lifecycle log: the run made 53 requests, and the log has a line for each"
  '(53 53)
  (list (length (obs "lc:expect")) (length (lc-log-lines))))

(test-equal "lifecycle log: each new route has a line: archive, unarchive, trash, untrash and DELETE, with a 200 or a 204 among them"
  '(#t #t #t #t #t)
  (let ((lines (map line-key (lc-log-lines))))
    (map (lambda (m path-end status)
           (and (member (list m (string-append "/v1/nodes/" (car path-end) (cdr path-end)) status (obs "lc:a-id")) lines) #t))
         '("POST" "POST" "POST" "POST" "DELETE")
         (list (cons lc-n1 "/archive") (cons lc-n1 "/unarchive") (cons lc-n1 "/trash") (cons lc-n1 "/untrash") (cons lc-n1 ""))
         '("200" "200" "200" "200" "204"))))

(test-equal "lifecycle log: no title word and no body word anywhere in the server's output or error stream"
  '(#t #t #f #f #f #f)
  (let ((o (obs "lcsrv:out")) (e (obs "lcsrv:err")))
    (list (and (string? o) (contains? o "path=/v1/nodes/")) (string? e)
          (and (string? o) (contains? o lc-title-word)) (and (string? o) (contains? o lc-body-word))
          (and (string? e) (contains? e lc-title-word)) (and (string? e) (contains? e lc-body-word)))))

(test-equal "lifecycle: the file after the server stops: states (purged, active, purged), revisions (8, 1, 3), the purged titles emptied, no snapshot of either purged node left, the ops in order, seq 1..12"
  (list '("purged" "active" "purged") '(8 1 3) '("" "narwhaltitle two" "") '() 0
        '("create" "archive" "update" "unarchive" "trash" "untrash" "trash" "purge"
          "create" "create" "trash" "purge")
        '(1 2 3 4 5 6 7 8 9 10 11 12))
  (obs "lc:db"))

;; --- the tree over the wire (slice 5a) -------------------------------------

;; tr-hex : String -> String    an id as the file shows it: no dashes
(define (tr-hex id)
  (list->string (filter (lambda (c) (not (char=? c #\-))) (string->list id))))
(define (tr-problem status code) (list status nd-problem code))
(define (tr-got k) (list (lg-st k) (nd-h k "content-type") (lg-code k)))
(define (tr-ids k) (lc-ids k))
(define (tr-parents k)
  (let ((is (jitems (nd-j k)))) (if (list? is) (map (lambda (i) (jget i "parent")) is) is)))
;; tr-moved : String -> (List Status ETag Parent (Listof String))
;; A move's answer: its status, ETag, parent and members.
(define (tr-moved k)
  (let ((j (nd-j k))) (list (lg-st k) (nd-h k "etag") (jget j "parent") (members j))))
;; tr-shown : String -> (List Status ETag State Revision Parent)
(define (tr-shown k)
  (let ((j (nd-j k))) (list (lg-st k) (nd-h k "etag") (jget j "state") (jget j "revision") (jget j "parent"))))
(define tr-invalid (tr-problem 409 "invalid_parent"))

(test-equal "tree: the run's setup worked: migrated, two accounts, the server stopped with 0 and raised nothing"
  '(0 #t #t 0 unobserved)
  (list (obs "tr:migrate")
        (and (string? (obs "tr:a-id")) (= 36 (string-length (obs "tr:a-id"))))
        (and (string? (obs "tr:b-id")) (not (equal? (obs "tr:a-id") (obs "tr:b-id"))))
        (obs "trsrv:exit") (obs "trsrv:raised")))

(test-equal "tree: a create is 201 with its parent in the answer: the project's id, null for \"parent\": null, and null where none was sent"
  (list (list 201 'null) (list 201 tr-p) (list 201 'null) (list 201 'null))
  (map (lambda (k) (list (lg-st k) (jget (nd-j k) "parent"))) '("tr:p-create" "tr:n-create" "tr:j-create" "tr:t-create")))

(test-equal "tree: ?parent=null lists the project, the journal and the task and not the note; ?parent=<project> lists the note; the flat list holds all four; each item has its parent"
  (list 200 (list tr-p tr-j tr-t) '(null null null)
        200 (list tr-n) (list tr-p)
        200 (list tr-p tr-n tr-j tr-t) (list 'null tr-p 'null 'null))
  (list (lg-st "tr:list-top") (tr-ids "tr:list-top") (tr-parents "tr:list-top")
        (lg-st "tr:list-p") (tr-ids "tr:list-p") (tr-parents "tr:list-p")
        (lg-st "tr:list-flat") (tr-ids "tr:list-flat") (tr-parents "tr:list-flat")))

(test-equal "tree: a move of the task into the project is 200, ETag \"2\", the parent the project, and no body member"
  (list 200 "\"2\"" tr-p state-less-members)
  (tr-moved "tr:t-to-p"))

(test-equal "tree: a move of the task into the journal is 409 invalid_parent; the note into the journal works (ETag \"2\"); the note under the task is invalid_parent"
  (list tr-invalid (list 200 "\"2\"" tr-j state-less-members) tr-invalid)
  (list (tr-got "tr:t-to-j") (tr-moved "tr:n-to-j") (tr-got "tr:n-under-t")))

(test-equal "tree: after the moves the journal holds the note and the project holds the task"
  (list (list tr-n) (list tr-t))
  (list (tr-ids "tr:list-j") (tr-ids "tr:list-p-2")))

(test-equal "tree: a project made in the project is 201; moving the outer project under the inner, or under itself, is 409 would_loop"
  (list 201 tr-p (tr-problem 409 "would_loop") (tr-problem 409 "would_loop"))
  (list (lg-st "tr:q-create") (jget (nd-j "tr:q-create") "parent")
        (tr-got "tr:p-under-q") (tr-got "tr:p-under-p")))

(test-equal "tree: a stale move is 412; none is 428; with If-None-Match is 400; as text/plain is 415; {} and an extra member are 400; a replace with a parent is 400"
  (list (tr-problem 412 "precondition_failed") (tr-problem 428 "precondition_required")
        (tr-problem 400 "invalid_request") (tr-problem 415 "unsupported_media_type")
        (tr-problem 400 "invalid_request") (tr-problem 400 "invalid_request")
        (tr-problem 400 "invalid_request"))
  (map tr-got '("tr:stale" "tr:no-match" "tr:none-match" "tr:text-plain" "tr:empty-object"
                "tr:extra-member" "tr:replace-parent")))

(test-equal "tree: after the refusals the task is as it was: active, revision 2, ETag \"2\", under the project"
  (list 200 "\"2\"" "active" 2 tr-p)
  (tr-shown "tr:t-after-refusals"))

(test-equal "tree: a move with {\"parent\": null} is 200, ETag \"3\", the parent null; the top level lists the project, the journal and the task again"
  (list (list 200 "\"3\"" 'null state-less-members) (list tr-p tr-j tr-t))
  (list (tr-moved "tr:t-to-top") (tr-ids "tr:list-top-2")))

(test-equal "tree: a trashed project: 200, ETag \"2\"; its child is still active, under it, in the flat list and under ?parent=<project>"
  (list (list 200 "\"2\"" "trashed") (list 200 "\"1\"" "active" 1 tr-p)
        (list tr-n tr-j tr-t tr-q tr-m) (list tr-q tr-m))
  (list (let ((j (nd-j "tr:p-trash"))) (list (lg-st "tr:p-trash") (nd-h "tr:p-trash" "etag") (jget j "state")))
        (tr-shown "tr:q-after-trash")
        (tr-ids "tr:list-flat-2") (tr-ids "tr:list-p-3")))

(test-equal "tree: into the trashed project a create and a move are 409 invalid_parent; the trashed project's own move is 409 wrong_state"
  (list tr-invalid tr-invalid (tr-problem 409 "wrong_state"))
  (map tr-got '("tr:create-in-trashed" "tr:t-into-trashed" "tr:p-move-trashed")))

(test-equal "tree: a DELETE of the trashed project with children is 409 has_children"
  (tr-problem 409 "has_children")
  (tr-got "tr:p-delete-full"))

(test-equal "tree: move-children to the top level is 200 {moved 2, left 0} with no ETag; the project's revision is unchanged; each child is at revision 2 with no parent"
  (list 200 "{\"moved\":2,\"left\":0}" #f
        (list 200 "\"2\"" "trashed" 2 'null) (list 200 "\"2\"" "active" 2 'null) (list 200 "\"2\"" "active" 2 'null))
  (list (lg-st "tr:p-move-children") (lg-text (obs "tr:p-move-children")) (nd-h "tr:p-move-children" "etag")
        (tr-shown "tr:p-get") (tr-shown "tr:q-get") (tr-shown "tr:m-get")))

(test-equal "tree: the DELETE then is 204 with an empty body, and the project is 404 after"
  (list 204 "" (tr-problem 404 "not_found"))
  (list (lg-st "tr:p-delete") (lg-text (obs "tr:p-delete")) (tr-got "tr:p-get-purged")))

(test-equal "tree: a second project holding a note, a task, a trashed note and an archived note; a bulk move of its children into itself is 409 would_loop"
  (list 201 201 201 201 "trashed" 201 "archived" (tr-problem 409 "would_loop"))
  (list (lg-st "tr:p2-create") (lg-st "tr:n2-create") (lg-st "tr:t2-create")
        (lg-st "tr:n3-create") (jget (nd-j "tr:n3-trash") "state")
        (lg-st "tr:n4-create") (jget (nd-j "tr:n4-archive") "state")
        (tr-got "tr:p2-into-p2")))

(test-equal "tree: a bulk move into the journal takes the active note and the archived note and leaves the task and the trashed note: {moved 2, left 2}; the project is at revision 1; the project still holds the task (active) and the trashed note (trashed); the journal holds the notes, the archived one under ?state=archived"
  (list 200 "{\"moved\":2,\"left\":2}" #f (list 200 "\"1\"" "active" 1 'null) (list tr-t2) (list tr-n tr-n2)
        (list tr-n3) (list tr-n4))
  (list (lg-st "tr:p2-into-j") (lg-text (obs "tr:p2-into-j")) (nd-h "tr:p2-into-j" "etag")
        (tr-shown "tr:p2-get") (tr-ids "tr:list-p2") (tr-ids "tr:list-j-2")
        (tr-ids "tr:list-p2-trashed") (tr-ids "tr:list-j-archived")))

(test-equal "tree: a bulk move of the second project to the top level takes the task and leaves the trashed note: {moved 1, left 1}, no ETag; the task is at revision 2 with no parent; the trashed note is still under the project"
  (list 200 "{\"moved\":1,\"left\":1}" #f (list 200 "\"2\"" "active" 2 'null) (list tr-n3))
  (list (lg-st "tr:p2-to-top") (lg-text (obs "tr:p2-to-top")) (nd-h "tr:p2-to-top" "etag")
        (tr-shown "tr:t2-get") (tr-ids "tr:list-p2-trashed-2")))

(test-equal "tree: the other account's move and move-children of the first account's project, at its revision, are 404 not_found and change nothing"
  (list (tr-problem 404 "not_found") (tr-problem 404 "not_found")
        (list 200 "\"1\"" "active" 1 'null) (list tr-t2))
  (list (tr-got "tr:b-move") (tr-got "tr:b-move-children")
        (tr-shown "tr:p2-get-after-b") (tr-ids "tr:list-p2-after-b")))

(test-equal "tree: the first account's project as the other account's parent, on a create and on a move, is 409 invalid_parent, the same bytes as for an id nobody holds"
  (list tr-invalid tr-invalid 201 tr-invalid tr-invalid #t #t)
  (list (tr-got "tr:b-create-under-a") (tr-got "tr:b-create-under-nobody") (lg-st "tr:nb-create")
        (tr-got "tr:b-move-under-a") (tr-got "tr:b-move-under-nobody")
        (equal? (lg-text (obs "tr:b-create-under-a")) (lg-text (obs "tr:b-create-under-nobody")))
        (equal? (lg-text (obs "tr:b-move-under-a")) (lg-text (obs "tr:b-move-under-nobody")))))

(test-equal "tree: ?parent=<the first account's project> is 404 for the other account, the same bytes as for an id nobody holds"
  (list (tr-problem 404 "not_found") (tr-problem 404 "not_found") #t)
  (list (tr-got "tr:b-list-a-project") (tr-got "tr:b-list-nobody")
        (equal? (lg-text (obs "tr:b-list-a-project")) (lg-text (obs "tr:b-list-nobody")))))

(test-equal "tree: ?parent= empty, NULL, twice and a non-id are each 400 invalid_request"
  (map (lambda (k) (tr-problem 400 "invalid_request")) '(1 2 3 4))
  (map tr-got '("tr:list-empty" "tr:list-NULL" "tr:list-twice" "tr:list-junk")))

(test-equal "tree: a missing id, as ?parent=, as a move and as a move-children, is 404 not_found; so is a purged project as ?parent="
  (map (lambda (k) (tr-problem 404 "not_found")) '(1 2 3 4))
  (map tr-got '("tr:list-missing" "tr:move-missing" "tr:move-children-missing" "tr:list-purged-parent")))

(define (tr-log-lines)
  (let ((o (obs "trsrv:out")))
    (if (string? o)
        (filter (lambda (l) (starts-with? (or (field-of l "path") "") "/v1/nodes")) (request-lines o))
        '())))

(test-equal "tree log: one line a request, in order, each with its method, path (no query), status and account (`-` for a 428, an If-None-Match 400 and a list's 400, answered before the key)"
  (map (lambda (e)
         (list (car e) (cadr e) (caddr e)
               (cond ((eq? (cadddr e) 'a) (obs "tr:a-id"))
                     ((eq? (cadddr e) 'b) (obs "tr:b-id"))
                     (else "-"))))
       (obs "tr:expect"))
  (map line-key (tr-log-lines)))

(test-equal "tree log: the run made 77 requests, and the log has a line for each"
  '(77 77)
  (list (length (obs "tr:expect")) (length (tr-log-lines))))

(test-equal "tree log: each new route has a line: move and move-children, 200 and 409 and 404 among them"
  '(#t #t #t #t #t #t)
  (let ((lines (map line-key (tr-log-lines))) (a (obs "tr:a-id")) (b (obs "tr:b-id")))
    (map (lambda (l) (and (member l lines) #t))
         (list (list "POST" (string-append "/v1/nodes/" tr-t "/move") "200" a)
               (list "POST" (string-append "/v1/nodes/" tr-t "/move") "409" a)
               (list "POST" (string-append "/v1/nodes/" tr-p "/move") "409" a)
               (list "POST" (string-append "/v1/nodes/" tr-p "/move-children") "200" a)
               (list "POST" (string-append "/v1/nodes/" tr-p2 "/move-children") "200" a)
               (list "POST" (string-append "/v1/nodes/" tr-p2 "/move-children") "404" b)))))

(test-equal "tree log: no title word and no body word anywhere in the server's output or error stream"
  '(#t #t #f #f #f #f)
  (let ((o (obs "trsrv:out")) (e (obs "trsrv:err")))
    (list (and (string? o) (contains? o "path=/v1/nodes/")) (string? e)
          (and (string? o) (contains? o tr-title-word)) (and (string? o) (contains? o tr-body-word))
          (and (string? e) (contains? e tr-title-word)) (and (string? e) (contains? e tr-body-word)))))

(test-equal "tree: the file after the server stops: the purged project has no parent and no children; every parent as the story leaves it; revisions; the first account's ops in order, and the moves, the bulk one's in id order"
  (list '("purged" "active" "active" "active" "active" "active" "active" "active" "active" "trashed" "archived" "active")
        '(3 2 1 3 2 2 1 2 2 2 3 1)
        0
        '("create" "create" "create" "create" "move" "move" "create" "move" "create" "trash"
          "move" "move" "purge" "create" "create" "create" "create" "trash" "create" "archive" "move" "move" "move")
        (map (lambda (p) (string-append (tr-hex (car p)) ":" (number->string (cdr p))))
             (list (cons tr-t 2) (cons tr-n 2) (cons tr-t 3) (cons tr-q 2) (cons tr-m 2) (cons tr-n2 2) (cons tr-n4 3) (cons tr-t2 2))))
  (let ((d (obs "tr:db")))
    (if (list? d)
        (list (car d) (cadr d)
              (car (list-ref d 4)) (list-ref d 5) (list-ref d 6))
        d)))

(test-equal "tree: the file's parents: the purged project, the journal, the task, the two projects made top level and the second account's note have none; the notes are under the journal and the second task under its project"
  (map (lambda (p) (if p (tr-hex p) "")) (list #f tr-j #f #f #f #f #f tr-j #f tr-p2 tr-j #f))
  (let ((d (obs "tr:db"))) (if (list? d) (list-ref d 3) d)))

;; --- links over the wire (slice 5b) -----------------------------------------

(define (ln-got k) (list (lg-st k) (nd-h k "content-type") (lg-code k)))
(define (ln-problem status code) (list status nd-problem code))
(define (ln-hex id) (tr-hex id))
;; ln-items : String -> (Listof (List Type Id Kind State))
(define (ln-items k)
  (let ((is (jitems (nd-j k))))
    (if (list? is)
        (map (lambda (i) (let ((n (jget i "node"))) (list (jget i "type") (jget n "id") (jget n "kind") (jget n "state")))) is)
        is)))
(define (ln-ids k) (let ((is (ln-items k))) (if (list? is) (map (lambda (i) (list (car i) (cadr i))) is) is)))
(define (ln-created k)
  (let ((is (jitems (nd-j k)))) (if (list? is) (map (lambda (i) (jget i "created")) is) is)))
;; ln-link : String -> (List Status ContentType Members ETag Location)
(define (ln-link k) (list (lg-st k) (nd-h k "content-type") (members (nd-j k)) (nd-h k "etag") (nd-h k "location")))
(define ln-link-members '("source" "type" "target" "created"))
(define ln-nf (ln-problem 404 "not_found"))
(define ln-bad (ln-problem 400 "invalid_request"))
(define ln-wrong (ln-problem 409 "wrong_state"))
(define (ln-text k) (if (lg-ok? k) (lg-text (obs k)) (obs k)))
(define (ln-nodes-same? a b) (equal? (ln-text a) (ln-text b)))

(test-equal "links: the run's setup worked: migrated, two accounts, the server stopped with 0 and raised nothing"
  '(0 #t #t 0 unobserved)
  (list (obs "ln:migrate")
        (and (string? (obs "ln:a-id")) (= 36 (string-length (obs "ln:a-id"))))
        (and (string? (obs "ln:b-id")) (not (equal? (obs "ln:a-id") (obs "ln:b-id"))))
        (obs "lnsrv:exit") (obs "lnsrv:raised")))

(test-equal "links: the nodes are made: 201 for each of the seven and the other account's"
  (list 201 201 201 201 201 201 201 201)
  (map lg-st '("ln:create-x" "ln:create-y" "ln:create-z" "ln:create-t" "ln:create-s" "ln:create-h"
               "ln:create-a" "ln:create-bn")))

;; making a link
(test-equal "links: a PUT makes a link: 201, application/json, the four members, the ends and the type as given, an integer created, no ETag, no Location"
  (list 201 "application/json" ln-link-members #f #f (list ln-x "related" ln-y) #t)
  (let ((j (nd-j "ln:put-1")))
    (append (ln-link "ln:put-1")
            (list (list (jget j "source") (jget j "type") (jget j "target"))
                  (exact? (jget j "created"))))))

(test-equal "links: the same PUT again, 30 ms later, is 200 with the same four members, the first created, no ETag, no Location"
  (list (list 200 "application/json" ln-link-members #f #f) #t)
  (list (ln-link "ln:put-2")
        (equal? (nd-j "ln:put-1") (nd-j "ln:put-2"))))

(test-equal "links: a link changes neither node: each GET is byte for byte the same before and after, with ETag \"1\", revision 1, and after the removals and the purge too"
  (list #t #t #t #t (list 200 "\"1\"" 1 1))
  (list (ln-nodes-same? "ln:x-0" "ln:x-1") (ln-nodes-same? "ln:y-0" "ln:y-1")
        (and (ln-nodes-same? "ln:x-0" "ln:x-del") (ln-nodes-same? "ln:y-0" "ln:y-del"))
        (and (ln-nodes-same? "ln:x-0" "ln:x-pre") (ln-nodes-same? "ln:x-0" "ln:x-post"))
        (list (lg-st "ln:x-1") (nd-h "ln:x-1" "etag") (jget (nd-j "ln:x-1") "revision")
              (jget (nd-j "ln:y-1") "revision"))))

;; listing
(test-equal "links: out from the source lists the target: 200, application/json, items of type, created and node, the created of the PUT, the node's id, kind and state, next null"
  (list 200 "application/json" '("items" "next") '("type" "created" "node")
        (list (list "related" ln-y "note" "active")) (list (jget (nd-j "ln:put-1") "created")) 'null)
  (let ((j (nd-j "ln:out-x-1")))
    (list (lg-st "ln:out-x-1") (nd-h "ln:out-x-1" "content-type") (members j)
          (members (car (jitems j))) (ln-items "ln:out-x-1") (ln-created "ln:out-x-1") (jget j "next"))))

(test-equal "links: in at the target lists the source, with the same created; the target's out list is empty before; direction=out is the default"
  (list (list (list "related" ln-x "note" "active")) (list (jget (nd-j "ln:put-1") "created")) '()
        (ln-items "ln:out-x-1"))
  (list (ln-items "ln:in-y-1") (ln-created "ln:in-y-1") (ln-items "ln:out-y-0") (ln-items "ln:out-x-1")))

(test-equal "links: a page's node is the nodes list's item for it, byte for byte, without a body"
  (list #t 10)
  (let* ((item (car (jitems (nd-j "ln:in-y-1"))))
         (node (jget item "node"))
         (listed (filter (lambda (n) (equal? (jget n "id") ln-x)) (jitems (nd-j "ln:nodes-list")))))
    (list (and (pair? listed) (equal? node (car listed)))
          (length (members node)))))

(test-equal "links: a link of each type between the same two nodes is three links, listed by type name: blocks, mentions, related, each with its own created"
  (list (list (list "blocks" ln-y) (list "mentions" ln-y) (list "related" ln-y)) 3
        (list 201 201 201))
  (list (ln-ids "ln:out-x-3")
        (distinct-count (ln-created "ln:out-x-3"))
        (map lg-st '("ln:put-1" "ln:put-m" "ln:put-b"))))

(test-equal "links: the reverse direction is its own link: 201; y lists x out, x lists y in"
  (list 201 (list (list "related" ln-x)) (list (list "related" ln-y)))
  (list (lg-st "ln:put-rev") (ln-ids "ln:out-y-1") (ln-ids "ln:in-x-1")))

(test-equal "links: in lists by type then by the source's id: a second source of the same type comes after the first"
  (list (list "blocks" ln-x) (list "mentions" ln-x) (list "related" ln-x) (list "related" ln-z))
  (ln-ids "ln:in-y-4"))

(test-equal "links: ?type= narrows: out of one type, in of one type with two sources, in of a type with none"
  (list (list (list "mentions" ln-y)) (list (list "related" ln-x) (list "related" ln-z)) '())
  (list (ln-ids "ln:out-x-mentions") (ln-ids "ln:in-y-related") (ln-ids "ln:in-x-blocks")))

;; paging
(test-equal "links: out of x with limit=1 gives one item a page and follows next, which is <type>:<id>, to a null; each link once, in order"
  (list (list 200 (list (list "blocks" ln-y)) (string-append "blocks:" ln-y))
        (list 200 (list (list "mentions" ln-y)) (string-append "mentions:" ln-y))
        (list 200 (list (list "related" ln-y)) 'null))
  (obs "ln:pg-out-x"))

(test-equal "links: in at y with limit=1 follows next through four pages, across the type's boundary and within it; with limit=2, two pages; typed, two pages"
  (list (list (list 200 (list (list "blocks" ln-x)) (string-append "blocks:" ln-x))
              (list 200 (list (list "mentions" ln-x)) (string-append "mentions:" ln-x))
              (list 200 (list (list "related" ln-x)) (string-append "related:" ln-x))
              (list 200 (list (list "related" ln-z)) 'null))
        (list (list 200 (list (list "blocks" ln-x) (list "mentions" ln-x)) (string-append "mentions:" ln-x))
              (list 200 (list (list "related" ln-x) (list "related" ln-z)) 'null))
        (list (list 200 (list (list "related" ln-x)) (string-append "related:" ln-x))
              (list 200 (list (list "related" ln-z)) 'null))
        (list (list 200 (list (list "blocks" ln-y) (list "mentions" ln-y) (list "related" ln-y)) 'null)))
  (list (obs "ln:pg-in-y") (obs "ln:pg-in-y-2") (obs "ln:pg-in-y-related") (obs "ln:pg-out-x-100")))

(test-equal "links: after names a place, not a link that must be there: the page after related:<x> typed, and after mentions:<x> untyped"
  (list (list (list "related" ln-z)) (list (list "related" ln-x) (list "related" ln-z)))
  (list (ln-ids "ln:after-typed") (ln-ids "ln:after-untyped")))

;; removing
(test-equal "links: a DELETE removes the link: 204 with an empty body, no ETag; again is 404 not_found"
  (list 204 "" #f ln-nf)
  (list (lg-st "ln:del-1") (lg-text (obs "ln:del-1")) (nd-h "ln:del-1" "etag") (ln-got "ln:del-2")))

(test-equal "links: after it, x's out list and y's in list are without it, and the other links stay: the other types, the second source, and the reverse"
  (list (list (list "blocks" ln-y) (list "mentions" ln-y))
        (list (list "blocks" ln-x) (list "mentions" ln-x) (list "related" ln-z))
        (list (list "related" ln-x)))
  (list (ln-ids "ln:out-x-del") (ln-ids "ln:in-y-del") (ln-ids "ln:out-y-del")))

;; states
(test-equal "links: with the target trashed, a new link is 409 wrong_state, so is one from a trashed source, and a trashed source with a missing target is 404"
  (list 200 ln-wrong ln-wrong ln-nf)
  (list (lg-st "ln:t-trash") (ln-got "ln:put-t-new") (ln-got "ln:put-from-t") (ln-got "ln:put-from-t-to-nobody")))

(test-equal "links: a link made before the trashing stays listed, out and in, with the node's state trashed; the trashed node's own out list is readable"
  (list (list (list "related" ln-t "note" "trashed")) (list (list "related" ln-x "note" "active")) '())
  (list (ln-items "ln:out-x-t") (ln-items "ln:in-t") (ln-items "ln:out-t")))

(test-equal "links: a repeated PUT of that older link is 200 with the first created, no ETag; the 409s left no link"
  (list (list 200 "application/json" ln-link-members #f #f) #t)
  (list (ln-link "ln:put-t-again") (equal? (nd-j "ln:put-t") (nd-j "ln:put-t-again"))))

(test-equal "links: a DELETE with the target trashed is 204, and the list is without the link"
  (list 204 '())
  (list (lg-st "ln:del-t") (ln-items "ln:out-x-t-del")))

(test-equal "links: a trashed source's link is listed and a DELETE of it is 204: 201, listed with the target active, 204, gone"
  (list 201 (list (list "related" ln-x "note" "active")) 204 '())
  (list (lg-st "ln:put-s") (ln-items "ln:out-s") (lg-st "ln:del-s") (ln-items "ln:out-s-del")))

(test-equal "links: an archived node can be linked to, and is listed with its state archived"
  (list 200 201 (list (list "related" ln-a "note" "archived")))
  (list (lg-st "ln:a-archive") (lg-st "ln:put-a") (ln-items "ln:out-x-a")))

;; the body of a PUT is not read
(test-equal "links: a PUT with a JSON body and Content-Type gets the same answer as one without: 201 then 200, the same members; a text/plain body that is not JSON too"
  (list (list 201 "application/json" ln-link-members #f #f) (list 200 "application/json" ln-link-members #f #f) #t
        (list 201 "application/json" ln-link-members #f #f))
  (list (ln-link "ln:put-body") (ln-link "ln:put-body-2")
        (equal? (nd-j "ln:put-body") (nd-j "ln:put-body-2"))
        (ln-link "ln:put-body-text")))

;; a purge
(test-equal "links: before the purge h links both ways: x lists h out (mentions) and in (related), z lists h out (blocks) and in (blocks), and h lists its two out links and its two in links while trashed"
  (list #t #t #t #t (list (list "blocks" ln-z) (list "related" ln-x))
        (list (list "blocks" ln-z) (list "mentions" ln-x)) 200)
  (let ((has (lambda (k t) (let ((is (ln-ids k))) (and (member (list t ln-h) is) #t)))))
    (list (has "ln:out-x-pre" "mentions") (has "ln:in-x-pre" "related")
          (has "ln:out-z-pre" "blocks") (has "ln:in-z-pre" "blocks")
          (ln-ids "ln:out-h-trashed") (ln-ids "ln:in-h-trashed") (lg-st "ln:h-trash"))))

(test-equal "links: the purge of h is 204 and h is 404 after, and no list of any other node shows it, either direction, and the lists of every other link are as they were"
  (list 204 ln-nf ln-nf
        (list (list "blocks" ln-y) (list "mentions" ln-y) (list "related" ln-z) (list "related" ln-a))
        (list (list "mentions" ln-z) (list "related" ln-y))
        (list (list "mentions" ln-x) (list "related" ln-y))
        (list (list "related" ln-x)))
  (list (lg-st "ln:h-purge") (ln-got "ln:h-get") (ln-got "ln:out-h-purged")
        (ln-ids "ln:out-x-post") (ln-ids "ln:in-x-post") (ln-ids "ln:out-z-post") (ln-ids "ln:in-z-post")))

(test-equal "links: the purge bumped no other node: x and z are byte for byte as before it, with ETag \"1\""
  (list #t #t "\"1\"" "\"1\"")
  (list (ln-nodes-same? "ln:x-pre" "ln:x-post") (ln-nodes-same? "ln:z-pre" "ln:z-post")
        (nd-h "ln:x-post" "etag") (nd-h "ln:z-post" "etag")))

(test-equal "links: nothing links to or from the purged h: PUT either way and DELETE of a link to it are 404"
  (list ln-nf ln-nf ln-nf)
  (map ln-got '("ln:put-to-h" "ln:put-from-h" "ln:del-to-h")))

;; another account
(test-equal "links: the other account's PUT, DELETE and GET on the first account's nodes are 404 not_found, the same bytes as for an id nobody holds: source, target, delete, list out and list in"
  (list ln-nf ln-nf ln-nf ln-nf ln-nf #t #t #t #t #t)
  (list (ln-got "ln:b-put-src") (ln-got "ln:b-put-tgt") (ln-got "ln:b-del") (ln-got "ln:b-get") (ln-got "ln:b-get-in")
        (ln-nodes-same? "ln:b-put-src" "ln:b-put-src-nobody")
        (ln-nodes-same? "ln:b-put-tgt" "ln:b-put-tgt-nobody")
        (ln-nodes-same? "ln:b-del" "ln:b-del-nobody")
        (ln-nodes-same? "ln:b-get" "ln:b-get-nobody")
        (ln-nodes-same? "ln:b-get-in" "ln:b-get-nobody")))

(test-equal "links: the first account's PUT to the other account's node is 404, the same bytes as to an id nobody holds; and the attempts changed nothing: the lists are as they were, the other account has no link"
  (list ln-nf ln-nf #t (ln-ids "ln:out-x-post") (ln-ids "ln:in-y-del") '())
  (list (ln-got "ln:a-put-bn") (ln-got "ln:a-put-nobody") (ln-nodes-same? "ln:a-put-bn" "ln:a-put-nobody")
        (ln-ids "ln:out-x-after-b") (ln-ids "ln:in-y-after-b") (ln-ids "ln:out-bn")))

;; refusals
(test-equal "links: each refusal is application/problem+json with its code: a type not in the list (any case, on PUT and DELETE, before a missing node is looked for), a bad id at either end, a v4 id, a node linked to itself, If-Match and If-None-Match on a PUT and a DELETE"
  (map (lambda (k) ln-bad)
       '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))
  (map ln-got '("ln:bad-type" "ln:bad-type-case" "ln:bad-type-del" "ln:bad-type-nobody"
                "ln:bad-source" "ln:bad-target" "ln:bad-target-del" "ln:v4-source" "ln:v4-target"
                "ln:self-put" "ln:self-del" "ln:if-match-put" "ln:if-match-del"
                "ln:if-none-match-put" "ln:if-none-match-del")))

(test-equal "links: a bad query is 400 invalid_request: direction (other, other case, twice, empty), type (other, other case, twice, empty), limit (0, twice, empty), after (junk, no colon, a type not in the list, a v4 id, text after the id, another type than ?type=, twice, empty), and a bad id in the path"
  (map (lambda (k) ln-bad) (quote (1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)))
  (map ln-got '("ln:q-direction" "ln:q-direction-upper" "ln:q-direction-twice" "ln:q-direction-empty"
                "ln:q-type" "ln:q-type-upper" "ln:q-type-twice" "ln:q-type-empty"
                "ln:q-limit-0" "ln:q-limit-twice" "ln:q-limit-empty"
                "ln:q-after-junk" "ln:q-after-no-colon" "ln:q-after-type" "ln:q-after-v4"
                "ln:q-after-extra" "ln:q-after-other-type" "ln:q-after-twice" "ln:q-after-empty"
                "ln:q-bad-id")))

(test-equal "links: If-Match on the GET is ignored: 200 and the list"
  (list 200 (list (list "mentions" ln-y)))
  (list (lg-st "ln:if-match-get") (ln-ids "ln:if-match-get")))

(test-equal "links: no key is 401 unauthorized"
  (ln-problem 401 "unauthorized")
  (ln-got "ln:no-key"))

(test-equal "links: POST and GET on one link are 405 method_not_allowed with allow PUT, DELETE; POST on the list is 405 with allow GET, HEAD"
  (list (list (ln-problem 405 "method_not_allowed") "PUT, DELETE")
        (list (ln-problem 405 "method_not_allowed") "PUT, DELETE")
        (list (ln-problem 405 "method_not_allowed") "GET, HEAD"))
  (map (lambda (k) (list (ln-got k) (nd-h k "allow"))) '("ln:post-link" "ln:get-link" "ln:post-list")))

;; the file
(test-equal "links: the file after the server stops: 7 links of one account; the first account's changes: a link or unlink row for each link made or removed and none for a repeat, a refusal or the purge; each at its source's revision; revisions and states as the story leaves them"
  (list 7 1
        '("create" "create" "create" "create" "create" "create" "create" "link" "link" "link" "link" "link" "unlink"
          "link" "trash" "unlink" "link" "trash" "unlink" "archive" "link" "link" "link" "link" "link" "link" "link"
          "trash" "purge")
        (list (string-append (ln-hex ln-x) ":1:link") (string-append (ln-hex ln-x) ":1:link")
              (string-append (ln-hex ln-x) ":1:link") (string-append (ln-hex ln-y) ":1:link")
              (string-append (ln-hex ln-z) ":1:link") (string-append (ln-hex ln-x) ":1:unlink")
              (string-append (ln-hex ln-x) ":1:link") (string-append (ln-hex ln-x) ":1:unlink")
              (string-append (ln-hex ln-s) ":1:link") (string-append (ln-hex ln-s) ":2:unlink")
              (string-append (ln-hex ln-x) ":1:link") (string-append (ln-hex ln-x) ":1:link")
              (string-append (ln-hex ln-z) ":1:link") (string-append (ln-hex ln-h) ":1:link")
              (string-append (ln-hex ln-x) ":1:link") (string-append (ln-hex ln-z) ":1:link")
              (string-append (ln-hex ln-h) ":1:link"))
        '(1 1 1 2 2 3 2 1)
        '("active" "active" "active" "trashed" "trashed" "purged" "archived" "active"))
  (let ((d (obs "ln:db")))
    (if (list? d)
        (list (car (list-ref d 0)) (car (list-ref d 1)) (list-ref d 2) (list-ref d 3) (list-ref d 4) (list-ref d 5))
        d)))

;; --- props and tasks over the wire (slice 6) --------------------------------

(define pw-problem ln-problem)
(define (pw-got k) (list (lg-st k) (nd-h k "content-type") (lg-code k)))
(define (pw-props k) (jget (nd-j k) "props"))
(define (pw-prop k m) (jget (pw-props k) m))
(define (pw-rev k) (jget (nd-j k) "revision"))
(define (pw-etag k) (nd-h k "etag"))
(define head-members '("id" "kind" "state" "parent" "title" "content_type" "props" "revision" "created" "updated"))
(define (pw-text k) (if (lg-ok? k) (lg-text (obs k)) (obs k)))
;; pw-norm : Json -> Json    objects' members sorted by name, to compare two texts as values
(define (pw-norm j)
  (cond ((vector? j) (vector-map pw-norm j))
        ((and (pair? j) (pair? (car j)) (string? (caar j)))
         (list-sort (lambda (a b) (string<? (car a) (car b)))
                    (map (lambda (p) (cons (car p) (pw-norm (cdr p)))) j)))
        (else j)))
(define (pw-sent text) (pw-norm (string->json (pw-q text))))
(define (pw-read k) (let ((p (pw-props k))) (if (list? p) (pw-norm p) p)))
;; pw-items : String -> (Listof (List Revision Title ContentType))
(define (pw-items k)
  (let ((is (jitems (nd-j k))))
    (if (list? is) (map (lambda (i) (list (jget i "revision") (jget i "title") (jget i "content_type"))) is) is)))
(define (pw-in-range? c lo hi) (and (integer? c) (<= (- lo 2000) c (+ hi 2000))))
(define pw-bad (pw-problem 400 "invalid_request"))

(test-equal "props: the run's setup worked: migrated, two accounts, the server stopped with 0 and raised nothing"
  '(0 #t #t 0 unobserved)
  (list (obs "pw:migrate")
        (and (string? (obs "pw:a-id")) (= 36 (string-length (obs "pw:a-id"))))
        (and (string? (obs "pw:b-id")) (not (equal? (obs "pw:a-id") (obs "pw:b-id"))))
        (obs "pwsrv:exit") (obs "pwsrv:raised")))

;; A Task's life
(test-equal "task life: a Task made with no props answers 201 and reads back {\"status\":\"TODO\"}, in the create's answer and in the GET"
  (list 201 '(("status" . "TODO")) '(("status" . "TODO")) 1 "\"1\"")
  (list (lg-st "pw:a-create") (pw-props "pw:a-create") (pw-props "pw:a-get1") (pw-rev "pw:a-get1") (pw-etag "pw:a-get1")))

(test-equal "task life: a replace sets a deadline (a date) and a scheduled (a local time): 200, revision 2, status kept"
  (list 200 "\"2\"" 2 (pw-norm '(("status" . "TODO") ("deadline" . "2026-12-01") ("scheduled" . "2026-11-30T09:00"))))
  (list (lg-st "pw:a-rep") (pw-etag "pw:a-rep") (pw-rev "pw:a-get2") (pw-read "pw:a-get2")))

(test-equal "task life: done is 200 with the node without its body, ETag \"3\", revision 3, status DONE, the deadline kept, a closed time in milliseconds near now"
  (list 200 "application/json" head-members "\"3\"" 3 "DONE" #t "2026-12-01" 'missing)
  (list (lg-st "pw:a-done") (nd-h "pw:a-done" "content-type") (members (nd-j "pw:a-done")) (pw-etag "pw:a-done")
        (pw-rev "pw:a-done") (pw-prop "pw:a-done" "status")
        (pw-in-range? (pw-prop "pw:a-done" "closed") (obs "pw:a-t0") (obs "pw:a-t1"))
        (pw-prop "pw:a-done" "deadline") (jget (nd-j "pw:a-done") "body")))

(test-equal "task life: the GET after done is the same Task: revision 3, ETag \"3\", the answer's props"
  (list "\"3\"" 3 #t)
  (list (pw-etag "pw:a-get3") (pw-rev "pw:a-get3") (equal? (pw-props "pw:a-get3") (pw-props "pw:a-done"))))

(test-equal "task life: done again is 409 wrong_status in the format; the next command takes revision 3, so it changed nothing"
  (list (pw-problem 409 "wrong_status") 200 4)
  (list (pw-got "pw:a-done-again") (lg-st "pw:a-wont") (pw-rev "pw:a-get4")))

(test-equal "task life: wontdo is 200, ETag \"4\", status WONTDO, and closed is the one done set"
  (list "\"4\"" "WONTDO" #t)
  (list (pw-etag "pw:a-wont") (pw-prop "pw:a-wont" "status")
        (and (integer? (pw-prop "pw:a-get3" "closed")) (equal? (pw-prop "pw:a-get3" "closed") (pw-prop "pw:a-get4" "closed")))))

(test-equal "task life: reopen is 200, ETag \"5\", status TODO, no closed, the deadline and scheduled kept"
  (list 200 "\"5\"" "TODO" 'missing "2026-12-01" "2026-11-30T09:00" 5)
  (list (lg-st "pw:a-reopen") (pw-etag "pw:a-reopen") (pw-prop "pw:a-get5" "status") (pw-prop "pw:a-get5" "closed")
        (pw-prop "pw:a-get5" "deadline") (pw-prop "pw:a-get5" "scheduled") (pw-rev "pw:a-get5")))

(test-equal "task life: the revisions list has a snapshot for each of the five revisions, newest first, each with the same title and content type"
  (list 200 '((5 "A" "text/plain") (4 "A" "text/plain") (3 "A" "text/plain") (2 "A" "text/plain") (1 "A" "text/plain")))
  (list (lg-st "pw:a-revs") (pw-items "pw:a-revs")))

(test-equal "task life: the snapshot of the DONE revision shows DONE with its closed; WONTDO's shows WONTDO with the same closed; revision 1 shows TODO; the reopen's shows TODO and no closed"
  (list "DONE" #t "WONTDO" #t "TODO" 'missing "TODO" 'missing "A" "text/plain")
  (list (pw-prop "pw:a-rev3" "status")
        (equal? (pw-prop "pw:a-rev3" "closed") (pw-prop "pw:a-get3" "closed"))
        (pw-prop "pw:a-rev4" "status")
        (equal? (pw-prop "pw:a-rev4" "closed") (pw-prop "pw:a-get3" "closed"))
        (pw-prop "pw:a-rev1" "status") (pw-prop "pw:a-rev1" "closed")
        (pw-prop "pw:a-rev5" "status") (pw-prop "pw:a-rev5" "closed")
        (jget (nd-j "pw:a-rev3") "title") (jget (nd-j "pw:a-rev3") "content_type")))

;; A restore keeps the status
(test-equal "restore: after a replace (deadline 2027-02-02, no scheduled) and a second done, the Task is DONE at revision 7 with a later closed"
  (list 200 6 200 "DONE" "2027-02-02" 'missing #t 7)
  (list (lg-st "pw:a-rep2") 6 (lg-st "pw:a-done2") (pw-prop "pw:a-get7" "status") (pw-prop "pw:a-get7" "deadline")
        (pw-prop "pw:a-get7" "scheduled")
        (let ((c1 (pw-prop "pw:a-get3" "closed")) (c2 (pw-prop "pw:a-get7" "closed")))
          (and (integer? c1) (integer? c2) (> c2 c1)))
        (pw-rev "pw:a-get7")))

(test-equal "restore: restoring revision 2 of the DONE Task is 200 at revision 8; it is still DONE with the same closed, and the old deadline and scheduled are back"
  (list 200 8 "DONE" #t "2026-12-01" "2026-11-30T09:00")
  (list (lg-st "pw:a-restore") (pw-rev "pw:a-get8") (pw-prop "pw:a-get8" "status")
        (and (integer? (pw-prop "pw:a-get7" "closed")) (equal? (pw-prop "pw:a-get7" "closed") (pw-prop "pw:a-get8" "closed")))
        (pw-prop "pw:a-get8" "deadline") (pw-prop "pw:a-get8" "scheduled")))

(test-equal "restore: the snapshot of the restore's revision shows DONE with that closed"
  (list "DONE" #t)
  (list (pw-prop "pw:a-rev8" "status")
        (equal? (pw-prop "pw:a-rev8" "closed") (pw-prop "pw:a-get7" "closed"))))

;; A replace cannot change the status
(test-equal "replace: sending the status read back is 200 (revision 2); another status, WONTDO, and a closed on a TODO Task are each 409 status_fixed"
  (list 200 2 (pw-problem 409 "status_fixed") (pw-problem 409 "status_fixed") (pw-problem 409 "status_fixed"))
  (list (lg-st "pw:c-same") (pw-rev "pw:c-same") (pw-got "pw:c-done-by-put") (pw-got "pw:c-wont-by-put") (pw-got "pw:c-closed-by-put")))

(test-equal "replace: the three refusals wrote nothing: revision 2, status TODO, the deadline as before"
  (list 2 (pw-norm '(("status" . "TODO") ("deadline" . "2026-12-01"))))
  (list (pw-rev "pw:c-get2") (pw-read "pw:c-get2")))

(test-equal "replace: leaving status out keeps it (TODO) and the new deadline is taken: 200, revision 3"
  (list 200 3 (pw-norm '(("status" . "TODO") ("deadline" . "2026-12-02"))))
  (list (lg-st "pw:c-left-out") (pw-rev "pw:c-left-out") (pw-read "pw:c-left-out")))

(test-equal "replace: a replace with no props at all keeps deadline and status, and changes the title: 200, revision 4"
  (list 200 4 "C2" (pw-norm '(("status" . "TODO") ("deadline" . "2026-12-02"))))
  (list (lg-st "pw:c-no-props") (pw-rev "pw:c-get4") (jget (nd-j "pw:c-get4") "title") (pw-read "pw:c-get4")))

(test-equal "replace: on a DONE Task, TODO is 409 status_fixed (no reopening by replace); the status and closed read back are 200; \"props\": {} clears the deadline and keeps the status and closed"
  (list (pw-problem 409 "status_fixed") 200 6 7 (pw-norm (list (cons "status" "DONE") (cons "closed" (pw-prop "pw:c-get5" "closed")))) "DONE")
  (list (pw-got "pw:c-reopen-by-put") (lg-st "pw:c-back") (pw-rev "pw:c-back") (pw-rev "pw:c-get7") (pw-read "pw:c-get7")
        (pw-prop "pw:c-get7" "status")))

;; An import
(test-equal "import: a create with status DONE and a closed keeps that time; WONTDO with a closed keeps it"
  (list 201 "DONE" 1700000000000 201 "WONTDO" 1700000000001)
  (list (lg-st "pw:d-create") (pw-prop "pw:d-get" "status") (pw-prop "pw:d-get" "closed")
        (lg-st "pw:f-create") (pw-prop "pw:f-get" "status") (pw-prop "pw:f-get" "closed")))

(test-equal "import: DONE with no closed gets a time near now"
  (list 201 "DONE" #t)
  (list (lg-st "pw:e-create") (pw-prop "pw:e-get" "status")
        (pw-in-range? (pw-prop "pw:e-get" "closed") (obs "pw:e-t0") (obs "pw:e-t1"))))

(test-equal "import: TODO with a closed, a closed with no status, a closed of 1.5 or null, and a status that is not one are each 400, and make no node"
  (list pw-bad pw-bad pw-bad pw-bad pw-bad (pw-problem 404 "not_found") (pw-problem 404 "not_found"))
  (list (pw-got "pw:g-create") (pw-got "pw:h-create") (pw-got "pw:i-create") (pw-got "pw:j-create") (pw-got "pw:k-create")
        (pw-got "pw:g-get") (pw-got "pw:h-get")))

;; Commands on the wrong thing
(test-equal "commands: done, wontdo and reopen on a Note are 409 not_a_task"
  (list (pw-problem 409 "not_a_task") (pw-problem 409 "not_a_task") (pw-problem 409 "not_a_task"))
  (map pw-got '("pw:n-done" "pw:n-wontdo" "pw:n-reopen")))

(test-equal "commands: on a trashed Task done and wontdo are 409 wrong_state, and it stays trashed at revision 2"
  (list (pw-problem 409 "wrong_state") (pw-problem 409 "wrong_state") "trashed" 2)
  (list (pw-got "pw:t-done") (pw-got "pw:t-wontdo") (jget (nd-j "pw:t-get") "state") (pw-rev "pw:t-get")))

(test-equal "commands: done on an archived Task is 200 (the plan's table; the guide is silent)"
  (list 200 "DONE")
  (list (lg-st "pw:ar-done") (pw-prop "pw:ar-done" "status")))

(test-equal "commands: a stale If-Match is 412 precondition_failed, none is 428 precondition_required, If-None-Match is 400, reopen on a TODO Task is 409 wrong_status; and the Task is untouched: revision 1, TODO"
  (list (pw-problem 412 "precondition_failed") (pw-problem 428 "precondition_required") pw-bad
        (pw-problem 409 "wrong_status") 1 "TODO")
  (list (pw-got "pw:s-stale") (pw-got "pw:s-none") (pw-got "pw:s-inm") (pw-got "pw:s-reopen")
        (pw-rev "pw:s-get-after") (pw-prop "pw:s-get-after" "status")))

(test-equal "commands: a missing id, another account's Task (done and reopen) are the same 404 bytes"
  (list (pw-problem 404 "not_found") (pw-problem 404 "not_found") (pw-problem 404 "not_found") #t #t)
  (list (pw-got "pw:s-missing") (pw-got "pw:s-other") (pw-got "pw:s-other-reopen")
        (equal? (pw-text "pw:s-missing") (pw-text "pw:s-other"))
        (equal? (pw-text "pw:s-missing") (pw-text "pw:s-other-reopen"))))

(test-equal "commands: a bad id is 400 and no key is 401"
  (list pw-bad (pw-problem 401 "unauthorized"))
  (list (pw-got "pw:s-bad-id") (pw-got "pw:s-no-key")))

(test-equal "commands: GET on /done and on /wontdo is 405 method_not_allowed with Allow: POST"
  (list (list (pw-problem 405 "method_not_allowed") "POST") (list (pw-problem 405 "method_not_allowed") "POST"))
  (map (lambda (k) (list (pw-got k) (nd-h k "allow"))) '("pw:s-get" "pw:s-get-wontdo")))

;; A Note
(test-equal "note: at in each of the three When forms is taken (201) and read back the same"
  (list 201 201 201
        '(("at" . "2026-12-01")) '(("at" . "2026-12-01T15:00")) '(("at" . "2026-12-01T20:00:00Z")))
  (list (lg-st "pw:at-date") (lg-st "pw:at-local") (lg-st "pw:at-moment")
        (pw-props "pw:at-date-get") (pw-props "pw:at-local-get") (pw-props "pw:at-moment-get")))

(test-equal "note: 2026-02-30, 24:00, a lower case t, a number, an offset, a deadline of month 13 and a scheduled of \"tomorrow\" are each 400"
  (map (lambda (k) pw-bad) '(1 2 3 4 5 6 7))
  (map pw-got '("pw:at-bad-day" "pw:at-bad-24" "pw:at-bad-t" "pw:at-bad-num" "pw:at-bad-offset"
                "pw:at-bad-deadline" "pw:at-bad-sched")))

;; A Contact
(test-equal "contact: the guide's example is taken (201) and read back as it was sent"
  (list 201 (pw-sent pw-guide-contact))
  (list (lg-st "pw:ct-guide") (pw-read "pw:ct-guide-get")))

(test-equal "contact: a rich one (name, three emails, three phones, two addresses, an organisation, a title naming it, pronouns, two links, an online service, a birthday) is taken and read back as sent"
  (list 201 (pw-sent pw-rich-contact))
  (list (lg-st "pw:ct-rich") (pw-read "pw:ct-rich-get")))

(test-equal "contact: what is read back, sent again as a replace, is taken (200, revision 2) and reads back identical, member for member in order"
  (list 200 2 #t (list "name" "organizations" "titles" "emails" "phones" "addresses" "anniversaries" "links" "onlineServices" "speakToAs"))
  (list (lg-st "pw:ct-rich-put") (pw-rev "pw:ct-rich-get2")
        (equal? (pw-props "pw:ct-rich-get") (pw-props "pw:ct-rich-get2"))
        (members (pw-props "pw:ct-rich-get2"))))

(test-equal "contact: the same Id maps sent in two orders read back identical props, in the ids' order"
  (list 201 201 #t '("e1" "e10" "e2") '("p1" "p2"))
  (list (lg-st "pw:ct-ord1") (lg-st "pw:ct-ord2")
        (equal? (pw-props "pw:ct-ord1-get") (pw-props "pw:ct-ord2-get"))
        (members (pw-prop "pw:ct-ord1-get" "emails")) (members (pw-prop "pw:ct-ord1-get" "phones"))))

(test-equal "contact: explicit defaults (kind individual, isOrdered false, a title's kind) and right @types are taken and not shown"
  (list 201 (pw-sent pw-defaults-read) #f)
  (list (lg-st "pw:ct-def") (pw-read "pw:ct-def-get")
        (contains? (lg-text (obs "pw:ct-def-get")) "@type")))

(test-equal "contact: a line break in an address's full is taken and read back; {} is a Contact and reads back {}"
  (list 201 "1 Main St\nTown" 201 '())
  (list (lg-st "pw:ct-nl") (jget (jget (jget (pw-props "pw:ct-nl-get") "addresses") "a1") "full")
        (lg-st "pw:ct-empty") (pw-props "pw:ct-empty-get")))

(test-equal "contact: each of an unknown member (top and nested), an empty string, an empty map, a control character in a label, pref 1.0, pref 0, a uri with no scheme, an email of a@, a dangling organizationId, a wrong @type, @type at the top, an empty contexts, a lower case countryCode and an unknown kind is 400 in the format"
  (map (lambda (bc) pw-bad) pw-bad-contacts)
  (map (lambda (bc) (pw-got (string-append "pw:ctbad-" (car bc)))) pw-bad-contacts))

(test-equal "contact: props over 4,096 bytes are 413 props_too_large, and make no node"
  (list (pw-problem 413 "props_too_large") (pw-problem 404 "not_found"))
  (list (pw-got "pw:ct-big") (pw-got "pw:ct-big-get")))

;; Kinds do not mix
(test-equal "kinds: a Task's status on a Note, a Contact's emails on a Task, and any member on a Project are each 400; a Project with {} is 201"
  (list pw-bad pw-bad pw-bad pw-bad pw-bad 201)
  (list (pw-got "pw:k-note-status") (pw-got "pw:k-task-emails") (pw-got "pw:k-project-at")
        (pw-got "pw:k-project-status") (pw-got "pw:k-project-x") (lg-st "pw:k-project-ok")))

(test-equal "kinds: a replace naming no kind is judged by the node's own: status on a Note, emails on a Note, at on a Task, emails on a Task, at on a Contact, at on a Project are each 400"
  (map (lambda (k) pw-bad) '(1 2 3 4 5 6))
  (map pw-got '("pw:k-note-as-task" "pw:k-note-emails" "pw:k-task-as-note" "pw:k-task-emails-put"
                "pw:k-contact-at" "pw:k-project-put")))

(test-equal "kinds: a replace naming task on a Note is 409 kind_fixed when the props suit a Task, 400 when they do not"
  (list (pw-problem 409 "kind_fixed") pw-bad)
  (list (pw-got "pw:k-note-named-task") (pw-got "pw:k-note-named-task-at")))

(test-equal "kinds: the same replaces with props that suit the node's own kind are 200: at on a Note, emails on a Contact, status and deadline on a Task"
  (list 200 '(("at" . "2026-12-02")) 200 200 (pw-norm '(("status" . "TODO") ("deadline" . "2026-12-05"))))
  (list (lg-st "pw:k-note-ok") (pw-props "pw:k-note-ok") (lg-st "pw:k-contact-ok") (lg-st "pw:k-task-ok")
        (pw-read "pw:k-task-ok")))

;; Links and lists
(test-equal "links: a link page's item shows a Task's props with its status: in at the TODO Task, and out of the Note, the DONE Task's (with closed) then the TODO one's"
  (list 201 201 (list '(("status" . "TODO")) '()) (list "DONE" "TODO") #t)
  (list (lg-st "pw:l-put-s") (lg-st "pw:l-put-a")
        (list (jget (jget (cadr (jitems (nd-j "pw:l-out"))) "node") "props")
              (jget (jget (car (jitems (nd-j "pw:l-in-s"))) "node") "props"))
        (map (lambda (i) (jget (jget (jget i "node") "props") "status")) (jitems (nd-j "pw:l-out")))
        (integer? (jget (jget (jget (car (jitems (nd-j "pw:l-out"))) "node") "props") "closed"))))

(test-equal "lists: a list item shows a Task's props with status, a Note's {}, and is the link page's node byte for byte"
  (list '(("status" . "TODO")) "DONE" '() #t)
  (let* ((items (jitems (nd-j "pw:l-list")))
         (item (lambda (id) (let ((m (filter (lambda (n) (equal? (jget n "id") id)) items))) (if (pair? m) (car m) #f)))))
    (list (jget (item (pw-id 14)) "props") (jget (jget (item (pw-id 1)) "props") "status") (jget (item (pw-id 11)) "props")
          (equal? (item (pw-id 14)) (jget (cadr (jitems (nd-j "pw:l-out"))) "node")))))

(test-end "integration")

(exit (suite-exit-status runner))
