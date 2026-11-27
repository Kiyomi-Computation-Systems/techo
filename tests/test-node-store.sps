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
        (only (techo nodes) node-kinds child-moves? child-kind-filter))

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
         (let ((made (ok-of (w (lambda (tx) (node->list (insert-node! tx A1 acct-a "note" "Title" "Body text" "text/markdown" "{}" #f 5000)))))))
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
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "task" "t" "b" "text/plain" "{}" #f 1)))
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
               (r (lambda (tx) (nodes-page tx acct-a "active" 'any #f 10)))
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
         (w (lambda (tx) (insert-node! tx A1 acct-a "project" "T1" "B1" "text/markdown" "{}" #f 100)))
         (let* ((s1 (snap->list (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 1))))))
                (made (ok-of (w (lambda (tx) (node->list (write-node! tx A1 acct-a 1 "T2" "B2" "text/plain" "{\"a\":1}" "update" 200))))))
                (read (node->list (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1))))))
                (s2 (snap->list (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 2)))))))
           (w (lambda (tx) (write-node! tx A1 acct-a 2 "T3" "B3" "text/html" "{}" "update" 300)))
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
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f 1)))
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
                  (x (w (lambda (tx) (write-node! tx A1 acct-a 1 "T2" "B1" "a/a" "{}" "update" 2))))
                  (c2 (check))
                  (y (w (lambda (tx) (write-node! tx A1 acct-a 2 "T2" "B3" "b/b" "{\"k\":[1]}" "restore" 3))))
                  (c3 (check)))
             (list 'ok (list c1 c2 c3)))))))))

(test-equal "write: a wrong expected revision raises with only the id and expected as irritants, and leaves nothing in the transaction"
  (list 'raised (list (nid 1) 7) #f #f
        '(1 1 1))
  (attempt
   (lambda ()
     (with-store "stale.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f 1)))
         (let ((res (ok-of (w (lambda (tx)
                                (let ((c (caught (lambda () (write-node! tx A1 acct-a 7 "SECRET-TITLE" "SECRET-BODY" "a/a" "{}" "update" 2)))))
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
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f 1)))
         (let* ((before (ok-of (r all-rows)))
                (res (ok-of (w (lambda (tx)
                                 (caught (lambda () (write-node! tx A1 acct-b 1 "SECRET-TITLE" "SECRET-BODY" "a/a" "{}" "update" 2)))))))
                (via-doorway (w (lambda (tx) (write-node! tx A1 acct-b 1 "SECRET-TITLE" "SECRET-BODY" "a/a" "{}" "update" 2)))))
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
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f 1)))
         (let* ((before (ok-of (r all-rows)))
                (res (w (lambda (tx)
                          (write-node! tx A1 acct-a 1 "T2" "B2" "a/a" "{}" "update" 2)
                          (write-node! tx A1 acct-a 1 "T3" "B3" "a/a" "{}" "update" 3)))))
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
              (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f 10)
              (insert-node! tx A2 acct-a "note" "t" "b" "a/a" "{}" #f 11)
              (insert-node! tx B1 acct-b "note" "t" "b" "a/a" "{}" #f 12)
              (write-node! tx A1 acct-a 1 "t" "b2" "a/a" "{}" "update" 13)
              (write-node! tx B1 acct-b 1 "t" "b2" "a/a" "{}" "update" 14)
              (write-node! tx A1 acct-a 2 "t" "b3" "a/a" "{}" "restore" 15)))
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
                    (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f 1)
                    (write-node! tx A1 acct-a 1 "t" "b" "a/a" "{}" "update" 2)
                    (write-node! tx A1 acct-a 2 "t" "b" "a/a" "{}" "update" 3)))
         (list (r (lambda (tx) (node-head tx acct-b A1)))
               (r (lambda (tx) (node-of-owner tx acct-b A1)))
               (r (lambda (tx) (snapshot-of tx acct-b A1 1)))
               (r (lambda (tx) (snapshot-of tx acct-b A1 3)))
               (r (lambda (tx) (nodes-page tx acct-b "active" 'any #f 10)))
               (r (lambda (tx) (snapshots-page tx acct-b A1 #f 10)))
               (r (lambda (tx) (node-in-use? tx A1)))
               (r (lambda (tx) (node-head tx acct-a A1)))))))))

(test-equal "owner: B's insert of A's id is refused by the table, and A's node is as it was"
  '((raised (sqlite constraint)) #t)
  (attempt
   (lambda ()
     (with-store "dup-id.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f 1)))
         (let ((before (ok-of (r all-rows))))
           (list (w (lambda (tx) (insert-node! tx A1 acct-b "note" "x" "y" "a/a" "{}" #f 2)))
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
              (for-each (lambda (n) (insert-node! tx (nid n) acct-a "note" "t" "body" "a/a" "{}" #f n)) '(5 1 3 2 6))
              (insert-node! tx (nid 4) acct-b "note" "t" "body" "a/a" "{}" #f 9)))
         (let* ((p1 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any #f 2)))))
                (p2 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any (node-id (cadr p1)) 2)))))
                (p3 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any (node-id (cadr p2)) 2)))))
                (p4 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any (node-id (car p3)) 2)))))
                (all (append p1 p2 p3)))
           (list (node-ids all)
                 (map node-body all)
                 (map node-ids (list p1 p2 p3))
                 (node-ids (ok-of (r (lambda (tx) (nodes-page tx acct-b "active" 'any #f 10)))))
                 p4))))))
  )

(test-equal "nodes-page: a page row has every other field of the node"
  (list A1 acct-a acct-a "journal" "T" #f "a/a" "{}" 1 7 7)
  (attempt
   (lambda ()
     (with-store "page-fields.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "journal" "T" "body" "a/a" "{}" #f 7)))
         (node->list (car (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any #f 5)))))))))))

(test-equal "snapshots-page: newest first, strictly falling, BEFORE exclusive, body #f, the owner's only"
  (list '(5 4) '(3 2) '(1) '(#f #f) '(5 4 3 2 1) '(4 3 2 1) '())
  (attempt
   (lambda ()
     (with-store "snaps.db"
       (lambda (w r p)
         (w (lambda (tx)
              (set-up! tx)
              (insert-node! tx A1 acct-a "note" "t1" "b1" "a/a" "{}" #f 1)
              (insert-node! tx B1 acct-b "note" "u1" "c1" "a/a" "{}" #f 1)
              (write-node! tx A1 acct-a 1 "t2" "b2" "a/a" "{}" "update" 2)
              (write-node! tx A1 acct-a 2 "t3" "b3" "a/a" "{}" "update" 3)
              (write-node! tx A1 acct-a 3 "t4" "b4" "a/a" "{}" "update" 4)
              (write-node! tx A1 acct-a 4 "t5" "b5" "a/a" "{}" "update" 5)))
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
              (insert-node! tx A1 acct-a "note" "t1" "b1" "a/a" "{}" #f 10)
              (write-node! tx A1 acct-a 1 "t2" "b2" "a/a" "{}" "update" 20)
              (write-node! tx A1 acct-a 2 "t3" "b3" "c/c" "{\"x\":1}" "update" 30)))
         (snap->list (car (ok-of (r (lambda (tx) (snapshots-page tx acct-a A1 #f 1)))))))))))

;;; A snapshot of the right node

;; two-nodes! : Tx -> Void
;; A's nodes A1 and A2, each at revision 2, with titles and bodies of their
;; own at each revision; B's B1 at revision 1.
(define (two-nodes! tx)
  (set-up! tx)
  (insert-node! tx A1 acct-a "note" "A1 t1" "A1 b1" "a/a" "{}" #f 1)
  (insert-node! tx A2 acct-a "note" "A2 t1" "A2 b1" "a/a" "{}" #f 2)
  (insert-node! tx B1 acct-b "note" "B1 t1" "B1 b1" "a/a" "{}" #f 3)
  (write-node! tx A1 acct-a 1 "A1 t2" "A1 b2" "a/a" "{}" "update" 4)
  (write-node! tx A2 acct-a 1 "A2 t2" "A2 b2" "a/a" "{}" "update" 5))

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
              (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" #f 1)
              (write-node! tx A1 acct-a 1 "t" "b2" "a/a" "{}" "update" 2)
              (insert-node! tx A2 acct-a "note" "t" "b" "a/a" "{}" #f 3)
              (insert-node! tx B1 acct-b "note" "t" "b" "a/a" "{}" #f 4)))
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
           (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "t" big "a/a" "{}" #f 1)))
           (list (equal? big (node-body (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1))))))
                 (equal? big (snapshot-body (ok-of (r (lambda (tx) (snapshot-of tx acct-a A1 1))))))
                 (let ((big2 (string-append big "z")))
                   (w (lambda (tx) (write-node! tx A1 acct-a 1 "t" big2 "a/a" "{}" "update" 2)))
                   (equal? big2 (node-body (ok-of (r (lambda (tx) (node-of-owner tx acct-a A1)))))))))))))
  )

(test-equal "text: non-ASCII title, body, content type and props round-trip"
  (list "t\x00e9;te \x65e5;\x672c;" "\x3b1;\x3b2;\x3b3; \x1f600; end" "text/\x3b4;" "{\"k\":\"\x1f600;\"}")
  (attempt
   (lambda ()
     (with-store "utf8.db"
       (lambda (w r p)
         (w (lambda (tx) (set-up! tx)
                    (insert-node! tx A1 acct-a "note" "t\x00e9;te \x65e5;\x672c;" "\x3b1;\x3b2;\x3b3; \x1f600; end" "text/\x3b4;" "{\"k\":\"\x1f600;\"}" #f 1)))
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
  (for-each (lambda (n) (insert-node! tx (nid n) acct-a "note" (string-append "T" (number->string n)) (string-append "B" (number->string n)) "a/a" "{}" #f 10))
            '(1 2 3 4 5 6))
  (insert-node! tx (nid 7) acct-b "note" "T7" "B7" "a/a" "{}" #f 10)
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
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "text/markdown" "{}" #f 100)))
         (w (lambda (tx) (write-node! tx A1 acct-a 1 "T2" "B2" "text/plain" "{\"a\":1}" "update" 200)))
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
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "task" "T1" "B1" "text/markdown" "{\"k\":1}" #f 100)))
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
                                (list (nothing-changes tx (lambda () (write-node! tx (nid 3) acct-a 2 "SECRET-T" "SECRET-B" "a/a" "{}" "update" 50)))
                                      (nothing-changes tx (lambda () (write-node! tx (nid 4) acct-a 3 "SECRET-T" "SECRET-B" "a/a" "{}" "update" 50)))))))))
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
         (let ((n (ok-of (w (lambda (tx) (write-node! tx (nid 2) acct-a 2 "T2b" "B2b" "a/a" "{}" "update" 60))))))
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
         (node-state (ok-of (w (lambda (tx) (write-node! tx (nid 1) acct-a 1 "T" "B" "a/a" "{}" "update" 60))))))))))

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
         (w (lambda (tx) (set-up! tx) (insert-node! tx A1 acct-a "note" "T1" "B1" "a/a" "{}" #f 10)
                         (write-node! tx A1 acct-a 1 "T1" "B2" "a/a" "{}" "update" 15)
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
                 (map (lambda (st) (ok-of (r (lambda (tx) (node-ids (nodes-page tx acct-a st 'any #f 10))))))
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
                        (ok-of (r (lambda (tx) (node-ids (nodes-page tx acct-a st 'any after n)))))))
                (states (map (lambda (st) (page st #f 10)) '("active" "archived" "trashed" "purged"))))
           (append states
                   (list (list-sort < (apply append states))
                         (let* ((p1 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any #f 2)))))
                                (p2 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any (node-id (cadr p1)) 2)))))
                                (p3 (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any (node-id (car p2)) 2))))))
                           (map node-ids (list p1 p2 p3)))
                         (ok-of (r (lambda (tx) (node-ids (nodes-page tx acct-b "active" 'any #f 10)))))
                         (list (page "archived" (nid 1) 10) (page "trashed" (nid 2) 10) (page "trashed" (nid 3) 10))))))))))

(test-equal "nodes-page: a page's nodes carry their state, and no body"
  '(("active" #f) ("archived" #f) ("trashed" #f))
  (attempt
   (lambda ()
     (with-store "state-pages-fields.db"
       (lambda (w r p)
         (w lc-set-up!)
         (map (lambda (st)
                (let ((n (car (ok-of (r (lambda (tx) (nodes-page tx acct-a st 'any #f 1)))))))
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

(test-equal "statements: every statement (techo node-store) runs is (statement 'NAME), NAME listed, none written in place; and every one listed is run"
  '(() ())
  (attempt
   (lambda ()
     (let* ((lib (call-with-input-file (loaded-source "techo/node-store.sls") read))
            (args (sql-arguments (list-tail lib 4)))
            (names (map statement-name args)))
       (list (filter (lambda (s) (not (let ((n (statement-name s))) (and n (assq n node-store-statements)))))
                     args)
             (filter (lambda (n) (not (memq n names))) (map car node-store-statements)))))))

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
   set-node-state move-node purge-snapshots purge-node))

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
;; amended); rows-changed, which reads no table; and the three INSERTs,
;; which write the owner they are handed.
(define owner-exempt
  '((node-in-use . "SELECT id FROM nodes ") (rows-changed . "SELECT changes()")
    (insert-node . "INSERT ") (insert-snapshot . "INSERT ") (insert-change . "INSERT ")))

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
             '(node-head node-of-owner snapshot-exists snapshot-of snapshots-page snapshots-page-before
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
  (insert-node! tx (nid 1) acct-a "project" "T1" "B1" "a/a" "{}" #f 10)
  (insert-node! tx (nid 2) acct-a "note" "T2" "B2" "a/a" "{}" (nid 1) 10)
  (insert-node! tx (nid 3) acct-a "task" "T3" "B3" "a/a" "{}" (nid 1) 10)
  (insert-node! tx (nid 4) acct-a "note" "T4" "B4" "a/a" "{}" (nid 1) 10)
  (insert-node! tx (nid 5) acct-a "note" "T5" "B5" "a/a" "{}" (nid 1) 10)
  (insert-node! tx (nid 6) acct-a "note" "T6" "B6" "a/a" "{}" (nid 2) 10)
  (insert-node! tx (nid 7) acct-a "project" "T7" "B7" "a/a" "{}" #f 10)
  (insert-node! tx (nid 20) acct-b "project" "T20" "B20" "a/a" "{}" #f 10)
  (insert-node! tx (nid 21) acct-b "note" "T21" "B21" "a/a" "{}" (nid 1) 10)
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
         (let* ((made (ok-of (w (lambda (tx) (insert-node! tx (nid 30) acct-a "note" "t" "b" "a/a" "{}" (nid 1) 11)))))
                (top (ok-of (w (lambda (tx) (insert-node! tx (nid 31) acct-a "note" "t" "b" "a/a" "{}" #f 11)))))
                (read (ok-of (r (lambda (tx) (node-of-owner tx acct-a (nid 2))))))
                (paged (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" 'any #f 100)))))
                (replaced (ok-of (w (lambda (tx) (write-node! tx (nid 2) acct-a 1 "T" "B" "a/a" "{}" "update" 50)))))
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
         (list (w (lambda (tx) (insert-node! tx A1 acct-a "note" "t" "b" "a/a" "{}" (nid 99) 1)))
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
  (ok-of (w-r (lambda (tx) (first-bytes (map node-id (nodes-page tx owner state parent after n)))))))

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
                 (exists node-body (ok-of (r (lambda (tx) (nodes-page tx acct-a "active" (nid 1) #f 10))))))))))))

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
      (insert-node! tx (nidn i) acct-a "project" "t" "b" "a/a" "{}" (and (> i 1) (nidn (- i 1))) 10))))

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
              (insert-node! tx (nidn 1) acct-b "project" "t" "b" "a/a" "{}" #f 10)
              (insert-node! tx (nidn 2) acct-b "project" "t" "b" "a/a" "{}" (nidn 1) 10)
              (insert-node! tx (nidn 3) acct-a "project" "t" "b" "a/a" "{}" (nidn 2) 10)))
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
                (insert-node! tx (nid 1) acct-a "project" "t" "b" "a/a" "{}" #f 10)
                (let loop ((cs combos) (i 0))
                  (unless (null? cs)
                    (insert-node! tx (child-id i) acct-a (cdar cs) "t" "b" "a/a" "{}" (nid 1) 10)
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
         (w (lambda (tx) (insert-node! tx (nid 8) acct-a "note" "t" "b" "a/a" "{}" (nid 7) 11)
                         (set-node-state! tx (nid 8) acct-a 1 "trashed" "trash" 12)
                         (purge-node! tx (nid 8) acct-a 2 13)))
         ;; node 9 at the top with only B's child
         (w (lambda (tx) (insert-node! tx (nid 9) acct-a "project" "t" "b" "a/a" "{}" #f 11)
                         (insert-node! tx (nid 22) acct-b "note" "t" "b" "a/a" "{}" (nid 9) 11)))
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
              (insert-node! tx (nidn 1) acct-a "project" "t" "b" "a/a" "{}" #f 10)
              (do ((i 100 (+ i 1))) ((= i 1100))
                (insert-node! tx (nidn i) acct-a "note" "t" "b" "a/a" "{}" (nidn 1) 10))
              (tx-execute! tx "UPDATE nodes SET state = 'trashed' WHERE parent = ?" (nidn 1))
              (do ((i 2000 (+ i 1))) ((= i 2005))
                (insert-node! tx (nidn i) acct-a "note" "t" "b" "a/a" "{}" (nidn 1) 10))))
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
         (w (lambda (tx) (write-node! tx (nid 5) acct-a 1 "T5b" "B5b" "text/plain" "{\"a\":1}" "update" 100)))
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
         (w (lambda (tx) (insert-node! tx (nid 8) acct-a "note" "t" "b" "a/a" "{}" (nid 7) 11)
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
         (w (lambda (tx) (insert-node! tx (nid 8) acct-a "note" "t" "b" "a/a" "{}" (nid 7) 11)
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
         (let ((res (w (lambda (tx) (let ((k (- (length args) 1))) (apply insert-node! tx (append (reverse (cdr (reverse args))) (list #f (car (reverse args))))))))))
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

(test-end "node-store")

(exit (suite-exit-status runner))
