#!r6rs
;;; The doorway suite: (techo doorway), the imperative shell of slice 2b, on
;;; real SQLite, and the clauses of "What the model assumes of SQLite" in the
;;; slice 2b plan (1 to 10). A clause is held on raw connections: two
;;; connections racing need two connections, and the doubles hold one each.
;;;
;;;   the clauses     raw connections on a real file
;;;   the handle      run through a JobShell, no worker needed
;;;   run-job!        each ending, the loop's net, the observer
;;;   job-perform!    one command, one call, the shapes
;;;   set-up          refusals, tear-down, an empty box
;;;   db-write/read   on circuit's doubles, inside its test host
;;;   wrap-db         the 503, the passing on, the log lines
;;;
;;; Every database file is under build/test-doorway/<unique>/, each test its
;;; own file. Everything that can raise is computed under `attempt` or `try`,
;;; and a raise comes out as a value the expectation never is. Thread tests
;;; (the interrupt clause) fork their own threads; no circuit worker is run
;;; with real threads here (that is slice 2b's task 5).
(import (rnrs)
        (rnrs records procedural)
        (only (chezscheme) chmod mkdir directory-list delete-directory file-directory?
                           current-time time-second time-nanosecond
                           box unbox set-box!
                           fork-thread sleep make-time)
        (srfi :64)
        (chez-sqlite3)
        (circuit)
        (circuit worker)
        (circuit http-server)
        (http-server testing)
        (techo-testing)
        (techo migrations)
        (techo db)
        (techo transaction)
        (techo doorway)
        (migrations-fixture))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; kind-of : Any -> Any
;; What was raised, as a value to compare.
(define (kind-of e)
  (cond ((db-unavailable? e) (list 'unavailable (db-unavailable-reason e)))
        ((db-transaction-ended? e) 'ended)
        ((db-refused? e) (list 'refused (db-refused-line e)))
        ((sqlite-busy? e) 'busy)
        ((sqlite-error? e) (list 'sqlite (sqlite-error-code e)))
        ((assertion-violation? e) 'assertion)
        ((string? e) (list 'string e))
        ((symbol? e) (list 'symbol e))
        (else (list 'other (describe e)))))

;; try : (-> Any ...) -> (U (Pair 'ok (Listof Any)) (List 'raised Kind))
(define (try thunk)
  (guard (e (#t (list 'raised (kind-of e))))
    (call-with-values thunk (lambda vs (cons 'ok vs)))))

;;; The directory

(define (rm-tree! p)
  (cond ((file-directory? p)
         (for-each (lambda (n) (rm-tree! (string-append p "/" n)))
                   (directory-list p))
         (delete-directory p))
        ((file-exists? p) (delete-file p))))

(define (make-dir! p) (unless (file-directory? p) (mkdir p #o755)))

(define test-dir
  (let ((t (current-time)))
    (guard (e (#t #f))
      (make-dir! "build")
      (rm-tree! "build/test-doorway")
      (make-dir! "build/test-doorway")
      (let ((d (string-append "build/test-doorway/"
                              (number->string (time-second t)) "-"
                              (number->string (time-nanosecond t)))))
        (make-dir! d)
        d))))

(define (path name) (string-append test-dir "/" name))

(define (clean! p)
  (for-each (lambda (s) (when (file-exists? (string-append p s))
                          (delete-file (string-append p s))))
            '("" "-wal" "-shm")))

(define (wal? p) (file-exists? (string-append p "-wal")))

;;; Files and connections

;; fresh : String -> String
;; A migrated file (all of the fixture's migrations, in WAL) of its own.
(define (fresh name)
  (let ((p (path name)))
    (clean! p)
    (migrate! p fixture-migrations)
    p))

(define latest (latest-version fixture-migrations))

(define (nap ms)
  (sleep (make-time 'time-duration (* 1000000 (mod ms 1000)) (div ms 1000))))

;; with-conn : String Symbol (Database -> A) -> A     closes it on the way out
(define (with-conn p mode proc)
  (let ((db (open-techo-db p mode 200)))
    (dynamic-wind
      (lambda () #f)
      (lambda () (proc db))
      (lambda () (guard (e (#t #f)) (close-database! db))))))

;; with-box : String Symbol Natural (Box -> A) -> A    a thread's box, torn down
(define (with-box p mode busy proc)
  (let ((b (doorway-set-up p mode fixture-migrations busy)))
    (dynamic-wind
      (lambda () #f)
      (lambda () (proc b))
      (lambda () (guard (e (#t #f)) (doorway-tear-down b))))))

(define (notes-count db)
  (vector-ref (query-row db "SELECT count(*) FROM notes") 0))

(define (version-of db)
  (vector-ref (query-row db "PRAGMA user_version") 0))

;; notes-in : String -> Natural     what a new connection sees
(define (notes-in p) (with-conn p 'read-only notes-count))

(define (add-note! db)
  (execute! db "INSERT INTO notes(body) VALUES ('x')"))

;; with-nums! : String -> String
;; A table nums(x) whose second row makes `abs` overflow: a query that raises midway.
(define (nums! p)
  (with-conn p 'read-write
    (lambda (db)
      (execute! db "CREATE TABLE nums(x INTEGER)")
      (execute! db "INSERT INTO nums VALUES (1)")
      (execute! db "INSERT INTO nums VALUES (-9223372036854775808)")))
  p)

;;; Running a job on a box

(define (start-of start)
  (let-values (((s c) (start latest))) s))

;; run-write, run-read : Box (Tx -> Any) [Observer] -> Any
(define (run-write b job . obs)
  (apply run-job! write-step (start-of write-start) (make-job-shell b) job obs))
(define (run-read b job . obs)
  (apply run-job! read-step (start-of read-start) (make-job-shell b) job obs))

(test-begin "doorway")

;;; Sanity: the file the tests start from

(test-equal "fixture: a migrated file is current, in WAL"
  (list latest 'wal)
  (attempt
   (lambda ()
     (let ((p (fresh "sanity.db")))
       (with-conn p 'read-only
         (lambda (db)
           (let ((f (read-db-facts db)))
             (list (cadr f) (cadddr f)))))))))

;;; ------------------------------------------------------------------
;;; The clauses
;;; ------------------------------------------------------------------

;; 1. BEGIN IMMEDIATE holds the write lock until the transaction ends.
(test-equal "clause 1: a second BEGIN IMMEDIATE is told busy and holds no transaction"
  '(busy #f)
  (attempt
   (lambda ()
     (let ((p (fresh "c1.db")))
       (with-conn p 'read-write
         (lambda (a)
           (with-conn p 'read-write
             (lambda (b)
               (execute! a "BEGIN IMMEDIATE")
               (let ((r (try (lambda () (execute! b "BEGIN IMMEDIATE")))))
                 (list (cadr r) (in-transaction? b)))))))))))

(test-equal "clause 1: the lock is held until the transaction ends, then it is free"
  '(busy ok)
  (attempt
   (lambda ()
     (let ((p (fresh "c1b.db")))
       (with-conn p 'read-write
         (lambda (a)
           (with-conn p 'read-write
             (lambda (b)
               (execute! a "BEGIN IMMEDIATE")
               (add-note! a)
               (let* ((during (cadr (try (lambda () (execute! b "BEGIN IMMEDIATE")))))
                      (_ (execute! a "COMMIT"))
                      (after (car (try (lambda () (execute! b "BEGIN IMMEDIATE") (execute! b "ROLLBACK"))))))
                 (list during after))))))))))

;; 2. A commit is whole; a rollback leaves nothing.
(test-equal "clause 2: a commit is whole, a rollback leaves nothing"
  '(0 2 2)
  (attempt
   (lambda ()
     (let ((p (fresh "c2.db")))
       (with-conn p 'read-write
         (lambda (w)
           (execute! w "BEGIN IMMEDIATE") (add-note! w) (add-note! w)
           (execute! w "ROLLBACK")
           (let ((after-rollback (notes-in p)))
             (execute! w "BEGIN IMMEDIATE") (add-note! w) (add-note! w)
             (execute! w "COMMIT")
             (list after-rollback (notes-in p) (notes-count w)))))))))

;; 3. A COMMIT refused by a deferred foreign key leaves the transaction open.
(test-equal "clause 3: a refused COMMIT leaves the transaction open; ROLLBACK leaves nothing"
  '((sqlite constraint) #t ok #f 0)
  (attempt
   (lambda ()
     (let ((p (fresh "c3.db")))
       (with-conn p 'read-write
         (lambda (w)
           (execute! w "CREATE TABLE par(id INTEGER PRIMARY KEY) STRICT")
           (execute! w "CREATE TABLE chi(pid INTEGER REFERENCES par(id) DEFERRABLE INITIALLY DEFERRED) STRICT")
           (execute! w "BEGIN IMMEDIATE")
           (execute! w "INSERT INTO chi VALUES (99)")
           (let* ((c (try (lambda () (execute! w "COMMIT"))))
                  (open-after (in-transaction? w))
                  (r (car (try (lambda () (execute! w "ROLLBACK")))))
                  (closed (in-transaction? w)))
             (list (cadr c) open-after r closed
                   (vector-ref (query-row w "SELECT count(*) FROM chi") 0)))))))))

;; 4. A close drops an open transaction.
(test-equal "clause 4: a close drops an open transaction: the lock is free, nothing is kept"
  '(ok 0)
  (attempt
   (lambda ()
     (let ((p (fresh "c4.db")))
       (let ((a (open-techo-db p 'read-write 200)))
         (execute! a "BEGIN IMMEDIATE") (add-note! a)
         (close-database! a))
       (with-conn p 'read-write
         (lambda (b)
           (let ((r (car (try (lambda () (execute! b "BEGIN IMMEDIATE") (execute! b "ROLLBACK"))))))
             (list r (notes-count b)))))))))

;; 5. Inside BEGIN, one snapshot from the first read on; user_version counts.
(test-equal "clause 5: a reader reads one snapshot from its first read, a version read being the first"
  '(0 1)
  (attempt
   (lambda ()
     (let ((p (fresh "c5.db")))
       (with-conn p 'read-write
         (lambda (w)
           (with-conn p 'read-only
             (lambda (r)
               (execute! r "BEGIN")
               (version-of r)                        ; the first read
               (add-note! w)                         ; committed by another
               (let ((inside (notes-count r)))
                 (execute! r "ROLLBACK")
                 (list inside (notes-count r)))))))))))

(test-equal "clause 5: the snapshot ends with the transaction: the next sees the commit"
  '(0 1)
  (attempt
   (lambda ()
     (let ((p (fresh "c5b.db")))
       (with-conn p 'read-write
         (lambda (w)
           (with-conn p 'read-only
             (lambda (r)
               (execute! r "BEGIN") (version-of r)
               (let ((before (notes-count r)))
                 (add-note! w)
                 (execute! r "ROLLBACK")
                 (execute! r "BEGIN") (version-of r)
                 (let ((after (notes-count r)))
                   (execute! r "ROLLBACK")
                   (list before after)))))))))))

;; 6. A read never waits for a write transaction.
(test-equal "clause 6: a read does not wait for an open write transaction, and sees only what was committed"
  '(0 #t)
  (attempt
   (lambda ()
     (let ((p (fresh "c6.db")))
       (with-conn p 'read-write
         (lambda (w)
           (execute! w "BEGIN IMMEDIATE") (add-note! w)
           (let ((r (open-techo-db p 'read-only 5000)))
             (let* ((t0 (current-time))
                    (n (notes-count r))
                    (t1 (current-time))
                    (ms (+ (* 1000 (- (time-second t1) (time-second t0)))
                           (div (- (time-nanosecond t1) (time-nanosecond t0)) 1000000))))
               (close-database! r)
               (execute! w "ROLLBACK")
               (list n (< ms 2000))))))))))

;; 7. A write on a read-only connection raises readonly.
(test-equal "clause 7: a write on a read-only connection raises readonly"
  '(sqlite readonly)
  (attempt
   (lambda ()
     (let ((p (fresh "c7.db")))
       (with-conn p 'read-only
         (lambda (r) (cadr (try (lambda () (add-note! r))))))))))

;; 8. After an interrupt, in-transaction? tells the truth.

;; interrupted : String Symbol String String -> (List Kind Boolean)
;; A thread opens a connection in MODE, runs BEGIN-SQL, then QUERY-SQL, which
;; runs until this one interrupts it. Gives what the query raised and what
;; in-transaction? said right after.
(define (interrupted p mode begin-sql query-sql)
  (let ((box #f) (started #f) (result #f) (finished #f))
    (fork-thread
     (lambda ()
       (guard (e (#t (set! result (list 'thread-raised (describe e)))
                     (set! finished #t)))
         (let ((db (open-techo-db p mode 200)))
           (set! box db)
           (execute! db begin-sql)
           (set! started #t)
           (let* ((r (try (lambda () (query db query-sql))))
                  (o (in-transaction? db)))
             (set! result (list (if (eq? (car r) 'raised)
                                    (list 'raised (interrupt-raised? r))
                                    'returned)
                                o))
             (guard (e (#t #f)) (execute! db "ROLLBACK"))
             (guard (e (#t #f)) (close-database! db))
             (set! finished #t))))))
    (let loop ((n 0))
      (cond (finished result)
            ((> n 600) 'timeout)
            (else
             (when (and started box (not result)) (interrupt-database! box))
             (nap 30)
             (loop (+ n 1)))))))

(define (interrupt-raised? r) (equal? (cadr r) '(sqlite interrupt)))

(define long-select
  "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 1000000000) SELECT count(*) FROM c")
(define long-insert
  "INSERT INTO notes(body) WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 1000000000) SELECT 'b' FROM c")

(test-equal "clause 8: an interrupted write leaves no transaction open"
  '((raised #t) #f)
  (attempt (lambda () (interrupted (fresh "c8a.db") 'read-write "BEGIN IMMEDIATE" long-insert))))

(test-equal "clause 8: an interrupted read leaves its transaction open"
  '((raised #t) #t)
  (attempt (lambda () (interrupted (fresh "c8b.db") 'read-only "BEGIN" long-select))))

(test-equal "clause 8: an interrupted read inside a write transaction leaves it open"
  '((raised #t) #t)
  (attempt (lambda () (interrupted (fresh "c8c.db") 'read-write "BEGIN IMMEDIATE" long-select))))

;; 9. Closing the last read-write connection removes the -wal.
(test-equal "clause 9: the -wal is there while a connection is open, gone when the last read-write one closes"
  '(#t #t #f)
  (attempt
   (lambda ()
     (let* ((p (fresh "c9.db")) (w (open-techo-db p 'read-write 200)))
       (add-note! w)
       (let ((during (wal? p)))
         (let ((r (open-techo-db p 'read-only 200)))
           (notes-count r)
           (close-database! r)
           (let ((still (wal? p)))
             (close-database! w)
             (list during still (wal? p)))))))))

;; 10. Through the handle, no statement outlives its call.
(define kept-statements '())          ; keeps a leaked statement from the collector
(define (leak-statement! db sql)
  (let ((s (prepare-statement db sql)))
    (set! kept-statements (cons s kept-statements))
    (step! s)))

(test-equal "clause 10, through the handle: after a read whose query raised midway, the next read sees a new commit"
  '((raised (sqlite error)) (ok 1))
  (attempt
   (lambda ()
     (let ((p (nums! (fresh "c10a.db"))))
       (with-box p 'read-only 100
         (lambda (rb)
           (with-conn p 'read-write
             (lambda (w)
               (let* ((r1 (try (lambda () (run-read rb (lambda (tx) (tx-query tx "SELECT abs(x) FROM nums"))))))
                      (_ (add-note! w))
                      (r2 (try (lambda () (run-read rb (lambda (tx) (vector-ref (tx-query-row tx "SELECT count(*) FROM notes") 0)))))))
                 (list r1 r2))))))))))

(test-equal "clause 10, through the handle: after a read job that escaped, the next read sees a new commit"
  '(escaped (ok 1))
  (attempt
   (lambda ()
     (let ((p (nums! (fresh "c10b.db"))))
       (with-box p 'read-only 100
         (lambda (rb)
           (with-conn p 'read-write
             (lambda (w)
               (let* ((r1 (call/cc (lambda (k)
                                     (run-read rb (lambda (tx)
                                                    (tx-query tx "SELECT x FROM nums")
                                                    (k 'escaped))))))
                      (_ (add-note! w))
                      (r2 (try (lambda () (run-read rb (lambda (tx) (vector-ref (tx-query-row tx "SELECT count(*) FROM notes") 0)))))))
                 (list r1 r2))))))))))

(test-equal "clause 10, through the handle: after writes whose query raised midway, and one that escaped, the next write commits"
  '((raised (sqlite error)) escaped (ok) 1)
  (attempt
   (lambda ()
     (let ((p (nums! (fresh "c10c.db"))))
       (with-box p 'read-write 100
         (lambda (wb)
           (let* ((r1 (try (lambda () (run-write wb (lambda (tx) (tx-query tx "SELECT abs(x) FROM nums"))))))
                  (r2 (call/cc (lambda (k)
                                 (run-write wb (lambda (tx)
                                                 (tx-query tx "SELECT x FROM nums")
                                                 (k 'escaped))))))
                  (r3 (try (lambda () (run-write wb (lambda (tx) (tx-execute! tx "INSERT INTO notes(body) VALUES ('ok')")))))))
             (list r1 r2 (list (car r3)) (notes-in p)))))))))

(test-equal "clause 10, bare: a statement stepped once and dropped makes the next read stale"
  '((ok left) (ok 0))
  (attempt
   (lambda ()
     (let ((p (nums! (fresh "c10d.db"))))
       (with-box p 'read-only 100
         (lambda (rb)
           (with-conn p 'read-write
             (lambda (w)
               (let* ((r1 (try (lambda ()
                                 (run-read rb (lambda (tx)
                                                (leak-statement! (unbox rb) "SELECT x FROM nums")
                                                'left)))))
                      (_ (add-note! w))
                      (r2 (try (lambda () (run-read rb (lambda (tx) (vector-ref (tx-query-row tx "SELECT count(*) FROM notes") 0)))))))
                 (list r1 r2))))))))))

(test-equal "clause 10, bare: a statement stepped once and dropped makes every later COMMIT refused"
  '((raised busy) (raised busy) 0)
  (attempt
   (lambda ()
     (let ((p (fresh "c10e.db")))
       (with-box p 'read-write 100
         (lambda (wb)
           (let* ((r1 (try (lambda ()
                             (run-write wb (lambda (tx)
                                             (leak-statement! (unbox wb)
                                                              "INSERT INTO notes(body) VALUES ('p') RETURNING id")
                                             'left)))))
                  (r2 (try (lambda () (run-write wb (lambda (tx) (tx-execute! tx "INSERT INTO notes(body) VALUES ('q')")))))))
             (list r1 r2 (notes-in p)))))))))

;;; ------------------------------------------------------------------
;;; The handle
;;; ------------------------------------------------------------------

(test-equal "handle: tx-execute!, tx-query and tx-query-row, with parameters"
  '(ok (#(1 "a")) #(1 "a") #f)
  (attempt
   (lambda ()
     (let ((p (fresh "h1.db")))
       (with-box p 'read-write 100
         (lambda (wb)
           (let ((r (run-write wb
                      (lambda (tx)
                        (tx-execute! tx "INSERT INTO notes(id, body) VALUES (?, ?)" 1 "a")
                        (list (tx-query tx "SELECT id, body FROM notes WHERE id = ?" 1)
                              (tx-query-row tx "SELECT id, body FROM notes WHERE body = ?" "a")
                              (tx-query-row tx "SELECT id, body FROM notes WHERE id = ?" 7))))))
             (list 'ok (car r) (cadr r) (caddr r)))))))))

(test-equal "handle: a write that returned is committed, for a new connection"
  1
  (attempt
   (lambda ()
     (let ((p (fresh "h1b.db")))
       (with-box p 'read-write 100
         (lambda (wb)
           (run-write wb (lambda (tx) (tx-execute! tx "INSERT INTO notes(body) VALUES ('a')")))
           (notes-in p)))))))

;; The forbidden words, each through each procedure.
(define forbidden-sql
  '("BEGIN" "COMMIT" "END" "ROLLBACK" "SAVEPOINT s" "RELEASE s"
    "ATTACH 'x.db' AS y" "DETACH y" "VACUUM" "PRAGMA user_version = 99"
    "commit" "  /* a comment */ Commit" "-- c\nPRAGMA query_only = 1" ";COMMIT"
    "EXPLAIN PRAGMA query_only = 1" "explain query plan pragma locking_mode = exclusive"))

(test-equal "handle: each forbidden first word is refused by each procedure, an assertion violation"
  (map (lambda (sql) '(assertion assertion assertion)) forbidden-sql)
  (attempt
   (lambda ()
     (let ((p (fresh "h2.db")))
       (with-box p 'read-write 100
         (lambda (wb)
           (map (lambda (sql)
                  (map (lambda (proc)
                         (let ((r (try (lambda () (run-write wb (lambda (tx) (proc tx sql)))))))
                           (if (equal? r '(raised assertion)) 'assertion r)))
                       (list tx-execute! tx-query tx-query-row)))
                forbidden-sql)))))))

(test-equal "handle: PRAGMA user_version = 99 is refused, and the version stays"
  (list '(raised assertion) latest)
  (attempt
   (lambda ()
     (let ((p (fresh "h3b.db")))
       (with-box p 'read-write 100
         (lambda (wb)
           (let ((r (try (lambda () (run-write wb (lambda (tx) (tx-execute! tx "PRAGMA user_version = 99")))))))
             (list r (with-conn p 'read-only version-of)))))))))

(test-equal "handle: a COMMIT is refused before it runs: the job's earlier write is not committed"
  '((raised assertion) 0)
  (attempt
   (lambda ()
     (let ((p (fresh "h3c.db")))
       (with-box p 'read-write 100
         (lambda (wb)
           (let ((r (try (lambda ()
                           (run-write wb (lambda (tx)
                                           (tx-execute! tx "INSERT INTO notes(body) VALUES ('a')")
                                           (tx-execute! tx "COMMIT")))))))
             (list r (notes-in p)))))))))

;; The check on the raise path: INSERT OR ROLLBACK ends the transaction and raises.
(define (conflict-fixture! p)
  (with-conn p 'read-write
    (lambda (w) (execute! w "INSERT INTO notes(id, body) VALUES (1, 'old')"))))

(test-equal "handle: a job that catches INSERT OR ROLLBACK and writes on: nothing of the job is committed, B never runs"
  '((raised ended) (sqlite constraint) ended (1 ("old")))
  (attempt
   (lambda ()
     (let ((p (fresh "h4.db")) (seen '()))
       (conflict-fixture! p)
       (with-box p 'read-write 100
         (lambda (wb)
           (let* ((r (try (lambda ()
                            (run-write wb
                              (lambda (tx)
                                (tx-execute! tx "INSERT INTO notes(id, body) VALUES (2, 'A')")
                                (guard (e (#t (set! seen (cons (kind-of e) seen))))
                                  (tx-execute! tx "INSERT OR ROLLBACK INTO notes(id, body) VALUES (1, 'dup')"))
                                (guard (e (#t (set! seen (cons (kind-of e) seen))))
                                  (tx-execute! tx "INSERT INTO notes(id, body) VALUES (3, 'B')"))
                                'done))))))
             (list r (car (reverse seen)) (car seen)
                   (with-conn p 'read-only
                     (lambda (o)
                       (list (notes-count o)
                             (map (lambda (row) (vector-ref row 1))
                                  (query o "SELECT id, body FROM notes ORDER BY id")))))))))))))

(test-equal "handle: the same job, seen from the raise path: the first call raised its own object again"
  '(sqlite constraint)
  (attempt
   (lambda ()
     (let ((p (fresh "h4b.db")) (seen '()))
       (conflict-fixture! p)
       (with-box p 'read-write 100
         (lambda (wb)
           (try (lambda ()
                  (run-write wb
                    (lambda (tx)
                      (guard (e (#t (set! seen (cons (kind-of e) seen))))
                        (tx-execute! tx "INSERT OR ROLLBACK INTO notes(id, body) VALUES (1, 'dup')"))
                      'done))))
           (car seen)))))))

(test-equal "handle: INSERT OR ROLLBACK that the job does not catch raises its own object"
  '(raised (sqlite constraint))
  (attempt
   (lambda ()
     (let ((p (fresh "h4c.db")))
       (conflict-fixture! p)
       (with-box p 'read-write 100
         (lambda (wb)
           (try (lambda ()
                  (run-write wb (lambda (tx)
                                  (tx-execute! tx "INSERT OR ROLLBACK INTO notes(id, body) VALUES (1, 'dup')")))))))))))

(test-equal "handle: a dead handle refuses every call, whichever procedure"
  '(ended ended ended)
  (attempt
   (lambda ()
     (let ((p (fresh "h4d.db")))
       (conflict-fixture! p)
       (with-box p 'read-write 100
         (lambda (wb)
           (let ((res '()))
             (try (lambda ()
                    (run-write wb
                      (lambda (tx)
                        (guard (e (#t #f))
                          (tx-execute! tx "INSERT OR ROLLBACK INTO notes(id, body) VALUES (1, 'dup')"))
                        (for-each (lambda (proc)
                                    (guard (e (#t (set! res (cons (kind-of e) res))))
                                      (proc tx "SELECT 1")))
                                  (list tx-execute! tx-query tx-query-row))
                        'done))))
             res)))))))

(test-equal "handle: no SQL can end a transaction by returning: each construct is refused or raises"
  '(assertion assertion assertion assertion)
  (attempt
   (lambda ()
     (let ((p (fresh "h5.db")))
       (with-box p 'read-write 100
         (lambda (wb)
           (map (lambda (sql)
                  (let ((r (try (lambda () (run-write wb (lambda (tx) (tx-execute! tx sql)))))))
                    (if (equal? r '(raised assertion)) 'assertion r)))
                '("COMMIT" "END TRANSACTION" "/* x */ ROLLBACK" ";\nCOMMIT"))))))))

;; The handle is dead once its job ends.
(define (kept-handle-after how)
  ;; HOW is 'return, 'raise or 'escape. Gives what the kept handle does after.
  (let ((p (fresh (string-append "h6-" (symbol->string how) ".db"))) (kept #f))
    (with-box p 'read-write 100
      (lambda (wb)
        (let ((job (lambda (k)
                     (lambda (tx)
                       (set! kept tx)
                       (case how
                         ((return) 'done)
                         ((raise) (raise 'boom))
                         ((escape) (k 'out)))))))
          (call/cc (lambda (k) (try (lambda () (run-write wb (job k))))))
          (list (try (lambda () (tx-query kept "SELECT 1")))
                (try (lambda () (tx-execute! kept "INSERT INTO notes(body) VALUES ('late')")))
                (in-transaction? (unbox wb))
                (notes-in p)))))))

(for-each
 (lambda (how)
   (test-equal (string-append "handle: dead after its job ended by a " (symbol->string how))
     '((raised assertion) (raised assertion) #f 0)
     (attempt (lambda () (kept-handle-after how)))))
 '(return raise escape))

;;; ------------------------------------------------------------------
;;; job-perform!: one command, one call, the shapes
;;; ------------------------------------------------------------------

(define (perform b cmd . job)
  (job-perform! (make-job-shell b) cmd (if (null? job) (lambda (tx) 'nothing) (car job))))

;; shape : RawOutcome -> RawOutcome with its object made a Kind
(define (shape raw)
  (list (car raw)
        (if (memq (car raw) '(busy failed raised)) (kind-of (cadr raw)) (cadr raw))
        (caddr raw)))

(test-equal "perform: (look) answers present, then absent once the box is empty"
  '((present #f #f) (absent #f #f))
  (attempt
   (lambda ()
     (let ((p (fresh "j1.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let ((a (perform b '(look))))
             (set-box! b #f)
             (list a (perform b '(look))))))))))

(test-equal "perform: begin-immediate, read-version, commit; the version is the whole number read"
  (list '(ok #t #t) (list 'ok latest #t) '(ok #t #f))
  (attempt
   (lambda ()
     (let ((p (fresh "j2.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (list (perform b '(begin-immediate))
                 (perform b (cons 'read-version latest))
                 (perform b '(commit)))))))))

(test-equal "perform: begin on a reader, and rollback"
  '((ok #t #t) (ok #t #f))
  (attempt
   (lambda ()
     (let ((p (fresh "j2b.db")))
       (with-box p 'read-only 100
         (lambda (b)
           (list (perform b '(begin)) (perform b '(rollback)))))))))

(test-equal "perform: begin-immediate with another holding the lock is busy, no transaction open"
  '(busy busy #f)
  (attempt
   (lambda ()
     (let ((p (fresh "j3.db")))
       ;; The box first: a writer's set-up needs the lock for a moment itself.
       (with-box p 'read-write 50
         (lambda (b)
           (with-conn p 'read-write
             (lambda (o)
               (execute! o "BEGIN IMMEDIATE")
               (let ((raw (perform b '(begin-immediate))))
                 (list (car raw) (kind-of (cadr raw)) (caddr raw)))))))))))

(test-equal "perform: a commit with no transaction is failed, the object raised, no transaction open"
  '(failed (sqlite error) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "j4.db")))
       (with-box p 'read-write 100
         (lambda (b) (shape (perform b '(commit)))))))))

(test-equal "perform: run-job returns the job's values as a list, and the transaction state"
  '(returned (1 2 3) #t)
  (attempt
   (lambda ()
     (let ((p (fresh "j5.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (perform b '(begin-immediate))
           (shape (perform b '(run-job) (lambda (tx) (values 1 2 3))))))))))

(test-equal "perform: run-job with a raise gives the object itself, not a string"
  '(#t #t)
  (attempt
   (lambda ()
     (let ((p (fresh "j5b.db")) (obj (list 'boom)))
       (with-box p 'read-write 100
         (lambda (b)
           (perform b '(begin-immediate))
           (let ((raw (perform b '(run-job) (lambda (tx) (raise obj)))))
             (list (eq? (car raw) 'raised) (eq? (cadr raw) obj)))))))))

(test-equal "perform: run-job's open? is #f when the job ended the transaction"
  '(returned (done) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "j5c.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (perform b '(begin-immediate))
           (shape (perform b '(run-job) (lambda (tx) (execute! (unbox b) "COMMIT") 'done)))))))))

(test-equal "perform: (close) empties the box and answers ok, and again on an empty box"
  '((ok #t #f) #f (ok #t #f))
  (attempt
   (lambda ()
     (let ((p (fresh "j6.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let ((r1 (perform b '(close))))
             (list r1 (unbox b) (perform b '(close))))))))))

(test-equal "perform: (close) of a connection already closed is ok, and the box is empty"
  '(ok #f)
  (attempt
   (lambda ()
     (let ((p (fresh "j6b.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (close-database! (unbox b))
           (let ((raw (perform b '(close))))
             (list (car raw) (unbox b)))))))))

(test-equal "perform: (end . _) is an assertion violation"
  '(raised assertion)
  (attempt
   (lambda ()
     (let ((p (fresh "j7.db")))
       (with-box p 'read-write 100
         (lambda (b) (try (lambda () (perform b '(end answer))))))))))

(test-equal "perform: a command on an empty box is an assertion violation (a bug, not an outcome)"
  '(raised assertion)
  (attempt (lambda () (try (lambda () (perform (box #f) '(begin-immediate)))))))

;;; ------------------------------------------------------------------
;;; run-job!: the four endings
;;; ------------------------------------------------------------------

(test-equal "run-job!: (answer) hands back the job's values, several, and they are committed"
  '((ok 1 2 3) 1)
  (attempt
   (lambda ()
     (let ((p (fresh "r1.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let ((r (try (lambda ()
                           (run-write b (lambda (tx)
                                          (tx-execute! tx "INSERT INTO notes(body) VALUES ('a')")
                                          (values 1 2 3)))))))
             (list r (notes-in p)))))))))

(test-equal "run-job!: a read job answers, and always ends rolled back"
  '((ok 7) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "r1b.db")))
       (with-box p 'read-only 100
         (lambda (b)
           (list (try (lambda () (run-read b (lambda (tx) 7))))
                 (in-transaction? (unbox b)))))))))

(test-equal "run-job!: a job's raise is raised as the same object, and the write is rolled back"
  '(#t 0 #f)
  (attempt
   (lambda ()
     (let ((p (fresh "r2.db")) (obj (list 'boom)))
       (with-box p 'read-write 100
         (lambda (b)
           (let ((got (guard (e (#t e))
                        (run-write b (lambda (tx)
                                       (tx-execute! tx "INSERT INTO notes(body) VALUES ('a')")
                                       (raise obj))))))
             (list (eq? got obj) (notes-in p) (in-transaction? (unbox b))))))))))

(test-equal "run-job!: (raise-ended): a job that ended its own transaction and returned raises &db-transaction-ended"
  '(raised ended)
  (attempt
   (lambda ()
     (let ((p (fresh "r3.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (try (lambda () (run-write b (lambda (tx) (execute! (unbox b) "COMMIT") 'returned))))))))))

(test-equal "run-job!: (raise-carried): a job that ended its own transaction and raised raises its own object"
  '(raised (string "mine"))
  (attempt
   (lambda ()
     (let ((p (fresh "r3b.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (try (lambda () (run-write b (lambda (tx) (execute! (unbox b) "COMMIT") (raise "mine")))))))))))

(test-equal "run-job!: a read job that ended its own transaction and returned raises &db-transaction-ended"
  '(raised ended)
  (attempt
   (lambda ()
     (let ((p (fresh "r3c.db")))
       (with-box p 'read-only 100
         (lambda (b)
           (try (lambda () (run-read b (lambda (tx) (execute! (unbox b) "COMMIT") 'returned))))))))))

(test-equal "run-job!: a refusal is &db-unavailable, and not a plain error nor an assertion violation"
  '(#t #f #f)
  (attempt
   (lambda ()
     (let ((e (guard (e (#t e)) (run-write (box #f) (lambda (tx) 'never)))))
       (list (db-unavailable? e) (assertion-violation? e) (db-transaction-ended? e))))))

(test-equal "run-job!: unavailable: an empty box refuses a write job and a read job, and the job never runs"
  '((raised (unavailable unavailable)) (raised (unavailable unavailable)) #f)
  (attempt
   (lambda ()
     (let ((ran #f))
       (list (try (lambda () (run-write (box #f) (lambda (tx) (set! ran #t)))))
             (try (lambda () (run-read (box #f) (lambda (tx) (set! ran #t)))))
             ran)))))

(test-equal "run-job!: busy at BEGIN IMMEDIATE is a refusal, the job never runs, the box stays, the next job runs"
  '((raised (unavailable busy)) #f (ok 5))
  (attempt
   (lambda ()
     (let ((p (fresh "r4.db")) (ran #f))
       (with-box p 'read-write 50
         (lambda (b)
           (let ((r1 (with-conn p 'read-write
                       (lambda (o)
                         (execute! o "BEGIN IMMEDIATE")
                         (try (lambda () (run-write b (lambda (tx) (set! ran #t)))))))))
             (list r1 ran (try (lambda () (run-write b (lambda (tx) 5))))))))))))

(test-equal "run-job!: moved: the version bumped by another connection is a refusal carrying both versions"
  (list '(raised (unavailable moved)) latest (+ latest 1) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "r5.db")) (ran #f) (cond-seen #f))
       (with-box p 'read-write 100
         (lambda (b)
           (with-conn p 'read-write
             (lambda (o) (execute! o (string-append "PRAGMA user_version = " (number->string (+ latest 1))))))
           (let ((r (try (lambda ()
                           (guard (e ((db-unavailable? e) (set! cond-seen e) (raise e)))
                             (run-write b (lambda (tx) (set! ran #t)))))))) 
             (list r (db-unavailable-expected cond-seen) (db-unavailable-found cond-seen) ran))))))))

(test-equal "run-job!: moved on a reader too, and nothing is left open"
  (list '(raised (unavailable moved)) latest (+ latest 1) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "r5b.db")) (ran #f) (cond-seen #f))
       (with-box p 'read-only 100
         (lambda (b)
           (with-conn p 'read-write
             (lambda (o) (execute! o (string-append "PRAGMA user_version = " (number->string (+ latest 1))))))
           (let ((r (try (lambda ()
                           (guard (e ((db-unavailable? e) (set! cond-seen e) (raise e)))
                             (run-read b (lambda (tx) (set! ran #t)))))))) 
             (list r (db-unavailable-expected cond-seen) (db-unavailable-found cond-seen)
                   (or ran (in-transaction? (unbox b)))))))))))

(test-equal "run-job!: busy and unavailable carry no versions"
  '(#f #f)
  (attempt
   (lambda ()
     (let ((e (guard (e (#t e)) (run-write (box #f) (lambda (tx) 'never)))))
       (list (db-unavailable-expected e) (db-unavailable-found e))))))

(test-equal "run-job!: (raise-carried) with nothing carried raises a condition of the shell's own, naming the command"
  (list #t (cons 'read-version fixture-latest-version) #t)
  (attempt
   (lambda ()
     (let ((p (fresh "r6.db")))
       (with-box p 'read-write 100
         (lambda (b)
           ;; A step that reads the version with no transaction open: the read says ok,
           ;; and the event is failed-closed, with no object carried.
           (let* ((step (lambda (state event)
                          (case (car state)
                            ((start) (values '(after-look) (cons 'read-version latest)))
                            (else (values '(over) '(end raise-carried))))))
                  (e (guard (e (#t e))
                       (run-job! step '(start) (make-job-shell b) (lambda (tx) 1)))))
             (list (assertion-violation? e)
                   (car (condition-irritants e))
                   (string? (condition-message e))))))))))

(test-equal "run-job!: a warning a job raises continuably is not its answer: the job goes on"
  '((ok 42) 1)
  (attempt
   (lambda ()
     (let ((p (fresh "r7.db")) (seen 0))
       (with-box p 'read-only 100
         (lambda (b)
           (let ((r (try (lambda ()
                           (with-exception-handler
                            (lambda (e) (set! seen (+ seen 1)) 'ignored)
                            (lambda ()
                              (run-read b (lambda (tx)
                                            (raise-continuable (make-warning))
                                            42))))))))
             (list r seen))))))))

;;; The loop's net

(define (step-failing-at n step)
  ;; A step that raises a bug on its Nth event.
  (let ((count 0))
    (lambda (state event)
      (set! count (+ count 1))
      (if (= count n) (raise 'a-bug) (step state event)))))

(test-equal "run-job!: a step that raises mid-job: rolled back, the bug raised again, the lock free, the next job runs clean"
  '((raised (symbol a-bug)) #f 0 (ok 1) 1)
  (attempt
   (lambda ()
     (let ((p (fresh "n1.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let* ((step (step-failing-at 4 write-step))     ; after the job ran
                  (r (try (lambda ()
                            (run-job! step (start-of write-start) (make-job-shell b)
                                      (lambda (tx) (tx-execute! tx "INSERT INTO notes(body) VALUES ('lost')"))))))
                  (open-after (in-transaction? (unbox b)))
                  (n (notes-in p))
                  (r2 (try (lambda () (run-write b (lambda (tx) (tx-execute! tx "INSERT INTO notes(body) VALUES ('kept')") 1))))))
             (list r open-after n r2 (notes-in p)))))))))

(test-equal "run-job!: a step that raises on the first event leaves nothing to roll back, and raises"
  '((raised (symbol a-bug)) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "n1b.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (list (try (lambda () (run-job! (step-failing-at 1 write-step) (start-of write-start)
                                            (make-job-shell b) (lambda (tx) 1))))
                 (in-transaction? (unbox b)))))))))

(test-equal "run-job!: an observer that raises mid-job: rolled back, the bug raised again"
  '((raised (symbol obs-bug)) #f 0)
  (attempt
   (lambda ()
     (let ((p (fresh "n2.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let ((r (try (lambda ()
                           (run-write b (lambda (tx) (tx-execute! tx "INSERT INTO notes(body) VALUES ('lost')"))
                                      (lambda (command raw)
                                        (when (eq? (car command) 'run-job) (raise 'obs-bug))))))))
             (list r (in-transaction? (unbox b)) (notes-in p)))))))))

(test-equal "run-job!: a bug at the end (an answer with no values carried): rolled back, an assertion violation"
  '((raised assertion) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "n3.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let* ((step (lambda (state event)
                          (case (car state)
                            ((start) (values '(begun) '(begin-immediate)))
                            (else (values '(over) '(end answer))))))
                  (r (try (lambda () (run-job! step '(start) (make-job-shell b) (lambda (tx) 1))))))
             (list r (in-transaction? (unbox b))))))))))

(test-equal "run-job!: a step that asks for a command no one knows: an assertion violation, rolled back"
  '((raised assertion) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "n3b.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let* ((step (lambda (state event)
                          (case (car state)
                            ((start) (values '(begun) '(begin-immediate)))
                            (else (values '(over) '(frobnicate))))))
                  (r (try (lambda () (run-job! step '(start) (make-job-shell b) (lambda (tx) 1))))))
             (list r (in-transaction? (unbox b))))))))))

(test-equal "run-job!: a job escaped by a continuation: rolled back on the way out, the lock free"
  '(escaped #f 0 ok)
  (attempt
   (lambda ()
     (let ((p (fresh "n4.db")))
       (with-box p 'read-write 100
         (lambda (b)
           (let* ((r (call/cc (lambda (k)
                                (run-write b (lambda (tx)
                                               (tx-execute! tx "INSERT INTO notes(body) VALUES ('lost')")
                                               (k 'escaped))))))
                  (open-after (in-transaction? (unbox b)))
                  (n (notes-in p))
                  (free (with-conn p 'read-write
                          (lambda (o) (car (try (lambda () (execute! o "BEGIN IMMEDIATE") (execute! o "ROLLBACK"))))))))
             (list r open-after n free))))))))

;;; The observer

(test-equal "observer: a write job's commands, each once, the end not among them"
  (list '(look) '(begin-immediate) (cons 'read-version latest) '(run-job) '(commit))
  (attempt
   (lambda ()
     (let ((p (fresh "o1.db")) (seen '()))
       (with-box p 'read-write 100
         (lambda (b)
           (run-write b (lambda (tx) 1) (lambda (command raw) (set! seen (cons command seen))))
           (reverse seen)))))))

(test-equal "observer: a read job's commands and raw outcomes"
  (list '((look) (present #f #f)) '((begin) (ok #t #t)) (list (cons 'read-version latest) (list 'ok latest #t))
        '((run-job) (returned (1) #t)) '((rollback) (ok #t #f)))
  (attempt
   (lambda ()
     (let ((p (fresh "o2.db")) (seen '()))
       (with-box p 'read-only 100
         (lambda (b)
           (run-read b (lambda (tx) 1) (lambda (command raw) (set! seen (cons (list command raw) seen))))
           (reverse seen)))))))

(test-equal "observer: on a refusal it sees the look, and only the look"
  '((look))
  (attempt
   (lambda ()
     (let ((seen '()))
       (try (lambda () (run-write (box #f) (lambda (tx) 1) (lambda (command raw) (set! seen (cons command seen))))))
       (reverse seen)))))

;;; ------------------------------------------------------------------
;;; The set-up and the tear-down
;;; ------------------------------------------------------------------

(define first-two (list (car fixture-migrations) (cadr fixture-migrations)))

(define (refusal-of thunk)
  (guard (e ((db-refused? e) (list 'refused (db-refused-line e)))
            (#t (list 'raised (describe e))))
    (thunk)
    'no-raise))

(test-equal "set-up: a file that is behind is refused, with the check's line"
  '(refused "the database is behind this binary: run `techo migrate`")
  (attempt
   (lambda ()
     (let ((p (path "s1.db")))
       (clean! p) (migrate! p first-two)
       (refusal-of (lambda () (doorway-set-up p 'read-write fixture-migrations 100)))))))

(test-equal "set-up: a file that is ahead is refused, with the check's line"
  (list 'refused (string-append "this binary is older than the database (version "
                                (number->string fixture-latest-version) ")"))
  (attempt
   (lambda ()
     (let ((p (fresh "s2.db")))
       (refusal-of (lambda () (doorway-set-up p 'read-write first-two 100)))))))

(test-equal "set-up: a current file not in WAL is refused, with the check's line"
  '(refused "the database is not in WAL mode: run `techo migrate`")
  (attempt
   (lambda ()
     (let ((p (fresh "s3.db")))
       (with-conn p 'read-write (lambda (db) (query db "PRAGMA journal_mode = delete")))
       (refusal-of (lambda () (doorway-set-up p 'read-write fixture-migrations 100)))))))

(test-equal "set-up: a reader is refused the same way"
  '(refused "the database is behind this binary: run `techo migrate`")
  (attempt
   (lambda ()
     (let ((p (path "s3b.db")))
       (clean! p) (migrate! p first-two)
       (refusal-of (lambda () (doorway-set-up p 'read-only fixture-migrations 100)))))))

(test-equal "set-up: the refusal's line is the check's own verdict line"
  #t
  (attempt
   (lambda ()
     (let ((p (path "s3c.db")))
       (clean! p) (migrate! p first-two)
       (let ((expected (with-conn p 'read-only
                         (lambda (db) (caddr (set-up-verdict (read-db-facts db) fixture-migrations))))))
         (equal? (refusal-of (lambda () (doorway-set-up p 'read-write fixture-migrations 100)))
                 (list 'refused expected)))))))

(test-equal "set-up: the connection is closed after a refusal (the -wal is gone), and is not when one is kept"
  '(#f #t)
  (attempt
   (lambda ()
     (let ((p1 (path "s4.db")) (p2 (path "s4b.db")))
       (clean! p1) (migrate! p1 first-two)
       (refusal-of (lambda () (doorway-set-up p1 'read-write fixture-migrations 100)))
       (let ((after-refusal (wal? p1)))
         ;; a control: a connection kept open by a set-up that accepts keeps the -wal
         (clean! p2) (migrate! p2 fixture-migrations)
         (let ((b (doorway-set-up p2 'read-write fixture-migrations 100)))
           (let ((kept (wal? p2)))
             (doorway-tear-down b)
             (list after-refusal kept))))))))

(test-equal "set-up: a file the writer cannot write is refused, and a reader still opens it"
  '((refused "cannot write the database file: check its permissions") #t)
  (attempt
   (lambda ()
     (let ((p (fresh "s4w.db")))
       ;; A reader first, so the -shm exists; then the file is made read-only.
       ;; SQLite's read-write open falls back to read-only without a word.
       (with-box p 'read-only 100
         (lambda (rb)
           (chmod p #o444)
           (let ((w (refusal-of (lambda () (doorway-set-up p 'read-write fixture-migrations 100))))
                 (r (let ((b (doorway-set-up p 'read-only fixture-migrations 100)))
                      (let ((held (database? (unbox b))))
                        (doorway-tear-down b)
                        held))))
             (chmod p #o644)
             (list w r))))))))

(test-equal "set-up: a writer's file that another holds locked is refused as busy"
  '(refused "the database is busy: another program holds it")
  (attempt
   (lambda ()
     (let* ((p (fresh "s4b.db"))
            (other (open-techo-db p 'read-write 0)))
       (execute! other "BEGIN IMMEDIATE")
       (let ((r (refusal-of (lambda () (doorway-set-up p 'read-write fixture-migrations 0)))))
         (execute! other "ROLLBACK")
         (close-database! other)
         r)))))

(test-equal "set-up: a good file gives a box holding a connection"
  '(#t #f)
  (attempt
   (lambda ()
     (let* ((p (fresh "s5.db"))
            (b (doorway-set-up p 'read-write fixture-migrations 100)))
       (let ((held (database? (unbox b))))
         (doorway-tear-down b)
         (list held (and (unbox b) #t)))))))

(test-equal "set-up: a reader's connection is read-only, a writer's is read-write"
  '((sqlite readonly) (ok))
  (attempt
   (lambda ()
     (let ((p (fresh "s6.db")))
       (with-box p 'read-only 100
         (lambda (rb)
           (with-box p 'read-write 100
             (lambda (wb)
               (list (cadr (try (lambda () (add-note! (unbox rb)))))
                     (list (car (try (lambda () (add-note! (unbox wb))))))))))))))) 

(test-equal "tear-down: closes the connection, the -wal goes, the box is empty, and a second tear-down is fine"
  '(#t #f #f ok)
  (attempt
   (lambda ()
     (let* ((p (fresh "t1.db"))
            (b (doorway-set-up p 'read-write fixture-migrations 100)))
       (add-note! (unbox b))
       (let ((during (wal? p)))
         (doorway-tear-down b)
         (list during (wal? p) (and (unbox b) #t)
               (car (try (lambda () (doorway-tear-down b))))))))))

(test-equal "tear-down: on an empty box does nothing, and does not raise"
  '(ok #f)
  (attempt
   (lambda ()
     (let ((b (box #f)))
       (list (car (try (lambda () (doorway-tear-down b)))) (unbox b))))))

;;; ------------------------------------------------------------------
;;; db-write and db-read on circuit's doubles, in its test host
;;; ------------------------------------------------------------------

(define unset (lambda (name) #f))

;; in-host : (-> A) -> A
;; Runs THUNK as the handler of one request in circuit's test host, since
;; db-write and db-read wait, and gives what it returned.
(define (in-host thunk)
  (let* ((result 'the-handler-did-not-run)
         (app (lambda (req) (set! result (thunk)) (make-res 200 '() "ok")))
         (host (make-test-host (circuit->handler app unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (string->utf8 "GET /x HTTP/1.1\r\nHost: x\r\n\r\n"))
    (test-client-responses c)
    result))

;; with-doorway : String (Doorway -> A) -> A      [busy timeout in ms]
(define (with-doorway p busy proc)
  (let ((d (make-test-doorway p fixture-migrations busy)))
    (dynamic-wind
      (lambda () #f)
      (lambda () (proc d))
      (lambda ()
        (guard (e (#t #f)) (doorway-stop-readers! d))
        (guard (e (#t #f)) (doorway-stop-writer! d))))))

(define (insert-job body)
  (lambda (tx) (tx-execute! tx "INSERT INTO notes(body) VALUES (?)" body)))
(define (count-job tx) (vector-ref (tx-query-row tx "SELECT count(*) FROM notes") 0))

(test-equal "db-write: an answer, and a db-read after it sees the write"
  '((ok 7) (ok 1))
  (attempt
   (lambda ()
     (let ((p (fresh "d1.db")))
       (with-doorway p 100
         (lambda (d)
           (in-host
            (lambda ()
              (let* ((w (try (lambda () (db-write d (lambda (tx) ((insert-job "a") tx) 7)))))
                     (r (try (lambda () (db-read d count-job)))))
                (list w r))))))))))

(test-equal "db-write and db-read: several values come back"
  '((ok 1 2 3) (ok a b))
  (attempt
   (lambda ()
     (let ((p (fresh "d2.db")))
       (with-doorway p 100
         (lambda (d)
           (in-host
            (lambda ()
              (list (try (lambda () (db-write d (lambda (tx) (values 1 2 3)))))
                    (try (lambda () (db-read d (lambda (tx) (values 'a 'b))))))))))))))

(test-equal "db-write: a job's raise reaches the handler as the same object, and rolls the write back"
  '(#t 0)
  (attempt
   (lambda ()
     (let ((p (fresh "d3.db")) (obj (list 'boom)))
       (with-doorway p 100
         (lambda (d)
           (let ((got (in-host
                       (lambda ()
                         (guard (e (#t e))
                           (db-write d (lambda (tx) ((insert-job "a") tx) (raise obj))))))))
             (list (eq? got obj) (notes-in p)))))))))

(test-equal "db-read: a job's raise reaches the handler as the same object"
  #t
  (attempt
   (lambda ()
     (let ((p (fresh "d3b.db")) (obj (list 'boom)))
       (with-doorway p 100
         (lambda (d)
           (eq? obj (in-host (lambda () (guard (e (#t e)) (db-read d (lambda (tx) (raise obj)))))))))))))

(test-equal "db-read: a write through it raises readonly, and writes nothing"
  '((raised (sqlite readonly)) 0)
  (attempt
   (lambda ()
     (let ((p (fresh "d4.db")))
       (with-doorway p 100
         (lambda (d)
           (let ((r (in-host (lambda () (try (lambda () (db-read d (insert-job "a"))))))))
             (list r (notes-in p)))))))))

(test-equal "db-write: busy is a refusal, (unavailable busy), and the job never ran"
  '((raised (unavailable busy)) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "d5.db")) (ran #f))
       (with-doorway p 50
         (lambda (d)
           (with-conn p 'read-write
             (lambda (o)
               (execute! o "BEGIN IMMEDIATE")
               (let ((r (in-host (lambda () (try (lambda () (db-write d (lambda (tx) (set! ran #t))))))))) 
                 (list r ran))))))))))

(test-equal "db-write and db-read: moved is a refusal, (unavailable moved), and neither job ran"
  '((raised (unavailable moved)) (raised (unavailable moved)) #f)
  (attempt
   (lambda ()
     (let ((p (fresh "d6.db")) (ran #f))
       (with-doorway p 100
         (lambda (d)
           (with-conn p 'read-write
             (lambda (o) (execute! o (string-append "PRAGMA user_version = " (number->string (+ latest 1))))))
           (in-host
            (lambda ()
              (list (try (lambda () (db-write d (lambda (tx) (set! ran #t)))))
                    (try (lambda () (db-read d (lambda (tx) (set! ran #t)))))
                    ran)))))))))

(test-equal "db-write: a job that ended its own transaction raises &db-transaction-ended"
  '(raised ended)
  (attempt
   (lambda ()
     (let ((p (fresh "d7.db")))
       (with-doorway p 100
         (lambda (d)
           (in-host
            (lambda ()
              (try (lambda ()
                     (db-write d (lambda (tx)
                                   (guard (e (#t #f)) (tx-execute! tx "SELECT 1"))
                                   ;; the job reaches the thread's connection only by the handle;
                                   ;; this one ends the transaction by SQLite's own rule
                                   (guard (e (#t #f))
                                     (tx-execute! tx "INSERT INTO notes(id, body) VALUES (1, 'x')")
                                     (tx-execute! tx "INSERT OR ROLLBACK INTO notes(id, body) VALUES (1, 'dup')"))
                                   'done)))))))))))) 

(test-equal "db-write: two writes in a row, each committed, and a read sees both"
  '((ok 2))
  (attempt
   (lambda ()
     (let ((p (fresh "d8.db")))
       (with-doorway p 100
         (lambda (d)
           (in-host
            (lambda ()
              (db-write d (insert-job "a"))
              (db-write d (insert-job "b"))
              (list (try (lambda () (db-read d count-job))))))))))))

(test-equal "db-retry-after is 5"
  5
  db-retry-after)

(test-equal "doorway: a made doorway has no worker, so its stops are no-ops"
  '(ok ok)
  (attempt
   (lambda ()
     (let ((d (make-doorway (path "never.db") 2 fixture-migrations)))
       (list (car (try (lambda () (doorway-stop-readers! d) 'x)))
             (car (try (lambda () (doorway-stop-writer! d) 'x))))))))

;;; ------------------------------------------------------------------
;;; wrap-db
;;; ------------------------------------------------------------------

;; unavailable-of : Symbol Any Any -> &db-unavailable
;; The condition, made by its record's constructor: the reasons are staged
;; here, since the machine gives each only on a real file in a state of its own.
(define unavailable-of
  (let ((make (record-constructor (make-record-constructor-descriptor (record-type-descriptor &db-unavailable) #f #f))))
    (lambda (reason expected found) (make reason expected found))))

;; answer-of : (Req -> Res) (String -> Void) -> (List Status Headers Body) | raised
(define (wrapped log handler)
  ((wrap-db log) handler))

(define (answer w)
  (guard (e (#t (list 'raised (describe e))))
    (let ((r (w #f)))
      (list (res-status r) (res-headers r) (res-body r)))))

(for-each
 (lambda (reason)
   (test-equal (string-append "wrap-db: " (symbol->string reason) " is an empty 503 with Retry-After: 5")
     '(503 (("retry-after" . "5")) #f)
     (answer (wrapped (lambda (line) #f)
                      (lambda (req) (raise (unavailable-of reason (and (eq? reason 'moved) 3) (and (eq? reason 'moved) 4))))))))
 '(busy moved unavailable))

(test-equal "wrap-db: a handler that does not raise is untouched"
  '(200 () "fine")
  (answer (wrapped (lambda (line) #f) (lambda (req) (make-res 200 '() "fine")))))

(define moved-text
  "database moved: the file is at version 4 and this server expects 3; a newer techo migrate ran beside it; database requests get 503 until the newer techo serves")
(define unavailable-text
  "database unavailable: a connection was closed after a failed rollback; database requests can get 503 until techo is restarted")

(test-equal "wrap-db: moved is logged once across several requests, with both versions"
  (list (list moved-text) 3)
  (attempt
   (lambda ()
     (let* ((lines '())
            (w (wrapped (lambda (line) (set! lines (cons line lines)))
                        (lambda (req) (raise (unavailable-of 'moved 3 4))))))
       (w #f) (w #f) (w #f)
       (list (reverse lines) 3)))))

(test-equal "wrap-db: the moved line names the versions it was given"
  (list "database moved: the file is at version 9 and this server expects 2; a newer techo migrate ran beside it; database requests get 503 until the newer techo serves")
  (attempt
   (lambda ()
     (let* ((lines '())
            (w (wrapped (lambda (line) (set! lines (cons line lines)))
                        (lambda (req) (raise (unavailable-of 'moved 2 9))))))
       (w #f)
       (reverse lines)))))

(test-equal "wrap-db: unavailable is logged once across several requests"
  (list unavailable-text)
  (attempt
   (lambda ()
     (let* ((lines '())
            (w (wrapped (lambda (line) (set! lines (cons line lines)))
                        (lambda (req) (raise (unavailable-of 'unavailable #f #f))))))
       (w #f) (w #f)
       (reverse lines)))))

(test-equal "wrap-db: moved and unavailable are each logged once, in the order first seen; busy never"
  (list unavailable-text moved-text)
  (attempt
   (lambda ()
     (let* ((lines '())
            (which (list 'busy 'unavailable 'moved 'busy 'moved 'unavailable))
            (w (wrapped (lambda (line) (set! lines (cons line lines)))
                        (lambda (req)
                          (let ((r (car which)))
                            (set! which (cdr which))
                            (raise (unavailable-of r (and (eq? r 'moved) 3) (and (eq? r 'moved) 4))))))))
       (for-each (lambda (i) (w #f)) '(1 2 3 4 5 6))
       (reverse lines)))))

(test-equal "wrap-db: each line is one call of the log procedure"
  '(1 1)
  (attempt
   (lambda ()
     (let* ((calls 0)
            (w (wrapped (lambda (line) (set! calls (+ calls 1))) (lambda (req) (raise (unavailable-of 'moved 3 4)))))
            (_ (w #f))
            (after-first calls)
            (w2 (wrapped (lambda (line) (set! calls (+ calls 1))) (lambda (req) (raise (unavailable-of 'unavailable #f #f)))))
            (_2 (w2 #f)))
       (list after-first (- calls after-first))))))

;; Passing on: anything else goes by raise-continuable, answered where it was raised.
(define (passes-through? thing)
  (let ((seen #f))
    (let ((r (answer
              (wrapped (lambda (line) (set! seen 'logged))
                       (lambda (req)
                         (let ((v (raise-continuable thing)))
                           (make-res 200 '() (if (eq? v 'resumed) "continued" "other")))))))
          )
      (list r seen))))

(define worker-full-condition
  ((record-constructor (make-record-constructor-descriptor (record-type-descriptor &worker-full) #f #f))))

(test-equal "wrap-db: a condition that is not its own goes by, to the handler beneath it, and the job goes on"
  '(#t (200 () "continued") #f)
  (attempt
   (lambda ()
     (let* ((got #f) (seen #f)
            (w (wrapped (lambda (line) (set! seen 'logged))
                        (lambda (req)
                          (let ((v (raise-continuable 'a-deadline)))
                            (make-res 200 '() (if (eq? v 'resumed) "continued" "other")))))))
       (let ((r (with-exception-handler
                 (lambda (e) (set! got e) 'resumed)
                 (lambda () (let ((r (w #f))) (list (res-status r) (res-headers r) (res-body r)))))))
         (list (eq? got 'a-deadline) r seen))))))

(test-equal "wrap-db: &worker-full is passed on untouched, not answered as a db refusal"
  '(#t (200 () "continued") #f)
  (attempt
   (lambda ()
     (let* ((got #f) (seen #f)
            (w (wrapped (lambda (line) (set! seen 'logged))
                        (lambda (req)
                          (let ((v (raise-continuable worker-full-condition)))
                            (make-res 200 '() (if (eq? v 'resumed) "continued" "other")))))))
       (let ((r (with-exception-handler
                 (lambda (e) (set! got e) 'resumed)
                 (lambda () (let ((r (w #f))) (list (res-status r) (res-headers r) (res-body r)))))))
         (list (eq? got worker-full-condition) r seen))))))

(test-equal "wrap-db: an error condition of another kind is passed on, and the log is silent"
  '(#t #f)
  (attempt
   (lambda ()
     (let* ((got #f) (seen #f) (err (make-error))
            (w (wrapped (lambda (line) (set! seen 'logged))
                        (lambda (req) (raise-continuable err) (make-res 200 '() "x")))))
       (with-exception-handler
        (lambda (e) (set! got e) 'resumed)
        (lambda () (w #f)))
       (list (eq? got err) seen)))))

(test-end "doorway")

(exit (suite-exit-status runner))
