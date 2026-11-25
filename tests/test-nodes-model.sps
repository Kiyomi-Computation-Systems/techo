#!r6rs
;;; The nodes model suite: ADR-0007's third layer for D5's versioned write
;;; (slice 4, task 5a). Seeded random sequences of requests by two accounts
;;; run against the real handlers (make-app inside wrap-server, raw HTTP
;;; through a test host) and real SQLite (the test doorway on a migrated
;;; file), with a wall clock the sequence steps. After every request the
;;; answer is compared with what write-step and the model say, and held to
;;; D5 in the plan's words; the three tables and every key's last_used are
;;; read whole and held to H1 to H6, H11, H15 and H16, and to the model's
;;; world. The machinery and the model are (nodes-model).
;;;
;;;   1. the oracle on a hand-made world, pure
;;;   2. the run: SEQUENCES seeds of 40 to 60 requests, every one to agree
;;;   3. coverage: every cell of D5 that can happen stepped, each at least
;;;      CELL-FLOOR times, and printed; every aim of the generator taken
;;;   4. teeth: the oracle given a changed table disagrees with the handlers
;;;
;;; Replay one seed, each request printed as it goes:
;;;   scripts/guix-env sh -c 'TECHO_NODES_MODEL_SEED=17 make test SUITES=tests/test-nodes-model.sps'
;;; Then only that seed runs, and only its agreement is asserted.
;;;
;;; Its files are under build/test-nodes-model/<unique>/, emptied at the
;;; start. Everything that can raise is computed under `attempt`, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (only (chezscheme) getenv real-time format)
        (srfi :64)
        (techo-testing)
        (only (http-support) fresh-dir open-test-store close-test-store! contains?)
        (only (techo nodes) write-step write-rows)
        (nodes-model))

(define runner (test-runner-simple))
(test-runner-current runner)

(define started (real-time))

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))
(define (take* xs n) (if (or (null? xs) (= n 0)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))

(test-begin "nodes-model")

;;; 1. The oracle, on a hand-made world

(define t0 1795515226123)
(define day 86400000)
(define a1 (make-bytevector 16 1))
(define a2 (make-bytevector 16 2))
(define b1 (make-bytevector 16 3))
(define (nid n) (node-id-of n))

(define (content kind title body) (make-content kind title body "text/plain" #f))
(define (create-at at tag key n kind title)
  (make-event 'put at tag key (nid n) 'create '() (content kind title "a body") #f #f #f '()))
(define (replace-at at tag key n rev kind title)
  (make-event 'put at tag key (nid n) rev '() (content kind title "a new body") #f #f #f '()))
(define (restore-at at tag key n rev k)
  (make-event 'restore at tag key (nid n) rev '() #f k #f #f '()))
(define (read-at at tag kind n k)
  (make-event kind at tag (if (eq? tag 'a) a1 b1) (and n (nid n)) #f '() #f k #f #f '()))
(define (bare-at at tag kind n pre)
  (make-event kind at tag (if (eq? tag 'a) a1 b1) (nid n) pre '()
              (and (eq? kind 'put) (content "note" "t" "b")) (and (eq? kind 'restore) 1) #f #f '()))

;; summary : Expectation -> (List Status Code ETag Cells Problem)
(define (summary x)
  (list (expectation-status x) (expectation-code x) (expectation-etag x) (expectation-cells x)
        (expectation-problem x)))

;; The hand world: a's node 1, a note, made at t0+1 by key a1 and replaced
;; at t0+2, so at revision 2; b's node 2, a task, at revision 1.
(define hand
  (attempt
   (lambda ()
     (fold-left (lambda (w e) (expectation-world (expect write-step w e)))
                model-start
                (list (create-at (+ t0 1) 'a a1 1 "note" "first")
                      (replace-at (+ t0 2) 'a a1 1 1 #f "second")
                      (create-at (+ t0 3) 'b b1 2 "task" "theirs"))))))

(define at (+ t0 10))

(define (oracle step e) (attempt (lambda () (summary (expect step hand e)))))

(test-equal "oracle: a create of an id no account holds is none x create, a 201 at revision 1"
  '(201 #f "\"1\"" ((none create)) #f)
  (oracle write-step (create-at at 'a a1 3 "journal" "new")))

(test-equal "oracle: a create of an id the account holds is differ x create, a 412"
  '(412 "precondition_failed" #f ((differ create)) #f)
  (oracle write-step (create-at at 'a a1 1 "note" "again")))

(test-equal "oracle: a create of an id the other account holds is differ x create, a 412 (D8)"
  '(412 "precondition_failed" #f ((differ create)) #f)
  (oracle write-step (create-at at 'a a1 2 "task" "theirs")))

(test-equal "oracle: a replace at the node's revision, kind left out or the same, is match x replace, a 200 at the next"
  '((200 #f "\"3\"" ((match replace)) #f) (200 #f "\"3\"" ((match replace)) #f))
  (list (oracle write-step (replace-at at 'a a1 1 2 #f "third"))
        (oracle write-step (replace-at at 'a a1 1 2 "note" "third"))))

(test-equal "oracle: a replace at an earlier revision, or one past it, is differ x replace, a 412"
  '((412 "precondition_failed" #f ((differ replace)) #f) (412 "precondition_failed" #f ((differ replace)) #f))
  (list (oracle write-step (replace-at at 'a a1 1 1 #f "stale"))
        (oracle write-step (replace-at at 'a a1 1 3 #f "ahead"))))

(test-equal "oracle: a replace naming another kind is match x replace-other-kind (409); stale, differ x it (412)"
  '((409 "kind_fixed" #f ((match replace-other-kind)) #f)
    (412 "precondition_failed" #f ((differ replace-other-kind)) #f))
  (list (oracle write-step (replace-at at 'a a1 1 2 "task" "a task now"))
        (oracle write-step (replace-at at 'a a1 1 1 "task" "a task now"))))

(test-equal "oracle: the other account at a's node and a's revision is none x replace, a 404, whatever kind (H6)"
  '((404 "not_found" #f ((none replace)) #f) (404 "not_found" #f ((none replace)) #f))
  (list (oracle write-step (replace-at at 'b b1 1 2 #f "mine now"))
        (oracle write-step (replace-at at 'b b1 1 2 "task" "mine now"))))

(test-equal "oracle: restoring snapshot 1, or the newest, at the node's revision is match x restore, a 200"
  '((200 #f "\"3\"" ((match restore)) #f) (200 #f "\"3\"" ((match restore)) #f))
  (list (oracle write-step (restore-at at 'a a1 1 2 1))
        (oracle write-step (restore-at at 'a a1 1 2 2))))

(test-equal "oracle: a snapshot the node does not have is match x restore-unknown, a 404"
  '(404 "not_found" #f ((match restore-unknown)) #f)
  (oracle write-step (restore-at at 'a a1 1 2 5)))

(test-equal "oracle: a stale restore is differ x restore, or x restore-unknown, a 412 either way"
  '((412 "precondition_failed" #f ((differ restore)) #f)
    (412 "precondition_failed" #f ((differ restore-unknown)) #f))
  (list (oracle write-step (restore-at at 'a a1 1 1 1))
        (oracle write-step (restore-at at 'a a1 1 1 5))))

(test-equal "oracle: the other account restoring a's node is none x restore-unknown, a 404"
  '(404 "not_found" #f ((none restore-unknown)) #f)
  (oracle write-step (restore-at at 'b b1 1 2 1)))

(test-equal "oracle: no precondition is 428, a malformed one 400, and neither steps the table"
  '((428 "precondition_required" #f () #f) (400 "invalid_request" #f () #f)
    (428 "precondition_required" #f () #f) (400 "invalid_request" #f () #f))
  (list (oracle write-step (bare-at at 'a 'put 1 'missing))
        (oracle write-step (bare-at at 'a 'put 1 'invalid))
        (oracle write-step (bare-at at 'a 'restore 1 'missing))
        (oracle write-step (bare-at at 'a 'restore 1 'invalid))))

;; restored : World     the hand world after a's restore of snapshot 1 at t0+10
(define restored
  (attempt (lambda () (expectation-world (expect write-step hand (restore-at at 'a a1 1 2 1))))))

(test-equal "oracle: a restore copies the snapshot as the next revision; a's change rows are 1 to 3: create update restore"
  (list 3 "first" "a body" at (+ t0 1)
        (list (list 1 1 "create" (+ t0 1)) (list 2 2 "update" (+ t0 2)) (list 3 3 "restore" at)))
  (attempt
   (lambda ()
     (let* ((n (world-node restored (nid 1)))
            (s (car (mnode-snaps n))))
       (list (msnap-revision s) (msnap-title s) (msnap-body s) (msnap-created s) (mnode-created n)
             (map (lambda (c) (list (mchange-seq c) (mchange-revision c) (mchange-op c) (mchange-created c)))
                  (world-changes-of restored 'a)))))))

(test-equal "oracle: b's change rows are numbered on their own, from 1"
  '(1)
  (attempt (lambda () (map mchange-seq (world-changes-of restored 'b)))))

;; D6: a1 was first used at t0+1. A write a day later is not due; a day
;; and a ms later it is; a refusal then leaves last_used as it was.
(test-equal "oracle: last_used is set by the first write, again only past a day, never by a refusal or a read"
  (list (+ t0 1) (+ t0 1) (+ t0 1 day 1) (+ t0 1) (+ t0 1))
  (attempt
   (lambda ()
     (let ((lu (lambda (e) (world-key-last-used (expectation-world (expect write-step hand e)) a1))))
       (list (world-key-last-used hand a1)
             (lu (replace-at (+ t0 1 day) 'a a1 1 2 #f "a day on"))
             (lu (replace-at (+ t0 1 day 1) 'a a1 1 2 #f "a day and a ms on"))
             (lu (replace-at (+ t0 1 day 1) 'a a1 1 1 #f "stale, a day and a ms on"))
             (lu (read-at (+ t0 1 day 1) 'a 'get-node 1 #f)))))))

(test-equal "oracle: the asking key alone is touched: a2's first write sets a2's, not a1's"
  (list (+ t0 1) at)
  (attempt
   (lambda ()
     (let ((w (expectation-world (expect write-step hand (replace-at at 'a a2 1 2 #f "by a2")))))
       (list (world-key-last-used w a1) (world-key-last-used w a2))))))

(test-equal "oracle: reads: the node with its ETag, the list without bodies, revisions newest first, a snapshot whole"
  '((200 "\"2\"") (404 #f) 1 (2 1) (200 "first") (404 #f))
  (attempt
   (lambda ()
     (let ((x (lambda (e) (expect write-step hand e))))
       (list (list (expectation-status (x (read-at at 'a 'get-node 1 #f)))
                   (expectation-etag (x (read-at at 'a 'get-node 1 #f))))
             (list (expectation-status (x (read-at at 'b 'get-node 1 #f)))
                   (expectation-etag (x (read-at at 'b 'get-node 1 #f))))
             (length (expectation-items (x (read-at at 'a 'list-nodes #f #f))))
             (map (lambda (item) (cdr (assoc "revision" item)))
                  (expectation-items (x (read-at at 'a 'list-revisions 1 #f))))
             (list (expectation-status (x (read-at at 'a 'get-snapshot 1 1)))
                   (cdr (assoc "title" (expectation-json (x (read-at at 'a 'get-snapshot 1 1))))))
             (list (expectation-status (x (read-at at 'a 'get-snapshot 1 3)))
                   (expectation-json (x (read-at at 'a 'get-snapshot 1 3)))))))))

(test-equal "oracle: no list item holds a body; a node answer does"
  '(#f #t)
  (attempt
   (lambda ()
     (list (and (assoc "body" (car (expectation-items (expect write-step hand (read-at at 'a 'list-nodes #f #f))))) #t)
           (and (assoc "body" (expectation-json (expect write-step hand (read-at at 'a 'get-node 1 #f)))) #t)))))

;; Changed tables, as the oracle's step.

;; kind-written : a replace naming another kind is written.
(define (kind-written found event)
  (if (and (eq? found 'match) (eq? event 'replace-other-kind))
      (values 'differ 'write)
      (write-step found event)))

;; in-use-404 : a create on an id in use is a 404.
(define (in-use-404 found event)
  (if (and (eq? found 'differ) (eq? event 'create))
      (values 'differ 'refuse-404)
      (write-step found event)))

;; copy-on-put : a replace at the revision is a copy.
(define (copy-on-put found event)
  (if (and (eq? found 'match) (eq? event 'replace))
      (values 'differ 'copy)
      (write-step found event)))

;; next-stays : a replace at the revision writes, and names match next.
(define (next-stays found event)
  (if (and (eq? found 'match) (eq? event 'replace))
      (values 'match 'write)
      (write-step found event)))

(test-equal "oracle: its answer is its step's: a table that writes another kind answers 200, the kind kept (H11)"
  '((200 #f "\"3\"" ((match replace-other-kind)) #f) "note")
  (attempt
   (lambda ()
     (let ((x (expect kind-written hand (replace-at at 'a a1 1 2 "task" "a task now"))))
       (list (summary x) (mnode-kind (world-node (expectation-world x) (nid 1))))))))

(test-equal "oracle: a command that makes no sense for the request is a step the model cannot take"
  '(#t #t)
  (attempt
   (lambda ()
     (list (contains? (expectation-problem (expect copy-on-put hand (replace-at at 'a a1 1 2 #f "x")))
                      "which only a restore performs")
           (contains? (expectation-problem (expect next-stays hand (replace-at at 'a a1 1 2 #f "x")))
                      "names next match, but the same request sent again finds differ")))))

;; plan-status, with no table: what each request must be answered.
(define (plan e) (attempt (lambda () (car (plan-status hand e)))))

(test-equal "plan's words: a fresh create 201, a used id 412, the other's node 404, stale 412 before kind 409"
  '(201 412 412 404 412 409 200 404 412 200 428 400)
  (list (plan (create-at at 'a a1 3 "note" "x"))
        (plan (create-at at 'a a1 1 "note" "x"))
        (plan (create-at at 'b b1 1 "note" "x"))
        (plan (replace-at at 'b b1 1 2 #f "x"))
        (plan (replace-at at 'a a1 1 1 "task" "x"))
        (plan (replace-at at 'a a1 1 2 "task" "x"))
        (plan (replace-at at 'a a1 1 2 "note" "x"))
        (plan (restore-at at 'a a1 1 2 9))
        (plan (restore-at at 'a a1 1 1 9))
        (plan (restore-at at 'a a1 1 2 2))
        (plan (bare-at at 'a 'restore 1 'missing))
        (plan (bare-at at 'a 'put 1 'invalid))))

(test-equal "plan's words: another account's node, or a snapshot it lacks, is missing to a read"
  '(200 404 200 404 200 404 200)
  (list (plan (read-at at 'a 'get-node 1 #f)) (plan (read-at at 'b 'get-node 1 #f))
        (plan (read-at at 'a 'list-revisions 1 #f)) (plan (read-at at 'b 'list-revisions 1 #f))
        (plan (read-at at 'a 'get-snapshot 1 2)) (plan (read-at at 'a 'get-snapshot 1 3))
        (plan (read-at at 'b 'list-nodes #f #f))))

;;; The store every sequence runs on, emptied by each

(define dir (attempt (lambda () (fresh-dir "test-nodes-model"))))
(define store (attempt (lambda () (open-test-store dir "model.db"))))

;; run-one : Step Natural Boolean -> (U Verdict (List 'raised String))
(define (run-one step seed trace?)
  (attempt (lambda () (run-sequence store step seed trace?))))

(define (raised? x) (and (pair? x) (eq? (car x) 'raised)))

;; failure : (U Verdict (List 'raised String)) -> (U String #f)
(define (failure v)
  (cond ((raised? v) (string-append "a sequence raised: " (cadr v)))
        ((verdict-report v) => (lambda (r) r))
        (else #f)))

(define replay-seed
  (let ((s (getenv "TECHO_NODES_MODEL_SEED")))
    (and s (string->number s))))

;;; Replay: one seed, traced

(define replayed (and replay-seed (failure (run-one write-step replay-seed #t))))

(when replay-seed
  (when replayed (display replayed))
  (test-equal (format "replay of seed ~a: every request agrees" replay-seed) #f replayed))

;;; 2. The run

(define sequences 300)
(define verdicts (if replay-seed '() (map (lambda (s) (run-one write-step s #f)) (from-to 1 sequences))))
(define failures (filter (lambda (f) f) (map failure verdicts)))
(define agreed (filter (lambda (v) (not (or (raised? v) (verdict-report v)))) verdicts))

(for-each (lambda (f) (display f) (newline)) (take* failures 3))

;; tally : (Verdict -> (Listof (Pair K Natural))) -> Hashtable
(define (tally of)
  (let ((t (make-hashtable equal-hash equal?)))
    (for-each (lambda (v)
                (for-each (lambda (p) (hashtable-update! t (car p) (lambda (c) (+ c (cdr p))) 0))
                          (of v)))
              agreed)
    t))

(define cells-hit (tally verdict-cells))
(define aims-hit (tally verdict-aims))
(define steps (apply + (map verdict-steps agreed)))
(define requests (apply + (map verdict-requests agreed)))
(define shortest (fold-left min 1000 (map verdict-steps agreed)))
(define cant-happen
  (apply + (map verdict-cant-happen (filter (lambda (v) (not (raised? v))) verdicts))))

(define cell-floor 100)
(define aim-floor 100)
(define rare-floor 15)

;; What the generator must have aimed at, and what must have come of it.
(define aims
  '(create-fresh create-own create-other
    replace-own-current replace-own-stale replace-own-ahead replace-other-current replace-other-stale
    replace-missing-any kind-absent kind-same kind-other
    restore-own-current restore-own-stale restore-own-ahead restore-other-current restore-missing-any
    restore-snap-newest restore-snap-older restore-snap-unknown
    get-node-own get-node-other get-node-missing list-nodes
    list-revisions-own list-revisions-other list-revisions-missing
    get-snapshot-own get-snapshot-other get-snap-newest get-snap-older get-snap-unknown
    wait-ms wait-a-day wait-a-day-and-a-ms wait-days wait-to-a-day-after-use wait-past-a-day-after-use
    last-used-set refused-while-due id-in-capitals))

(define rare-aims
  '(no-precondition-put no-precondition-restore bad-precondition-put bad-precondition-restore
    bad-star bad-weak bad-list bad-bare bad-twice bad-both bad-zero bad-leading-zero bad-inner-space
    bad-none-match-tag bad-none-match-twice bad-create-on-restore))

(define (at-least floor n) (if (>= n floor) (list 'at-least floor) (list 'only n)))

(unless replay-seed
  (test-equal "the run: every sequence agrees with write-step, the plan's words and the laws (the first three that do not)"
    '()
    (take* failures 3))

  (test-equal "the run: every one of the sequences ran and agreed" sequences (length agreed))

  (test-equal "the run: every sequence is at least 40 requests" '(at-least 40) (at-least 40 shortest))

  (test-equal "the run: at least 12,000 requests" '(at-least 12000) (at-least 12000 steps))

  ;;; 3. Coverage

  (for-each
   (lambda (row)
     (test-equal (format "coverage: ~a x ~a (~a) is stepped at least ~a times"
                         (car row) (cadr row) (cadddr row) cell-floor)
       (list 'at-least cell-floor)
       (at-least cell-floor (hashtable-ref cells-hit (list (car row) (cadr row)) 0))))
   write-rows)

  (test-equal "coverage: the model steps no pair the table does not have"
    '()
    (filter (lambda (k) (not (exists (lambda (row) (equal? k (list (car row) (cadr row)))) write-rows)))
            (vector->list (hashtable-keys cells-hit))))

  (test-equal "coverage: no pair D5 says cannot happen was asked, in any sequence" 0 cant-happen)

  (for-each
   (lambda (aim)
     (test-equal (format "coverage: ~a at least ~a times" aim aim-floor)
       (list 'at-least aim-floor)
       (at-least aim-floor (hashtable-ref aims-hit aim 0))))
   aims)

  (for-each
   (lambda (aim)
     (test-equal (format "coverage: ~a at least ~a times" aim rare-floor)
       (list 'at-least rare-floor)
       (at-least rare-floor (hashtable-ref aims-hit aim 0))))
   rare-aims)

  (display (format "nodes-model: ~a sequences, ~a requests made, ~a HTTP requests sent, the shortest ~a\n"
                   (length agreed) steps requests shortest))
  (display "  the cells of D5 stepped:\n")
  (for-each (lambda (row)
              (display (format "    ~a x ~a (~a): ~a\n" (car row) (cadr row) (cadddr row)
                               (hashtable-ref cells-hit (list (car row) (cadr row)) 0))))
            write-rows)
  (display "  the aims:\n")
  (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0))))
            (append aims rare-aims))
  (display "  and with no floor:\n")
  (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0))))
            (list-sort (lambda (x y) (string<? (symbol->string x) (symbol->string y)))
                       (filter (lambda (aim) (not (or (memq aim aims) (memq aim rare-aims))))
                               (vector->list (hashtable-keys aims-hit))))))

;;; 4. Teeth: the oracle with a changed table, the handlers as they are

;; first-difference : Step (Listof Natural) -> (U String #f)
(define (first-difference step seeds)
  (let loop ((ss seeds))
    (if (null? ss)
        #f
        (or (failure (run-one step (car ss) #f)) (loop (cdr ss))))))

(unless replay-seed
  (test-equal "teeth: a table that writes another kind disagrees with the handlers' 409"
    #t
    (let ((f (first-difference kind-written (from-to 1 30))))
      (and f
           (contains? f "stepping match x replace-other-kind")
           (contains? f "status: the model has 200, the handlers answered 409")
           #t)))

  (test-equal "teeth: a table that answers a used id's create with 404 disagrees with the handlers' 412"
    #t
    (let ((f (first-difference in-use-404 (from-to 1 30))))
      (and f
           (contains? f "stepping differ x create")
           (contains? f "status: the model has 404, the handlers answered 412")
           #t))))

(unless (raised? store) (close-test-store! store))

(display (format "nodes-model: ~a ms\n" (- (real-time) started)))

(test-end "nodes-model")

(exit (suite-exit-status runner))
