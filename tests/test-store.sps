#!r6rs
;;; The store suite: (techo store), each statement slice 3 needs, run against
;;; real SQLite through the test doorway, on a file the shipped migrations
;;; made. A job runs inside circuit's test host, the pattern of the doorway
;;; suite. Ids are 16-byte and hashes 32-byte bytevectors written out here.
;;;
;;; Every database file is under build/test-store/<unique>/. Everything that
;;; can raise is computed under `attempt` or `try`, and a raise comes out as
;;; a value the expectation never is.
(import (rnrs)
        (only (chezscheme) mkdir directory-list delete-directory file-directory?
                           current-time time-second time-nanosecond)
        (srfi :64)
        (chez-sqlite3)
        (circuit)
        (circuit response)
        (circuit worker)
        (circuit http-server)
        (http-server testing)
        (techo-testing)
        (techo migrations)
        (techo db)
        (techo doorway)
        (techo store))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; try : (-> A) -> (U (List 'ok A) (List 'raised Any))
;; A SQLite raise as its code; anything else as its description.
(define (try thunk)
  (guard (e ((sqlite-error? e) (list 'raised (list 'sqlite (sqlite-error-code e))))
            (#t (list 'raised (describe e))))
    (list 'ok (thunk))))

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
      (rm-tree! "build/test-store")
      (make-dir! "build/test-store")
      (let ((d (string-append "build/test-store/"
                              (number->string (time-second t)) "-"
                              (number->string (time-nanosecond t)))))
        (make-dir! d)
        d))))

(define (path name) (string-append test-dir "/" name))

(define (clean! p)
  (for-each (lambda (s) (when (file-exists? (string-append p s))
                          (delete-file (string-append p s))))
            '("" "-wal" "-shm")))

;; fresh : String -> String     a file the shipped migrations made, in WAL
(define (fresh name)
  (let ((p (path name)))
    (clean! p)
    (migrate! p migrations)
    p))

;; in-host : (-> A) -> A
;; Runs THUNK as the handler of one request in circuit's test host, since
;; db-write and db-read wait, and gives what it returned.
(define unset (lambda (name) #f))
(define (in-host thunk)
  (let* ((result 'the-handler-did-not-run)
         (app (lambda (req) (set! result (thunk)) (make-res 200 '() "ok")))
         (host (make-test-host (circuit->handler app unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (string->utf8 "GET /x HTTP/1.1\r\nHost: x\r\n\r\n"))
    (test-client-responses c)
    result))

;; with-store : String ((Proc Job -> A) (Proc Job -> A) -> B) -> B
;; A doorway on a fresh file. The body is given W and R: each runs a job
;; (Tx -> A) as db-write or db-read would, and gives its answer. The
;; doorway's threads are stopped on the way out.
(define (with-store name body)
  (let* ((p (fresh name))
         (d (make-test-doorway p migrations 100)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (body (lambda (job) (in-host (lambda () (try (lambda () (db-write d job))))))
              (lambda (job) (in-host (lambda () (try (lambda () (db-read d job))))))
              p))
      (lambda ()
        (guard (e (#t #f)) (doorway-stop-readers! d))
        (guard (e (#t #f)) (doorway-stop-writer! d))))))

;; ok-of : (U (List 'ok A) Any) -> (U A Any)
(define (ok-of r) (if (and (pair? r) (eq? (car r) 'ok)) (cadr r) r))

;;; Data

(define (bv n fill) (make-bytevector n fill))
(define acct-a (bv 16 #xA1))
(define acct-b (bv 16 #xB2))
(define (kid n) (bv 16 n))              ; key ids sort by n
(define (khash n) (bv 32 (+ #x40 n)))

;; account->list : (U Account #f) -> (U (List ...) #f)
(define (account->list a)
  (and a (list (account-id a) (account-username a) (account-email a)
               (account-password-hash a) (account-created a))))

;; key->list : (U Key #f) -> (U (List ...) #f)
(define (key->list k)
  (and k (list (key-id k) (key-account k) (key-name k) (key-hash k)
               (key-created k) (key-last-used k) (key-revoked k))))

(define (key-ids keys) (map (lambda (k) (bytevector-u8-ref (key-id k) 0)) keys))

;; set-up! : Tx -> Void     two accounts
(define (set-up! tx)
  (insert-account! tx acct-a "alice" "alice@example.com" "hash-a" 1000)
  (insert-account! tx acct-b "bob" "bob@example.com" "hash-b" 2000))

;; the key rows of a file, raw, to see that a refused change changed nothing
(define (raw-keys p)
  (let ((db (open-database p '((busy-timeout . 0)))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (map vector->list
             (query db "SELECT id, account, name, key_hash, created, last_used, revoked FROM api_keys ORDER BY id")))
      (lambda () (close-database! db)))))

(test-begin "store")

;;; Accounts

(test-equal "accounts: inserted, found by id and by email, every field"
  (let ((a (list acct-a "alice" "alice@example.com" "hash-a" 1000)))
    (list '(ok #t) a a))
  (attempt
   (lambda ()
     (with-store "accounts.db"
       (lambda (w r p)
         (list (let ((x (w (lambda (tx) (set-up! tx) #t)))) x)
               (account->list (ok-of (r (lambda (tx) (account-by-id tx acct-a)))))
               (account->list (ok-of (r (lambda (tx) (account-by-email tx "alice@example.com")))))))))))

(test-equal "accounts: a missing id or email answers #f"
  '((ok #f) (ok #f))
  (attempt
   (lambda ()
     (with-store "accounts-missing.db"
       (lambda (w r p)
         (w set-up!)
         (list (r (lambda (tx) (account-by-id tx (bv 16 9))))
               (r (lambda (tx) (account-by-email tx "nobody@example.com")))))))))

(test-equal "accounts: email lookup is exact, and a duplicate username or email reaches SQLite's own constraint raise"
  '((ok #f) (raised (sqlite constraint)) (raised (sqlite constraint)))
  (attempt
   (lambda ()
     (with-store "accounts-dup.db"
       (lambda (w r p)
         (w set-up!)
         (list (r (lambda (tx) (account-by-email tx "ALICE@example.com")))
               (w (lambda (tx) (insert-account! tx (bv 16 3) "alice" "other@example.com" "h" 1)))
               (w (lambda (tx) (insert-account! tx (bv 16 4) "carol" "bob@example.com" "h" 1)))))))))

;;; Keys

(test-equal "keys: inserted, found by hash and by account and id; null columns read as #f"
  (let ((k (list (kid 1) acct-a "laptop" (khash 1) 3000 #f #f)))
    (list k k))
  (attempt
   (lambda ()
     (with-store "keys.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-key! tx (kid 1) acct-a "laptop" (khash 1) 3000)))
         (list (key->list (ok-of (r (lambda (tx) (key-by-hash tx (khash 1))))))
               (key->list (ok-of (r (lambda (tx) (key-of-account tx acct-a (kid 1))))))))))))

(test-equal "keys: a missing hash, id or account answers #f"
  '((ok #f) (ok #f) (ok #f))
  (attempt
   (lambda ()
     (with-store "keys-missing.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-key! tx (kid 1) acct-a "laptop" (khash 1) 3000)))
         (list (r (lambda (tx) (key-by-hash tx (khash 2))))
               (r (lambda (tx) (key-of-account tx acct-a (kid 2))))
               (r (lambda (tx) (key-of-account tx (bv 16 9) (kid 1))))))))))

(test-equal "keys: a key naming a missing account is refused by SQLite, and nothing is written"
  '((raised (sqlite constraint)) ())
  (attempt
   (lambda ()
     (with-store "keys-orphan.db"
       (lambda (w r p)
         (list (w (lambda (tx) (insert-key! tx (kid 1) (bv 16 9) "x" (khash 1) 1)))
               (raw-keys p)))))))

;;; Scoping

(define (two-accounts-keys! tx)
  (set-up! tx)
  (insert-key! tx (kid 1) acct-a "a-key" (khash 1) 3000)
  (insert-key! tx (kid 2) acct-b "b-key" (khash 2) 4000))

(test-equal "scoping: account A cannot read B's key by id"
  '((ok #f) (ok #t))
  (attempt
   (lambda ()
     (with-store "scope-read.db"
       (lambda (w r p)
         (w two-accounts-keys!)
         (list (r (lambda (tx) (key-of-account tx acct-a (kid 2))))
               (r (lambda (tx) (and (key-of-account tx acct-b (kid 2)) #t)))))))))

(test-equal "scoping: account A cannot revoke or re-hash B's key: the rows are as they were"
  (list '(ok #t) #t)
  (attempt
   (lambda ()
     (with-store "scope-write.db"
       (lambda (w r p)
         (w two-accounts-keys!)
         (let ((before (raw-keys p)))
           (w (lambda (tx)
                (revoke-key! tx acct-a (kid 2) 9999)
                (replace-key-hash! tx acct-a (kid 2) (bv 32 #x77))))
           (list (r (lambda (tx) (and (key-by-hash tx (khash 2)) #t)))
                 (equal? before (raw-keys p)))))))))

(test-equal "scoping: the active count and the page are of the account alone"
  '((ok 1) (ok 1) (ok (1)) (ok (2)))
  (attempt
   (lambda ()
     (with-store "scope-page.db"
       (lambda (w r p)
         (w two-accounts-keys!)
         (list (r (lambda (tx) (count-active-keys tx acct-a)))
               (r (lambda (tx) (count-active-keys tx acct-b)))
               (let ((x (r (lambda (tx) (key-ids (keys-page tx acct-a #f 10)))))) x)
               (r (lambda (tx) (key-ids (keys-page tx acct-b #f 10))))))))))

;;; keys-page

(define (many-keys! tx)
  (set-up! tx)
  ;; inserted out of order
  (for-each (lambda (n) (insert-key! tx (kid n) acct-a "k" (khash n) (* n 10)))
            '(5 2 9 1 7))
  (insert-key! tx (kid 3) acct-b "other" (khash 3) 1))

(test-equal "keys-page: id order, the limit, and AFTER"
  '((ok (1 2 5 7 9)) (ok (1 2)) (ok (5 7)) (ok (9)) (ok ()) (ok (7 9)) (ok ()))
  (attempt
   (lambda ()
     (with-store "page.db"
       (lambda (w r p)
         (w many-keys!)
         (list (r (lambda (tx) (key-ids (keys-page tx acct-a #f 10))))
               (r (lambda (tx) (key-ids (keys-page tx acct-a #f 2))))
               (r (lambda (tx) (key-ids (keys-page tx acct-a (kid 2) 2))))
               (r (lambda (tx) (key-ids (keys-page tx acct-a (kid 7) 5))))
               (r (lambda (tx) (key-ids (keys-page tx acct-a (kid 9) 5))))
               (r (lambda (tx) (key-ids (keys-page tx acct-a (kid 5) 2)))) ; after 5, ids 7 9
               (r (lambda (tx) (key-ids (keys-page tx acct-a #f 0))))))))))

(test-equal "keys-page: AFTER need not be a key's id, and a page carries whole keys"
  '((ok (7 9)) (ok ((7 "k" 70))))
  (attempt
   (lambda ()
     (with-store "page2.db"
       (lambda (w r p)
         (w many-keys!)
         (list (r (lambda (tx) (key-ids (keys-page tx acct-a (kid 6) 5))))
               (r (lambda (tx)
                    (map (lambda (k) (list (bytevector-u8-ref (key-id k) 0) (key-name k) (key-created k)))
                         (keys-page tx acct-a (kid 6) 1))))))))))

;; plan-of : String String Any ... -> (Listof String)
;; The detail column of EXPLAIN QUERY PLAN, on a plain connection: a job may
;; not run EXPLAIN.
(define (plan-of p sql . params)
  (let ((db (open-database p '((busy-timeout . 0)))))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (map (lambda (row) (vector-ref row 3))
             (apply query db (string-append "EXPLAIN QUERY PLAN " sql) params)))
      (lambda () (close-database! db)))))

(define (contains? hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

(test-equal "keys-page: SQLite searches the index api_keys_account, and has no sort step (with and without AFTER)"
  '(#t #t #f #f)
  (attempt
   (lambda ()
     (let* ((p (fresh "plan.db"))
            (a (plan-of p (keys-page-sql #f) acct-a 5))
            (b (plan-of p (keys-page-sql #t) acct-a (kid 1) 5)))
       (list (exists (lambda (d) (and (contains? d "SEARCH") (contains? d "USING INDEX api_keys_account"))) a)
             (exists (lambda (d) (and (contains? d "SEARCH") (contains? d "USING INDEX api_keys_account"))) b)
             (exists (lambda (d) (contains? d "TEMP B-TREE")) a)
             (exists (lambda (d) (contains? d "TEMP B-TREE")) b))))))

;;; revoke, count, re-hash, touch

(test-equal "revoke-key!: sets revoked, the key is still found by hash, the active count drops"
  '((ok 2) (ok #t) (ok 5000) (ok 1))
  (attempt
   (lambda ()
     (with-store "revoke.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
              (insert-key! tx (kid 1) acct-a "one" (khash 1) 1)
              (insert-key! tx (kid 2) acct-a "two" (khash 2) 2)))
         (let ((c1 (r (lambda (tx) (count-active-keys tx acct-a)))))
           (w (lambda (tx) (revoke-key! tx acct-a (kid 1) 5000)))
           (list c1
                 (r (lambda (tx) (and (key-by-hash tx (khash 1)) #t)))
                 (r (lambda (tx) (key-revoked (key-by-hash tx (khash 1)))))
                 (r (lambda (tx) (count-active-keys tx acct-a))))))))))

(test-equal "revoke-key!: a second revoke keeps the first time"
  '(ok 5000)
  (attempt
   (lambda ()
     (with-store "revoke2.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-key! tx (kid 1) acct-a "one" (khash 1) 1)))
         (w (lambda (tx) (revoke-key! tx acct-a (kid 1) 5000)))
         (w (lambda (tx) (revoke-key! tx acct-a (kid 1) 9000)))
         (r (lambda (tx) (key-revoked (key-of-account tx acct-a (kid 1))))))))))

(test-equal "replace-key-hash!: the new hash finds the key, the old finds none, other fields stay"
  (list '(ok #f) (list (kid 1) acct-a "one" (bv 32 #x77) 1 #f #f))
  (attempt
   (lambda ()
     (with-store "rehash.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-key! tx (kid 1) acct-a "one" (khash 1) 1)))
         (w (lambda (tx) (replace-key-hash! tx acct-a (kid 1) (bv 32 #x77))))
         (list (r (lambda (tx) (key-by-hash tx (khash 1))))
               (key->list (ok-of (r (lambda (tx) (key-by-hash tx (bv 32 #x77))))))))))))

(test-equal "touch-key!: sets last_used, and nothing else"
  (list 7000 (list (kid 1) acct-a "one" (khash 1) 1 7000 #f))
  (attempt
   (lambda ()
     (with-store "touch.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-key! tx (kid 1) acct-a "one" (khash 1) 1)))
         (w (lambda (tx) (touch-key! tx (kid 1) 7000)))
         (let ((k (ok-of (r (lambda (tx) (key-by-hash tx (khash 1)))))))
           (list (key-last-used k) (key->list k))))))))

(test-equal "count-active-keys: an account with no keys has 0"
  '(ok 0)
  (attempt
   (lambda ()
     (with-store "count0.db"
       (lambda (w r p)
         (w set-up!)
         (r (lambda (tx) (count-active-keys tx acct-a))))))))

;;; Login's three statements

(test-equal "account-by-username: finds the account, every field; exact; a missing name answers #f"
  (list (list acct-b "bob" "bob@example.com" "hash-b" 2000) '(ok #f) '(ok #f))
  (attempt
   (lambda ()
     (with-store "by-username.db"
       (lambda (w r p)
         (w set-up!)
         (list (account->list (ok-of (r (lambda (tx) (account-by-username tx "bob")))))
               (r (lambda (tx) (account-by-username tx "BOB")))
               (r (lambda (tx) (account-by-username tx "nobody")))))))))

(test-equal "set-password-hash!: right old hash changes it (#t) and only that row; wrong old hash, unknown id: #f and nothing changes"
  (list '(ok #t) "new-a" "hash-b"
        '(ok #f) "new-a"
        '(ok #f) "new-a" "hash-b")
  (attempt
   (lambda ()
     (with-store "set-hash.db"
       (lambda (w r p)
         (w set-up!)
         (let* ((hash-of (lambda (id) (account-password-hash (ok-of (r (lambda (tx) (account-by-id tx id)))))))
                (r1 (w (lambda (tx) (set-password-hash! tx acct-a "hash-a" "new-a"))))
                (a1 (hash-of acct-a))
                (b1 (hash-of acct-b))
                (r2 (w (lambda (tx) (set-password-hash! tx acct-a "hash-a" "other"))))
                (a2 (hash-of acct-a))
                (r3 (w (lambda (tx) (set-password-hash! tx (bv 16 9) "hash-a" "other"))))
                (a3 (hash-of acct-a))
                (b3 (hash-of acct-b)))
           (list r1 a1 b1 r2 a2 r3 a3 b3)))))))

(test-equal "revoke-all-keys!: revokes the active keys of one account, counts them, keeps old times, leaves another account's keys"
  (list '(ok 2) 6000 6000 5000 #f '(ok 0) '(ok 0))
  (attempt
   (lambda ()
     (with-store "revoke-all.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-key! tx (kid 1) acct-a "one" (khash 1) 1)
              (insert-key! tx (kid 2) acct-a "two" (khash 2) 1)
              (insert-key! tx (kid 3) acct-a "three" (khash 3) 1)
              (insert-key! tx (kid 4) acct-b "bobs" (khash 4) 1)))
         (w (lambda (tx) (revoke-key! tx acct-a (kid 3) 5000)))
         (let* ((n (w (lambda (tx) (revoke-all-keys! tx acct-a 6000))))
                (rev (lambda (a k) (key-revoked (ok-of (r (lambda (tx) (key-of-account tx a (kid k))))))))
                (v1 (rev acct-a 1)) (v2 (rev acct-a 2)) (v3 (rev acct-a 3)) (v4 (rev acct-b 4))
                (again (w (lambda (tx) (revoke-all-keys! tx acct-a 7000))))
                (none (w (lambda (tx) (revoke-all-keys! tx (bv 16 9) 7000)))))
           (list n v1 v2 v3 v4 again none)))))))

;;; A read job

(test-equal "db-read: each writing procedure raises SQLite's readonly, and nothing changes"
  (list (map (lambda (i) '(raised (sqlite readonly))) '(1 2 3 4 5))
        #t
        '(ok 2))
  (attempt
   (lambda ()
     (with-store "readonly.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-key! tx (kid 1) acct-a "one" (khash 1) 1)))
         (let* ((before (raw-keys p))
                (results
                 (list (r (lambda (tx) (insert-account! tx (bv 16 3) "c" "c@example.com" "h" 1)))
                       (r (lambda (tx) (insert-key! tx (kid 2) acct-a "two" (khash 2) 1)))
                       (r (lambda (tx) (revoke-key! tx acct-a (kid 1) 5)))
                       (r (lambda (tx) (replace-key-hash! tx acct-a (kid 1) (bv 32 #x77))))
                       (r (lambda (tx) (touch-key! tx (kid 1) 5))))))
           (list results
                 (equal? before (raw-keys p))
                 (r (lambda (tx) (vector-ref (tx-query-row tx "SELECT count(*) FROM accounts") 0))))))))))

(test-end "store")

(exit (suite-exit-status runner))
