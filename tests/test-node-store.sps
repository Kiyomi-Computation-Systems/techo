#!r6rs
;;; The node store suite: (techo node-store), each statement slice 4 needs, run against
;;; real SQLite through the test doorway, on a file the shipped migrations
;;; made. A job runs inside circuit's test host, the pattern of the doorway
;;; suite. Ids are 16-byte and hashes 32-byte bytevectors written out here.
;;; The statements themselves are read too, from node-store-statements: their
;;; text, SQLite's plan for them, and the library's source (H12, H19).
;;;
;;; Every database file is under build/test-node-store/<unique>/. Everything that
;;; can raise is computed under `attempt` or `try`, and a raise comes out as
;;; a value the expectation never is.
(import (rnrs)
        (only (chezscheme) mkdir directory-list delete-directory file-directory?
                           current-time time-second time-nanosecond library-directories)
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
        (techo store)
        (techo node-store)
        (only (techo nodes) node-kinds child-moves? child-kind-filter)
        (only (jsonparse easy) json->string))

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
      (rm-tree! "build/test-node-store")
      (make-dir! "build/test-node-store")
      (let ((d (string-append "build/test-node-store/"
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
(define (nid n) (bv 16 n))              ; node ids sort by n

;; set-up! : Tx -> Void     two accounts
(define (set-up! tx)
  (insert-account! tx acct-a "alice" "alice@example.com" "hash-a" 1000)
  (insert-account! tx acct-b "bob" "bob@example.com" "hash-b" 2000))

;; node->list : (U Node #f) -> (U (List ...) #f)
(define (node->list n)
  (and n (list (node-id n) (node-owner n) (node-author n) (node-kind n)
               (node-title n) (node-body n) (node-content-type n)
               (node-props n) (node-revision n) (node-created n)
               (node-updated n))))

;; snap->list : (U Snapshot #f) -> (U (List ...) #f)
(define (snap->list s)
  (and s (list (snapshot-node s) (snapshot-revision s) (snapshot-author s)
               (snapshot-title s) (snapshot-body s) (snapshot-content-type s)
               (snapshot-props s) (snapshot-created s))))

(define (node-ids ns) (map (lambda (n) (bytevector-u8-ref (node-id n) 0)) ns))

;; raw : Tx String Any ... -> (Listof (Listof Any))
(define (raw tx sql . args)
  (map vector->list (apply tx-query tx sql args)))

;; all-rows : Tx -> (List ...)    every row of the three tables, in key order
(define (all-rows tx)
  (list (raw tx "SELECT num, id, owner, author, kind, title, content_type, props, revision, created, updated, state, parent FROM nodes ORDER BY num")
        (raw tx "SELECT node, revision, author, title, content_type, props, created, body FROM revisions ORDER BY node, revision")
        (raw tx "SELECT owner, seq, node, revision, op, created FROM changes ORDER BY owner, seq")))

(define (changes-of tx owner)
  (raw tx "SELECT seq, node, revision, op, created FROM changes WHERE owner = ? ORDER BY seq" owner))

(define (count-of tx table)
  (vector-ref (tx-query-row tx (string-append "SELECT count(*) FROM " table)) 0))

;; contains? : String String -> Boolean
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? sub (substring s i (+ i m))) #t)
            (else (loop (+ i 1)))))))

;; caught : (-> A) -> (U (List 'value A) (List 'raised (Listof Any) String))
;; The irritants and the whole text of what THUNK raised.
(define (caught thunk)
  (guard (e (#t (list 'raised
                      (if (irritants-condition? e) (condition-irritants e) 'none)
                      (describe e))))
    (list 'value (thunk))))

(define A1 (nid 1))
(define A2 (nid 2))
(define A3 (nid 3))
(define B1 (nid 4))

(test-begin "node-store")

;;; Insert and read back

(test-equal "insert: every field comes back; revision 1, author is the owner, one snapshot, one change row"
  (list (list A1 acct-a acct-a "note" "Title" "Body text" "text/markdown" "{}" 1 5000 5000)
        (list A1 acct-a acct-a "note" "Title" "Body text" "text/markdown" "{}" 1 5000 5000)
        (list A1 1 acct-a "Title" "Body text" "text/markdown" "{}" 5000)
        (list (list 1 A1 1 "create" 5000))
        (list 1 1 1)
        '())
  (attempt
   (lambda ()
     (with-store "insert.db"
       (lambda (w r p)
         (w set-up!)
         (let ((made (ok-of (w (lambda (tx) (node->list (insert-node! tx A1 acct-a "note" "Title" "Body text" "text/markdown" "{}" #f '() 5000)))))))
           (list made
                 (node->list (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1)))))
                 (snap->list (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 1)))))
                 (ok-of (r (lambda (tx) (changes-of tx acct-a))))
                 (ok-of (r (lambda (tx) (list (count-of tx "nodes") (count-of tx "revisions") (count-of tx "changes")))))
                 (ok-of (r (lambda (tx) (changes-of tx acct-b)))))))))))

(test-equal "insert: node-head is (revision kind state parent), from the node alone"
  '(ok (1 "task" "active" #f))
  (attempt
   (lambda ()
     (with-store "head.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "task" "t" "b" "text/plain" "{}" #f '() 1)))
         (r (lambda (tx) (node-head tx acct-a A1))))))))

(test-equal "insert: a missing id is #f everywhere, and not in use"
  '((ok #f) (ok #f) (ok #f) (ok #f) (ok ()) (ok ()) (ok #f))
  (attempt
   (lambda ()
     (with-store "missing.db"
       (lambda (w r p)
         (w set-up!)
         (list (r (lambda (tx) (node-head tx acct-a A1)))
               (r (lambda (tx) (node-of-owner tx acct-a A1)))
               (r (lambda (tx) (snapshot-of tx acct-a A1 1)))
               (r (lambda (tx) (node-in-use? tx A1)))
               (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() #f 10)))
               (r (lambda (tx) (snapshots-page tx acct-a A1 #f 10)))
               (r (lambda (tx) (node-in-use? tx (nid 99))))))))))

;;; Write

(test-equal "write: revision up by one, updated set, created and kind kept; node equals newest snapshot; older snapshot untouched"
  (list (list A1 acct-a acct-a "project" "T2" "B2" "text/plain" "{\"a\":1}" 2 100 200)
        (list A1 acct-a acct-a "project" "T2" "B2" "text/plain" "{\"a\":1}" 2 100 200)
        (list A1 2 acct-a "T2" "B2" "text/plain" "{\"a\":1}" 200)
        #t
        (list A1 3 acct-a "T3" "B3" "text/html" "{}" 300)
        '(3 "project" "active" #f))
  (attempt
   (lambda ()
     (with-store "write.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (insert-node! tx A1 acct-a "project" "T1" "B1" "text/markdown" "{}" #f '() 100)))
         (let* ((s1 (snap->list (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 1))))))
                (made (ok-of (w (lambda (tx) (node->list (write-node! tx A1 acct-a 1 "T2" "B2" "text/plain" "{\"a\":1}" 'keep "update" 200))))))
                (read (node->list (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1))))))
                (s2 (snap->list (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 2)))))))
           (w (lambda (tx) (write-node! tx A1 acct-a 2 "T3" "B3" "text/html" "{}" 'keep "update" 300)))
           (list made read s2
                 (equal? s1 (snap->list (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 1))))))
                 (snap->list (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 3)))))
                 (ok-of (r (lambda (tx) (node-head tx acct-a A1)))))))))))

(test-equal "write: the node's title, content type and props equal the newest snapshot's after each write; there is a snapshot at its revision"
  '(ok ((1 #t) (2 #t) (3 #t)))
  (attempt
   (lambda ()
     (with-store "h2.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 1)))
         (let ((check (lambda ()
                        (ok-of (r (lambda (tx)
                                    (let ((n (node-of-owner tx acct-a A1)))
                                      (let ((s (snapshot-of tx acct-a A1 (node-revision n))))
                                        (list (node-revision n)
                                              (and s
                                                   (string=? (node-title n) (snapshot-title s))
                                                   (string=? (node-content-type n) (snapshot-content-type s))
                                                   (string=? (node-props n) (snapshot-props s))
                                                   (string=? (node-body n) (snapshot-body s))
                                                   (eqv? (node-updated n) (snapshot-created s))))))))))))
           (let* ((c1 (check))
                  (x (w (lambda (tx) (write-node! tx A1 acct-a 1 "T2" "B1" "a/a" "{}" 'keep "update" 2))))
                  (c2 (check))
                  (y (w (lambda (tx) (write-node! tx A1 acct-a 2 "T2" "B3" "b/b" "{\"k\":[1]}" 'keep "restore" 3))))
                  (c3 (check)))
             (list 'ok (list c1 c2 c3)))))))))

(test-equal "write: a wrong expected revision raises with only the id and expected as irritants, and leaves nothing in the transaction"
  (list 'raised (list (nid 1) 7) #f #f
        '(1 1 1))
  (attempt
   (lambda ()
     (with-store "stale.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 1)))
         (let ((res (ok-of (w (lambda (tx)
                                (let ((c (caught (lambda () (write-node! tx A1 acct-a 7 "SECRET-TITLE" "SECRET-BODY" "a/a" "{}" 'keep "update" 2)))))
                                  (list c (list (count-of tx "nodes") (count-of tx "revisions") (count-of tx "changes")))))))))
           (let ((c (car res)))
             (list (car c) (cadr c)
                   (contains? (caddr c) "SECRET-TITLE")
                   (contains? (caddr c) "SECRET-BODY")
                   (cadr res)))))))))

(test-equal "write: the wrong owner raises, with no title or body in what was raised, and nothing changes"
  (list 'raised (list A1 1) #f #f #t)
  (attempt
   (lambda ()
     (with-store "wrong-owner.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 1)))
         (let* ((before (ok-of (r all-rows)))
                (res (ok-of (w (lambda (tx)
                                 (caught (lambda () (write-node! tx A1 acct-b 1 "SECRET-TITLE" "SECRET-BODY" "a/a" "{}" 'keep "update" 2)))))))
                (via-doorway (w (lambda (tx) (write-node! tx A1 acct-b 1 "SECRET-TITLE" "SECRET-BODY" "a/a" "{}" 'keep "update" 2)))))
           (list (car res) (cadr res)
                 (contains? (caddr res) "SECRET-TITLE")
                 (contains? (caddr res) "SECRET-BODY")
                 (and (pair? via-doorway) (eq? (car via-doorway) 'raised)
                      (equal? before (ok-of (r all-rows)))))))))))

(test-equal "write: a raise through the doorway undoes the whole job, its first write too"
  '(#t #t)
  (attempt
   (lambda ()
     (with-store "undo.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 1)))
         (let* ((before (ok-of (r all-rows)))
                (res (w (lambda (tx)
                          (write-node! tx A1 acct-a 1 "T2" "B2" "a/a" "{}" 'keep "update" 2)
                          (write-node! tx A1 acct-a 1 "T3" "B3" "a/a" "{}" 'keep "update" 3)))))
           (list (and (pair? res) (eq? (car res) 'raised))
                 (equal? before (ok-of (r all-rows))))))))))

;;; Change numbers

(test-equal "changes: each owner's numbers are 1..M with no gap, apart from the other's; node, revision, op and time right"
  (list (list (list 1 A1 1 "create" 10)
              (list 2 A2 1 "create" 11)
              (list 3 A1 2 "update" 13)
              (list 4 A1 3 "restore" 15))
        (list (list 1 B1 1 "create" 12)
              (list 2 B1 2 "update" 14)))
  (attempt
   (lambda ()
     (with-store "changes.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f '() 10)
              (insert-node! tx A2 acct-a "note" "t" "b" "a/a" "{}" #f '() 11)
              (insert-node! tx B1 acct-b "note" "t" "b" "a/a" "{}" #f '() 12)
              (write-node! tx A1 acct-a 1 "t" "b2" "a/a" "{}" 'keep "update" 13)
              (write-node! tx B1 acct-b 1 "t" "b2" "a/a" "{}" 'keep "update" 14)
              (write-node! tx A1 acct-a 2 "t" "b3" "a/a" "{}" 'keep "restore" 15)))
         (list (ok-of (r (lambda (tx) (changes-of tx acct-a))))
               (ok-of (r (lambda (tx) (changes-of tx acct-b))))))))))

;;; Another account's node

(test-equal "owner: account B sees nothing of A's node, yet the id is in use"
  '((ok #f) (ok #f) (ok #f) (ok #f) (ok ()) (ok ()) (ok #t) (ok (3 "note" "active" #f)))
  (attempt
   (lambda ()
     (with-store "owner.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                    (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f '() 1)
                    (write-node! tx A1 acct-a 1 "t" "b" "a/a" "{}" 'keep "update" 2)
                    (write-node! tx A1 acct-a 2 "t" "b" "a/a" "{}" 'keep "update" 3)))
         (list (r (lambda (tx) (node-head tx acct-b A1)))
               (r (lambda (tx) (node-of-owner tx acct-b A1)))
               (r (lambda (tx) (snapshot-of tx acct-b A1 1)))
               (r (lambda (tx) (snapshot-of tx acct-b A1 3)))
               (r (lambda (tx) (nodes-page tx acct-b "active" 'any '() #f 10)))
               (r (lambda (tx) (snapshots-page tx acct-b A1 #f 10)))
               (r (lambda (tx) (node-in-use? tx A1)))
               (r (lambda (tx) (node-head tx acct-a A1)))))))))

(test-equal "owner: B's insert of A's id is refused by the table, and A's node is as it was"
  '((raised (sqlite constraint)) #t)
  (attempt
   (lambda ()
     (with-store "dup-id.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f '() 1)))
         (let ((before (ok-of (r all-rows))))
           (list (w (lambda (tx) (insert-node! tx A1 acct-b "note" "x" "y" "a/a" "{}" #f '() 2)))
                 (equal? before (ok-of (r all-rows))))))))))

;;; Paging

(test-equal "nodes-page: every node of the owner once across pages, by id, body #f; none of the other's"
  (list '(1 2 3 5 6) '(#f #f #f #f #f) '((1 2) (3 5) (6)) '(4) '())
  (attempt
   (lambda ()
     (with-store "pages.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (for-each (lambda (n) (insert-node! tx (nid n) acct-a "note" "t" "body" "a/a" "{}" #f '() n)) '(5 1 3 2 6))
              (insert-node! tx (nid 4) acct-b "note" "t" "body" "a/a" "{}" #f '() 9)))
         (let* ((p1 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() #f 2)))))
                (p2 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() (node-id (cadr p1)) 2)))))
                (p3 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() (node-id (cadr p2)) 2)))))
                (p4 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() (node-id (car p3)) 2)))))
                (all (append p1 p2 p3)))
           (list (node-ids all)
                 (map node-body all)
                 (map node-ids (list p1 p2 p3))
                 (node-ids (ok-of (r (lambda (tx) (nodes-page tx acct-b "active" 'any '() #f 10)))))
                 p4))))))
  )

(test-equal "nodes-page: a page row has every other field of the node"
  (list A1 acct-a acct-a "journal" "T" #f "a/a" "{}" 1 7 7)
  (attempt
   (lambda ()
     (with-store "page-fields.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "journal" "T" "body" "a/a" "{}" #f '() 7)))
         (node->list (car (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() #f 5)))))))))))

(test-equal "snapshots-page: newest first, strictly falling, BEFORE exclusive, body #f, the owner's only"
  (list '(5 4) '(3 2) '(1) '(#f #f) '(5 4 3 2 1) '(4 3 2 1) '())
  (attempt
   (lambda ()
     (with-store "snaps.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx A1 acct-a "note" "t1" "b1" "a/a" "{}" #f '() 1)
              (insert-node! tx B1 acct-b "note" "u1" "c1" "a/a" "{}" #f '() 1)
              (write-node! tx A1 acct-a 1 "t2" "b2" "a/a" "{}" 'keep "update" 2)
              (write-node! tx A1 acct-a 2 "t3" "b3" "a/a" "{}" 'keep "update" 3)
              (write-node! tx A1 acct-a 3 "t4" "b4" "a/a" "{}" 'keep "update" 4)
              (write-node! tx A1 acct-a 4 "t5" "b5" "a/a" "{}" 'keep "update" 5)))
         (let* ((revs (lambda (l) (map snapshot-revision l)))
                (g1 (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 #f 2)))))
                (g2 (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 4 2)))))
                (g3 (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 2 2)))))
                (all (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 #f 50)))))
                (below5 (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 5 50))))))
           (list (revs g1) (revs g2) (revs g3)
                 (map snapshot-body g1)
                 (revs all) (revs below5)
                 (ok-of (r (lambda (tx) (snapshots-page tx acct-b A1 #f 50)))))))))))

(test-equal "snapshots-page: a row has the snapshot's other fields"
  (list A1 3 acct-a "t3" #f "c/c" "{\"x\":1}" 30)
  (attempt
   (lambda ()
     (with-store "snap-fields.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx A1 acct-a "note" "t1" "b1" "a/a" "{}" #f '() 10)
              (write-node! tx A1 acct-a 1 "t2" "b2" "a/a" "{}" 'keep "update" 20)
              (write-node! tx A1 acct-a 2 "t3" "b3" "c/c" "{\"x\":1}" 'keep "update" 30)))
         (snap->list (car (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 #f 1)))))))))))

;;; A snapshot of the right node

;; two-nodes! : Tx -> Void
;; A's nodes A1 and A2, each at revision 2, with titles and bodies of their
;; own at each revision; B's B1 at revision 1.
(define (two-nodes! tx)
  (set-up! tx)
  (insert-node! tx A1 acct-a "note" "A1 t1" "A1 b1" "a/a" "{}" #f '() 1)
  (insert-node! tx A2 acct-a "note" "A2 t1" "A2 b1" "a/a" "{}" #f '() 2)
  (insert-node! tx B1 acct-b "note" "B1 t1" "B1 b1" "a/a" "{}" #f '() 3)
  (write-node! tx A1 acct-a 1 "A1 t2" "A1 b2" "a/a" "{}" 'keep "update" 4)
  (write-node! tx A2 acct-a 1 "A2 t2" "A2 b2" "a/a" "{}" 'keep "update" 5))

(test-equal "snapshot-of: two nodes of one owner at the same revisions: each answers its own snapshot, title and body"
  (list (list A1 1 "A1 t1" "A1 b1") (list A1 2 "A1 t2" "A1 b2")
        (list A2 1 "A2 t1" "A2 b1") (list A2 2 "A2 t2" "A2 b2"))
  (attempt
   (lambda ()
     (with-store "right-node.db"
       (lambda (w r p)
         (w two-nodes!)
         (let* ((of (lambda (id n)
                      (let ((s (ok-of (r (lambda (tx) (snapshot-of tx acct-a id n))))))
                        (and (snapshot? s)
                             (list (snapshot-node s) (snapshot-revision s)
                                   (snapshot-title s) (snapshot-body s))))))
                (a1 (of A1 1))
                (a2 (of A1 2))
                (b1 (of A2 1))
                (b2 (of A2 2)))
           (list a1 a2 b1 b2)))))))

(test-equal "snapshot-exists?: each snapshot the owner's node has, and no other: none past its revision, none of another node, none to another owner"
  '(ok (#t #t #f #f #f #f #f))
  (attempt
   (lambda ()
     (with-store "exists.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f '() 1)
              (write-node! tx A1 acct-a 1 "t" "b2" "a/a" "{}" 'keep "update" 2)
              (insert-node! tx A2 acct-a "note" "t" "b" "a/a" "{}" #f '() 3)
              (insert-node! tx B1 acct-b "note" "t" "b" "a/a" "{}" #f '() 4)))
         (r (lambda (tx)
              (list (snapshot-exists? tx acct-a A1 1)
                    (snapshot-exists? tx acct-a A1 2)
                    (snapshot-exists? tx acct-a A1 3)
                    (snapshot-exists? tx acct-a A2 2)
                    (snapshot-exists? tx acct-b A1 1)
                    (snapshot-exists? tx acct-a B1 1)
                    (snapshot-exists? tx acct-a A3 1)))))))))

;;; Large and non-ASCII text

(test-equal "text: a body of 1,048,576 characters round-trips, in the node and in its snapshot"
  '(#t #t #t)
  (attempt
   (lambda ()
     (with-store "big.db"
       (lambda (w r p)
         (let ((big (string-append (make-string 1048575 #\x) "y")))
           (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "t" big "a/a" "{}" #f '() 1)))
           (list (equal? big (node-body (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1))))))
                 (equal? big (snapshot-body (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 1))))))
                 (let ((big2 (string-append big "z")))
                   (w (lambda (tx) (write-node! tx A1 acct-a 1 "t" big2 "a/a" "{}" 'keep "update" 2)))
                   (equal? big2 (node-body (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1)))))))))))))
  )

(test-equal "text: non-ASCII title, body, content type and props round-trip"
  (list "t\x00e9;te \x65e5;\x672c;" "\x3b1;\x3b2;\x3b3; \x1f600; end" "text/\x3b4;" "{\"k\":\"\x1f600;\"}")
  (attempt
   (lambda ()
     (with-store "utf8.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                    (insert-node! tx A1 acct-a "note" "t\x00e9;te \x65e5;\x672c;" "\x3b1;\x3b2;\x3b3; \x1f600; end" "text/\x3b4;" "{\"k\":\"\x1f600;\"}" #f '() 1)))
         (let ((n (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1))))))
           (list (node-title n) (node-body n) (node-content-type n) (node-props n))))))))

;;; State

;; changed-nothing? : Tx (-> Any) -> (List Any Boolean)
;; What THUNK raised or answered (as `caught`), and whether the three tables
;; are as they were afterwards.
(define (nothing-changes tx thunk)
  (let* ((before (all-rows tx))
         (c (caught thunk)))
    (list c (equal? before (all-rows tx)))))

;; The raised part of a `caught`, without the text: its tag and irritants.
(define (raised-with c) (and (eq? (car c) 'raised) (list (car c) (cadr c))))

;; lifecycle fixture: A's nodes 1 active, 2 archived, 3 trashed, 4 purged,
;; 5 and 6 active; B's node 7 active. Times 10 up.
(define (lc-set-up! tx)
  (set-up! tx)
  (for-each (lambda (n) (insert-node! tx (nid n) acct-a "note" (string-append "T" (number->string n)) (string-append "B" (number->string n)) "a/a" "{}" #f '() 10))
            '(1 2 3 4 5 6))
  (insert-node! tx (nid 7) acct-b "note" "T7" "B7" "a/a" "{}" #f '() 10)
  (set-node-state! tx (nid 2) acct-a 1 "archived" "archive" 20)
  (set-node-state! tx (nid 3) acct-a 1 "trashed" "trash" 20)
  (set-node-state! tx (nid 4) acct-a 1 "trashed" "trash" 20)
  (purge-node! tx (nid 4) acct-a 2 30))

(test-equal "state: the body is the newest snapshot's when the node's revision is ahead of it, after a state change; the state is read"
  (list (list A1 acct-a acct-a "note" "T2" "B2" "text/plain" "{\"a\":1}" 3 100 300 "archived")
        "archived"
        '(3 "note" "archived" #f)
        '(2 1)
        #f
        #t)
  (attempt
   (lambda ()
     (with-store "newest.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "text/markdown" "{}" #f '() 100)))
         (w (lambda (tx) (write-node! tx A1 acct-a 1 "T2" "B2" "text/plain" "{\"a\":1}" 'keep "update" 200)))
         (w (lambda (tx) (set-node-state! tx A1 acct-a 2 "archived" "archive" 300)))
         (let ((n (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1))))))
           (list (append (node->list n) (list (node-state n)))
                 (node-state n)
                 (ok-of (r (lambda (tx) (node-head tx acct-a A1))))
                 (map snapshot-revision (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 #f 10)))))
                 (ok-of (r (lambda (tx) (snapshot-exists? tx acct-a A1 3))))
                 (string? (node-body n)))))))))

(test-equal "set-node-state!: revision up by one, updated set, one change row with the op, no snapshot; the answer has the new state and no body; the rest of the row untouched"
  (list (list A1 acct-a acct-a "task" "T1" #f "text/markdown" "{\"k\":1}" 2 100 250 "trashed")
        '(2 250)
        (list (list 1 A1 1 "create" 100) (list 2 A1 2 "trash" 250))
        '(1)
        '(("T1" "text/markdown" "{\"k\":1}" "task" 100 #t))
        '(2 "task" "trashed" #f))
  (attempt
   (lambda ()
     (with-store "setstate.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "task" "T1" "B1" "text/markdown" "{\"k\":1}" #f '() 100)))
         (let* ((made (ok-of (w (lambda (tx) (let ((n (set-node-state! tx A1 acct-a 1 "trashed" "trash" 250)))
                                               (append (node->list n) (list (node-state n))))))))
                (nrows (ok-of (r (lambda (tx) (raw tx "SELECT revision, updated FROM nodes WHERE id = ?" A1)))))
                )
           (list made
                 (car nrows)
                 (ok-of (r (lambda (tx) (changes-of tx acct-a))))
                 (ok-of (r (lambda (tx) (map car (raw tx "SELECT revision FROM revisions WHERE node = ?" A1)))))
                 (ok-of (r (lambda (tx) (map (lambda (row) (append (list (list-ref row 0) (list-ref row 1) (list-ref row 2) (list-ref row 3) (list-ref row 4)) (list (equal? (list-ref row 5) acct-a)))) (raw tx "SELECT title, content_type, props, kind, created, author FROM nodes WHERE id = ?" A1)))))
                 (ok-of (r (lambda (tx) (node-head tx acct-a A1)))))))))))

(test-equal "set-node-state!: a stale revision, another owner and a purged row each raise with the id and the revision only, and change nothing"
  (list (list (list 'raised (list (nid 1) 7)) #t)
        (list (list 'raised (list (nid 1) 1)) #t)
        (list (list 'raised (list (nid 4) 2)) #t)
        (list (list 'raised (list (nid 4) 3)) #t))
  (attempt
   (lambda ()
     (with-store "setstate-refused.db"
       (lambda (w r p)
         (w lc-set-up!)
         (map (lambda (res) (list (raised-with (car res)) (cadr res)))
              (ok-of (w (lambda (tx)
                          (list (nothing-changes tx (lambda () (set-node-state! tx (nid 1) acct-a 7 "archived" "archive" 40)))
                                (nothing-changes tx (lambda () (set-node-state! tx (nid 1) acct-b 1 "archived" "archive" 40)))
                                (nothing-changes tx (lambda () (set-node-state! tx (nid 4) acct-a 2 "trashed" "trash" 40)))
                                (nothing-changes tx (lambda () (set-node-state! tx (nid 4) acct-a 3 "trashed" "trash" 40)))))))))))))

(test-equal "set-node-state!: what it raises names the id and revision, and no text of the node"
  #f
  (attempt
   (lambda ()
     (with-store "setstate-text.db"
       (lambda (w r p)
         (w lc-set-up!)
         (let ((c (ok-of (w (lambda (tx) (caught (lambda () (set-node-state! tx (nid 1) acct-a 7 "archived" "archive" 40))))))))
           (or (contains? (caddr c) "T1") (contains? (caddr c) "B1"))))))))

(test-equal "write-node!: on a trashed row and on a purged row it raises with the id and revision only, and changes nothing"
  (list (list (list 'raised (list (nid 3) 2)) #t) (list (list 'raised (list (nid 4) 3)) #t) #f #f)
  (attempt
   (lambda ()
     (with-store "write-state.db"
       (lambda (w r p)
         (w lc-set-up!)
         (let ((res (ok-of (w (lambda (tx)
                                (list (nothing-changes tx (lambda () (write-node! tx (nid 3) acct-a 2 "SECRET-T" "SECRET-B" "a/a" "{}" 'keep "update" 50)))
                                      (nothing-changes tx (lambda () (write-node! tx (nid 4) acct-a 3 "SECRET-T" "SECRET-B" "a/a" "{}" 'keep "update" 50)))))))))
           (list (list (raised-with (car (car res))) (cadr (car res)))
                 (list (raised-with (car (cadr res))) (cadr (cadr res)))
                 (contains? (caddr (car (car res))) "SECRET")
                 (contains? (caddr (car (cadr res))) "SECRET"))))))))

(test-equal "write-node!: on an archived row it works, and the Node says archived; the state stays"
  '("archived" 3 "archived" "B2b")
  (attempt
   (lambda ()
     (with-store "write-archived.db"
       (lambda (w r p)
         (w lc-set-up!)
         (let ((n (ok-of (w (lambda (tx) (write-node! tx (nid 2) acct-a 2 "T2b" "B2b" "a/a" "{}" 'keep "update" 60))))))
           (list (node-state n) (node-revision n)
                 (node-state (ok-of (r (lambda (tx) (node-of-owner tx acct-a (nid 2))))))
                 (node-body (ok-of (r (lambda (tx) (node-of-owner tx acct-a (nid 2)))))))))))))

(test-equal "write-node!: on an active row the Node says active"
  "active"
  (attempt
   (lambda ()
     (with-store "write-active.db"
       (lambda (w r p)
         (w lc-set-up!)
         (node-state (ok-of (w (lambda (tx) (write-node! tx (nid 1) acct-a 1 "T" "B" "a/a" "{}" 'keep "update" 60))))))))))

(test-equal "purge-node!: no snapshot left; the row emptied; kind, author, owner, created and num kept; one purge change row; still in use; found by nothing that answers"
  (list '()
        (list "" "{}" "application/octet-stream" "purged" 4 40)
        (list "note" #t #t 10)
        '(4 . "purge")
        #t
        (list #f #f #f #f '() '())
        (list '() '() '() '()))
  (attempt
   (lambda ()
     (with-store "purge.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 10)
                         (write-node! tx A1 acct-a 1 "T1" "B2" "a/a" "{}" 'keep "update" 15)
                         (set-node-state! tx A1 acct-a 2 "trashed" "trash" 20)))
         (let ((num-before (ok-of (r (lambda (tx) (raw tx "SELECT num FROM nodes WHERE id = ?" A1))))))
           (w (lambda (tx) (purge-node! tx A1 acct-a 3 40)))
           (list (ok-of (r (lambda (tx) (raw tx "SELECT revision FROM revisions WHERE node = ?" A1))))
                 (car (ok-of (r (lambda (tx) (raw tx "SELECT title, props, content_type, state, revision, updated FROM nodes WHERE id = ?" A1)))))
                 (let ((row (car (ok-of (r (lambda (tx) (raw tx "SELECT kind, author, owner, created, num FROM nodes WHERE id = ?" A1)))))))
                   (list (car row) (equal? (cadr row) acct-a) (equal? (caddr row) acct-a) (cadddr row)))
                 (let ((c (ok-of (r (lambda (tx) (changes-of tx acct-a))))))
                   (cons (length c) (cadddr (car (reverse c)))))
                 (and (equal? num-before (ok-of (r (lambda (tx) (raw tx "SELECT num FROM nodes WHERE id = ?" A1)))))
                      (ok-of (r (lambda (tx) (node-in-use? tx A1)))))
                 (list (ok-of (r (lambda (tx) (node-head tx acct-a A1))))
                       (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1))))
                       (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 1))))
                       (ok-of (r (lambda (tx) (snapshot-exists? tx acct-a A1 1))))
                       (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 #f 10))))
                       (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 5 10)))))
                 (map (lambda (st) (ok-of (r (lambda (tx) (node-ids (nodes-page tx acct-a st 'any '() #f 10))))))
                      '("active" "archived" "trashed" "purged")))))))))

(test-equal "purge-node!: a node that is not trashed, a stale revision and another owner's node each raise with the id and revision only; the job rolls back, the snapshots are still there; another owner's are not even deleted in the job"
  (list (list (list 'raised (list (nid 1) 1)) #t)
        (list (list 'raised (list (nid 3) 1)) #t)
        (list (list 'raised (list (nid 3) 2)) #t)
        (list (list 'raised (list (nid 4) 3)) #t)
        #t)
  (attempt
   (lambda ()
     (with-store "purge-refused.db"
       (lambda (w r p)
         (w lc-set-up!)
         (let* ((seen #f)
                ;; Runs THUNK in a job, keeps what it raised, then raises so
                ;; the job rolls back; answers that, and whether the tables
                ;; are as they were afterwards.
                (rolled-back
                 (lambda (thunk)
                   (let* ((before (ok-of (r all-rows)))
                          (res (w (lambda (tx)
                                    (set! seen (raised-with (caught (lambda () (thunk tx)))))
                                    (assertion-violation 'test "roll the job back")))))
                     (list seen (and (eq? (car res) 'raised) (equal? before (ok-of (r all-rows))))))))
                (a (rolled-back (lambda (tx) (purge-node! tx (nid 1) acct-a 1 40))))
                (b (rolled-back (lambda (tx) (purge-node! tx (nid 3) acct-a 1 40))))
                (c (rolled-back (lambda (tx) (purge-node! tx (nid 3) acct-b 2 40))))
                (d (rolled-back (lambda (tx) (purge-node! tx (nid 4) acct-a 3 40))))
                (e (ok-of (w (lambda (tx)
                               (nothing-changes tx (lambda () (purge-node! tx (nid 3) acct-b 2 40))))))))
           (list a b c d (and (eq? (car (car e)) 'raised) (cadr e)))))))))

(test-equal "purge-node!: a refused purge through the doorway undoes the job: the snapshots return"
  '(raised 1)
  (attempt
   (lambda ()
     (with-store "purge-rollback.db"
       (lambda (w r p)
         (w lc-set-up!)
         (let ((res (w (lambda (tx) (purge-node! tx (nid 1) acct-a 1 40)))))
           (list (car res)
                 (ok-of (r (lambda (tx) (length (raw tx "SELECT revision FROM revisions WHERE node = ?" (nid 1)))))))))))))

(test-equal "nodes-page: every state lists its own nodes, a node is under exactly one state, a purged one under none, another owner's under none"
  (list '(1 5 6) '(2) '(3) '() '(1 2 3 5 6)
        '((1 5) (6) ())
        '(7)
        '((2) (3) ()))
  (attempt
   (lambda ()
     (with-store "state-pages.db"
       (lambda (w r p)
         (w lc-set-up!)
         (let* ((page (lambda (st after n)
                        (ok-of (r (lambda (tx) (node-ids (nodes-page tx acct-a st 'any '() after n)))))))
                (states (map (lambda (st) (page st #f 10)) '("active" "archived" "trashed" "purged"))))
           (append states
                   (list (list-sort < (apply append states))
                         (let* ((p1 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() #f 2)))))
                                (p2 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() (node-id (cadr p1)) 2)))))
                                (p3 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() (node-id (car p2)) 2))))))
                           (map node-ids (list p1 p2 p3)))
                         (ok-of (r (lambda (tx) (node-ids (nodes-page tx acct-b "active" 'any '() #f 10)))))
                         (list (page "archived" (nid 1) 10) (page "trashed" (nid 2) 10) (page "trashed" (nid 3) 10))))))))))

(test-equal "nodes-page: a page's nodes carry their state, and no body"
  '(("active" #f) ("archived" #f) ("trashed" #f))
  (attempt
   (lambda ()
     (with-store "state-pages-fields.db"
       (lambda (w r p)
         (w lc-set-up!)
         (map (lambda (st)
                (let ((n (car (ok-of (r (lambda (tx) (nodes-page tx acct-a st 'any '() #f 1)))))))
                  (list (node-state n) (node-body n))))
              '("active" "archived" "trashed")))))))

(test-equal "state: a purged node is found by none of the reads of its own owner, and its siblings are"
  '((#f #f #f #f ()) ((1 "note" "active" #f) #t))
  (attempt
   (lambda ()
     (with-store "purged-reads.db"
       (lambda (w r p)
         (w lc-set-up!)
         (list (ok-of (r (lambda (tx) (list (node-head tx acct-a (nid 4)) (node-of-owner tx acct-a (nid 4))
                                            (snapshot-of tx acct-a (nid 4) 1) (snapshot-exists? tx acct-a (nid 4) 1)
                                            (snapshots-page tx acct-a (nid 4) #f 10)))))
               (ok-of (r (lambda (tx) (list (node-head tx acct-a (nid 1)) (and (node-of-owner tx acct-a (nid 1)) #t)))))))))))

;;; A node's props (slice 6): props-of, the one statement a replace, a
;;; restore and a transition of a Task need, since node-head reads none

(test-equal "props-of: the stored text as written, for each kind; after a write the new text; an archived and a trashed node's too"
  (list "{\"status\":\"DONE\",\"closed\":5}" "{\"at\":\"2026-12-01\"}" "{}"
        "{\"deadline\":\"2026-12-24\"}" "{\"emails\":{\"e1\":{\"address\":\"a@b\"}}}" "{}")
  (attempt
   (lambda ()
     (with-store "props-of.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx A1 acct-a "task" "t" "b" "a/a" "{\"status\":\"DONE\",\"closed\":5}" #f '() 10)
              (insert-node! tx A2 acct-a "note" "t" "b" "a/a" "{\"at\":\"2026-12-01\"}" #f '() 10)
              (insert-node! tx A3 acct-a "project" "t" "b" "a/a" "{}" #f '() 10)
              (insert-node! tx (nid 5) acct-a "task" "t" "b" "a/a" "{}" #f '() 10)
              (write-node! tx (nid 5) acct-a 1 "t" "b" "a/a" "{\"deadline\":\"2026-12-24\"}" 'keep "update" 20)
              (set-node-state! tx (nid 5) acct-a 2 "archived" "archive" 30)
              (insert-node! tx (nid 6) acct-a "contact" "t" "b" "a/a" "{\"emails\":{\"e1\":{\"address\":\"a@b\"}}}" #f '() 10)
              (set-node-state! tx (nid 6) acct-a 1 "trashed" "trash" 30)
              (insert-node! tx (nid 7) acct-a "journal" "t" "b" "a/a" "{}" #f '() 10)))
         (ok-of (r (lambda (tx) (map (lambda (n) (props-of tx acct-a (nid n))) '(1 2 3 5 6 7))))))))))

(test-equal "props-of: owner-scoped: B's node, A's purged node and an id no one holds are each #f; B reads B's own"
  '(#f #f #f #f "{\"at\":\"2026-12-02\"}")
  (attempt
   (lambda ()
     (with-store "props-of-owner.db"
       (lambda (w r p)
         (w (lambda (tx)
              (lc-set-up! tx)
              (write-node! tx (nid 7) acct-b 1 "T7" "B7" "a/a" "{\"at\":\"2026-12-02\"}" 'keep "update" 40)))
         (ok-of (r (lambda (tx) (list (props-of tx acct-a (nid 7)) (props-of tx acct-a (nid 4))
                                      (props-of tx acct-b (nid 4)) (props-of tx acct-a (nid 99))
                                      (props-of tx acct-b (nid 7)))))))))))

;;; The statements (H12, H19)
;;;
;;; node-store-statements is every statement (techo node-store) runs, by
;;; name, and each of its procedures takes its SQL from there. These tests
;;; read that list, so they read exactly what runs. An answer never showed
;;; a list's body either way, so what a statement selects is read here, in
;;; its text and in SQLite's plan for it.

;; statement-of : Symbol -> (U String #f)
(define (statement-of name)
  (let ((s (assq name node-store-statements))) (and s (cdr s))))

;; starts? : String String -> Boolean
(define (starts? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

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

;; loaded-source : String -> (U String #f)
;; REL under the first of Chez's library directories that holds it: the
;; file this suite loaded, a mutant's copy when one is first on the path.
(define (loaded-source rel)
  (let loop ((ds (library-directories)))
    (cond ((null? ds) #f)
          ((file-exists? (string-append (caar ds) "/" rel)) (string-append (caar ds) "/" rel))
          (else (loop (cdr ds))))))

;; sql-arguments : Any -> (Listof Any)
;; The SQL argument S of every (tx-execute! tx S ...), (tx-query tx S ...)
;; and (tx-query-row tx S ...) in FORM, as written in the source.
(define (sql-arguments form)
  (cond ((not (pair? form)) '())
        ((and (memq (car form) '(tx-execute! tx-query tx-query-row)) (list? form) (>= (length form) 3))
         (cons (caddr form) (apply append (map sql-arguments (cdr form)))))
        (else (append (sql-arguments (car form)) (sql-arguments (cdr form))))))

;; statement-name : Any -> (U Symbol #f)     NAME of (statement 'NAME), else #f
(define (statement-name s)
  (and (list? s) (= (length s) 2) (eq? (car s) 'statement)
       (let ((q (cadr s)))
         (and (list? q) (= (length q) 2) (eq? (car q) 'quote) (symbol? (cadr q)) (cadr q)))))

;; queried-names : -> (Listof Symbol)
;; Every name tagged-query answers: for 1 to 10 tags, under each kind of
;; parent. tagged-page runs them through its one (statement (car q)).
(define (queried-names)
  (let loop ((k 10) (acc '()))
    (if (= k 0)
        acc
        (let ((counted (let tags ((j k) (ts '())) (if (= j 0) ts (tags (- j 1) (cons (cons (number->string j) 1) ts))))))
          (loop (- k 1)
                (append (map (lambda (parent) (car (tagged-query acct-a "active" parent counted #f 5)))
                             (list 'any #f A1))
                        acc))))))

(test-equal "statements: every statement (techo node-store) runs is (statement 'NAME), NAME listed, none written in place, but tagged-page's one (statement (car q)), each of whose names, tagged-query's, is listed; and every one listed is run"
  '(() ((statement (car q))) 30 () ())
  (attempt
   (lambda ()
     (let* ((lib (call-with-input-file (loaded-source "techo/node-store.sls") read))
            (args (sql-arguments (list-tail lib 4)))
            (names (map statement-name args))
            (queried (queried-names)))
       (list (filter (lambda (s) (let ((n (statement-name s))) (and n (not (assq n node-store-statements)))))
                     args)
             (filter (lambda (s) (not (statement-name s))) args)
             (length queried)
             (filter (lambda (n) (not (assq n node-store-statements))) queried)
             (filter (lambda (n) (not (or (memq n names) (memq n queried)))) (map car node-store-statements)))))))

(test-equal "statements: nodes-page's plan, with AFTER and without, reads nodes alone: each line is of n, none names revisions (H12)"
  '((#t #f) (#t #f))
  (attempt
   (lambda ()
     (let ((p (fresh "plan-pages.db")))
       (map (lambda (plan)
              (list (and (pair? plan)
                         (for-all (lambda (d) (or (starts? d "SEARCH n ") (starts? d "SCAN n "))) plan))
                    (exists (lambda (d) (contains? d "revisions")) plan)))
            (list (plan-of p (statement-of 'nodes-page) acct-a "active" 5)
                  (plan-of p (statement-of 'nodes-page-after) acct-a "active" A1 5)))))))

(test-equal "statements: the pages by parent read nodes alone too, the top level with `parent IS NULL` and a parent's children with `parent = ?`; none names revisions"
  '((#t #f) (#t #f) (#t #f) (#t #f) #t #t)
  (attempt
   (lambda ()
     (let ((p (fresh "plan-pages-parent.db")))
       (append
        (map (lambda (plan)
               (list (and (pair? plan)
                          (for-all (lambda (d) (or (starts? d "SEARCH n ") (starts? d "SCAN n "))) plan))
                     (exists (lambda (d) (contains? d "revisions")) plan)))
             (list (plan-of p (statement-of 'nodes-page-top) acct-a "active" 5)
                   (plan-of p (statement-of 'nodes-page-top-after) acct-a "active" A1 5)
                   (plan-of p (statement-of 'nodes-page-of) acct-a "active" A1 5)
                   (plan-of p (statement-of 'nodes-page-of-after) acct-a "active" A1 A2 5)))
        (list (contains? (statement-of 'nodes-page-top) "n.parent IS NULL")
              (contains? (statement-of 'nodes-page-of) "n.parent = ?")))))))

(for-each
 (lambda (name)
   (test-equal (string-append "statements: " (symbol->string name) " does not name body (H12)")
     '(#t #f)
     (attempt
      (lambda ()
        (let ((s (statement-of name)))
          (list (string? s) (and (string? s) (contains? s "body"))))))))
 '(nodes-page nodes-page-after nodes-page-top nodes-page-top-after nodes-page-of nodes-page-of-after
   snapshots-page snapshots-page-before node-head node-in-use snapshot-exists
   ancestors has-children count-children children-heads children-heads-kind
   set-node-state move-node purge-snapshots purge-node
   link-of insert-link delete-link links-out links-out-typed links-in links-in-typed
   purge-links-source purge-links-target props-of))

;; SQLite searches the id's own unique index for both, the owner's terms
;; then checked on the one row: as fast as nodes_owner, and one row at most.
(test-equal "statements: props-of's plan is node-head's, one search of nodes by an index on the id, no scan and no other table; it selects props alone, from nodes"
  '(#t #t "SELECT props FROM nodes WHERE owner = ? AND id = ? AND state <> 'purged'")
  (attempt
   (lambda ()
     (let* ((p (fresh "plan-props.db"))
            (plan (plan-of p (statement-of 'props-of) acct-a A1)))
       (list (and (= (length plan) 1)
                  (starts? (car plan) "SEARCH nodes USING ")
                  (contains? (car plan) "id=?"))
             (equal? plan (plan-of p (statement-of 'node-head) acct-a A1))
             (statement-of 'props-of))))))

(test-equal "statements: node-in-use's plan is one search of a covering index: it reads the id alone (H19)"
  #t
  (attempt
   (lambda ()
     (let ((plan (plan-of (fresh "plan-in-use.db") (statement-of 'node-in-use) A1)))
       (and (= (length plan) 1)
            (starts? (car plan) "SEARCH ")
            (contains? (car plan) "USING COVERING INDEX"))))))

(test-equal "statements: snapshot-exists's plan reads revisions by a covering index alone, so never a body; it reads the node's row for its state"
  #t
  (attempt
   (lambda ()
     (let ((plan (plan-of (fresh "plan-exists.db") (statement-of 'snapshot-exists) acct-a A1 1)))
       (and (pair? plan)
            (for-all (lambda (d) (and (starts? d "SEARCH ")
                                      (or (starts? d "SEARCH n ") (contains? d "USING COVERING INDEX"))))
                     plan)
            (exists (lambda (d) (and (starts? d "SEARCH r ") (contains? d "USING COVERING INDEX"))) plan))))))

;; where-clause : String -> (U String #f)     SQL after its first " WHERE "
(define (where-clause sql)
  (let ((n (string-length sql)) (m (string-length " WHERE ")))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring sql i (+ i m)) " WHERE ") (substring sql (+ i m) n))
            (else (loop (+ i 1)))))))

;; owner-scoped? : String -> Boolean
;; Its WHERE names the owner, `owner = ?`, with no OR beside it. A statement
;; on revisions, which has no owner column, names `n.owner = ?`, with nodes
;; as n joined on the node's id.
(define (owner-scoped? sql)
  (let ((w (where-clause sql)))
    (and w
         (not (contains? w " OR "))
         (if (contains? sql "revisions")
             (and (contains? w "n.owner = ?")
                  (contains? sql "nodes n ")
                  (or (contains? sql "n.id = r.node") (contains? sql "r.node = n.id")))
             (contains? w "owner = ?")))))

;; owner-exempt : (Listof (Pair Symbol String))
;; The statements with no owner in their WHERE, each by name and with what
;; its text begins with: node-in-use, the one query without (ADR-0003,
;; amended); rows-changed, which reads no table; and the INSERTs, which
;; write the owner they are handed (insert-link and insert-tag too: an
;; INSERT of VALUES has no WHERE to name the owner in; insert-tags-json
;; reads a JSON text, no table).
(define owner-exempt
  '((node-in-use . "SELECT id FROM nodes ") (rows-changed . "SELECT changes()")
    (insert-node . "INSERT ") (insert-snapshot . "INSERT ") (insert-change . "INSERT ")
    (insert-link . "INSERT ") (insert-tag . "INSERT ") (insert-tags-json . "INSERT ")))

(test-equal "statements: each one not exempt by name names the owner in its WHERE, a snapshot's through its node (H19)"
  '()
  (attempt
   (lambda ()
     (map car (filter (lambda (s) (not (or (assq (car s) owner-exempt) (owner-scoped? (cdr s)))))
                      node-store-statements)))))

(test-equal "statements: each exempt one is listed and begins as it is exempt for: node-in-use a SELECT of the id, rows-changed changes(), the rest INSERTs"
  '()
  (attempt
   (lambda ()
     (map car (filter (lambda (e) (let ((s (statement-of (car e)))) (not (and s (starts? s (cdr e))))))
                      owner-exempt)))))

(test-equal "statements: set-node-state, purge-snapshots and purge-node are listed; the purge's DELETE has exactly the decided shape"
  (list #t #t #t
        "DELETE FROM revisions AS r WHERE r.node = ? AND EXISTS (SELECT 1 FROM nodes n WHERE n.id = r.node AND n.owner = ?)")
  (attempt
   (lambda ()
     (list (and (statement-of 'set-node-state) #t) (and (statement-of 'purge-node) #t) (and (statement-of 'purge-snapshots) #t)
           (statement-of 'purge-snapshots)))))

(test-equal "statements: each read of a node a client can reach leaves out a purged one; each write that changes a node refuses a purged one"
  '()
  (attempt
   (lambda ()
     (filter (lambda (name)
               (let ((s (statement-of name)))
                 (not (and s (or (contains? s "state <> 'purged'") (contains? s "state = 'trashed'")
                                 (contains? s "state IN ('active','archived')"))))))
             '(node-head props-of node-of-owner snapshot-exists snapshot-of snapshots-page snapshots-page-before
               write-node set-node-state move-node purge-node)))))

(test-equal "statements: nodes-page and nodes-page-after filter by state, and node-of-owner reads the newest snapshot"
  '(#t #t #t #f)
  (attempt
   (lambda ()
     (list (contains? (statement-of 'nodes-page) "n.state = ?")
           (contains? (statement-of 'nodes-page-after) "n.state = ?")
           (contains? (statement-of 'node-of-owner) "SELECT max(revision) FROM revisions WHERE node = n.id")
           (contains? (statement-of 'node-of-owner) "r.revision = n.revision")))))

;;; The tree: a node's parent (slice 5a)

;; nidn : Natural -> Bytevector     a 16-byte id that sorts by n, for big trees
(define (nidn n)
  (let ((b (make-bytevector 16 0)))
    (bytevector-u16-set! b 14 n (endianness big))
    (bytevector-u8-set! b 0 #x70)
    b))

;; raw-parent : Tx Bytevector -> (U Bytevector #f)     the stored column
(define (raw-parent tx id)
  (let ((v (vector-ref (tx-query-row tx "SELECT parent FROM nodes WHERE id = ?" id) 0)))
    (if (sql-null? v) #f v)))

;; leaf-ids : (Listof Bytevector) -> (Listof Natural)     first byte of each
(define (first-bytes ids) (map (lambda (i) (bytevector-u8-ref i 0)) ids))

;; tree-set-up! : Tx -> Void
;; A's nodes: 1 project at the top; 2 note under 1; 3 task under 1 (archived);
;; 4 note under 1 (trashed); 5 note under 1; 6 note under 2; 7 project at the
;; top. B's node 20 at the top and B's node 21 under A's 1. Times 10 up.
(define (tree-set-up! tx)
  (set-up! tx)
  (insert-node! tx (nid 1) acct-a "project" "T1" "B1" "a/a" "{}" #f '() 10)
  (insert-node! tx (nid 2) acct-a "note" "T2" "B2" "a/a" "{}" (nid 1) '() 10)
  (insert-node! tx (nid 3) acct-a "task" "T3" "B3" "a/a" "{}" (nid 1) '() 10)
  (insert-node! tx (nid 4) acct-a "note" "T4" "B4" "a/a" "{}" (nid 1) '() 10)
  (insert-node! tx (nid 5) acct-a "note" "T5" "B5" "a/a" "{}" (nid 1) '() 10)
  (insert-node! tx (nid 6) acct-a "note" "T6" "B6" "a/a" "{}" (nid 2) '() 10)
  (insert-node! tx (nid 7) acct-a "project" "T7" "B7" "a/a" "{}" #f '() 10)
  (insert-node! tx (nid 20) acct-b "project" "T20" "B20" "a/a" "{}" #f '() 10)
  (insert-node! tx (nid 21) acct-b "note" "T21" "B21" "a/a" "{}" (nid 1) '() 10)
  (set-node-state! tx (nid 3) acct-a 1 "archived" "archive" 20)
  (set-node-state! tx (nid 4) acct-a 1 "trashed" "trash" 20))

(test-equal "parent: a Node shows its parent from every read and write; a replace and a state change keep it; node-head has it"
  (list (nid 1) #f (nid 1) (nid 1) (nid 1) (nid 1) (nid 1) (nid 1)
        (list 3 "note" "archived" (nid 1)) (list 1 "project" "active" #f)
        (nid 1) (nid 1))
  (attempt
   (lambda ()
     (with-store "parent-nodes.db"
       (lambda (w r p)
         (w tree-set-up!)
         (let* ((made (ok-of (w (lambda (tx) (insert-node! tx (nid 30) acct-a "note" "t" "b" "a/a" "{}" (nid 1) '() 11)))))
                (top (ok-of (w (lambda (tx) (insert-node! tx (nid 31) acct-a "note" "t" "b" "a/a" "{}" #f '() 11)))))
                (read (ok-of (r (lambda (tx) (node-of-owner tx acct-a (nid 2))))))
                (paged (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any '() #f 100)))))
                (replaced (ok-of (w (lambda (tx) (write-node! tx (nid 2) acct-a 1 "T" "B" "a/a" "{}" 'keep "update" 50)))))
                (archived (ok-of (w (lambda (tx) (set-node-state! tx (nid 2) acct-a 2 "archived" "archive" 60)))))
                (after (ok-of (r (lambda (tx) (node-of-owner tx acct-a (nid 2)))))))
           (list (node-parent made) (node-parent top) (node-parent read)
                 (node-parent (cadr paged))
                 (node-parent replaced) (node-parent archived) (node-parent after)
                 (ok-of (r (lambda (tx) (raw-parent tx (nid 2)))))
                 (ok-of (r (lambda (tx) (node-head tx acct-a (nid 2)))))
                 (ok-of (r (lambda (tx) (node-head tx acct-a (nid 1)))))
                 (ok-of (r (lambda (tx) (raw-parent tx (nid 30)))))
                 (node-parent (ok-of (r (lambda (tx) (node-of-owner tx acct-a (nid 30)))))))))))))

(test-equal "insert-node!: a parent that is not a node is refused by the foreign key, and nothing is left"
  '((raised (sqlite constraint)) (0 0 0))
  (attempt
   (lambda ()
     (with-store "c-parent.db"
       (lambda (w r p)
         (w set-up!)
         (list (w (lambda (tx) (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" (nid 99) '() 1)))
               (ok-of (r (lambda (tx) (list (count-of tx "nodes") (count-of tx "revisions") (count-of tx "changes")))))))))))

(test-equal "insert-node!: a parent of 15 bytes is refused by the column's CHECK"
  '(raised (sqlite constraint))
  (attempt
   (lambda ()
     (with-store "c-parent-len.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (tx-execute! tx "PRAGMA foreign_keys = off")))
         (w (lambda (tx) (tx-execute! tx "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated, parent) VALUES (?, ?, ?, 'note', 't', 'a/a', '{}', 1, 1, 1, ?)" A1 acct-a acct-a (bv 15 1)))))))))

;;; nodes-page by parent

(define (page-ids w-r owner state parent after n)
  (ok-of (w-r (lambda (tx) (first-bytes (map node-id (nodes-page tx owner state parent '() after n)))))))

(test-equal "nodes-page: 'any, #f and an id, each with a state and with AFTER; the flat page is what it was"
  '(((1 2 5 6 7) (2 5 6 7) (7) (1 7) (1) (7) (2 5) (3) (4) () (5) (2) (6) ()) #f)
  (attempt
   (lambda ()
     (with-store "page-parent.db"
       (lambda (w r p)
         (w tree-set-up!)
         (let ((ids (lambda (st par after n) (page-ids r acct-a st par after n))))
           (list (list (ids "active" 'any #f 10)
                       (ids "active" 'any (nid 1) 10)
                       (ids "active" 'any (nid 6) 10)
                       (ids "active" #f #f 10)
                       (ids "active" #f #f 1)
                       (ids "active" #f (nid 1) 10)
                       (ids "active" (nid 1) #f 10)
                       (ids "archived" (nid 1) #f 10)
                       (ids "trashed" (nid 1) #f 10)
                       (ids "purged" (nid 1) #f 10)
                       (ids "active" (nid 1) (nid 2) 10)
                       (ids "active" (nid 1) #f 1)
                       (ids "active" (nid 2) #f 10)
                       (ids "active" (nid 5) #f 10))
                 (exists node-body (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" (nid 1) '() #f 10))))))))))))

(test-equal "nodes-page: another owner's nodes are never in a page, whatever the parent; B sees its own"
  '((20 21) (20) (21) () ())
  (attempt
   (lambda ()
     (with-store "page-parent-owner.db"
       (lambda (w r p)
         (w tree-set-up!)
         (list (page-ids r acct-b "active" 'any #f 10)
               (page-ids r acct-b "active" #f #f 10)
               (page-ids r acct-b "active" (nid 1) #f 10)
               (page-ids r acct-b "active" (nid 20) #f 10)
               (page-ids r acct-a "active" (nid 20) #f 10)))))))

;;; ancestors

;; chain-set-up! : Natural -> (Tx -> Void)
;; A's nodes nidn 1 .. N, each the parent of the next.
(define (chain-set-up! n)
  (lambda (tx)
    (set-up! tx)
    (do ((i 1 (+ i 1))) ((> i n))
      (insert-node! tx (nidn i) acct-a "project" "t" "b" "a/a" "{}" (and (> i 1) (nidn (- i 1))) '() 10))))

(define (ancestor-nums r owner id n)
  (ok-of (r (lambda (tx) (map (lambda (b) (bytevector-u16-ref b 14 (endianness big))
                              ) (ancestors tx owner id n))))))

(test-equal "ancestors: a root, a chain of 5 (nearest first, capped by n, n 0), a missing id, another owner's"
  '(() (4 3 2 1) (4 3) () () () ())
  (attempt
   (lambda ()
     (with-store "anc-chain.db"
       (lambda (w r p)
         (w (chain-set-up! 5))
         (list (ancestor-nums r acct-a (nidn 1) 10)
               (ancestor-nums r acct-a (nidn 5) 10)
               (ancestor-nums r acct-a (nidn 5) 2)
               (ancestor-nums r acct-a (nidn 5) 0)
               (ancestor-nums r acct-a (nidn 99) 10)
               (ancestor-nums r acct-b (nidn 5) 10)
               (ancestor-nums r acct-b (nidn 99) 10)))))))

(test-equal "ancestors: a chain of 1,000 asked with 64 answers exactly 64, nearest first; 65 asked of a chain 64 deep answers 63"
  (list 64 999 936 63)
  (attempt
   (lambda ()
     (with-store "anc-deep.db"
       (lambda (w r p)
         (w (chain-set-up! 1000))
         (let ((a (ancestor-nums r acct-a (nidn 1000) 64)))
           (list (length a) (car a) (car (reverse a))
                 (length (ancestor-nums r acct-a (nidn 64) 65)))))))))

(test-equal "ancestors: a 2-cycle made by hand answers n ids and returns; the ids alternate"
  '(7 (2 1 2 1 2 1 2))
  (attempt
   (lambda ()
     (with-store "anc-cycle.db"
       (lambda (w r p)
         (w (chain-set-up! 2))
         (w (lambda (tx) (tx-execute! tx "UPDATE nodes SET parent = ? WHERE id = ?" (nidn 2) (nidn 1))))
         (let ((a (ancestor-nums r acct-a (nidn 1) 7)))
           (list (length a) a)))))))

(test-equal "ancestors: the plan's recursive step is SCAN up then a SEARCH of nodes by id; no line is a search of nodes_parent, or of anything by owner alone"
  '(#t #t #f #f)
  (attempt
   (lambda ()
     (let ((plan (plan-of (fresh "plan-anc.db") (statement-of 'ancestors) acct-a A1 acct-a 64 64)))
       (list (exists (lambda (d) (starts? d "SCAN up")) plan)
             (exists (lambda (d) (and (starts? d "SEARCH n ") (contains? d "USING INDEX sqlite_autoindex_nodes_1 (id=?)"))) plan)
             (exists (lambda (d) (contains? d "nodes_parent")) plan)
             (exists (lambda (d) (contains? d "(owner=?)")) plan))))))

(test-equal "ancestors: the cap is in the statement itself"
  #t
  (attempt
   (lambda ()
     (let ((s (statement-of 'ancestors)))
       (and (contains? s "WITH RECURSIVE up") (contains? s " FROM up CROSS JOIN nodes n WHERE n.id = up.id AND n.owner = ?")
            (contains? s "up.depth < ?") (contains? s "LIMIT ?"))))))

;;; The owner term in the walk's recursive step

(test-equal "ancestors: a walk for A from A's node under B's chain stops at B's row: the step's owner term; (2), never (2 1)"
  '(2)
  (attempt
   (lambda ()
     (with-store "anc-owner.db"
       (lambda (w r p)
         ;; B's 1; B's 2 under 1; A's 3 under B's 2 (the foreign key takes it)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx (nidn 1) acct-b "project" "t" "b" "a/a" "{}" #f '() 10)
              (insert-node! tx (nidn 2) acct-b "project" "t" "b" "a/a" "{}" (nidn 1) '() 10)
              (insert-node! tx (nidn 3) acct-a "project" "t" "b" "a/a" "{}" (nidn 2) '() 10)))
         (ancestor-nums r acct-a (nidn 3) 64))))))

;;; The bulk move's statements and the pure rule

(test-equal "children-heads: with the filter child-kind-filter names, a child is answered exactly when child-moves? says it moves: every state x every kind x the top level, a Project and a Journal"
  '(("top" any #t #t) ("project" any #t #t) ("journal" "note" #t #t))
  (attempt
   (lambda ()
     (let* ((states '(active archived trashed))
            (combos (apply append (map (lambda (st) (map (lambda (k) (cons st k)) node-kinds)) states)))
            (child-id (lambda (i) (nid (+ 10 i)))))
       (with-store "heads-rule.db"
         (lambda (w r p)
           (w (lambda (tx)
                (set-up! tx)
                (insert-node! tx (nid 1) acct-a "project" "t" "b" "a/a" "{}" #f '() 10)
                (let loop ((cs combos) (i 0))
                  (unless (null? cs)
                    (insert-node! tx (child-id i) acct-a (cdar cs) "t" "b" "a/a" "{}" (nid 1) '() 10)
                    (case (caar cs)
                      ((archived) (set-node-state! tx (child-id i) acct-a 1 "archived" "archive" 11))
                      ((trashed) (set-node-state! tx (child-id i) acct-a 1 "trashed" "trash" 11)))
                    (loop (cdr cs) (+ i 1))))))
           (let* ((idx (lambda (ids) (map (lambda (b) (- (bytevector-u8-ref b 0) 10)) ids)))
                  (results
                   (map (lambda (pk)
                          (let* ((answer (idx (map car (ok-of (r (lambda (tx) (children-heads tx acct-a (nid 1) (child-kind-filter pk) 1000)))))))
                                 (expected (let loop ((cs combos) (i 0) (acc '()))
                                             (cond ((null? cs) (reverse acc))
                                                   ((child-moves? (caar cs) (cdar cs) pk) (loop (cdr cs) (+ i 1) (cons i acc)))
                                                   (else (loop (cdr cs) (+ i 1) acc))))))
                            (list (if pk pk "top") (child-kind-filter pk) (equal? answer expected) (> (length expected) 0))))
                        (list #f "project" "journal"))))
             ;; per parent: its filter, the answer equals the rule's, the rule moves some child
             results)))))))

;;; Pages by parent need no sort

(test-equal "statements: a page of a parent's children and a page of the top level need no sort: no TEMP B-TREE, each searches nodes_parent"
  '((#t #t) (#t #t) (#t #t) (#t #t))
  (attempt
   (lambda ()
     (let ((p (fresh "plan-pages-nosort.db")))
       (map (lambda (plan)
              (list (not (exists (lambda (d) (contains? d "TEMP B-TREE")) plan))
                    (exists (lambda (d) (contains? d "nodes_parent")) plan)))
            (list (plan-of p (statement-of 'nodes-page-of) acct-a "active" A1 5)
                  (plan-of p (statement-of 'nodes-page-of-after) acct-a "active" A1 A2 5)
                  (plan-of p (statement-of 'nodes-page-top) acct-a "active" 5)
                  (plan-of p (statement-of 'nodes-page-top-after) acct-a "active" A1 5)))))))

;;; has-children? and count-children

(test-equal "has-children?, count-children: none; some, trashed and archived counted; a purged child and another owner's not"
  '((#t 4) (#f 0) (#t 1) (#f 0) (#f 0) (#f 0))
  (attempt
   (lambda ()
     (with-store "children-count.db"
       (lambda (w r p)
         (w tree-set-up!)
         ;; node 8 under 7, trashed then purged: its parent is cleared
         (w (lambda (tx) (insert-node! tx (nid 8) acct-a "note" "t" "b" "a/a" "{}" (nid 7) '() 11)
                         (set-node-state! tx (nid 8) acct-a 1 "trashed" "trash" 12)
                         (purge-node! tx (nid 8) acct-a 2 13)))
         ;; node 9 at the top with only B's child
         (w (lambda (tx) (insert-node! tx (nid 9) acct-a "project" "t" "b" "a/a" "{}" #f '() 11)
                         (insert-node! tx (nid 22) acct-b "note" "t" "b" "a/a" "{}" (nid 9) '() 11)))
         (let ((both (lambda (owner id)
                       (ok-of (r (lambda (tx) (list (has-children? tx owner id) (count-children tx owner id))))))))
           (list (both acct-a (nid 1)) (both acct-a (nid 5)) (both acct-a (nid 2))
                 (both acct-a (nid 7)) (both acct-a (nid 9)) (both acct-a (nid 99)))))))))

(test-equal "has-children?, count-children: B's own rows under A's node are B's to count; A sees four there, B one"
  '((4 #t) (1 #t))
  (attempt
   (lambda ()
     (with-store "children-owner.db"
       (lambda (w r p)
         (w tree-set-up!)
         (list (ok-of (r (lambda (tx) (list (count-children tx acct-a (nid 1)) (has-children? tx acct-a (nid 1))))))
               (ok-of (r (lambda (tx) (list (count-children tx acct-b (nid 1)) (has-children? tx acct-b (nid 1))))))))))))

(test-equal "has-children?, count-children: each plan is one search of the covering index nodes_parent"
  '(#t #t)
  (attempt
   (lambda ()
     (let ((p (fresh "plan-children.db")))
       (map (lambda (name)
              (let ((plan (plan-of p (statement-of name) acct-a A1)))
                (and (= (length plan) 1) (starts? (car plan) "SEARCH ")
                     (contains? (car plan) "USING COVERING INDEX nodes_parent")
                     (contains? (car plan) "owner=? AND parent=?"))))
            '(has-children count-children))))))

;;; children-heads

(define (heads-of r owner parent kind n)
  (ok-of (r (lambda (tx) (map (lambda (h) (cons (bytevector-u8-ref (car h) 0) (cdr h))) (children-heads tx owner parent kind n))))))

(test-equal "children-heads: only active and archived; the kind filter; id order; the cap n; another owner's not"
  '(((2 . 1) (3 . 2) (5 . 1)) ((2 . 1) (5 . 1)) ((3 . 2)) () ((2 . 1) (3 . 2)) ((6 . 1)) ())
  (attempt
   (lambda ()
     (with-store "heads.db"
       (lambda (w r p)
         (w tree-set-up!)
         (list (heads-of r acct-a (nid 1) 'any 10)
               (heads-of r acct-a (nid 1) "note" 10)
               (heads-of r acct-a (nid 1) "task" 10)
               (heads-of r acct-a (nid 1) "journal" 10)
               (heads-of r acct-a (nid 1) 'any 2)
               (heads-of r acct-a (nid 2) 'any 10)
               (heads-of r acct-b (nid 20) 'any 10)))))))

(test-equal "children-heads: B's own child of A's node is B's to see"
  '(() ((21 . 1)))
  (attempt
   (lambda ()
     (with-store "heads-owner.db"
       (lambda (w r p)
         (w tree-set-up!)
         (list (heads-of r acct-a (nid 20) 'any 10)
               (heads-of r acct-b (nid 1) 'any 10)))))))

(test-equal "children-heads: 1,000 trashed children whose ids sort first and 5 active after them, asked with 1000, answers the 5"
  '(5 5 0)
  (attempt
   (lambda ()
     (with-store "heads-many.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx (nidn 1) acct-a "project" "t" "b" "a/a" "{}" #f '() 10)
              (do ((i 100 (+ i 1))) ((= i 1100))
                (insert-node! tx (nidn i) acct-a "note" "t" "b" "a/a" "{}" (nidn 1) '() 10))
              (tx-execute! tx "UPDATE nodes SET state = 'trashed' WHERE parent = ?" (nidn 1))
              (do ((i 2000 (+ i 1))) ((= i 2005))
                (insert-node! tx (nidn i) acct-a "note" "t" "b" "a/a" "{}" (nidn 1) '() 10))))
         (list (length (ok-of (r (lambda (tx) (children-heads tx acct-a (nidn 1) 'any 1000)))))
               (length (ok-of (r (lambda (tx) (children-heads tx acct-a (nidn 1) "note" 1000)))))
               (length (ok-of (r (lambda (tx) (children-heads tx acct-a (nidn 1) "task" 1000)))))))))))

;;; move-node!

(test-equal "move-node!: revision + 1, updated, one move change row, no snapshot; the rest of the row untouched; the body still the newest snapshot's; to #f and back"
  (list (list (nid 5) acct-a acct-a "note" "T5b" #f "text/plain" "{\"a\":1}" 3 10 500 "active" (nid 7))
        '(3 500) (list 3 "move") '(1 2)
        (list "T5b" "B5b" "text/plain" (nid 7) 3)
        (list (nid 5) acct-a acct-a "note" "T5b" #f "text/plain" "{\"a\":1}" 4 10 600 "active" #f)
        (list 4 "move") '(1 2) #f #t)
  (attempt
   (lambda ()
     (with-store "move.db"
       (lambda (w r p)
         (w tree-set-up!)
         (w (lambda (tx) (write-node! tx (nid 5) acct-a 1 "T5b" "B5b" "text/plain" "{\"a\":1}" 'keep "update" 100)))
         (let* ((full (lambda (n) (append (node->list n) (list (node-state n) (node-parent n)))))
                (m1 (ok-of (w (lambda (tx) (full (move-node! tx (nid 5) acct-a 2 (nid 7) 500))))))
                (row1 (ok-of (r (lambda (tx) (let ((n (node-of-owner tx acct-a (nid 5))))
                                                (list (node-title n) (node-body n) (node-content-type n) (node-parent n) (node-revision n)))))))
                (c1 (ok-of (r (lambda (tx) (let ((c (car (reverse (changes-of tx acct-a))))) (list (caddr c) (cadddr c)))))))
                (snaps1 (ok-of (r (lambda (tx) (map car (raw tx "SELECT revision FROM revisions WHERE node = ? ORDER BY revision" (nid 5)))))))
                (m2 (ok-of (w (lambda (tx) (full (move-node! tx (nid 5) acct-a 3 #f 600))))))
                (c2 (ok-of (r (lambda (tx) (let ((c (car (reverse (changes-of tx acct-a))))) (list (caddr c) (cadddr c)))))))
                (snaps2 (ok-of (r (lambda (tx) (map car (raw tx "SELECT revision FROM revisions WHERE node = ? ORDER BY revision" (nid 5)))))))
                (back (ok-of (r (lambda (tx) (raw-parent tx (nid 5)))))))
           (list m1 (list (list-ref row1 4) 500)
                 c1 snaps1 row1 m2 c2 snaps2 back
                 (equal? (ok-of (r (lambda (tx) (node-head tx acct-a (nid 5))))) (list 4 "note" "active" #f)))))))))

(test-equal "move-node!: an archived node moves and stays archived; the author and created stay"
  '("archived" 3 #t 10)
  (attempt
   (lambda ()
     (with-store "move-archived.db"
       (lambda (w r p)
         (w tree-set-up!)
         (let ((n (ok-of (w (lambda (tx) (move-node! tx (nid 3) acct-a 2 (nid 7) 500))))))
           (list (node-state n) (node-revision n) (equal? (node-author n) acct-a) (node-created n))))))))

(test-equal "move-node!: a stale revision, another owner, a trashed node and a purged one each raise with the id and the revision only, and change nothing"
  (list (list (list 'raised (list (nid 5) 9)) #t)
        (list (list 'raised (list (nid 5) 1)) #t)
        (list (list 'raised (list (nid 4) 2)) #t)
        (list (list 'raised (list (nid 8) 3)) #t))
  (attempt
   (lambda ()
     (with-store "move-refused.db"
       (lambda (w r p)
         (w tree-set-up!)
         (w (lambda (tx) (insert-node! tx (nid 8) acct-a "note" "t" "b" "a/a" "{}" (nid 7) '() 11)
                         (set-node-state! tx (nid 8) acct-a 1 "trashed" "trash" 12)
                         (purge-node! tx (nid 8) acct-a 2 13)))
         (map (lambda (res) (list (raised-with (car res)) (cadr res)))
              (ok-of (w (lambda (tx)
                          (list (nothing-changes tx (lambda () (move-node! tx (nid 5) acct-a 9 (nid 7) 40)))
                                (nothing-changes tx (lambda () (move-node! tx (nid 5) acct-b 1 (nid 7) 40)))
                                (nothing-changes tx (lambda () (move-node! tx (nid 4) acct-a 2 (nid 7) 40)))
                                (nothing-changes tx (lambda () (move-node! tx (nid 8) acct-a 3 (nid 7) 40)))))))))))))

(test-equal "move-node!: what it raises names no text of the node"
  #f
  (attempt
   (lambda ()
     (with-store "move-text.db"
       (lambda (w r p)
         (w tree-set-up!)
         (let ((c (ok-of (w (lambda (tx) (caught (lambda () (move-node! tx (nid 5) acct-a 9 (nid 7) 40))))))))
           (or (contains? (caddr c) "T5") (contains? (caddr c) "B5"))))))))

(test-equal "purge-node!: leaves parent NULL, and the old parent has no children from it"
  '(#t #f 0)
  (attempt
   (lambda ()
     (with-store "purge-parent.db"
       (lambda (w r p)
         (w tree-set-up!)
         (w (lambda (tx) (insert-node! tx (nid 8) acct-a "note" "t" "b" "a/a" "{}" (nid 7) '() 11)
                         (set-node-state! tx (nid 8) acct-a 1 "trashed" "trash" 12)))
         (let ((before (ok-of (r (lambda (tx) (raw-parent tx (nid 8)))))))
           (w (lambda (tx) (purge-node! tx (nid 8) acct-a 2 13)))
           (list (equal? before (nid 7))
                 (ok-of (r (lambda (tx) (raw-parent tx (nid 8)))))
                 (ok-of (r (lambda (tx) (count-children tx acct-a (nid 7))))))))))))

;;; The tables' checks

(define (refused-insert name . args)
  (attempt
   (lambda ()
     (with-store name
       (lambda (w r p)
         (w set-up!)
         (let ((res (w (lambda (tx) (let ((k (- (length args) 1))) (apply insert-node! tx (append (reverse (cdr (reverse args))) (list #f '() (car (reverse args))))))))))
           (list res (ok-of (r (lambda (tx) (list (count-of tx "nodes") (count-of tx "revisions") (count-of tx "changes"))))))))))))

(test-equal "checks: a 15-byte id is refused, and nothing is left"
  '((raised (sqlite constraint)) (0 0 0))
  (refused-insert "c-id.db" (bv 15 1) acct-a "note" "t" "b" "a/a" "{}" 1))
(test-equal "checks: an unknown kind is refused"
  '((raised (sqlite constraint)) (0 0 0))
  (refused-insert "c-kind.db" A1 acct-a "folder" "t" "b" "a/a" "{}" 1))
(test-equal "checks: a title of 1001 characters is refused, 1000 is not"
  '(((raised (sqlite constraint)) (0 0 0)) #t)
  (list (refused-insert "c-title.db" A1 acct-a "note" (make-string 1001 #\t) "b" "a/a" "{}" 1)
        (let ((r (refused-insert "c-title2.db" A1 acct-a "note" (make-string 1000 #\t) "b" "a/a" "{}" 1)))
          (and (pair? r) (eq? 'ok (car (car r))) #t))))
(test-equal "checks: an empty content type is refused"
  '((raised (sqlite constraint)) (0 0 0))
  (refused-insert "c-ct.db" A1 acct-a "note" "t" "b" "" "{}" 1))
(test-equal "checks: props that are not JSON are refused"
  '((raised (sqlite constraint)) (0 0 0))
  (refused-insert "c-props.db" A1 acct-a "note" "t" "b" "a/a" "{nope" 1))
(test-equal "checks: props that are not JSON are refused by the node's own table, not only by its snapshot's"
  '((raised (sqlite constraint)) 0)
  (attempt
   (lambda ()
     (with-store "c-props-raw.db"
       (lambda (w r p)
         (w set-up!)
         (list (w (lambda (tx)
                    (tx-execute! tx "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated) VALUES (?, ?, ?, 'note', 't', 'a/a', '{nope', 1, 1, 1)" A1 acct-a acct-a)))
               (ok-of (r (lambda (tx) (count-of tx "nodes"))))))))))
(test-equal "checks: revision 0 is refused"
  '((raised (sqlite constraint)) 0)
  (attempt
   (lambda ()
     (with-store "c-rev.db"
       (lambda (w r p)
         (w set-up!)
         (list (w (lambda (tx)
                    (tx-execute! tx "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated) VALUES (?, ?, ?, 'note', 't', 'a/a', '{}', 0, 1, 1)" A1 acct-a acct-a)))
               (ok-of (r (lambda (tx) (count-of tx "nodes"))))))))))

;;; Links (slice 5b)

;; link-set-up! : Tx -> Void
;; A's nodes 1 to 6 and B's 20 and 21, times 10. Then A's links, `created`
;; 100 up, each at revision 1 as the job read it:
;;   out of 1: blocks 2 (101), mentions 3 (102), mentions 5 (106), related 2
;;             (103), related 4 (104), related 5 (105)
;;   into 1:   related from 2 (110), blocks from 3 (111), related from 5
;;             (112), mentions from 6 (113)
;;   others:   2 -> 3 related (120); B's 20 -> 21 related (130)
;; Then node 3 is trashed and node 4 archived.
(define (link-set-up! tx)
  (set-up! tx)
  (for-each (lambda (n) (insert-node! tx (nid n) acct-a "note" (string-append "T" (number->string n))
                                      (string-append "B" (number->string n)) "a/a" "{}" #f '() 10))
            '(1 2 3 4 5 6))
  (insert-node! tx (nid 20) acct-b "note" "T20" "B20" "a/a" "{}" #f '() 10)
  (insert-node! tx (nid 21) acct-b "note" "T21" "B21" "a/a" "{}" #f '() 10)
  (for-each (lambda (l) (insert-link! tx acct-a (nid (car l)) (cadr l) (nid (caddr l)) 1 (cadddr l)))
            '((1 "blocks" 2 101) (1 "mentions" 3 102) (1 "related" 2 103) (1 "related" 4 104)
              (1 "related" 5 105) (1 "mentions" 5 106)
              (2 "related" 1 110) (3 "blocks" 1 111) (5 "related" 1 112) (6 "mentions" 1 113)
              (2 "related" 3 120)))
  (insert-link! tx acct-b (nid 20) "related" (nid 21) 1 130)
  (set-node-state! tx (nid 3) acct-a 1 "trashed" "trash" 20)
  (set-node-state! tx (nid 4) acct-a 1 "archived" "archive" 20))

;; link-rows : Tx -> (Listof (List ...))     every row of links, in key order
(define (link-rows tx)
  (raw tx "SELECT owner, source, type, target, created FROM links ORDER BY owner, source, type, target"))

;; item->list : (List String Natural Node) -> (List String Natural Natural String String)
;; (type created first-byte-of-id state title)
(define (item->list i)
  (list (car i) (cadr i) (bytevector-u8-ref (node-id (caddr i)) 0)
        (node-state (caddr i)) (node-title (caddr i))))

;; page-all : (Proc Job -> A) Bytevector Bytevector (U 'out 'in) (U String #f)
;;            Natural -> (Listof (List ...))
;; Every page of the list at limit N, each from the cursor the last item
;; makes, to the end, as item->list. At most 200 pages.
(define (page-all r owner node dir type n)
  (let loop ((cursor #f) (acc '()) (k 0))
    (let ((page (ok-of (r (lambda (tx) (links-page tx owner node dir type cursor n))))))
      (cond ((or (not (list? page)) (null? page) (> k 200)) (if (list? page) (reverse acc) page))
            (else
             (let ((last (car (reverse page))))
               (loop (cons (car last) (node-id (caddr last)))
                     (append (reverse (map item->list page)) acc)
                     (+ k 1))))))))

(define out-all
  '(("blocks" 101 2 "active" "T2") ("mentions" 102 3 "trashed" "T3") ("mentions" 106 5 "active" "T5")
    ("related" 103 2 "active" "T2") ("related" 104 4 "archived" "T4") ("related" 105 5 "active" "T5")))
(define in-all
  '(("blocks" 111 3 "trashed" "T3") ("mentions" 113 6 "active" "T6")
    ("related" 110 2 "active" "T2") ("related" 112 5 "active" "T5")))

(test-equal "link-of: the link's created; #f for another type, target, source, or owner; the key alone finds it"
  (list 103 #f #f #f #f 130 #f)
  (attempt
   (lambda ()
     (with-store "link-of.db"
       (lambda (w r p)
         (w link-set-up!)
         (let ((of (lambda (o s t g) (ok-of (r (lambda (tx) (link-of tx o (nid s) t (nid g))))))))
           (list (of acct-a 1 "related" 2) (of acct-a 1 "blocks" 3) (of acct-a 1 "related" 3)
                 (of acct-a 2 "related" 2) (of acct-b 1 "related" 2)
                 (of acct-b 20 "related" 21) (of acct-a 20 "related" 21))))))))

(test-equal "insert-link!: one link row, created kept as given; one change row link on the SOURCE at the revision given (not the node's), the owner's next seq; no row of nodes or revisions changed"
  (list #t 777 1 (list 1 "link" 5 777) 'unchanged #t)
  (attempt
   (lambda ()
     (with-store "link-insert.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                         (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 10)
                         (insert-node! tx A2 acct-a "note" "T2" "B2" "a/a" "{}" #f '() 10)))
         (let* ((before (ok-of (r (lambda (tx) (list (raw tx "SELECT * FROM nodes ORDER BY num")
                                                      (raw tx "SELECT * FROM revisions ORDER BY node, revision"))))))
                (cbefore (ok-of (r (lambda (tx) (length (changes-of tx acct-a))))))
                (res (w (lambda (tx) (insert-link! tx acct-a A1 "related" A2 5 777))))
                (changes (ok-of (r (lambda (tx) (changes-of tx acct-a)))))
                (last (car (reverse changes))))
           (list (eq? (car res) 'ok)
                 (ok-of (r (lambda (tx) (link-of tx acct-a A1 "related" A2))))
                 (ok-of (r (lambda (tx) (count-of tx "links"))))
                 (list (- (length changes) cbefore) (cadddr last) (caddr last) (list-ref last 4))
                 (if (equal? before (ok-of (r (lambda (tx) (list (raw tx "SELECT * FROM nodes ORDER BY num")
                                                                   (raw tx "SELECT * FROM revisions ORDER BY node, revision"))))))
                     'unchanged 'changed)
                 (and (equal? (cadr last) A1) #t))))))))

(test-equal "insert-link!: the change row's owner is the link's owner (B's link, B's seq 3: its two creates, then the link)"
  '(3 "link" 1)
  (attempt
   (lambda ()
     (with-store "link-insert-owner.db"
       (lambda (w r p)
         (w link-set-up!)
         (let ((c (ok-of (r (lambda (tx) (changes-of tx acct-b))))))
           (let ((l (car (reverse c)))) (list (car l) (cadddr l) (caddr l)))))))))

(test-equal "insert-link!: the same link twice raises, in its own job: one link row, one link change row, nothing new in the second; the raise names no title or body"
  (list 'raised 1 1 #f)
  (attempt
   (lambda ()
     (with-store "link-twice.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                         (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 10)
                         (insert-node! tx A2 acct-a "note" "T2" "B2" "a/a" "{}" #f '() 10)
                         (insert-link! tx acct-a A1 "related" A2 1 50)))
         (let* ((second (w (lambda (tx) (insert-link! tx acct-a A1 "related" A2 1 60))))
                (text (caddr (ok-of (w (lambda (tx) (caught (lambda () (insert-link! tx acct-a A1 "related" A2 1 60)))))))))
           (list (car second)
                 (ok-of (r (lambda (tx) (count-of tx "links"))))
                 (ok-of (r (lambda (tx) (length (filter (lambda (c) (string=? (cadddr c) "link")) (changes-of tx acct-a))))))
                 (or (contains? text "T1") (contains? text "B1") (contains? text "T2") (contains? text "B2")))))))))

(test-equal "insert-link!: a second link of the same ends and another type is a second link; the same type from the other end too"
  '(3 3)
  (attempt
   (lambda ()
     (with-store "link-twins.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                         (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f '() 10)
                         (insert-node! tx A2 acct-a "note" "T2" "B2" "a/a" "{}" #f '() 10)
                         (insert-link! tx acct-a A1 "related" A2 1 50)
                         (insert-link! tx acct-a A1 "blocks" A2 1 50)
                         (insert-link! tx acct-a A2 "related" A1 1 50)))
         (list (ok-of (r (lambda (tx) (count-of tx "links"))))
               (ok-of (r (lambda (tx) (length (filter (lambda (c) (string=? (cadddr c) "link")) (changes-of tx acct-a))))))))))))

(test-equal "delete-link!: removes that link only; a change row unlink on the source at the revision given; the others and their created kept; no node row changed"
  (list 1 '(#f 101 104 111) 1 (list "unlink" 7 (nid 1) 400) #t)
  (attempt
   (lambda ()
     (with-store "link-delete.db"
       (lambda (w r p)
         (w link-set-up!)
         (let* ((nodes-before (ok-of (r (lambda (tx) (raw tx "SELECT * FROM nodes ORDER BY num")))))
                (cb (ok-of (r (lambda (tx) (length (changes-of tx acct-a))))))
                (links-before (ok-of (r (lambda (tx) (count-of tx "links")))))
                (res (w (lambda (tx) (delete-link! tx acct-a (nid 1) "related" (nid 2) 7 400))))
                (cs (ok-of (r (lambda (tx) (changes-of tx acct-a)))))
                (l (car (reverse cs)))
                (of (lambda (s t g) (ok-of (r (lambda (tx) (link-of tx acct-a (nid s) t (nid g))))))))
           (list (- links-before (ok-of (r (lambda (tx) (count-of tx "links")))))
                 (list (of 1 "related" 2) (of 1 "blocks" 2) (of 1 "related" 4) (of 3 "blocks" 1))
                 (- (length cs) cb)
                 (list (cadddr l) (caddr l) (cadr l) (list-ref l 4))
                 (equal? nodes-before (ok-of (r (lambda (tx) (raw tx "SELECT * FROM nodes ORDER BY num"))))))))))))

(test-equal "delete-link!: a link that is not there (another type, target, source, owner) raises with the two ids only, writes no change row and no link row"
  (list (list (list 'raised (list (nid 1) (nid 2)) #t)) 4)
  (attempt
   (lambda ()
     (with-store "link-delete-absent.db"
       (lambda (w r p)
         (w link-set-up!)
         (let ((res (ok-of (w (lambda (tx)
                                (let ((before (list (link-rows tx) (changes-of tx acct-a) (changes-of tx acct-b))))
                                  (map (lambda (thunk)
                                         (let ((c (caught thunk)))
                                           (list (car c) (cadr c)
                                                 (equal? before (list (link-rows tx) (changes-of tx acct-a) (changes-of tx acct-b))))))
                                       (list (lambda () (delete-link! tx acct-a (nid 1) "mentions" (nid 2) 1 400))
                                             (lambda () (delete-link! tx acct-a (nid 1) "related" (nid 3) 1 400))
                                             (lambda () (delete-link! tx acct-a (nid 4) "related" (nid 2) 1 400))
                                             (lambda () (delete-link! tx acct-b (nid 1) "related" (nid 2) 1 400))))))))))
           (list (list (list (car (car res)) (list (nid 1) (nid 2)) (caddr (car res))))
                 (length (filter (lambda (x) (and (eq? (car x) 'raised) (caddr x))) res)))))))))

(test-equal "links-page: out and in, untyped and typed, every link once and in order (type, then the other end's id), at limits 1, 2, 3, 4 and 100"
  (list out-all
        '(("related" 103 2 "active" "T2") ("related" 104 4 "archived" "T4") ("related" 105 5 "active" "T5"))
        '(("mentions" 102 3 "trashed" "T3") ("mentions" 106 5 "active" "T5"))
        in-all
        '(("related" 110 2 "active" "T2") ("related" 112 5 "active" "T5"))
        '() '())
  (attempt
   (lambda ()
     (with-store "links-pages.db"
       (lambda (w r p)
         (w link-set-up!)
         (let ((each (lambda (owner node dir type)
                       (let ((ans (map (lambda (n) (page-all r owner node dir type n)) '(1 2 3 4 100))))
                         (if (for-all (lambda (a) (equal? a (car ans))) ans) (car ans) (list 'differ ans))))))
           (list (each acct-a (nid 1) 'out #f)
                 (each acct-a (nid 1) 'out "related")
                 (each acct-a (nid 1) 'out "mentions")
                 (each acct-a (nid 1) 'in #f)
                 (each acct-a (nid 1) 'in "related")
                 (each acct-a (nid 1) 'out "nonesuch")
                 (each acct-a (nid 4) 'out #f))))))))

(test-equal "links-page: the other end's state and title as they are now; a write to the node shows; a link is listed from a trashed node as well"
  (list '("related" 103 2 "active" "T2 now") '("related" 104 4 "trashed" "T4")
        '(("related" 110 1 "active" "T1") ("related" 120 3 "trashed" "T3"))
        '(("mentions" 102 1 "active" "T1") ("related" 120 2 "active" "T2 now")))
  (attempt
   (lambda ()
     (with-store "links-now.db"
       (lambda (w r p)
         (w link-set-up!)
         (w (lambda (tx)
              (write-node! tx (nid 2) acct-a 1 "T2 now" "B2 now" "a/a" "{}" 'keep "update" 200)
              (set-node-state! tx (nid 4) acct-a 2 "trashed" "trash" 210)))
         (let ((out (page-all r acct-a (nid 1) 'out "related" 100)))
           (list (car out) (cadr out)
                 (page-all r acct-a (nid 2) 'out #f 100)
                 (page-all r acct-a (nid 3) 'in #f 100))))))))

(test-equal "links-page: the page's Node is the small row, body #f, with every column of the node's own"
  (list #f (list (nid 2) acct-a acct-a "note" "T2" "a/a" "{}" 1 10 10 "active" #f))
  (attempt
   (lambda ()
     (with-store "links-node.db"
       (lambda (w r p)
         (w link-set-up!)
         (let ((n (caddr (car (ok-of (r (lambda (tx) (links-page tx acct-a (nid 1) 'out "blocks" #f 5))))))))
           (list (node-body n)
                 (list (node-id n) (node-owner n) (node-author n) (node-kind n) (node-title n) (node-content-type n)
                       (node-props n) (node-revision n) (node-created n) (node-updated n) (node-state n) (node-parent n)))))))))

(test-equal "links-page: another account's links are never shown: B's link rows on A's node, and A's link rows to B's node, so A's two lists are as without them; B sees only its own"
  (list out-all in-all '(("related" 130 21 "active" "T21")) '(("related" 130 20 "active" "T20")))
  (attempt
   (lambda ()
     (with-store "links-owner.db"
       (lambda (w r p)
         (w link-set-up!)
         ;; made by hand: B's link whose source is A's node 1 to B's 20; A's link from 1 to B's 20 and from B's 21 to 1
         (w (lambda (tx)
              (tx-execute! tx "INSERT INTO links(owner, source, type, target, created) VALUES (?, ?, 'blocks', ?, 140)" acct-b (nid 1) (nid 20))
              (tx-execute! tx "INSERT INTO links(owner, source, type, target, created) VALUES (?, ?, 'blocks', ?, 141)" acct-a (nid 1) (nid 20))
              (tx-execute! tx "INSERT INTO links(owner, source, type, target, created) VALUES (?, ?, 'blocks', ?, 142)" acct-a (nid 21) (nid 1))))
         (list (page-all r acct-a (nid 1) 'out #f 100)
               (page-all r acct-a (nid 1) 'in #f 100)
               (page-all r acct-b (nid 20) 'out #f 100)
               (page-all r acct-b (nid 21) 'in #f 100)))))))

(test-equal "links-page: a link whose other end is purged is not listed, by each of the four statements (a link row made by hand: a purge deletes them)"
  '((("related" 104 4 "archived" "T4") ("related" 105 5 "active" "T5"))
    (("mentions" 102 3 "trashed" "T3") ("mentions" 106 5 "active" "T5")
     ("related" 104 4 "archived" "T4") ("related" 105 5 "active" "T5"))
    (("related" 112 5 "active" "T5"))
    (("blocks" 111 3 "trashed" "T3") ("mentions" 113 6 "active" "T6") ("related" 112 5 "active" "T5")))
  (attempt
   (lambda ()
     (with-store "links-purged-end.db"
       (lambda (w r p)
         (w link-set-up!)
         (w (lambda (tx) (tx-execute! tx "UPDATE nodes SET state = 'purged' WHERE id = ?" (nid 2))))
         (list (page-all r acct-a (nid 1) 'out "related" 100)
               (page-all r acct-a (nid 1) 'out #f 100)
               (page-all r acct-a (nid 1) 'in "related" 100)
               (page-all r acct-a (nid 1) 'in #f 100)))))))

(test-equal "links-page: a purge of a node's other end takes its links, so the page then lacks them, through purge-node!"
  (list '(("related" 104 4 "archived" "T4") ("related" 105 5 "active" "T5")) '(("related" 112 5 "active" "T5")))
  (attempt
   (lambda ()
     (with-store "links-purged-real.db"
       (lambda (w r p)
         (w link-set-up!)
         (w (lambda (tx) (set-node-state! tx (nid 2) acct-a 1 "trashed" "trash" 20)
                         (purge-node! tx (nid 2) acct-a 2 30)))
         (list (page-all r acct-a (nid 1) 'out "related" 100)
               (page-all r acct-a (nid 1) 'in "related" 100)
               ))))))

(test-equal "links-page: a direction that is neither out nor in raises"
  'raised
  (attempt
   (lambda ()
     (with-store "links-dir.db"
       (lambda (w r p)
         (w link-set-up!)
         (car (r (lambda (tx) (links-page tx acct-a (nid 1) 'sideways #f #f 5)))))))))

;;; The plans of the four page statements, held whole

;; link-plan : Symbol -> (Listof String)
;; The plan of a page statement on a fresh file with no sqlite_stat1.
(define (link-plan name)
  (let ((p (fresh (string-append "plan-" (symbol->string name) ".db")))
        (zero (bv 16 0)))
    (case name
      ((links-out links-in) (plan-of p (statement-of name) acct-a A1 "" zero 5))
      (else (plan-of p (statement-of name) acct-a A1 "related" zero 5)))))

(for-each
 (lambda (c)
   (test-equal (string-append "plan: " (symbol->string (car c)) " is exactly its two lines, its first as the plan decided; no temp b-tree")
     (list (list (cadr c) "SEARCH n USING INDEX nodes_owner (owner=? AND id=?)") #f)
     (attempt
      (lambda ()
        (let ((plan (link-plan (car c))))
          (list plan (exists (lambda (d) (contains? d "TEMP B-TREE")) plan)))))))
 '((links-out "SEARCH l USING PRIMARY KEY (owner=? AND source=? AND (type,target)>(?,?))")
   (links-out-typed "SEARCH l USING PRIMARY KEY (owner=? AND source=? AND type=? AND target>?)")
   (links-in "SEARCH l USING INDEX links_target (owner=? AND target=? AND (type,source)>(?,?))")
   (links-in-typed "SEARCH l USING INDEX links_target (owner=? AND target=? AND type=? AND source>?)")))

(test-equal "plan: the purge's delete by target searches links_target by owner and target; the delete by source, the primary key by owner and source"
  (list (list "SEARCH links USING INDEX links_target (owner=? AND target=?)")
        (list "SEARCH links USING PRIMARY KEY (owner=? AND source=?)"))
  (attempt
   (lambda ()
     ;; An older SQLite calls a delete's index a COVERING INDEX (seen in
     ;; 3.37.2 and in CI's 3.45.1, which failed this test as first written;
     ;; 3.53 says INDEX): the search
     ;; and its terms are the same, so the one word is dropped before the
     ;; comparison.
     (let ((p (fresh "plan-purge-links.db"))
           (plain (lambda (plan)
                    (map (lambda (line)
                           (let ((old "SEARCH links USING COVERING INDEX ")
                                 (new "SEARCH links USING INDEX "))
                             (if (and (>= (string-length line) (string-length old))
                                      (string=? (substring line 0 (string-length old)) old))
                                 (string-append new (substring line (string-length old)
                                                               (string-length line)))
                                 line)))
                         plan))))
       (list (plain (plan-of p (statement-of 'purge-links-target) acct-a A1))
             (plan-of p (statement-of 'purge-links-source) acct-a A1))))))

(test-equal "plan: link-of and delete-link by the whole key: one search of the primary key each"
  (list (list "SEARCH links USING PRIMARY KEY (owner=? AND source=? AND type=? AND target=?)")
        (list "SEARCH links USING PRIMARY KEY (owner=? AND source=? AND type=? AND target=?)"))
  (attempt
   (lambda ()
     (let ((p (fresh "plan-link-key.db")))
       (list (plan-of p (statement-of 'link-of) acct-a A1 "related" A2)
             (plan-of p (statement-of 'delete-link) acct-a A1 "related" A2))))))

(test-equal "statements: the page statements' texts: an in statement names links_target and an out one never; a typed one has no row value; each is ordered, joins the node's owner and leaves a purged node out"
  '(#t #t #t #t)
  (attempt
   (lambda ()
     (map (lambda (name)
            (let ((s (statement-of name)))
              (and s
                   (contains? s "ORDER BY")
                   (contains? s "n.owner = l.owner")
                   (contains? s "n.state <> 'purged'")
                   (contains? s " FROM links l ")
                   (contains? s " CROSS JOIN nodes n ")
                   (eq? (and (contains? s "INDEXED BY links_target") #t) (and (memq name '(links-in links-in-typed)) #t))
                   (or (memq name '(links-out links-in)) (not (contains? s "(l.type")))
                   (not (contains? s "body")))))
          '(links-out links-out-typed links-in links-in-typed)))))

(test-equal "statements: the purge's delete by target names links_target; the one by source does not"
  '(#t #f)
  (attempt
   (lambda ()
     (list (contains? (statement-of 'purge-links-target) "INDEXED BY links_target")
           (contains? (statement-of 'purge-links-source) "INDEXED BY")))))

(test-equal "statements: insert-link is a plain INSERT and delete-link a plain DELETE: no OR, no ON CONFLICT; and the link statements are all listed"
  (list #f #f #t '(link-of insert-link delete-link links-out links-out-typed links-in links-in-typed
                   purge-links-source purge-links-target))
  (attempt
   (lambda ()
     (let ((s (statement-of 'insert-link)))
       (list (or (contains? s "OR IGNORE") (contains? s "OR REPLACE") (contains? s "OR "))
             (contains? s "ON CONFLICT")
             (starts? (statement-of 'delete-link) "DELETE FROM links WHERE owner = ?")
             (filter (lambda (n) (contains? (statement-of n) "links"))
                     (map car node-store-statements)))))))

;;; purge-node! and a node's links

;; nodes-and-changes : Tx -> (List ...)
;; The rows of nodes and changes. Not revisions: a purge deletes the snapshots
;; first, and in its job they stay deleted until the job rolls back.
(define (nodes-and-changes tx)
  (list (raw tx "SELECT * FROM nodes ORDER BY num")
        (raw tx "SELECT owner, seq, node, revision, op, created FROM changes ORDER BY owner, seq")))

;; purge-fixture : Tx -> Void     link-set-up!, then node 1 is trashed (revision 2)
(define (purge-links-set-up! tx)
  (link-set-up! tx)
  (set-node-state! tx (nid 1) acct-a 1 "trashed" "trash" 30))

(test-equal "purge-node!: a node linked both ways loses every link of it and no other link; one purge change row however many; no other node's row changed"
  (list (list 12 2) '(0 0) '(((2 3 "related") . 1)) 1 "purge" #t)
  (attempt
   (lambda ()
     (with-store "purge-links.db"
       (lambda (w r p)
         ;; node 1 has 6 links out and 4 in; the others are A's 2 -> 3 and B's 20 -> 21
         (w purge-links-set-up!)
         (let* ((others-before (ok-of (r (lambda (tx) (raw tx "SELECT * FROM nodes WHERE id <> ? ORDER BY num" (nid 1))))))
                (n-before (ok-of (r (lambda (tx) (count-of tx "links")))))
                (cb (ok-of (r (lambda (tx) (length (changes-of tx acct-a))))))
                (res (w (lambda (tx) (purge-node! tx (nid 1) acct-a 2 40))))
                (cs (ok-of (r (lambda (tx) (changes-of tx acct-a)))))
                (l (car (reverse cs)))
                (left (ok-of (r (lambda (tx) (raw tx "SELECT source, target, type FROM links WHERE owner = ?" acct-a))))))
           (list (list n-before (ok-of (r (lambda (tx) (count-of tx "links")))))
                 (ok-of (r (lambda (tx) (list (length (raw tx "SELECT 1 FROM links WHERE source = ?" (nid 1)))
                                               (length (raw tx "SELECT 1 FROM links WHERE target = ?" (nid 1)))))))
                 (list (cons (list (bytevector-u8-ref (car (car left)) 0) (bytevector-u8-ref (cadr (car left)) 0) (caddr (car left)))
                             (length left)))
                 (- (length cs) cb)
                 (cadddr l)
                 (equal? others-before
                         (ok-of (r (lambda (tx) (raw tx "SELECT * FROM nodes WHERE id <> ? ORDER BY num" (nid 1)))))))))))))

(test-equal "purge-node!: a stale revision on a node with exactly one OUTGOING link raises as before; within the job the node is not purged and the link is still there (the deletes come after the check)"
  (list (list 'raised (list (nid 1) 1)) #t #t #t)
  (attempt
   (lambda ()
     (with-store "purge-stale-out.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                         (insert-node! tx (nid 1) acct-a "note" "T1" "B1" "a/a" "{}" #f '() 10)
                         (insert-node! tx (nid 2) acct-a "note" "T2" "B2" "a/a" "{}" #f '() 10)
                         (insert-link! tx acct-a (nid 1) "related" (nid 2) 1 50)
                         (set-node-state! tx (nid 1) acct-a 1 "trashed" "trash" 60)))
         (ok-of (w (lambda (tx)
                     (let* ((before (list (link-rows tx) (nodes-and-changes tx)))
                            (c (caught (lambda () (purge-node! tx (nid 1) acct-a 1 70)))))
                       (list (raised-with c)
                             (equal? (link-rows tx) (car before))
                             (equal? (nodes-and-changes tx) (cadr before))
                             (equal? (raw tx "SELECT state, revision FROM nodes WHERE id = ?" (nid 1)) '(("trashed" 2)))))))))))))

(test-equal "purge-node!: a stale revision on a node with exactly one INCOMING link raises as before and leaves the link (a delete placed before the check would let the check read the delete's count)"
  (list (list 'raised (list (nid 2) 1)) #t #t #t)
  (attempt
   (lambda ()
     (with-store "purge-stale-in.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                         (insert-node! tx (nid 1) acct-a "note" "T1" "B1" "a/a" "{}" #f '() 10)
                         (insert-node! tx (nid 2) acct-a "note" "T2" "B2" "a/a" "{}" #f '() 10)
                         (insert-link! tx acct-a (nid 1) "related" (nid 2) 1 50)
                         (set-node-state! tx (nid 2) acct-a 1 "trashed" "trash" 60)))
         (ok-of (w (lambda (tx)
                     (let* ((before (list (link-rows tx) (nodes-and-changes tx)))
                            (c (caught (lambda () (purge-node! tx (nid 2) acct-a 1 70)))))
                       (list (raised-with c)
                             (equal? (link-rows tx) (car before))
                             (equal? (nodes-and-changes tx) (cadr before))
                             (equal? (raw tx "SELECT state, revision FROM nodes WHERE id = ?" (nid 2)) '(("trashed" 2)))))))))))))

(test-equal "purge-node!: a node that is not trashed, and another owner's node, with links: each raises and keeps every link, within the job"
  (list 12 (list 'raised (list (nid 2) 1)) #t (list 'raised (list (nid 1) 2)) #t)
  (attempt
   (lambda ()
     (with-store "purge-refused-links.db"
       (lambda (w r p)
         (w purge-links-set-up!)
         (cons (ok-of (r (lambda (tx) (count-of tx "links"))))
          (ok-of (w (lambda (tx)
                     (let* ((b1 (link-rows tx))
                            (c1 (caught (lambda () (purge-node! tx (nid 2) acct-a 1 70))))
                            (k1 (equal? b1 (link-rows tx)))
                            (c2 (caught (lambda () (purge-node! tx (nid 1) acct-b 2 70))))
                            (k2 (equal? b1 (link-rows tx))))
                       (list (raised-with c1) k1 (raised-with c2) k2)))))))))))

;;; Tags (slice 7a)
;;;
;;; A node's present tags are its rows in node_tags; a snapshot's are a JSON
;;; array written from those rows by the snapshot's own INSERT. The laws are
;;; the plan's as its review restates them: L3 (a content write's snapshot
;;; holds the rows), L4 (keep changes no row), L5 (a step), L6 (another
;;; account), L7 (a purge), L9 (a row's owner is its node's), L11 (a restore)
;;; and L14 (every plan of the filter and the tags list). Ids sort by their
;;; first byte, so A's and B's nodes interleave by id: a statement that
;;; forgot the owner meets B's rows among A's.

;; tag-rows : Tx -> (Listof (List Bytevector String Bytevector))
;; Every row of node_tags, owner, tag, node, in key order.
(define (tag-rows tx) (raw tx "SELECT owner, tag, node FROM node_tags ORDER BY owner, tag, node"))

;; rows-of : Tx Bytevector -> (Listof String)    a node's rows, whatever their owner
(define (rows-of tx id) (map car (raw tx "SELECT tag FROM node_tags WHERE node = ? ORDER BY tag" id)))

;; snap-tags : Tx Bytevector Natural -> (U String #f)     a snapshot's tags column
(define (snap-tags tx id rev)
  (let ((r (raw tx "SELECT tags FROM revisions WHERE node = ? AND revision = ?" id rev)))
    (and (pair? r) (caar r))))

;; newest-tags : Tx Bytevector -> (U String #f)     the newest snapshot's tags column
(define (newest-tags tx id)
  (let ((r (raw tx "SELECT tags FROM revisions WHERE node = ? ORDER BY revision DESC LIMIT 1" id)))
    (and (pair? r) (caar r))))

;; heads : Tx -> (Listof (List Natural Natural Natural String))
;; Each node's first id byte, revision, updated and state, by id.
(define (heads tx)
  (map (lambda (r) (cons (bytevector-u8-ref (car r) 0) (cdr r)))
       (raw tx "SELECT id, revision, updated, state FROM nodes ORDER BY id")))

;; changes-after : Tx Bytevector Natural -> (List ...)
;; The owner's change rows past SEQ: seq, first id byte, revision, op, created.
(define (changes-after tx owner seq)
  (map (lambda (r) (list (car r) (bytevector-u8-ref (cadr r) 0) (caddr r) (cadddr r) (car (cddddr r))))
       (raw tx "SELECT seq, node, revision, op, created FROM changes WHERE owner = ? AND seq > ? ORDER BY seq" owner seq)))

;; owner-rows : Tx Bytevector -> (List ...)    an owner's rows of nodes, node_tags and changes
(define (owner-rows tx owner)
  (list (raw tx "SELECT id, revision, updated, state FROM nodes WHERE owner = ? ORDER BY id" owner)
        (raw tx "SELECT tag, node FROM node_tags WHERE owner = ? ORDER BY tag, node" owner)
        (raw tx "SELECT seq, node, revision, op, created FROM changes WHERE owner = ? ORDER BY seq" owner)))

;; misowned : Tx -> Natural     rows of node_tags whose owner is not their node's (L9)
(define (misowned tx)
  (vector-ref (tx-query-row tx "SELECT count(*) FROM node_tags t JOIN nodes n ON n.id = t.node WHERE n.owner <> t.owner") 0))

;; tags-json : (Listof String) -> String     json->string of the list, sorted
(define (tags-json ts) (json->string (list->vector (list-sort string<? ts))))

;; with-store-on : String ((Proc Job -> A) (Proc Job -> A) -> B) -> B
;; with-store's doorway on a file already made, at the shipped version.
(define (with-store-on p body)
  (let ((d (make-test-doorway p migrations 100)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (body (lambda (job) (in-host (lambda () (try (lambda () (db-write d job))))))
              (lambda (job) (in-host (lambda () (try (lambda () (db-read d job))))))))
      (lambda ()
        (guard (e (#t #f)) (doorway-stop-readers! d))
        (guard (e (#t #f)) (doorway-stop-writer! d))))))

;; iota* : Integer Integer -> (Listof Integer)     A to B, both in
(define (iota* a b) (if (> a b) '() (cons a (iota* (+ a 1) b))))

;; rolled-back : (Proc Job -> Any) (Tx -> Any) (Tx -> B) -> (U (List Any B) #f)
;; ACT in a write job; what it raised or answered, as `caught` has it, and
;; what PROBE reads after it in the same job; then the job raises, so the
;; doorway rolls it back and nothing of ACT is kept.
(define (rolled-back w act probe)
  (let ((seen #f))
    (w (lambda (tx)
         (let* ((c (caught (lambda () (act tx))))
                (p (probe tx)))
           (set! seen (list c p))
           (raise 'roll-back))))
    seen))

;; note! : Tx Bytevector Bytevector (Listof String) Natural -> Node    a note with TAGS
(define (note! tx id owner tags now)
  (insert-node! tx id owner "note" "T" "B" "a/a" "{}" #f tags now))

;;; A node's rows, and the snapshot's tags (L3, L4)

(test-equal "insert-node!: tags given in any order are rows of the owner, sorted; the Node, node-of-owner, tags-of and the snapshot agree (L3)"
  (list '("a" "b" "c") '("a" "b" "c") '("a" "b" "c") "[\"a\",\"b\",\"c\"]"
        (list (list acct-a "a" A1) (list acct-a "b" A1) (list acct-a "c" A1)))
  (attempt
   (lambda ()
     (with-store "tags-insert.db"
       (lambda (w r p)
         (w set-up!)
         (let ((made (ok-of (w (lambda (tx) (node-tags (note! tx A1 acct-a '("c" "a" "b") 10)))))))
           (list made
                 (ok-of (r (lambda (tx) (node-tags (node-of-owner tx acct-a A1)))))
                 (ok-of (r (lambda (tx) (tags-of tx acct-a A1))))
                 (ok-of (r (lambda (tx) (snapshot-tags (snapshot-of tx acct-a A1 1)))))
                 (ok-of (r tag-rows)))))))))

(test-equal "insert-node!: no tags: no row, the Node's tags are (), the snapshot's []"
  (list '() '() "[]" '())
  (attempt
   (lambda ()
     (with-store "tags-insert-none.db"
       (lambda (w r p)
         (w set-up!)
         (list (ok-of (w (lambda (tx) (node-tags (note! tx A1 acct-a '() 10)))))
               (ok-of (r (lambda (tx) (node-tags (node-of-owner tx acct-a A1)))))
               (ok-of (r (lambda (tx) (snapshot-tags (snapshot-of tx acct-a A1 1)))))
               (ok-of (r tag-rows))))))))

(test-equal "insert-node!: a tag given twice is refused by the key and the job rolls back; what is raised names no tag"
  (list '(raised (sqlite constraint)) '(0 0 0 0) '(raised #f))
  (attempt
   (lambda ()
     (with-store "tags-insert-twice.db"
       (lambda (w r p)
         (w set-up!)
         (let* ((res (w (lambda (tx) (note! tx A1 acct-a '("secret-tag-q" "secret-tag-q") 10))))
                (left (ok-of (r (lambda (tx) (map (lambda (t) (count-of tx t)) '("nodes" "revisions" "changes" "node_tags"))))))
                (text (let ((c (car (rolled-back w (lambda (tx) (note! tx A2 acct-a '("secret-tag-q" "secret-tag-q") 10))
                                                 (lambda (tx) #f)))))
                        (list (car c) (contains? (caddr c) "secret-tag-q")))))
           (list res left text)))))))

(test-equal "node_tags: a tag of 65 characters and an empty one are refused by the table's CHECK; 64 is taken, astral characters counted as one each"
  (list '(raised (sqlite constraint)) '(raised (sqlite constraint)) '(ok #t) '(raised (sqlite constraint)) '(ok #t))
  (attempt
   (lambda ()
     (with-store "tags-check.db"
       (lambda (w r p)
         (w set-up!)
         (list (w (lambda (tx) (note! tx A1 acct-a (list (make-string 65 #\t)) 10)))
               (w (lambda (tx) (note! tx A1 acct-a (list "") 10)))
               (w (lambda (tx) (note! tx A1 acct-a (list (make-string 64 #\t)) 10) #t))
               (w (lambda (tx) (note! tx A2 acct-a (list (make-string 65 #\x1D400)) 10)))
               (w (lambda (tx) (note! tx A2 acct-a (list (make-string 64 #\x1D400)) 10) #t))))))))

(test-equal "write-node!: a list replaces the rows; each Node and each new snapshot hold the rows written; older snapshots keep theirs (L3)"
  (list '("b" "c") '("d") '("d") (list "[\"a\",\"b\"]" "[\"b\",\"c\"]" "[\"d\"]") (list (list acct-a "d" A1)))
  (attempt
   (lambda ()
     (with-store "tags-write-list.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a" "b") 10)))
         (let* ((n2 (ok-of (w (lambda (tx) (node-tags (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" '("c" "b") "update" 20))))))
                (n3 (ok-of (w (lambda (tx) (node-tags (write-node! tx A1 acct-a 2 "T" "B" "a/a" "{}" '("d") "update" 30)))))))
           (list n2 n3
                 (ok-of (r (lambda (tx) (tags-of tx acct-a A1))))
                 (ok-of (r (lambda (tx) (map (lambda (k) (snap-tags tx A1 k)) '(1 2 3)))))
                 (ok-of (r tag-rows)))))))))

(test-equal "write-node!: keep changes no row of node_tags (L4); the Node and the new snapshot hold the rows as they are (L3)"
  (list #t '("a" "b") "[\"a\",\"b\"]" '("a" "b"))
  (attempt
   (lambda ()
     (with-store "tags-write-keep.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a" "b") 10) (note! tx A2 acct-a '("z") 10)))
         (let* ((before (ok-of (r tag-rows)))
                (n2 (ok-of (w (lambda (tx) (node-tags (write-node! tx A1 acct-a 1 "T2" "B2" "a/a" "{}" 'keep "update" 20)))))))
           (list (equal? before (ok-of (r tag-rows)))
                 n2
                 (ok-of (r (lambda (tx) (snap-tags tx A1 2))))
                 (ok-of (r (lambda (tx) (node-tags (node-of-owner tx acct-a A1))))))))))))

(test-equal "write-node!: () clears the rows, and the snapshot holds []; another node's rows stay"
  (list '() "[]" '("z"))
  (attempt
   (lambda ()
     (with-store "tags-write-clear.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a" "b") 10) (note! tx A2 acct-a '("z") 10)))
         (list (ok-of (w (lambda (tx) (node-tags (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" '() "update" 20)))))
               (ok-of (r (lambda (tx) (snap-tags tx A1 2))))
               (ok-of (r (lambda (tx) (tags-of tx acct-a A2))))))))))

(test-equal "write-node!: a snapshot's tags as stored (a String) become the rows as they are, never folded; the new snapshot holds them (L11)"
  (list '("Upper" "b") '("Upper" "b") "[\"Upper\",\"b\"]" '() "[]")
  (attempt
   (lambda ()
     (with-store "tags-write-json.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a") 10)))
         (let* ((n2 (ok-of (w (lambda (tx) (node-tags (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" "[\"Upper\",\"b\"]" "restore" 20))))))
                (rows2 (ok-of (r (lambda (tx) (tags-of tx acct-a A1)))))
                (snap2 (ok-of (r (lambda (tx) (snap-tags tx A1 2))))))
           (w (lambda (tx) (write-node! tx A1 acct-a 2 "T" "B" "a/a" "{}" "[]" "restore" 30)))
           (list n2 rows2 snap2
                 (ok-of (r (lambda (tx) (tags-of tx acct-a A1))))
                 (ok-of (r (lambda (tx) (snap-tags tx A1 3)))))))))))

(test-equal "restore: a snapshot restored through write-node! with its own tags sets the rows to them; after a rename, the newest snapshot brings the old tag back (L11)"
  (list '(1 . 0) '("y") "[\"x\"]" 1 '("x") "[\"x\"]" 3)
  (attempt
   (lambda ()
     (with-store "tags-restore.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("x") 10)))
         (let* ((step (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "y" 500 20)))))
                (rows (ok-of (r (lambda (tx) (tags-of tx acct-a A1)))))
                (newest (ok-of (r (lambda (tx) (newest-tags tx A1)))))
                (snaps (ok-of (r (lambda (tx) (count-of tx "revisions")))))
                (restored (ok-of (w (lambda (tx)
                                      (let ((s (snapshot-of tx acct-a A1 1)))
                                        (node-tags (write-node! tx A1 acct-a 2 (snapshot-title s) (snapshot-body s)
                                                                (snapshot-content-type s) (snapshot-props s)
                                                                (snapshot-tags s) "restore" 30))))))))
           (list step rows newest snaps restored
                 (ok-of (r (lambda (tx) (snap-tags tx A1 3))))
                 (ok-of (r (lambda (tx) (node-revision (node-of-owner tx acct-a A1))))))))))))

(test-equal "write-node!: the rows are written after the revision check: a stale write, with a list, a snapshot's tags or (), changes no row within its job"
  (list (list 'raised (list A1 7)) (list 'raised (list A1 7)) (list 'raised (list A1 7)) '("a"))
  (attempt
   (lambda ()
     (with-store "tags-write-stale.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a") 10)))
         (let ((one (lambda (tags)
                      (let ((seen (rolled-back w (lambda (tx) (write-node! tx A1 acct-a 7 "T" "B" "a/a" "{}" tags "update" 20))
                                               (lambda (tx) (rows-of tx A1)))))
                        (list (raised-with (car seen)) (cadr seen))))))
           (let* ((c1 (one '("zzz"))) (c2 (one "[\"zzz\"]")) (c3 (one '())))
             (list (car c1) (car c2) (car c3)
                   (if (equal? (cadr c1) (cadr c2)) (if (equal? (cadr c2) (cadr c3)) (cadr c1) (list (cadr c2) (cadr c3))) (list (cadr c1) (cadr c2)))))))))))

(test-equal "write-node!: tags that are no list, no snapshot's text and not keep raise with no irritant, and the job rolls back"
  (list '(raised ()) '("a") 1)
  (attempt
   (lambda ()
     (with-store "tags-write-bad.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a") 10)))
         (let ((c (raised-with (car (rolled-back w (lambda (tx) (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" 'replace "update" 20))
                                                 (lambda (tx) #f))))))
           (w (lambda (tx) (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" 'replace "update" 20)))
           (list c
                 (ok-of (r (lambda (tx) (tags-of tx acct-a A1))))
                 (ok-of (r (lambda (tx) (node-revision (node-of-owner tx acct-a A1))))))))))))

;; Quotes, a backslash, a slash, DEL, non-ASCII, CJK, an astral letter,
;; U+FFFD, a space and U+1680: what jsonparse writes for each is what
;; SQLite's json_group_array writes (the review's json-text.sps).
(define json-corpus
  (list "a\"b" "a\\b" "a/b" "\x7F;" "\xE9;" "\x65E5;\x672C;" "\x1D400;" "-x" "z" "\xFFFD;" "a b" "\x1680;"))

(test-equal "snapshot: its tags are byte for byte json->string's of the sorted list, for quotes, backslashes, non-ASCII and astral tags, and the order holds for rows inserted in reverse"
  (let ((j (tags-json json-corpus)))
    (list j j (list-sort string<? json-corpus) (list-sort string<? json-corpus)))
  (attempt
   (lambda ()
     (with-store "tags-json-text.db"
       (lambda (w r p)
         (let ((reversed (reverse (list-sort string<? json-corpus))))
           (w set-up!)
           (w (lambda (tx) (note! tx A1 acct-a reversed 10)))
           (w (lambda (tx) (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" reversed "update" 20)))
           (list (ok-of (r (lambda (tx) (snap-tags tx A1 1))))
                 (ok-of (r (lambda (tx) (snap-tags tx A1 2))))
                 (ok-of (r (lambda (tx) (tags-of tx acct-a A1))))
                 (ok-of (r (lambda (tx) (node-tags (node-of-owner tx acct-a A1))))))))))))

(test-equal "set-node-state! and move-node!: the Node has its tags; no row changes and no snapshot is written"
  (list '("a" "b") '("a" "b") #t 1)
  (attempt
   (lambda ()
     (with-store "tags-state-move.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("b" "a") 10) (note! tx A2 acct-a '() 10)))
         (let* ((before (ok-of (r tag-rows)))
                (s (ok-of (w (lambda (tx) (node-tags (set-node-state! tx A1 acct-a 1 "archived" "archive" 20))))))
                (m (ok-of (w (lambda (tx) (node-tags (move-node! tx A1 acct-a 2 A2 30)))))))
           (list s m (equal? before (ok-of (r tag-rows)))
                 (ok-of (r (lambda (tx) (vector-ref (tx-query-row tx "SELECT count(*) FROM revisions WHERE node = ?" A1) 0)))))))))))

(test-equal "nodes-page and links-page: each Node carries its own tags, the other end's in a link page"
  (list '((1 ("a")) (2 ("b" "c")) (3 ())) '(("b" "c")) '(("a")))
  (attempt
   (lambda ()
     (with-store "tags-pages.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx)
              (note! tx A1 acct-a '("a") 10) (note! tx A2 acct-a '("c" "b") 10) (note! tx A3 acct-a '() 10)
              (insert-link! tx acct-a A1 "related" A2 1 20)))
         (list (ok-of (r (lambda (tx) (map (lambda (n) (list (bytevector-u8-ref (node-id n) 0) (node-tags n)))
                                           (nodes-page tx acct-a "active" 'any '() #f 10)))))
               (ok-of (r (lambda (tx) (map (lambda (i) (node-tags (caddr i))) (links-page tx acct-a A1 'out #f #f 10)))))
               (ok-of (r (lambda (tx) (map (lambda (i) (node-tags (caddr i))) (links-page tx acct-a A2 'in #f #f 10)))))))))))

(test-equal "tags-of: owner-scoped: A reads none of B's node, B its own; a node with none and an id no one holds are ()"
  (list '() '("b") '() '())
  (attempt
   (lambda ()
     (with-store "tags-of-owner.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx B1 acct-b '("b") 10) (note! tx A1 acct-a '() 10)))
         (ok-of (r (lambda (tx) (list (tags-of tx acct-a B1) (tags-of tx acct-b B1)
                                      (tags-of tx acct-a A1) (tags-of tx acct-a (nid 99)))))))))))

(test-equal "snapshots-page: a page's snapshots carry no tags (#f); snapshot-of the text as stored"
  (list '(#f #f) "[\"a\"]" "[\"b\"]")
  (attempt
   (lambda ()
     (with-store "tags-snapshots.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a") 10)
                 (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" '("b") "update" 20)))
         (list (ok-of (r (lambda (tx) (map snapshot-tags (snapshots-page tx acct-a A1 #f 10)))))
               (ok-of (r (lambda (tx) (snapshot-tags (snapshot-of tx acct-a A1 1)))))
               (ok-of (r (lambda (tx) (snapshot-tags (snapshot-of tx acct-a A1 2)))))))))))

(test-equal "purge-node!: the node's rows go, after the check (a stale purge keeps them within its job); another node's stay (L7)"
  (list (list 'raised (list A1 9)) '("a" "b") '() '("a") 0)
  (attempt
   (lambda ()
     (with-store "tags-purge.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a '("a" "b") 10) (note! tx A2 acct-a '("a") 10)
                 (set-node-state! tx A1 acct-a 1 "trashed" "trash" 20)))
         (let ((stale (let ((seen (rolled-back w (lambda (tx) (purge-node! tx A1 acct-a 9 30))
                                              (lambda (tx) (rows-of tx A1)))))
                        (list (raised-with (car seen)) (cadr seen)))))
           (w (lambda (tx) (purge-node! tx A1 acct-a 2 40)))
           (list (car stale) (cadr stale)
                 (ok-of (r (lambda (tx) (rows-of tx A1))))
                 (ok-of (r (lambda (tx) (rows-of tx A2))))
                 (ok-of (r misowned)))))))))

;;; A step: rename-tag! and remove-tag! (L5, L6, L9)

;; step fixture: A's nodes 1 3 5 7 9 11 13 carry "x" (7 carries "y" too; 3
;; is archived, 5 trashed); A's 15 carries "other". B's 2 4 6 8 10 carry
;; "x" (4 "y" too), and 12 carries "bonly"; B then writes ten times, so its
;; seq runs ahead of A's. After it, A's seq is 10 and B's 16.
(define step-a '(1 3 5 7 9 11 13))
(define (step-set-up! tx)
  (set-up! tx)
  (for-each (lambda (n) (note! tx (nid n) acct-a (if (= n 7) '("x" "y") '("x")) 10)) step-a)
  (note! tx (nid 15) acct-a '("other") 10)
  (for-each (lambda (n) (note! tx (nid n) acct-b (if (= n 4) '("x" "y") '("x")) 10)) '(2 4 6 8 10))
  (note! tx (nid 12) acct-b '("bonly") 10)
  (set-node-state! tx (nid 3) acct-a 1 "archived" "archive" 20)
  (set-node-state! tx (nid 5) acct-a 1 "trashed" "trash" 20)
  (let loop ((rev 1))
    (when (<= rev 10)
      (write-node! tx (nid 2) acct-b rev "t" "b" "a/a" "{}" 'keep "update" (+ 30 rev))
      (loop (+ rev 1)))))

;; bumped : (Listof (List Natural Natural Natural String)) (Listof Natural) Natural
;;          -> (Listof ...)
;; HEADS with each node in IDS at revision + 1 and updated NOW.
(define (bumped hs ids now)
  (map (lambda (h) (if (memv (car h) ids) (list (car h) (+ (cadr h) 1) now (cadddr h)) h)) hs))

(test-equal "rename-tag!: every carrier when fewer than the cap: (7 . 0); each bumped once, the archived and the trashed ones too, their states kept; one change row tags each at its new revision, numbered in id order from A's next seq; no snapshot; FROM gone, TO on each; no other node changed (L5)"
  (list '(7 . 0) #t
        '((11 1 2 "tags" 1000) (12 3 3 "tags" 1000) (13 5 3 "tags" 1000) (14 7 2 "tags" 1000)
          (15 9 2 "tags" 1000) (16 11 2 "tags" 1000) (17 13 2 "tags" 1000))
        #t '() step-a '("y" "z") '("other") 0)
  (attempt
   (lambda ()
     (with-store "step-all.db"
       (lambda (w r p)
         (w step-set-up!)
         (let* ((hs (ok-of (r heads)))
                (snaps (ok-of (r (lambda (tx) (count-of tx "revisions")))))
                (res (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "z" 10 1000))))))
           (ok-of
            (r (lambda (tx)
                 (list res
                       (equal? (heads tx) (bumped hs step-a 1000))
                       (changes-after tx acct-a 10)
                       (= snaps (count-of tx "revisions"))
                       (raw tx "SELECT node FROM node_tags WHERE owner = ? AND tag = 'x'" acct-a)
                       (map (lambda (r) (bytevector-u8-ref (car r) 0))
                            (raw tx "SELECT node FROM node_tags WHERE owner = ? AND tag = 'z' ORDER BY node" acct-a))
                       (rows-of tx (nid 7))
                       (rows-of tx (nid 15))
                       (misowned tx)))))))))))

(test-equal "rename-tag!: onto a tag a carrier already has: one row of it, no duplicate; that node bumped once, with one change row (a merge)"
  (list '(7 . 0) step-a '(7) '(2) 7)
  (attempt
   (lambda ()
     (with-store "step-merge.db"
       (lambda (w r p)
         (w step-set-up!)
         (let ((res (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "y" 500 1000))))))
           (ok-of
            (r (lambda (tx)
                 (list res
                       (map (lambda (r) (bytevector-u8-ref (car r) 0))
                            (raw tx "SELECT node FROM node_tags WHERE owner = ? AND tag = 'y' ORDER BY node" acct-a))
                       (map (lambda (r) (bytevector-u8-ref (car r) 0))
                            (raw tx "SELECT node FROM node_tags WHERE owner = ? AND tag = 'y' AND node = ?" acct-a (nid 7)))
                       (map car (raw tx "SELECT revision FROM nodes WHERE id = ?" (nid 7)))
                       (length (changes-after tx acct-a 10))))))))))))

(test-equal "rename-tag!: more carriers than the cap: (3 . 4), (3 . 1), (1 . 0), then (0 . 0); each node bumped exactly once over the steps; seq 11 to 17 with no gap, in id order; B untouched (L5, L6)"
  (list '((3 . 4) (3 . 1) (1 . 0) (0 . 0)) #t
        '((11 1 2 "tags" 1000) (12 3 3 "tags" 1000) (13 5 3 "tags" 1000) (14 7 2 "tags" 1001)
          (15 9 2 "tags" 1001) (16 11 2 "tags" 1001) (17 13 2 "tags" 1002))
        #t 0)
  (attempt
   (lambda ()
     (with-store "step-cap.db"
       (lambda (w r p)
         (w step-set-up!)
         (let* ((hs (ok-of (r heads)))
                (b-before (ok-of (r (lambda (tx) (owner-rows tx acct-b)))))
                (s1 (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "z" 3 1000)))))
                (s2 (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "z" 3 1001)))))
                (s3 (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "z" 3 1002)))))
                (s4 (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "z" 3 1003))))))
           (ok-of
            (r (lambda (tx)
                 (list (list s1 s2 s3 s4)
                       (equal? (map (lambda (h) (list (car h) (cadr h))) (heads tx))
                               (map (lambda (h) (list (car h) (cadr h))) (bumped hs step-a 0)))
                       (changes-after tx acct-a 10)
                       (equal? b-before (owner-rows tx acct-b))
                       (misowned tx)))))))))))

(test-equal "remove-tag!: (4 . 3), then (3 . 0); the tag is gone from A, every other tag stays, B keeps its own; seven change rows tags"
  (list '((4 . 3) (3 . 0)) '() '("y") '("other") 7 #t)
  (attempt
   (lambda ()
     (with-store "step-remove.db"
       (lambda (w r p)
         (w step-set-up!)
         (let* ((b-before (ok-of (r (lambda (tx) (owner-rows tx acct-b)))))
                (s1 (ok-of (w (lambda (tx) (remove-tag! tx acct-a "x" 4 1000)))))
                (s2 (ok-of (w (lambda (tx) (remove-tag! tx acct-a "x" 4 1001))))))
           (ok-of
            (r (lambda (tx)
                 (list (list s1 s2)
                       (raw tx "SELECT node FROM node_tags WHERE owner = ? AND tag = 'x'" acct-a)
                       (rows-of tx (nid 7))
                       (rows-of tx (nid 15))
                       (length (filter (lambda (c) (equal? (cadddr c) "tags")) (changes-after tx acct-a 10)))
                       (equal? b-before (owner-rows tx acct-b))))))))))))

(test-equal "a step on a tag only another account carries, or none: (0 . 0), and no row of any table changes (L6)"
  (list '(0 . 0) '(0 . 0) '(0 . 0) #t)
  (attempt
   (lambda ()
     (with-store "step-none.db"
       (lambda (w r p)
         (w step-set-up!)
         (let* ((before (ok-of (r (lambda (tx) (list (all-rows tx) (tag-rows tx))))))
                (a (ok-of (w (lambda (tx) (rename-tag! tx acct-a "bonly" "z" 500 1000)))))
                (b (ok-of (w (lambda (tx) (remove-tag! tx acct-a "bonly" 500 1000)))))
                (c (ok-of (w (lambda (tx) (remove-tag! tx acct-a "nothing" 500 1000))))))
           (list a b c (equal? before (ok-of (r (lambda (tx) (list (all-rows tx) (tag-rows tx)))))))))))))

(test-equal "a step: a purged node is never picked, as purge-node! took its rows: it keeps its row and gets no change row; a row left on a purged node by hand makes the step raise with the two counts alone, naming no tag, and the job rolls back"
  (list '(6 . 0) '((5 3 50 "purged")) '() (list (list 'raised '(7 6) #f) #t))
  (attempt
   (lambda ()
     (append
      (with-store "step-purged.db"
        (lambda (w r p)
          (w step-set-up!)
          (w (lambda (tx) (purge-node! tx (nid 5) acct-a 2 50)))
          (let ((res (ok-of (w (lambda (tx) (rename-tag! tx acct-a "x" "z" 10 1000))))))
            (ok-of (r (lambda (tx)
                        (list res
                              (filter (lambda (h) (= (car h) 5)) (heads tx))
                              (filter (lambda (c) (and (= (cadr c) 5) (equal? (cadddr c) "tags"))) (changes-after tx acct-a 0)))))))))
      (with-store "step-purged-by-hand.db"
        (lambda (w r p)
          (w step-set-up!)
          (w (lambda (tx) (rename-tag! tx acct-a "x" "secret-tag-p" 500 40)))
          (w (lambda (tx)
               (purge-node! tx (nid 5) acct-a 3 50)
               (tx-execute! tx "INSERT INTO node_tags(owner, tag, node) VALUES (?, 'secret-tag-p', ?)" acct-a (nid 5))))
          (let* ((before (ok-of (r (lambda (tx) (list (all-rows tx) (tag-rows tx))))))
                 (c (car (rolled-back w (lambda (tx) (remove-tag! tx acct-a "secret-tag-p" 500 1000)) (lambda (tx) #f)))))
            (list (list (list (car c) (cadr c) (contains? (caddr c) "secret-tag-p"))
                        (equal? before (ok-of (r (lambda (tx) (list (all-rows tx) (tag-rows tx)))))))))))))))

(test-equal "a step's change rows: no gap and no clash with a write made before and after it, in its job and in jobs of their own"
  (list (iota* 11 19) (iota* 20 28))
  (attempt
   (lambda ()
     (with-store "step-seq.db"
       (lambda (w r p)
         (w step-set-up!)
         (w (lambda (tx)
              (write-node! tx (nid 15) acct-a 1 "t" "b" "a/a" "{}" 'keep "update" 900)
              (rename-tag! tx acct-a "x" "z" 500 1000)
              (write-node! tx (nid 15) acct-a 2 "t" "b" "a/a" "{}" 'keep "update" 1100)))
         (let ((one (ok-of (r (lambda (tx) (map car (changes-after tx acct-a 10)))))))
           (w (lambda (tx) (write-node! tx (nid 15) acct-a 3 "t" "b" "a/a" "{}" 'keep "update" 1200)))
           (w (lambda (tx) (rename-tag! tx acct-a "z" "x" 500 1300)))
           (w (lambda (tx) (write-node! tx (nid 15) acct-a 4 "t" "b" "a/a" "{}" 'keep "update" 1400)))
           (list one (ok-of (r (lambda (tx) (map car (changes-after tx acct-a 19))))))))))))

(test-equal "a step writes no snapshot: the carriers' newest snapshots still hold FROM, the rows TO; they differ by exactly the step (L3, restated)"
  (list '("[\"x\"]" "[\"x\"]") '(("z") ("z")) #t)
  (attempt
   (lambda ()
     (with-store "step-no-snapshot.db"
       (lambda (w r p)
         (w step-set-up!)
         (let ((before (ok-of (r (lambda (tx) (raw tx "SELECT node, revision, tags FROM revisions ORDER BY node, revision"))))))
           (w (lambda (tx) (rename-tag! tx acct-a "x" "z" 500 1000)))
           (ok-of (r (lambda (tx)
                       (list (list (newest-tags tx (nid 1)) (newest-tags tx (nid 9)))
                             (list (rows-of tx (nid 1)) (rows-of tx (nid 9)))
                             (equal? before (raw tx "SELECT node, revision, tags FROM revisions ORDER BY node, revision"))))))))))))

(test-equal "rename-tag!: FROM equal to TO raises naming no tag, and a cap of 0 raises; neither writes"
  (list (list 'raised '() #f) (list 'raised '(0)) #t)
  (attempt
   (lambda ()
     (with-store "step-refused.db"
       (lambda (w r p)
         (w step-set-up!)
         (let* ((before (ok-of (r (lambda (tx) (list (all-rows tx) (tag-rows tx))))))
                (same (let ((c (car (rolled-back w (lambda (tx) (rename-tag! tx acct-a "secret-tag-s" "secret-tag-s" 500 1000))
                                                 (lambda (tx) #f)))))
                        (list (car c) (cadr c) (contains? (caddr c) "secret-tag-s"))))
                (zero (raised-with (car (rolled-back w (lambda (tx) (remove-tag! tx acct-a "x" 0 1000)) (lambda (tx) #f))))))
           (list same zero (equal? before (ok-of (r (lambda (tx) (list (all-rows tx) (tag-rows tx)))))))))))))

(test-equal "retag-store-states: every live state, and the step's UPDATE names exactly those"
  (list '("active" "archived" "trashed") #t)
  (attempt
   (lambda ()
     (list retag-store-states
           (contains? (statement-of 'retag-bump) "state IN ('active','archived','trashed')")))))

;;; The filter: nodes-page with tags

;; filter fixture: A's nodes 1 to 24, B's 30 to 35.
;; tags: a on 1..20; b on the even ones of 2..20; c on 1..5; t0..t9 on
;; 10..14, and t0 and t1 on 15 too. B's nodes carry every tag.
;; states: 3, 12, 16 archived; 4, 13, 17 trashed; 18 purged (and a row of a
;; left on it by hand: a page still never shows it).
;; parents: 21 and 22 are projects; 1..8 sit under 21, 10..15 under 22; the
;; rest are at the top level.
(define ten-tags '("t0" "t1" "t2" "t3" "t4" "t5" "t6" "t7" "t8" "t9"))
(define (fx-tags n)
  (list-sort string<?
             (append (if (<= 1 n 20) '("a") '())
                     (if (and (even? n) (<= 2 n 20)) '("b") '())
                     (if (<= 1 n 5) '("c") '())
                     (cond ((<= 10 n 14) ten-tags) ((= n 15) '("t0" "t1")) (else '())))))
(define (fx-state n)
  (cond ((memv n '(3 12 16)) "archived") ((memv n '(4 13 17)) "trashed") ((= n 18) "purged") (else "active")))
(define (fx-parent n)
  (cond ((<= 1 n 8) 21) ((<= 10 n 15) 22) (else #f)))
(define fx-nodes (iota* 1 24))

(define (filter-set-up! tx)
  (set-up! tx)
  (for-each (lambda (n) (insert-node! tx (nid n) acct-a "project" "P" "B" "a/a" "{}" #f '() 10)) '(21 22))
  (for-each (lambda (n)
              (unless (memv n '(21 22))
                (insert-node! tx (nid n) acct-a "note" "T" "B" "a/a" "{}"
                              (let ((pa (fx-parent n))) (and pa (nid pa))) (fx-tags n) 10)))
            fx-nodes)
  (for-each (lambda (n) (note! tx (nid n) acct-b (append '("a" "b" "c") ten-tags) 10)) (iota* 30 35))
  (for-each (lambda (n) (set-node-state! tx (nid n) acct-a 1 "archived" "archive" 20)) '(3 12 16))
  (for-each (lambda (n) (set-node-state! tx (nid n) acct-a 1 "trashed" "trash" 20)) '(4 13 17 18))
  (purge-node! tx (nid 18) acct-a 2 30)
  (tx-execute! tx "INSERT INTO node_tags(owner, tag, node) VALUES (?, 'a', ?)" acct-a (nid 18)))

;; oracle : String (U 'any #f Natural) (Listof String) Natural -> (Listof Natural)
;; A's nodes past AFTER in STATE under PARENT carrying every tag, by id.
(define (oracle state parent tags after)
  (filter (lambda (n)
            (and (> n after)
                 (string=? (fx-state n) state)
                 (not (string=? state "purged"))
                 (cond ((eq? parent 'any) #t)
                       ((not parent) (not (fx-parent n)))
                       (else (eqv? (fx-parent n) parent)))
                 (for-all (lambda (t) (member t (fx-tags n))) tags)))
          fx-nodes))

;; paged : Tx String (U 'any #f Natural) (Listof String) Natural Natural -> (Listof Natural)
;; Every page of N from AFTER (0: from the start) until a short one, joined.
;; The fixture has 24 nodes, so a 26th page means the cursor is not
;; followed: the answer is then marked, never a hang.
(define (paged tx state parent tags after n)
  (let loop ((cur (and (> after 0) (nid after))) (acc '()) (pages 0))
    (let* ((page (nodes-page tx acct-a state (if (number? parent) (nid parent) parent) tags cur n))
           (acc (append acc (node-ids page))))
      (cond ((< (length page) n) acc)
            ((> pages 25) (list 'more-pages-than-nodes acc))
            (else (loop (node-id (car (reverse page))) acc (+ pages 1)))))))

(define filter-tag-sets
  (list '("a") '("a" "b") '("b" "a") ten-tags '("c" "t0") '("t0" "t1")))
(define filter-states '("active" "archived" "trashed" "purged"))
(define filter-parents (list 'any #f 21 22))

;; filter-cases : (Listof (List (Listof String) String (U 'any #f Natural) Natural Natural))
;; (tags state parent after limit): every tag set, state and parent, paged
;; from the start by 2, after node 5 by 100, and after node 11 by 1.
(define filter-cases
  (apply append
         (map (lambda (tags)
                (apply append
                       (map (lambda (state)
                              (apply append
                                     (map (lambda (parent)
                                            (list (list tags state parent 0 2)
                                                  (list tags state parent 5 100)
                                                  (list tags state parent 11 1)))
                                          filter-parents)))
                            filter-states)))
              filter-tag-sets)))

;; filter-answers : (U (Listof (Pair Case (Listof Natural))) Any)
;; Each case's answer, all read on one file.
(define filter-answers
  (attempt
   (lambda ()
     (with-store "tags-filter.db"
       (lambda (w r p)
         (let ((s (w filter-set-up!)))
           (if (not (and (pair? s) (eq? (car s) 'ok)))
               (list 'set-up s)
               (ok-of (r (lambda (tx)
                           (map (lambda (c)
                                  (cons c (paged tx (cadr c) (caddr c) (car c) (cadddr c) (car (cddddr c)))))
                                filter-cases)))))))))))

(for-each
 (lambda (tags)
   (for-each
    (lambda (state)
      (test-equal (string-append "filter: tags " (let loop ((ts tags) (acc "")) (if (null? ts) acc (loop (cdr ts) (string-append acc " " (car ts)))))
                                 ", " state ": under each parent ('any, the top, 21, 22), paged by 2 from the start, by 100 after node 5 and by 1 after node 11, is the oracle's")
        (map (lambda (parent)
               (list (oracle state parent tags 0) (oracle state parent tags 5) (oracle state parent tags 11)))
             filter-parents)
        (if (list? filter-answers)
            (map (lambda (parent)
                   (map (lambda (after n)
                          (let ((a (assoc (list tags state parent after n) filter-answers)))
                            (if a (cdr a) (list 'missing filter-answers))))
                        '(0 5 11) '(2 100 1)))
                 filter-parents)
            filter-answers)))
    filter-states))
 filter-tag-sets)

(test-equal "filter: the cases are not all empty: an intersection of every kind is met (a, a b, ten tags, t0 t1) and c t0 is empty"
  '(#t #t #t #t #t)
  (list (pair? (oracle "active" 'any '("a") 0)) (pair? (oracle "active" 21 '("a" "b") 0))
        (pair? (oracle "active" 22 ten-tags 0)) (pair? (oracle "active" 22 '("t0" "t1") 0))
        (null? (oracle "active" 'any '("c" "t0") 0))))

(test-equal "filter: a page's Nodes carry their tags and no body; B sees only its own; a tag given twice is that tag once; a tag no node carries is the empty page; 11 tags raise, naming the count alone"
  (list (map (lambda (n) (list n (fx-tags n) #f)) (oracle "active" 'any '("a") 0))
        (iota* 30 35)
        (oracle "active" 'any '("a") 0)
        '()
        (list 'raised '(11)))
  (attempt
   (lambda ()
     (with-store "tags-filter-2.db"
       (lambda (w r p)
         (w filter-set-up!)
         (ok-of (r (lambda (tx)
                     (list (map (lambda (n) (list (bytevector-u8-ref (node-id n) 0) (node-tags n) (node-body n)))
                                (nodes-page tx acct-a "active" 'any '("a") #f 100))
                           (node-ids (nodes-page tx acct-b "active" 'any '("a" "t9") #f 100))
                           (node-ids (nodes-page tx acct-a "active" 'any '("a" "a") #f 100))
                           (nodes-page tx acct-a "active" 'any '("nothing" "a") #f 100)
                           (raised-with (caught (lambda () (nodes-page tx acct-a "active" 'any (cons "a" ten-tags) #f 100)))))))))))))

;; The rarest tag drives the scan (the review's blocker 6). Which tag
;; drives changes no row of the answer, only its cost, and nothing SQLite
;; answers a job shows a statement's bound values. So the choice is pure,
;; and held here directly: tag-counts, the counts on a real file;
;; tagged-query, the statement and its arguments for those counts, its
;; tags in rarest-first's order; and rarest-first. tagged-page only runs
;; tagged-query's answer for tag-counts' answer: its whole definition is
;; held below, read from the library's source. (A test that held this by
;; the clock, best of five with a threefold margin, was replaced: a timing
;; test flakes on a loaded machine. So was one that read only that the
;; statements' tags came from a call of rarest-first: a call on counts all
;; 0 passed it, and so did tag-counts answering 1 for every tag.)

(test-equal "rarest-first: tags with their counts to the tags, fewest first, equal counts by string<? (by code point): none; one; the rare before the common whatever the order given; ties; two at the cap of 1,000; ten mixed"
  (list '() '("a") '("rare" "common") '("rare" "common") '("c" "a" "b") '("y" "z")
        '("t5" "t0" "t3" "t9" "t1" "t2" "t8" "t4" "t6" "t7")
        '("a" "B" "\xE9;"))
  (attempt
   (lambda ()
     (list (rarest-first '())
           (rarest-first '(("a" . 3)))
           (rarest-first '(("common" . 1000) ("rare" . 1)))
           (rarest-first '(("rare" . 1) ("common" . 1000)))
           (rarest-first '(("b" . 5) ("a" . 5) ("c" . 2)))
           (rarest-first '(("z" . 1000) ("y" . 1000)))
           (rarest-first '(("t0" . 7) ("t1" . 50) ("t2" . 50) ("t3" . 7) ("t4" . 999) ("t5" . 1)
                           ("t6" . 1000) ("t7" . 1000) ("t8" . 51) ("t9" . 8)))
           (rarest-first '(("\xE9;" . 2) ("B" . 2) ("a" . 1)))))))

;; counted-on : String (Tx -> A) -> (U A Any)     the filter fixture's counts, read by JOB
(define (counted-on name job)
  (attempt
   (lambda ()
     (with-store name
       (lambda (w r p)
         (let ((s (w filter-set-up!)))
           (if (and (pair? s) (eq? (car s) 'ok)) (ok-of (r job)) (list 'set-up s))))))))

(test-equal "tag-counts: each tag with how many of the owner's nodes carry it, in every state, in the order given: c 5, b 9 (a purged node's row gone), a 20 (one left on it by hand counted), t0 6, t9 5; B's own, 6 each; #f when one is on no node, wherever it is"
  (list '(("c" . 5) ("b" . 9) ("a" . 20)) '(("t9" . 5) ("t0" . 6) ("t1" . 6) ("t5" . 5))
        '(("a" . 6) ("t9" . 6)) #f #f)
  (counted-on "tags-counts.db"
              (lambda (tx)
                (list (tag-counts tx acct-a '("c" "b" "a")) (tag-counts tx acct-a '("t9" "t0" "t1" "t5"))
                      (tag-counts tx acct-b '("a" "t9")) (tag-counts tx acct-a '("nothing" "a"))
                      (tag-counts tx acct-a '("a" "b" "nothing"))))))

(test-equal "tagged-query: the statement for the number of tags and the parent, then the owner, the state, AFTER or the zero id, the parent when it is an id, the tags fewest first by their real counts (not as given, nor by string<?), and N"
  (let ((z (bv 16 0)))
    (list (list 'nodes-tagged-3 acct-a "active" z "c" "b" "a" 5)
          (list 'nodes-tagged-top-3 acct-a "trashed" (nid 7) "c" "b" "a" 2)
          (list 'nodes-tagged-of-3 acct-a "archived" z (nid 22) "c" "b" "a" 100)
          (list 'nodes-tagged-of-2 acct-a "active" (nid 11) (nid 22) "t2" "t0" 1)
          (list 'nodes-tagged-10 acct-a "active" z "t2" "t3" "t4" "t5" "t6" "t7" "t8" "t9" "t0" "t1" 51)
          (list 'nodes-tagged-top-1 acct-b "active" z "a" 5)))
  (counted-on "tags-query.db"
              (lambda (tx)
                (list (tagged-query acct-a "active" 'any (tag-counts tx acct-a '("a" "b" "c")) #f 5)
                      (tagged-query acct-a "trashed" #f (tag-counts tx acct-a '("a" "c" "b")) (nid 7) 2)
                      (tagged-query acct-a "archived" (nid 22) (tag-counts tx acct-a '("b" "a" "c")) #f 100)
                      (tagged-query acct-a "active" (nid 22) (tag-counts tx acct-a '("t0" "t2")) (nid 11) 1)
                      (tagged-query acct-a "active" 'any (tag-counts tx acct-a ten-tags) #f 51)
                      (tagged-query acct-b "active" #f (tag-counts tx acct-b '("a")) #f 5)))))

(test-equal "tagged-query: it names each of the thirty filter statements once, by the number of tags and the parent; 0 or 11 tags raise, naming the count alone"
  (list (apply append
               (map (lambda (mode)
                      (map (lambda (k) (string->symbol (string-append "nodes-tagged-" mode (number->string k))))
                           (iota* 1 10)))
                    '("" "top-" "of-")))
        (list 'raised '(0)) (list 'raised '(11)))
  (attempt
   (lambda ()
     (let ((counted (lambda (k) (map (lambda (j) (cons (string-append "t" (number->string j)) 1)) (iota* 1 k)))))
       (list (apply append
                    (map (lambda (parent)
                           (map (lambda (k) (car (tagged-query acct-a "active" parent (counted k) #f 5))) (iota* 1 10)))
                         (list 'any #f A1)))
             (raised-with (caught (lambda () (tagged-query acct-a "active" 'any '() #f 5))))
             (raised-with (caught (lambda () (tagged-query acct-a "active" 'any (counted 11) #f 5)))))))))

;; tagged-page-form : Any -> (U List #f)     the (define (tagged-page ...) ...) in the library's body
(define (tagged-page-form lib)
  (find (lambda (f) (and (pair? f) (eq? (car f) 'define) (pair? (cdr f)) (pair? (cadr f))
                         (eq? (caadr f) 'tagged-page)))
        (list-tail lib 4)))

;; Held whole, as the statements' texts are: any change to it fails here,
;; and is read again by whoever changes the text below.
(test-equal "filter: tagged-page only runs what tagged-query answers for tag-counts' answer, after the cap's check: its whole definition, read from the library's source"
  '(define (tagged-page tx owner state parent tags after n)
     (let ((k (length tags)))
       (unless (<= 1 k filter-tag-cap)
         (assertion-violation 'nodes-page "a filter takes 1 to 10 tags" k))
       (let ((counted (tag-counts tx owner tags)))
         (if counted
             (let ((q (tagged-query owner state parent counted after n)))
               (map (lambda (r) (row->node tx r #f)) (apply tx-query tx (statement (car q)) (cdr q))))
             '()))))
  (attempt
   (lambda ()
     (tagged-page-form (call-with-input-file (loaded-source "techo/node-store.sls") read)))))

;;; tags-page and tag-count-capped

(define (tags-page-set-up! tx)
  (set-up! tx)
  (note! tx A1 acct-a '("b" "a") 10)
  (note! tx A2 acct-a '("a" "c") 10)
  (note! tx A3 acct-a '("a" "d") 10)
  (note! tx (nid 5) acct-a '("e") 10)
  (note! tx B1 acct-b '("a" "zz") 10)
  (set-node-state! tx A3 acct-a 1 "trashed" "trash" 20)
  (set-node-state! tx (nid 5) acct-a 1 "archived" "archive" 20))

(test-equal "tags-page: each distinct tag of the owner once, in order, with its count over every state; paged by 2 from the start and from each last tag; B's own; a page of 0 is empty"
  (list '(("a" . 3) ("b" . 1) ("c" . 1) ("d" . 1) ("e" . 1))
        '((("a" . 3) ("b" . 1)) (("c" . 1) ("d" . 1)) (("e" . 1)) ())
        '(("a" . 1) ("zz" . 1))
        '()
        '(("c" . 1) ("d" . 1) ("e" . 1)))
  (attempt
   (lambda ()
     (with-store "tags-page.db"
       (lambda (w r p)
         (w tags-page-set-up!)
         (ok-of (r (lambda (tx)
                     (list (tags-page tx acct-a #f 100)
                           (list (tags-page tx acct-a #f 2) (tags-page tx acct-a "b" 2)
                                 (tags-page tx acct-a "d" 2) (tags-page tx acct-a "e" 2))
                           (tags-page tx acct-b #f 100)
                           (tags-page tx acct-a #f 0)
                           (tags-page tx acct-a "bb" 100))))))))))

;; big-id : Natural -> Bytevector     ids past 255 nodes: C0 bytes, K at the end
(define (big-id k)
  (let ((b (make-bytevector 16 #xC0))) (bytevector-u32-set! b 12 k (endianness big)) b))

(test-equal "tags-page: a count stops at 1,000: tags on 999, 1,000 and 1,001 nodes answer 999, 1000 and 1000; tag-count-capped with a cap past it counts 1,001; tag-counts stops at 1,000 too"
  (list '(("c1000" . 1000) ("c1001" . 1000) ("c999" . 999)) 1001 1000 999
        '(("c1001" . 1000) ("c999" . 999) ("c1000" . 1000)))
  (attempt
   (lambda ()
     (with-store "tags-page-cap.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (let loop ((k 1))
                (when (<= k 1001)
                  (note! tx (big-id k) acct-a
                         (append '("c1001") (if (<= k 1000) '("c1000") '()) (if (<= k 999) '("c999") '()))
                         10)
                  (loop (+ k 1))))))
         (ok-of (r (lambda (tx)
                     (list (tags-page tx acct-a #f 100)
                           (tag-count-capped tx acct-a "c1001" 5000)
                           (tag-count-capped tx acct-a "c1001" 1000)
                           (tag-count-capped tx acct-a "c999" 5000)
                           (tag-counts tx acct-a '("c1001" "c999" "c1000")))))))))))

(test-equal "tags-page and tags-of: SQLite's BINARY order is string<?'s for non-ASCII and astral tags"
  (list (list-sort string<? json-corpus) (list-sort string<? json-corpus))
  (attempt
   (lambda ()
     (with-store "tags-order.db"
       (lambda (w r p)
         (w set-up!)
         (w (lambda (tx) (note! tx A1 acct-a json-corpus 10)))
         (ok-of (r (lambda (tx)
                     (list (map car (tags-page tx acct-a #f 100))
                           (tags-of tx acct-a A1))))))))))

(test-equal "tag-count-capped: min(count, cap) of the owner's nodes in every state, caps 1, 2 and 1,000; B's rows not counted"
  '(1 2 3 1 0)
  (attempt
   (lambda ()
     (with-store "tags-count.db"
       (lambda (w r p)
         (w tags-page-set-up!)
         (ok-of (r (lambda (tx)
                     (list (tag-count-capped tx acct-a "a" 1) (tag-count-capped tx acct-a "a" 2)
                           (tag-count-capped tx acct-a "a" 1000) (tag-count-capped tx acct-b "a" 1000)
                           (tag-count-capped tx acct-a "zz" 1000))))))))))

;;; Migration 7 on a file that has snapshots (L11)

(test-equal "migration 7: a snapshot from before it reads [], its node has no tags; a write gives it some, and restoring the old snapshot clears them"
  (list '() "[]" '("k") '() "[]")
  (attempt
   (lambda ()
     (let ((p (path "tags-v6.db")))
       (clean! p)
       (migrate! p (filter (lambda (m) (<= (car m) 6)) migrations))
       (let ((db (open-techo-db p 'read-write)))
         (dynamic-wind
           (lambda () #f)
           (lambda ()
             (execute! db "INSERT INTO accounts(id, username, email, password_hash, created) VALUES (?, 'alice', 'alice@example.com', 'h', 1)" acct-a)
             (execute! db "INSERT INTO nodes(id, owner, author, kind, title, content_type, props, revision, created, updated) VALUES (?, ?, ?, 'note', 'T', 'a/a', '{}', 1, 1, 1)" A1 acct-a acct-a)
             (execute! db "INSERT INTO revisions(node, revision, author, title, content_type, props, created, body) VALUES (?, 1, ?, 'T', 'a/a', '{}', 1, 'old body')" A1 acct-a))
           (lambda () (close-database! db))))
       (migrate! p migrations)
       (with-store-on p
         (lambda (w r)
           (let* ((tags0 (ok-of (r (lambda (tx) (node-tags (node-of-owner tx acct-a A1))))))
                  (old (ok-of (r (lambda (tx) (snapshot-tags (snapshot-of tx acct-a A1 1))))))
                  (given (ok-of (w (lambda (tx) (node-tags (write-node! tx A1 acct-a 1 "T" "B" "a/a" "{}" '("k") "update" 20))))))
                  (restored (ok-of (w (lambda (tx)
                                        (let ((s (snapshot-of tx acct-a A1 1)))
                                          (node-tags (write-node! tx A1 acct-a 2 (snapshot-title s) (snapshot-body s)
                                                                  (snapshot-content-type s) (snapshot-props s)
                                                                  (snapshot-tags s) "restore" 30))))))))
             (list tags0 old given restored (ok-of (r (lambda (tx) (snap-tags tx A1 3))))))))))))

;;; The statements on tags, and their plans (L14)

(define tagged-statement-names
  (apply append
         (map (lambda (mode)
                (map (lambda (k) (string->symbol (string-append "nodes-tagged-" mode (number->string k))))
                     (iota* 1 10)))
              '("" "top-" "of-"))))

(define tag-statement-names
  (append '(tags-of insert-tag insert-tags-json delete-tags tag-count-capped tags-page
            retag-pick retag-add retag-bump retag-changes retag-delete retag-left)
          tagged-statement-names))

;; searches : (Listof String) -> (Listof String)
;; A plan's SEARCH lines, each with "COVERING " taken out: an older SQLite
;; calls an index COVERING where 3.53 does not (traps.md), and the search
;; and its terms are the same.
(define (searches plan)
  (map (lambda (line)
         (let loop ((s line))
           (let ((n (string-length s)) (w "COVERING "))
             (let find ((i 0))
               (cond ((> (+ i (string-length w)) n) s)
                     ((string=? (substring s i (+ i (string-length w))) w)
                      (loop (string-append (substring s 0 i) (substring s (+ i (string-length w)) n))))
                     (else (find (+ i 1))))))))
       (filter (lambda (d) (starts? d "SEARCH ")) plan)))

;; table-scan? : String -> Boolean     a line that walks a table or one of its aliases
(define (table-scan? d)
  (exists (lambda (t) (or (string=? d (string-append "SCAN " t)) (starts? d (string-append "SCAN " t " "))))
          '("node_tags" "nodes" "changes" "revisions" "t" "u" "n" "u1" "u2" "u3" "u4" "u5" "u6" "u7" "u8" "u9")))

;; matches? : (Listof String) (Listof (Listof String)) -> Boolean
;; Each line is one of its place's choices, and there are as many.
(define (matches? lines choices)
  (and (= (length lines) (length choices))
       (for-all (lambda (l c) (and (member l c) #t)) lines choices)))

;; A probe of one row of node_tags by its three columns, by node_tags_node
;; (which holds the key's tag), and a node's row by nodes_owner: the
;; statement names each index, so the plan is one on every SQLite. Left to
;; itself, 3.45.1 sorted two of the thirty in a temp b-tree (traps.md).
(define (probe alias)
  (list (string-append "SEARCH " alias " USING INDEX node_tags_node (owner=? AND node=? AND tag=?)")))
(define (by-id alias)
  (list (string-append "SEARCH " alias " USING INDEX nodes_owner (owner=? AND id=?)")))

;; The step's statements name no index: SQLite picks among these, each one
;; search.
(define (probe-any alias)
  (list (string-append "SEARCH " alias " USING PRIMARY KEY (owner=? AND tag=? AND node=?)")
        (string-append "SEARCH " alias " USING INDEX node_tags_node (owner=? AND node=? AND tag=?)")))
(define (by-id-any alias)
  (list (string-append "SEARCH " alias " USING INDEX nodes_owner (owner=? AND id=?)")
        (string-append "SEARCH " alias " USING INDEX sqlite_autoindex_nodes_1 (id=?)")
        (string-append "SEARCH " alias " USING INDEX nodes_parent (owner=? AND parent=? AND id=?)")))

(define (tagged-choices k mode)
  (let ((others (map (lambda (j) (probe (string-append "u" (number->string j)))) (iota* 1 (- k 1)))))
    (if (string=? mode "of-")
        (append (list '("SEARCH n USING INDEX nodes_parent (owner=? AND parent=? AND id>?)") (probe "t")) others)
        (append (list '("SEARCH t USING PRIMARY KEY (owner=? AND tag=? AND node>?)")) others (list (by-id "n"))))))

(define tag-plan-file (attempt (lambda () (fresh "plan-tags.db"))))

(for-each
 (lambda (mode)
   (for-each
    (lambda (k)
      (let ((name (string->symbol (string-append "nodes-tagged-" mode (number->string k)))))
        (test-equal (string-append "plan: " (symbol->string name) " drives from "
                                   (if (string=? mode "of-") "nodes_parent" "the first tag's key")
                                   ", asks each other tag by one search, the node by its id; no scan of a table, no temp b-tree")
          '(#t #f #f)
          (attempt
           (lambda ()
             (let* ((zero (bv 16 0))
                    (tags (map (lambda (j) (string-append "t" (number->string j))) (iota* 1 k)))
                    (plan (apply plan-of tag-plan-file (statement-of name)
                                 (append (list acct-a "active" zero) (if (string=? mode "of-") (list A1) '())
                                         tags (list 51)))))
               (list (matches? (searches plan) (tagged-choices k mode))
                     (exists table-scan? plan)
                     (exists (lambda (d) (contains? d "TEMP B-TREE")) plan))))))))
    (iota* 1 10)))
 '("" "top-" "of-"))

(for-each
 (lambda (c)
   (test-equal (string-append "plan: " (symbol->string (car c)) " is its searches, each by the index made for it; no scan of a table"
                              (if (cadddr c) ", no temp b-tree" ""))
     '(#t #f #f)
     (attempt
      (lambda ()
        (let ((plan (apply plan-of tag-plan-file (statement-of (car c)) (caddr c))))
          (list (matches? (searches plan) (cadr c))
                (exists table-scan? plan)
                (and (cadddr c) (exists (lambda (d) (contains? d "TEMP B-TREE")) plan))))))))
 (let ((z (bv 16 0)))
   (list
    (list 'tags-of '(("SEARCH node_tags USING INDEX node_tags_node (owner=? AND node=?)")) (list acct-a z) #t)
    (list 'delete-tags '(("SEARCH node_tags USING INDEX node_tags_node (owner=? AND node=?)")) (list acct-a z) #t)
    (list 'insert-snapshot '(("SEARCH node_tags USING INDEX node_tags_node (owner=? AND node=?)"))
          (list z 1 acct-a "t" "c" "{}" 1 "b" acct-a z) #t)
    (list 'tag-count-capped '(("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag=?)")) (list acct-a "x" 1000) #t)
    ;; the page's own ORDER BY sorts its rows (at most the page): no table is sorted
    (list 'tags-page '(("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag>?)")
                       ("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag>?)")
                       ("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag=?)"))
          (list acct-a "" acct-a 51 acct-a 1000) #f)
    (list 'retag-pick '(("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag=?)")) (list acct-a "x" 499) #t)
    (list 'retag-add (list '("SEARCH t USING PRIMARY KEY (owner=? AND tag=? AND node<?)") (probe-any "u"))
          (list acct-a "y" acct-a "x" z acct-a "y") #t)
    (list 'retag-bump (list (by-id-any "nodes") '("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag=? AND node<?)"))
          (list 1 acct-a acct-a "x" z) #t)
    (list 'retag-changes (list '("SEARCH t USING PRIMARY KEY (owner=? AND tag=? AND node<?)") (by-id-any "n")
                               '("SEARCH changes USING PRIMARY KEY (owner=?)"))
          (list acct-a acct-a 1 acct-a "x" z acct-a) #t)
    (list 'retag-delete '(("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag=? AND node<?)")) (list acct-a "x" z) #t)
    (list 'retag-left '(("SEARCH node_tags USING PRIMARY KEY (owner=? AND tag=?)")) (list acct-a "x") #t))))

(test-equal "statements: a step's six, and the reads by node, have exactly the decided text: every one names the owner"
  (list "SELECT tag FROM node_tags WHERE owner = ? AND node = ? ORDER BY tag"
        "DELETE FROM node_tags WHERE owner = ? AND node = ?"
        "SELECT node FROM node_tags WHERE owner = ? AND tag = ? ORDER BY node LIMIT 1 OFFSET ?"
        "INSERT INTO node_tags(owner, tag, node) SELECT ?, ?, t.node FROM node_tags t WHERE t.owner = ? AND t.tag = ? AND t.node <= ? AND NOT EXISTS (SELECT 1 FROM node_tags u WHERE u.owner = ? AND u.tag = ? AND u.node = t.node)"
        "UPDATE nodes SET revision = revision + 1, updated = ? WHERE owner = ? AND state IN ('active','archived','trashed') AND id IN (SELECT node FROM node_tags WHERE owner = ? AND tag = ? AND node <= ?)"
        "INSERT INTO changes(owner, seq, node, revision, op, created) SELECT ?, (SELECT coalesce(max(seq), 0) FROM changes WHERE owner = ?) + row_number() OVER (ORDER BY t.node), t.node, n.revision, 'tags', ? FROM node_tags t CROSS JOIN nodes n WHERE t.owner = ? AND t.tag = ? AND t.node <= ? AND n.id = t.node AND n.owner = ?"
        "DELETE FROM node_tags WHERE owner = ? AND tag = ? AND node <= ?"
        "SELECT count(*) FROM node_tags WHERE owner = ? AND tag = ?"
        "SELECT count(*) FROM (SELECT 1 FROM node_tags WHERE owner = ? AND tag = ? LIMIT ?)")
  (map statement-of '(tags-of delete-tags retag-pick retag-add retag-bump retag-changes retag-delete retag-left tag-count-capped)))

(test-equal "statements: the snapshot's INSERT takes its tags from the node's rows, in order, in the statement itself"
  #t
  (attempt
   (lambda ()
     (contains? (statement-of 'insert-snapshot)
                "(SELECT json_group_array(tag) FROM (SELECT tag FROM node_tags WHERE owner = ? AND node = ? ORDER BY tag))"))))

(test-equal "statements: every statement on node_tags is listed, none is INSERT OR IGNORE, OR REPLACE or ON CONFLICT, and each names the owner as often as it reads the table"
  (list '() '() '())
  (attempt
   (lambda ()
     (let* ((on-tags (filter (lambda (s) (contains? (cdr s) "node_tags")) node-store-statements))
            (count-of-text (lambda (s sub)
                             (let loop ((i 0) (k 0))
                               (cond ((> (+ i (string-length sub)) (string-length s)) k)
                                     ((string=? sub (substring s i (+ i (string-length sub)))) (loop (+ i 1) (+ k 1)))
                                     (else (loop (+ i 1) k)))))))
       (list (filter (lambda (n) (not (assq n on-tags)))
                     (filter (lambda (n) (not (memq n tagged-statement-names))) tag-statement-names))
             (map car (filter (lambda (s) (or (contains? (cdr s) " OR ") (contains? (cdr s) "ON CONFLICT"))) on-tags))
             (map car (filter (lambda (s)
                                (< (count-of-text (cdr s) "owner = ")
                                   (+ (count-of-text (cdr s) "FROM node_tags") (count-of-text (cdr s) "JOIN node_tags"))))
                              on-tags)))))))

(test-equal "statements: the filter's thirty are listed, each names the owner, joins nodes by the owner, reads no body and no revisions, and leaves a purged node out"
  '()
  (attempt
   (lambda ()
     (filter (lambda (name)
               (let ((s (statement-of name)))
                 (not (and s (owner-scoped? s)
                           (or (contains? s "n.owner = t.owner") (contains? s "t.owner = n.owner"))
                           (contains? s "n.state <> 'purged'")
                           (contains? s "n.state = ?")
                           (not (contains? s "body"))
                           (not (contains? s "revisions"))))))
             tagged-statement-names))))

(test-equal "imports: (techo node-store) does not import (techo tags)"
  #f
  (attempt
   (lambda ()
     (let* ((lib (call-with-input-file (loaded-source "techo/node-store.sls") read))
            (imports (cdr (cadddr lib))))
       (exists (lambda (spec) (and (member '(techo tags) (let flat ((x spec)) (if (pair? x) (cons x (apply append (map flat x))) '()))) #t))
               imports)))))

(for-each
 (lambda (name)
   (test-equal (string-append "statements: " (symbol->string name) " does not name body (H12)")
     '(#t #f)
     (attempt
      (lambda ()
        (let ((s (statement-of name)))
          (list (string? s) (and (string? s) (contains? s "body"))))))))
 tag-statement-names)

(test-end "node-store")

(exit (suite-exit-status runner))
