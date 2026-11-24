#!r6rs
;;; The doorway's layer 5: real worker threads, a real server as a child
;;; process, signals and kills (slice 2b, .plans/2026-11-23-slice-2b-doorway.md).
;;;
;;; The child is tests/doorway-child.sps: the real doorway and the real
;;; `wrap-app`, a table of its own made by (migrations-fixture)'s migrations,
;;; and routes that write, read and hold a write job open. It runs the same
;;; loop as `techo serve`, (techo serve)'s `serve-loop`.
;;;
;;;   T2       500 writes, each followed by a read on a new connection; and
;;;            500 on one kept-alive connection: the read sees the write
;;;   T3       a write job held open: a read answers with the old count, and
;;;            /health too, before the job ends; a second write waits
;;;   full     a write cap of 1: further writes get an empty 503 at once
;;;   timeout  a caller that timed out (504) before its job began: its write
;;;            is absent; after its job began: present
;;;   sigterm  idle: exit 0 and no `-wal`; with a write held open past a
;;;            short drain: exit 0, the held write committed, the queued one
;;;            absent, no `-wal`
;;;   kill -9  during a job of two rows: both or neither, the server starts
;;;   half     a job that writes half and raises: the half is absent
;;;   moved    `migrate!` with a longer list beside the child: 503 for the
;;;            next read and write, nothing written, the log line once
;;;   badport  the server refuses the port after the workers exist: exit 2,
;;;            the refusal on standard error, no `-wal`
;;;
;;; Nothing waits on a sleep being long enough: a test waits for a line in
;;; the child's output or an answer, each wait bounded by a deadline that
;;; fails the test. A held job's line is printed after its first row is
;;; written, so "held" means the transaction is open. A write that is queued
;;; prints "write TAG" from the route, in the loop's thread, just before it
;;; calls db-write: the loop runs on until the job is queued, so a request
;;; sent after the line is behind it.
;;;
;;; Every observation is made under `attempt` and compared by the tests.
;;; Everything that can raise is computed under a guard.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) directory-list system process getenv real-time sleep make-time
                           library-directories)
        (techo-testing)
        (only (chez-sqlite3) close-database! query query-row)
        (only (techo db) open-techo-db migrate!)
        (migrations-fixture)
        (http-client))

(define runner (test-runner-simple))
(test-runner-current runner)

;; A failing test shows what it expected and what it saw: these tests watch
;; processes, and the number alone would not say what happened.
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

;; --- small helpers --------------------------------------------------------

(define (quote-word s)
  (string-append
   "'"
   (apply string-append
          (map (lambda (c) (if (char=? c #\') "'\\''" (string c))) (string->list s)))
   "'"))

(define (join strs sep)
  (if (null? strs)
      ""
      (fold-left (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))

(define (sh . parts) (system (apply string-append parts)))

(define (make-temp-dir)
  (let* ((ports (process "mkdir -p build && mktemp -d \"$PWD/build/dt.XXXXXX\""))
         (line (get-line (car ports))))
    (close-port (car ports))
    (close-port (cadr ports))
    (if (and (string? line) (> (string-length line) 1) (char=? (string-ref line 0) #\/))
        line
        (error 'make-temp-dir "mktemp -d answered no absolute path" line))))

(define (file-text path)
  (guard (e (#t ""))
    (call-with-input-file path
      (lambda (p) (let ((s (get-string-all p))) (if (eof-object? s) "" s))))))

(define (split-lines s)
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (cond ((null? cs) (reverse (if (null? cur) acc (cons (list->string (reverse cur)) acc))))
          ((char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

(define (split-words s)
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (define (flush) (if (null? cur) acc (cons (list->string (reverse cur)) acc)))
    (cond ((null? cs) (reverse (flush)))
          ((char=? (car cs) #\space) (loop (cdr cs) '() (flush)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

;; count-of : String String -> Nat    how many times SUB occurs in S
(define (count-of s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0) (k 0))
      (cond ((> (+ i m) n) k)
            ((string=? (substring s i (+ i m)) sub) (loop (+ i m) (+ k 1)))
            (else (loop (+ i 1) k))))))

;; poll : Nat (-> (U A #f)) -> (U A #f)
;; THUNK's first true answer, tried every 10 ms, or #f after MS.
(define (poll ms thunk)
  (let ((stop (+ (real-time) ms)))
    (let loop ()
      (or (thunk)
          (and (< (real-time) stop)
               (begin (sleep (make-time 'time-duration 10000000 0))
                      (loop)))))))

(define deadline-ms 20000)

;; --- children -------------------------------------------------------------

(define (chez)
  (let ((c (getenv "CHEZ")))
    (if (and c (> (string-length c) 0)) c "scheme")))

(define (libdirs) (join (map car (library-directories)) ":"))

(define-record-type child (fields dir name))

(define (child-file c ext)
  (string-append (child-dir c) "/" (child-name c) "." ext))

;; spawn-child : String String (Listof String) -> Child
;; tests/doorway-child.sps in the background as NAME, with SET (NAME=value)
;; added to its environment. Its pid goes to NAME.pid, its status to
;; NAME.status when it ends.
(define (spawn-child dir name set)
  (let* ((c (make-child dir name))
         (out (quote-word (child-file c "out")))
         (err (quote-word (child-file c "err")))
         (pid (quote-word (child-file c "pid")))
         (st (quote-word (child-file c "status")))
         (cmd (join (append
                     (list "env")
                     (map quote-word (cons "CHEZ_HTTP_HOST=127.0.0.1" set))
                     (list (quote-word (chez)) "--libdirs" (quote-word (libdirs))
                           "--program" (quote-word "tests/doorway-child.sps")))
                    " ")))
    (sh "( " cmd " >" out " 2>" err " </dev/null & echo $! >" pid
        "; wait $!; echo $? >" st ".tmp; mv " st ".tmp " st
        " ) >/dev/null 2>&1 &")
    c))

(define (child-pid c)
  (let ((s (file-text (child-file c "pid"))))
    (and (> (string-length s) 0) (car (split-lines s)))))

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

;; kill! : Child -> Void    whatever state it is in
(define (kill! c)
  (let ((pid (child-pid c)))
    (when (and pid (not (file-exists? (child-file c "status"))))
      (sh "kill -KILL " pid " >/dev/null 2>&1"))))

(define (child-out c) (file-text (child-file c "out")))
(define (child-err c) (file-text (child-file c "err")))

;; listening-port : Child -> (U Nat 'no-listening-line)
(define (listening-port c)
  (or (poll deadline-ms
            (lambda ()
              (let loop ((ls (split-lines (child-out c))))
                (cond ((null? ls) #f)
                      ((and (contains? (car ls) "listening ")
                            (= (length (split-words (car ls))) 3))
                       (string->number (caddr (split-words (car ls)))))
                      (else (loop (cdr ls)))))))
      'no-listening-line))

;; await-line : Child String -> Boolean
;; The child's output holds LINE, as a whole line, within the deadline.
(define (await-line c line)
  (and (poll deadline-ms (lambda () (and (member line (split-lines (child-out c))) #t))) #t))

(define (out-has? c line) (and (member line (split-lines (child-out c))) #t))

;; --- requests --------------------------------------------------------------

;; Response : (List Nat (U String #f) String)    status, retry-after, body

(define (url port path) (string-append "http://127.0.0.1:" (number->string port) path))

;; call : Session Nat Symbol String -> Response
(define (call session port method path)
  (let ((r (if (eq? method 'post)
               (http-post session (url port path) 'body "")
               (http-get session (url port path)))))
    (list (http-response-status r)
          (http-response-header r "retry-after")
          (http-response-text r))))

;; req : Nat Symbol String -> Response    on a connection of its own
(define (req port method path)
  (call-with-http-session 'timeout-ms 15000
    (lambda (session) (call session port method path))))

;; bg! : Child Nat String Symbol String -> String
;; A request made in the background by curl, so a call can be in flight while
;; the suite goes on. Its raw response (status line, headers, body) is written
;; to the returned file once it ends, however it ends (a timed-out request
;; writes what curl wrote: nothing).
(define (bg! c port name method path)
  (let ((f (child-file c (string-append "resp-" name))))
    (sh "( curl -s -i -m 30 -X " (if (eq? method 'post) "POST" "GET") " "
        (quote-word (url port path)) " >" (quote-word f) ".tmp 2>/dev/null; mv "
        (quote-word f) ".tmp " (quote-word f) " ) >/dev/null 2>&1 &")
    f))

;; bg-status : String -> (U Nat 'no-answer)
;; The status line of a background response, waited for.
(define (bg-status f)
  (or (poll deadline-ms
            (lambda ()
              (and (file-exists? f)
                   (let ((ws (split-words (let ((ls (split-lines (file-text f))))
                                            (if (null? ls) "" (car ls))))))
                     (if (>= (length ws) 2) (string->number (cadr ws)) 0)))))
      'no-answer))

;; --- the database ----------------------------------------------------------

;; prepare-db : String String -> String
(define (prepare-db dir name)
  (let ((db (string-append dir "/" name ".db")))
    (let ((r (migrate! db fixture-migrations)))
      (unless (eq? (car r) 'applied)
        (error 'prepare-db "migrate! did not end ok" r)))
    db))

;; leftovers : String -> (Listof Boolean)    whether -wal and -shm exist
(define (leftovers db)
  (map (lambda (x) (file-exists? (string-append db x))) '("-wal" "-shm")))

;; rows-of : String -> (Listof String)
;; The notes' bodies in order. Opens the file read-only, which makes a `-wal`
;; of its own: look at `leftovers` first.
(define (rows-of db)
  (let ((conn (open-techo-db db 'read-only)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (map (lambda (r) (vector-ref r 0)) (query conn "SELECT body FROM notes ORDER BY id")))
      (lambda () (guard (e (#t #f)) (close-database! conn))))))

;; start : String String (Listof String) -> Child
(define (start dir name set)
  (spawn-child dir name set))

(define (env-db db) (string-append "CHILD_DB=" db))

;; with-child : Child (Child -> A) -> A    the child is killed however it ends
(define (with-child c proc)
  (dynamic-wind (lambda () #f) (lambda () (proc c)) (lambda () (kill! c))))

;; rows-text : String -> (Listof String)    a /rows body as a list
(define (rows-list text)
  (let ((t (let ((ls (split-lines text))) (if (null? ls) "" (car ls)))))
    (if (string=? t "")
        '()
        (let loop ((cs (string->list t)) (cur '()) (acc '()))
          (cond ((null? cs) (reverse (cons (list->string (reverse cur)) acc)))
                ((char=? (car cs) #\,) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
                (else (loop (cdr cs) (cons (car cs) cur) acc)))))))

(define (body-of r) (if (and (list? r) (= (length r) 3)) (caddr r) r))
(define (status-of r) (if (and (list? r) (= (length r) 3)) (car r) r))

;; --- observations -----------------------------------------------------------

(define observations (make-hashtable string-hash string=?))
(define (obs-set! k v) (hashtable-set! observations k v))
(define (obs k) (hashtable-ref observations k 'unobserved))
(define-syntax observe
  (syntax-rules ()
    ((_ k e) (obs-set! k (attempt (lambda () e))))))

;; T2 ------------------------------------------------------------------------

;; t2 : String -> (List Status (Listof String) (Listof Boolean) Nat)
;; 500 writes on connections of their own, each followed by a read on a new
;; connection, and 500 more on one kept-alive session. Answers the exit
;; status, the mismatches (the count each read should have seen against what
;; it saw), the leftovers, and how many reads were made.
(define (t2 dir)
  (let* ((db (prepare-db dir "t2"))
         (c (start dir "t2" (list (env-db db) "CHEZ_HTTP_PORT=0"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (bad '())
               (reads 0))
          (define (check! k got)
            (set! reads (+ reads 1))
            (unless (equal? got (string-append (number->string k) "\n"))
              (set! bad (cons (list k got) bad))))
          (do ((i 1 (+ i 1))) ((> i 500))
            (req port 'post "/add")
            (check! i (body-of (req port 'get "/count"))))
          (call-with-http-session 'timeout-ms 15000
            (lambda (session)
              (do ((i 501 (+ i 1))) ((> i 1000))
                (call session port 'post "/add")
                (check! i (body-of (call session port 'get "/count"))))))
          (signal! c "TERM")
          (let ((status (await-status c deadline-ms)))
            (list status (reverse bad) (leftovers db) reads)))))))

;; T3 ------------------------------------------------------------------------

;; t3 : String -> (List ...)
;; A write held open for 4 s. While it is open: a read, and /health. Then a
;; second write.
(define (t3 dir)
  (let* ((db (prepare-db dir "t3"))
         (c (start dir "t3" (list (env-db db) "CHEZ_HTTP_PORT=0"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (hold (bg! c port "hold" 'post "/hold?tag=h&ms=4000"))
               (held (await-line c "held h"))
               (read (req port 'get "/count"))
               (read-done-before-release (not (out-has? c "released h")))
               (health (req port 'get "/health"))
               (health-done-before-release (not (out-has? c "released h")))
               (second (begin (bg! c port "second" 'post "/add?tag=w") #t))
               (hold-status (bg-status hold))
               (second-status (bg-status (child-file c "resp-second")))
               (rows (req port 'get "/rows")))
          (signal! c "TERM")
          (list held
                (list (status-of read) (body-of read) read-done-before-release)
                (list (status-of health) health-done-before-release)
                second hold-status second-status
                (rows-list (body-of rows))
                (await-status c deadline-ms)))))))

;; full ----------------------------------------------------------------------

;; full : String -> (List ...)
;; A write cap of 1: one job running, one queued. Further writes get an empty
;; 503 with retry-after: 5 at once.
(define (full dir)
  (let* ((db (prepare-db dir "full"))
         (c (start dir "full" (list (env-db db) "CHEZ_HTTP_PORT=0" "CHILD_WCAP=1"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (hold (bg! c port "hold" 'post "/hold?tag=a&ms=4000"))
               (held (await-line c "held a"))
               (queued (bg! c port "queued" 'post "/add?tag=q"))
               (queued-line (await-line c "write q"))
               (refusals (map (lambda (t) (req port 'post (string-append "/add?tag=" t)))
                              '("r1" "r2" "r3")))
               (all-before-release (not (out-has? c "released a")))
               (hold-status (bg-status hold))
               (queued-status (bg-status queued))
               (rows (req port 'get "/rows")))
          (signal! c "TERM")
          (list held queued-line refusals all-before-release hold-status queued-status
                (rows-list (body-of rows))
                (await-status c deadline-ms)))))))

;; timeout -------------------------------------------------------------------

;; timeout : String -> (List ...)
;; Request timeout 1 s. A write holds the thread for 3 s (its job began, its
;; caller gives up at 1 s); a second write is queued behind it and gives up at
;; 1 s before its job begins.
(define (timeout dir)
  (let* ((db (prepare-db dir "timeout"))
         (c (start dir "timeout" (list (env-db db) "CHEZ_HTTP_PORT=0" "CHILD_TIMEOUT=1000"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (hold (bg! c port "hold" 'post "/hold?tag=began&ms=3000"))
               (held (await-line c "held began"))
               (queued (begin (bg! c port "queued" 'post "/add?tag=queued") #t))
               (queued-line (await-line c "write queued"))
               (queued-status (bg-status (child-file c "resp-queued")))
               (hold-status (bg-status hold))
               (released (await-line c "released began"))
               ;; the sentinel waits behind everything before it
               (sentinel (req port 'post "/add?tag=s"))
               (rows (req port 'get "/rows")))
          (signal! c "TERM")
          (list held queued-line queued-status hold-status released
                (status-of sentinel)
                (rows-list (body-of rows))
                (await-status c deadline-ms)))))))

;; sigterm, idle ----------------------------------------------------------------

;; sigterm-idle : String -> (List Status (Listof Boolean) (Listof String))
(define (sigterm-idle dir)
  (let* ((db (prepare-db dir "idle"))
         (c (start dir "idle" (list (env-db db) "CHEZ_HTTP_PORT=0"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (wrote (status-of (req port 'post "/add?tag=i")))
               (read (body-of (req port 'get "/count"))))
          (signal! c "TERM")
          (let* ((status (await-status c deadline-ms))
                 (left (leftovers db)))
            (list wrote read status left (rows-of db))))))))

;; the read threads' count -----------------------------------------------------

;; threads-of : Child -> Natural
;; The child's threads, counted in /proc (Linux, as the project is).
(define (threads-of c)
  (length (directory-list (string-append "/proc/" (child-pid c) "/task"))))

;; readers : String -> (List Natural Natural Status Status)
;; The same server with 1 read thread and with 3: once it listens, every
;; worker thread exists, so the second has two threads more.
(define (readers dir)
  (define (count name n)
    (let* ((db (prepare-db dir name))
           (c (start dir name (list (env-db db) "CHEZ_HTTP_PORT=0"
                                    (string-append "CHILD_READERS=" n)))))
      (with-child c
        (lambda (c)
          (listening-port c)
          (let ((threads (threads-of c)))
            (signal! c "TERM")
            (cons threads (await-status c deadline-ms)))))))
  (let* ((one (count "readers1" "1"))
         (three (count "readers3" "3")))
    (list (car one) (car three) (cdr one) (cdr three))))

;; sigterm, a write held past a short drain ---------------------------------------

;; sigterm-held : String -> (List ...)
;; Drain 1 s. A write held for 3 s, one write queued behind it; SIGTERM. The
;; drain closes the connections at 1 s, and the stop waits for the held job.
(define (sigterm-held dir)
  (let* ((db (prepare-db dir "held"))
         (c (start dir "held" (list (env-db db) "CHEZ_HTTP_PORT=0" "CHEZ_HTTP_DRAIN_TIMEOUT=1"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (hold (bg! c port "hold" 'post "/hold?tag=h&ms=3000"))
               (held (await-line c "held h"))
               (queued (bg! c port "queued" 'post "/add?tag=q"))
               (queued-line (await-line c "write q")))
          (signal! c "TERM")
          (let* ((status (await-status c deadline-ms))
                 (left (leftovers db)))
            (list held queued-line status left
                  (out-has? c "released h")
                  (rows-of db))))))))

;; kill -9 ---------------------------------------------------------------------------

;; killed : String -> (List ...)
;; A job of two rows, held between them (the first row written, the second
;; not); `kill -9`; a restart on the same file.
(define (killed dir)
  (let* ((db (prepare-db dir "kill"))
         (c (start dir "kill" (list (env-db db) "CHEZ_HTTP_PORT=0"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (hold (bg! c port "hold" 'post "/hold?tag=k&ms=60000&rows=2"))
               (held (await-line c "held k"))
               (dead (begin (kill! c) (await-status c deadline-ms))))
          (let* ((c2 (start dir "kill2" (list (env-db db) "CHEZ_HTTP_PORT=0"))))
            (with-child c2
              (lambda (c2)
                (let* ((port2 (listening-port c2))
                       (rows (req port2 'get "/rows"))
                       (write (status-of (req port2 'post "/add?tag=after")))
                       (rows2 (req port2 'get "/rows")))
                  (signal! c2 "TERM")
                  (list held (integer? dead)
                        (integer? port2)
                        (rows-list (body-of rows))
                        write
                        (rows-list (body-of rows2))
                        (await-status c2 deadline-ms)))))))))))

;; half ----------------------------------------------------------------------------

;; half : String -> (List ...)
(define (half dir)
  (let* ((db (prepare-db dir "half"))
         (c (start dir "half" (list (env-db db) "CHEZ_HTTP_PORT=0"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (r (req port 'post "/half?tag=hf"))
               (after (req port 'post "/add?tag=after"))
               (rows (req port 'get "/rows")))
          (signal! c "TERM")
          (list (status-of r) (status-of after)
                (rows-list (body-of rows))
                (await-status c deadline-ms)))))))

;; moved -----------------------------------------------------------------------------

;; a fourth migration, which the child's binary (the fixture's three) does not have
(define longer-list
  (append fixture-migrations
          (list (list 4 "extra" (list "CREATE TABLE extra (id INTEGER PRIMARY KEY) STRICT")))))

;; moved : String -> (List ...)
(define (moved dir)
  (let* ((db (prepare-db dir "moved"))
         (c (start dir "moved" (list (env-db db) "CHEZ_HTTP_PORT=0"))))
    (with-child c
      (lambda (c)
        (let* ((port (listening-port c))
               (before (list (status-of (req port 'post "/add?tag=before"))
                             (body-of (req port 'get "/count"))))
               (m (migrate! db longer-list))
               (reads (map (lambda (i) (req port 'get "/count")) '(1 2 3)))
               (writes (map (lambda (i) (req port 'post "/add?tag=after")) '(1 2 3)))
               (health (status-of (req port 'get "/health")))
               (out (child-out c)))
          (signal! c "TERM")
          (let ((status (await-status c deadline-ms)))
            (list before (car m)
                  (map (lambda (r) (list (status-of r) (cadr r))) reads)
                  (map (lambda (r) (list (status-of r) (cadr r) (body-of r))) writes)
                  health
                  (count-of out "database moved")
                  (count-of out "the file is at version 4 and this server expects 3")
                  status
                  (rows-of db))))))))

;; bad port ---------------------------------------------------------------------------

;; badport : String -> (List Status String (Listof Boolean))
(define (badport dir)
  (let* ((db (prepare-db dir "badport"))
         (c (start dir "badport" (list (env-db db) "CHEZ_HTTP_PORT=abc"))))
    (with-child c
      (lambda (c)
        (let* ((status (await-status c deadline-ms))
               (left (leftovers db)))
          (list status (child-err c) left))))))

;; --- run -------------------------------------------------------------------------------

(define (observe-all! dir)
  (observe "t2" (t2 dir))
  (observe "t3" (t3 dir))
  (observe "full" (full dir))
  (observe "timeout" (timeout dir))
  (observe "sigterm-idle" (sigterm-idle dir))
  (observe "sigterm-held" (sigterm-held dir))
  (observe "killed" (killed dir))
  (observe "half" (half dir))
  (observe "moved" (moved dir))
  (observe "badport" (badport dir))
  (observe "readers" (readers dir)))

(let ((dir (attempt make-temp-dir)))
  (if (string? dir)
      (dynamic-wind
        (lambda () #f)
        (lambda () (guard (e (#t (obs-set! "run" (list 'raised (describe e))))) (observe-all! dir)))
        (lambda () (sh "rm -rf " (quote-word dir) " >/dev/null 2>&1")))
      (obs-set! "run" dir)))

;; --- tests ------------------------------------------------------------------------------

;; field : String Nat -> Any
;; The Nth element of an observation that is a list, else the observation.
(define (field key n)
  (let ((r (obs key)))
    (if (and (list? r) (> (length r) n) (not (eq? (car r) 'raised))) (list-ref r n) r)))

(test-begin "doorway-threads")

(test-equal "run: the observing ended without a raise" 'unobserved (obs "run"))

;; T2
(test-equal "T2: the server exits 0 on SIGTERM after 1000 writes"
  0 (field "t2" 0))
(test-equal "T2: every read, on a new connection or a kept-alive one, saw the write before it"
  '() (field "t2" 1))
(test-equal "T2: 1000 reads were made"
  1000 (field "t2" 3))
(test-equal "T2: no -wal and no -shm after the stop"
  '(#f #f) (field "t2" 2))

;; T3
(test-equal "T3: the write job was held open (its first row written)"
  #t (field "t3" 0))
(test-equal "T3: a read answers 200 with the old count, before the held job ends"
  '(200 "0\n" #t) (field "t3" 1))
(test-equal "T3: /health answers 200 before the held job ends"
  '(200 #t) (field "t3" 2))
(test-equal "T3: the held write and the second write both answer 200"
  '(200 200) (list (field "t3" 4) (field "t3" 5)))
(test-equal "T3: the second write waited: the rows are in order, held first"
  '("h-1" "w") (field "t3" 6))
(test-equal "T3: exit 0" 0 (field "t3" 7))

;; full
(test-equal "full: a job was held, one write was queued"
  '(#t #t) (list (field "full" 0) (field "full" 1)))
(test-equal "full: further writes get an empty 503 with retry-after: 5"
  '((503 "5" "") (503 "5" "") (503 "5" ""))
  (field "full" 2))
(test-equal "full: the refusals came before the held job ended"
  #t (field "full" 3))
(test-equal "full: the held write and the queued write both answer 200 after the hold"
  '(200 200) (list (field "full" 4) (field "full" 5)))
(test-equal "full: only the held and the queued write are there"
  '("a-1" "q") (field "full" 6))
(test-equal "full: exit 0" 0 (field "full" 7))

;; timeout
(test-equal "timeout: the hold's job began, a second write was queued behind it"
  '(#t #t) (list (field "timeout" 0) (field "timeout" 1)))
(test-equal "timeout: both callers got a 504"
  '(504 504) (list (field "timeout" 2) (field "timeout" 3)))
(test-equal "timeout: the held job still ran to its end"
  #t (field "timeout" 4))
(test-equal "timeout: a write after them answers 200"
  200 (field "timeout" 5))
(test-equal "timeout: the write that timed out after its job began is present; the one that timed out before is absent"
  '("began-1" "s") (field "timeout" 6))
(test-equal "timeout: exit 0" 0 (field "timeout" 7))

;; SIGTERM, idle
(test-equal "sigterm idle: a write and a read worked first"
  '(200 "1\n") (list (field "sigterm-idle" 0) (field "sigterm-idle" 1)))
(test-equal "sigterm idle: exit 0"
  0 (field "sigterm-idle" 2))
(test-equal "sigterm idle: no -wal and no -shm, looked for before the file is opened again"
  '(#f #f) (field "sigterm-idle" 3))
(test-equal "sigterm idle: the write is in the file"
  '("i") (field "sigterm-idle" 4))

;; the read threads' count
(test-equal "readers: three read threads are two threads more than one"
  2 (- (field "readers" 1) (field "readers" 0)))
(test-equal "readers: both servers stop with exit 0"
  '(0 0) (list (field "readers" 2) (field "readers" 3)))

;; SIGTERM with a held write
(test-equal "sigterm held: a job was held and a write queued behind it before the signal"
  '(#t #t) (list (field "sigterm-held" 0) (field "sigterm-held" 1)))
(test-equal "sigterm held: exit 0"
  0 (field "sigterm-held" 2))
(test-equal "sigterm held: no -wal and no -shm"
  '(#f #f) (field "sigterm-held" 3))
(test-equal "sigterm held: the held job ended in the child's output"
  #t (field "sigterm-held" 4))
(test-equal "sigterm held: the held write is committed, the queued write is absent"
  '("h-1") (field "sigterm-held" 5))

;; kill -9
(test-equal "kill -9: a job was held between its two rows, and the child died"
  '(#t #t) (list (field "killed" 0) (field "killed" 1)))
(test-equal "kill -9: the server restarts on the file"
  #t (field "killed" 2))
(test-equal "kill -9: both rows or neither (the transaction was open: neither)"
  '() (field "killed" 3))
(test-equal "kill -9: a write after the restart works, and it is the only row"
  '(200 ("after")) (list (field "killed" 4) (field "killed" 5)))
(test-equal "kill -9: the restarted server stops with exit 0"
  0 (field "killed" 6))

;; half
(test-equal "half: the job that writes half and raises answers 500; the next write 200"
  '(500 200) (list (field "half" 0) (field "half" 1)))
(test-equal "half: the half is absent, the next write is alone"
  '("after") (field "half" 2))
(test-equal "half: exit 0" 0 (field "half" 3))

;; moved
(test-equal "moved: before the migration a write and a read worked"
  '(200 "1\n") (field "moved" 0))
(test-equal "moved: the migration ran beside the server and applied"
  'applied (field "moved" 1))
(test-equal "moved: every read after it is an empty 503 with retry-after: 5"
  '((503 "5") (503 "5") (503 "5")) (field "moved" 2))
(test-equal "moved: every write after it is an empty 503 with retry-after: 5"
  '((503 "5" "") (503 "5" "") (503 "5" "")) (field "moved" 3))
(test-equal "moved: /health still answers 200"
  200 (field "moved" 4))
(test-equal "moved: the 'database moved' line is in the output exactly once, after six refused requests"
  1 (field "moved" 5))
(test-equal "moved: the line has both versions"
  1 (field "moved" 6))
(test-equal "moved: exit 0" 0 (field "moved" 7))
(test-equal "moved: nothing was written under the new version"
  '("before") (field "moved" 8))

;; bad port
(test-equal "badport: exit 2"
  2 (field "badport" 0))
(test-equal "badport: the refusal is on standard error, naming the variable and not its value"
  '(#t #f) (let ((e (field "badport" 1)))
             (if (string? e)
                 (list (and (contains? e "techo: ") (contains? e "CHEZ_HTTP_PORT")) (contains? e "abc"))
                 e)))
(test-equal "badport: no -wal and no -shm are left, though the workers had been opened"
  '(#f #f) (field "badport" 2))

(test-end "doorway-threads")

(exit (suite-exit-status runner))
