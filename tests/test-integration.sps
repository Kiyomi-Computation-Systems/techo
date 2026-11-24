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
        (only (techo keys) key-secret id->string)
        (only (techo auth) key-hash)
        (only (techo db) open-techo-db read-db-facts migrate!)
        (only (techo migrations) techo-application-id migrations latest-version)
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

;; The shipped schema, as the file's facts count it: accounts, api_keys, the
;; index, and the automatic indexes of the primary and unique keys.
(define shipped-latest (latest-version migrations))
(define shipped-objects 8)
(define shipped-tables '("accounts" "api_keys"))

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
                  (go! port "api:forced-500" 'post (url-of-key a1 "regenerate") new #f)
                  (go! port "api:forced-500-revoke" 'post (url-of-key a4 "revoke") new #f)
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
  (list 1 "" (nl "techo: refused: this binary is older than the database (version 5)"))
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
        (append shipped-tables '("notes" "tags")))
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
    (list (list techo-application-id shipped-latest (+ shipped-objects 1) 'wal)
          (list 'listening (list 200 "application/json" '(("status" . "ok"))) 0))
    (let ((r (obs key)))
      (if (and (list? r) (= (length r) 12))
          (list (list-ref r 8)
                (list-ref r 9))
          r)))

  (test-equal (string-append label ": a migration then applies on top, and the rows are still there")
    (list (list 'applied (list fixture-notes-version fixture-tags-version)) #t)
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

(test-end "integration")

(exit (suite-exit-status runner))
