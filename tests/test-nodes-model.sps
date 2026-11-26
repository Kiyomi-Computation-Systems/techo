#!r6rs
;;; The nodes model suite: ADR-0007's third layer for D5's versioned write
;;; (slice 4, task 5a) and the node lifecycle (slice 4b, task 4a). Seeded
;;; random sequences of requests by two accounts run against the real
;;; handlers (make-app inside wrap-server, raw HTTP through a test host) and
;;; real SQLite (the test doorway on a migrated file), with a wall clock the
;;; sequence steps. After every request the answer is compared with the
;;; model's, which is the plan's rules written again in (nodes-model), never
;;; the tables of (techo nodes); the answers are held to laws that need no
;;; model; the three tables and every key's last_used are read whole and
;;; held to laws that need no model (H1 to H6, H11, H2', H3', H15', H16,
;;; G3, G6, G9, G11, G12, G16) and to the model's world.
;;;
;;;   1. the oracle on a hand-made world, pure
;;;   2. the run: SEQUENCES seeds of 45 to 65 requests, every one to agree
;;;   3. coverage, printed and held to floors: D5's cells; the lifecycle's
;;;      18 (three states by five events and a write); node-command's
;;;      reachable cells, and no other; requests at purged ids, by route,
;;;      and a create by the owner and by the other account; the aims
;;;   4. teeth: the oracle given a twisted rule disagrees with the handlers
;;;
;;; Replay one seed, each request printed as it goes:
;;;   scripts/guix-env sh -c 'TECHO_NODES_MODEL_SEED=17 make test SUITES=tests/test-nodes-model.sps'
;;; Then only that seed runs, and only its agreement is asserted. The run's
;;; seeds are FIRST to FIRST + 299, FIRST 1 unless TECHO_NODES_MODEL_FIRST
;;; names another, so the floors can be held on other seeds.
;;;
;;; Its files are under build/test-nodes-model/<unique>/, emptied at the
;;; start. Everything that can raise is computed under `attempt`, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (only (chezscheme) getenv real-time format)
        (srfi :64)
        (techo-testing)
        (only (http-support) fresh-dir open-test-store close-test-store! contains?)
        (only (techo nodes) write-rows)
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
(define (repeat n x) (if (= n 0) '() (cons x (repeat (- n 1) x))))

(test-begin "nodes-model")

;;; 1. The oracle, on a hand-made world

(define t0 1795515226123)
(define day 86400000)
(define a1 (make-bytevector 16 1))
(define a2 (make-bytevector 16 2))
(define b1 (make-bytevector 16 3))
(define (nid n) (node-id-of n))
(define (key-of tag) (if (eq? tag 'a) a1 b1))

(define (content kind title body) (make-content kind title body "text/plain" #f))
(define (create-at at tag key n kind title)
  (make-event 'put at tag key (nid n) 'create '() (content kind title "a body") #f #f #f #f '()))
(define (replace-at at tag key n rev kind title)
  (make-event 'put at tag key (nid n) rev '() (content kind title "a new body") #f #f #f #f '()))
(define (restore-at at tag key n rev k)
  (make-event 'restore at tag key (nid n) rev '() #f k #f #f #f '()))
(define (life-at at tag key n rev ev)
  (make-event ev at tag key (nid n) rev '() #f #f #f #f #f '()))
(define (read-at at tag kind n k)
  (make-event kind at tag (key-of tag) (and n (nid n)) #f '() #f k #f #f #f '()))
(define (list-at at tag q)
  (make-event 'list-nodes at tag (key-of tag) #f #f '() #f #f #f q #f '()))
(define (bare-at at tag kind n pre)
  (make-event kind at tag (key-of tag) (nid n) pre '()
              (and (eq? kind 'put) (content "note" "t" "b")) (and (eq? kind 'restore) 1) #f #f #f '()))

;; summary : Expectation -> (List Status Code ETag Cells Problem)
(define (summary x)
  (list (expectation-status x) (expectation-code x) (expectation-etag x) (expectation-cells x)
        (expectation-problem x)))

(define (member-of alist name) (let ((p (and (list? alist) (assoc name alist)))) (if p (cdr p) 'absent)))

;; The hand world. a's node 1, a note, made at t0+1 by key a1 and replaced
;; at t0+2: active at 2. b's node 2, a task, active at 1. a's node 3, a
;; journal, archived at 2 (t0+5); a's node 4, a contact, trashed at 2
;; (t0+7); a's node 5, a project, trashed at 2 (t0+9) and purged at 3
;; (t0+10). Each archived or trashed node has the one snapshot, 1.
(define hand
  (attempt
   (lambda ()
     (fold-left (lambda (w e)
                  (let ((x (expect as-planned w e)))
                    (when (expectation-problem x)
                      (assertion-violation 'hand "the model cannot take a hand step" (expectation-problem x)))
                    (expectation-world x)))
                model-start
                (list (create-at (+ t0 1) 'a a1 1 "note" "first")
                      (replace-at (+ t0 2) 'a a1 1 1 #f "second")
                      (create-at (+ t0 3) 'b b1 2 "task" "theirs")
                      (create-at (+ t0 4) 'a a1 3 "journal" "kept")
                      (life-at (+ t0 5) 'a a1 3 1 'archive)
                      (create-at (+ t0 6) 'a a1 4 "contact" "binned")
                      (life-at (+ t0 7) 'a a1 4 1 'trash)
                      (create-at (+ t0 8) 'a a1 5 "project" "gone")
                      (life-at (+ t0 9) 'a a1 5 1 'trash)
                      (life-at (+ t0 10) 'a a1 5 2 'purge))))))

(define at (+ t0 20))

(define (oracle e) (attempt (lambda () (summary (expect as-planned hand e)))))
(define (after e) (attempt (lambda () (expectation-world (expect as-planned hand e)))))
(define (node-in w n) (world-node w (nid n)))
(define (status-code e) (attempt (lambda () (let ((x (expect as-planned hand e)))
                                              (list (expectation-status x) (expectation-code x))))))

(test-equal "oracle: the hand world is a's 1 active at 2, 3 archived at 2, 4 trashed at 2, 5 purged at 3, and b's 2 active at 1"
  '((1 active 2 (2 1)) (2 active 1 (1)) (3 archived 2 (1)) (4 trashed 2 (1)) (5 purged 3 ()))
  (attempt
   (lambda ()
     (map (lambda (k)
            (let ((n (node-in hand k)))
              (list k (mnode-state n) (mnode-revision n) (map msnap-revision (mnode-snaps n)))))
          '(1 2 3 4 5)))))

(test-equal "oracle: a create of an id no account has used is none x - x create, a 201 at 1, active, with its body"
  '((201 #f "\"1\"" ((none #f create)) #f) "active" "a body")
  (attempt
   (lambda ()
     (let ((x (expect as-planned hand (create-at at 'a a1 9 "journal" "new"))))
       (list (summary x) (member-of (expectation-json x) "state") (member-of (expectation-json x) "body"))))))

(test-equal "oracle: a create on an id in use is differ x - x create, a 412: the account's own, the other's, a purged one by its owner and by the other account (D8, G6)"
  (repeat 4 '(412 "precondition_failed" #f ((differ #f create)) #f))
  (list (oracle (create-at at 'a a1 1 "note" "again"))
        (oracle (create-at at 'a a1 2 "task" "theirs"))
        (oracle (create-at at 'a a1 5 "project" "back"))
        (oracle (create-at at 'b b1 5 "project" "mine now"))))

(test-equal "oracle: a replace at the node's revision, kind left out or the same, is match x active x replace, a 200 at the next"
  '((200 #f "\"3\"" ((match active replace)) #f) (200 #f "\"3\"" ((match active replace)) #f))
  (list (oracle (replace-at at 'a a1 1 2 #f "third"))
        (oracle (replace-at at 'a a1 1 2 "note" "third"))))

(test-equal "oracle: a replace at an earlier revision, or one past it, is differ x active x replace, a 412"
  '((412 "precondition_failed" #f ((differ active replace)) #f) (412 "precondition_failed" #f ((differ active replace)) #f))
  (list (oracle (replace-at at 'a a1 1 1 #f "stale"))
        (oracle (replace-at at 'a a1 1 3 #f "ahead"))))

(test-equal "oracle: a replace naming another kind is 409 kind_fixed; stale, it is 412"
  '((409 "kind_fixed" #f ((match active replace-other-kind)) #f)
    (412 "precondition_failed" #f ((differ active replace-other-kind)) #f))
  (list (oracle (replace-at at 'a a1 1 2 "task" "a task now"))
        (oracle (replace-at at 'a a1 1 1 "task" "a task now"))))

(test-equal "oracle: the other account at a's node and a's revision is none x - x replace, a 404, whatever kind (H6)"
  '((404 "not_found" #f ((none #f replace)) #f) (404 "not_found" #f ((none #f replace)) #f))
  (list (oracle (replace-at at 'b b1 1 2 #f "mine now"))
        (oracle (replace-at at 'b b1 1 2 "task" "mine now"))))

(test-equal "oracle: restores of node 1: snapshot 1 or 2 at its revision 200; 5, which it lacks, 404; stale 412 either way; b's 404"
  '((200 #f "\"3\"" ((match active restore)) #f) (200 #f "\"3\"" ((match active restore)) #f)
    (404 "not_found" #f ((match active restore-unknown)) #f)
    (412 "precondition_failed" #f ((differ active restore)) #f)
    (412 "precondition_failed" #f ((differ active restore-unknown)) #f)
    (404 "not_found" #f ((none #f restore-unknown)) #f))
  (list (oracle (restore-at at 'a a1 1 2 1)) (oracle (restore-at at 'a a1 1 2 2))
        (oracle (restore-at at 'a a1 1 2 5)) (oracle (restore-at at 'a a1 1 1 1))
        (oracle (restore-at at 'a a1 1 1 5)) (oracle (restore-at at 'b b1 1 2 1))))

(test-equal "oracle: no precondition is 428, a malformed one 400, on every write route, and neither steps a cell"
  (append (repeat 4 '(428 "precondition_required" #f () #f)) (repeat 4 '(400 "invalid_request" #f () #f)))
  (append (map (lambda (k) (oracle (bare-at at 'a k 1 'missing))) '(put restore archive purge))
          (map (lambda (k) (oracle (bare-at at 'a k 1 'invalid))) '(put restore untrash purge))))

;; The lifecycle at the node's own revision: node 1 active, 3 archived, 4
;; trashed, each at 2. (status code state-after) for each event.
(test-equal "oracle: each event from each live state at the node's revision is as L2, L5 and L8 say, the state after it in the world"
  '(((200 #f archived) (409 "wrong_state" active) (200 #f trashed) (409 "wrong_state" active) (409 "wrong_state" active))
    ((409 "wrong_state" archived) (200 #f active) (200 #f trashed) (409 "wrong_state" archived) (409 "wrong_state" archived))
    ((409 "wrong_state" trashed) (409 "wrong_state" trashed) (409 "wrong_state" trashed) (200 #f active) (204 #f purged)))
  (attempt
   (lambda ()
     (map (lambda (k)
            (map (lambda (ev)
                   (let ((x (expect as-planned hand (life-at at 'a a1 k 2 ev))))
                     (list (expectation-status x) (expectation-code x)
                           (mnode-state (node-in (expectation-world x) k)))))
                 lifecycle-events))
          '(1 3 4)))))

(test-equal "oracle: an archive of node 1 is match x active x archive: 200, ETag 3, the node archived, its JSON without a body"
  '((200 #f "\"3\"" ((match active archive)) #f) "archived" 3 absent "second")
  (attempt
   (lambda ()
     (let* ((x (expect as-planned hand (life-at at 'a a1 1 2 'archive))) (j (expectation-json x)))
       (list (summary x) (member-of j "state") (member-of j "revision") (member-of j "body") (member-of j "title"))))))

(test-equal "oracle: a purge of node 4, trashed at 2, is match x trashed x purge: 204, no ETag, an empty body"
  '((204 #f #f ((match trashed purge)) #f) empty)
  (attempt
   (lambda ()
     (let ((x (expect as-planned hand (life-at at 'a a1 4 2 'purge))))
       (list (summary x) (expectation-json x))))))

(test-equal "oracle: stale is 412 before the state, whatever the state and the event (G5)"
  (map (lambda (k s) (map (lambda (ev) (list 412 "precondition_failed" #f (list (list 'differ s ev)) #f)) lifecycle-events))
       '(1 3 4) '(active archived trashed))
  (map (lambda (k) (map (lambda (ev) (oracle (life-at at 'a a1 k 1 ev))) lifecycle-events)) '(1 3 4)))

(test-equal "oracle: b at a's nodes at a's own revisions: 404 from every write route, stepping none x -, the world as it was (G7)"
  (repeat 3 (map (lambda (ev) (list 404 "not_found" (list (list 'none #f ev)) #t))
                    (append '(replace restore-unknown) lifecycle-events)))
  (map (lambda (k)
         (map (lambda (e)
                (attempt (lambda ()
                           (let ((x (expect as-planned hand e)))
                             (list (expectation-status x) (expectation-code x) (expectation-cells x)
                                   (eq? (expectation-world x) hand))))))
              (append (list (replace-at at 'b b1 k 2 #f "mine") (restore-at at 'b b1 k 2 1))
                      (map (lambda (ev) (life-at at 'b b1 k 2 ev)) lifecycle-events))))
       '(1 3 4)))

(test-equal "oracle: a trashed node refuses a write with 409 wrong_state: a replace, one naming another kind (not kind_fixed), a restore of its snapshot, of its gap and of one it never had (G15)"
  '((409 "wrong_state" #f ((match trashed replace)) #f)
    (409 "wrong_state" #f ((match trashed replace-other-kind)) #f)
    (409 "wrong_state" #f ((match trashed restore)) #f)
    (409 "wrong_state" #f ((match trashed restore-unknown)) #f)
    (409 "wrong_state" #f ((match trashed restore-unknown)) #f)
    (412 "precondition_failed" #f ((differ trashed replace)) #f))
  (list (oracle (replace-at at 'a a1 4 2 #f "x")) (oracle (replace-at at 'a a1 4 2 "task" "x"))
        (oracle (restore-at at 'a a1 4 2 1)) (oracle (restore-at at 'a a1 4 2 2))
        (oracle (restore-at at 'a a1 4 2 7)) (oracle (replace-at at 'a a1 4 1 #f "stale"))))

(test-equal "oracle: an archived node is written as an active one and stays archived (G12); its gap, revision 2, is a 404 to a restore"
  '((200 "archived" "a new body") (200 "archived" "a body") (404 "not_found" ((match archived restore-unknown)))
    (409 "kind_fixed"))
  (attempt
   (lambda ()
     (let ((x (lambda (e) (expect as-planned hand e))))
       (list (let ((r (x (replace-at at 'a a1 3 2 #f "new"))))
               (list (expectation-status r) (member-of (expectation-json r) "state") (member-of (expectation-json r) "body")))
             (let ((r (x (restore-at at 'a a1 3 2 1))))
               (list (expectation-status r) (member-of (expectation-json r) "state") (member-of (expectation-json r) "body")))
             (let ((r (x (restore-at at 'a a1 3 2 2))))
               (list (expectation-status r) (expectation-code r) (expectation-cells r)))
             (status-code (replace-at at 'a a1 3 2 "task" "x")))))))

(test-equal "oracle: a state change bumps the revision, writes no snapshot, adds its change row and leaves the content (G3, G11)"
  (list 3 'trashed '(2 1) at "second" (list 10 3 "trash" at))
  (attempt
   (lambda ()
     (let* ((w (after (life-at at 'a a1 1 2 'trash)))
            (n (node-in w 1))
            (c (car (reverse (world-changes-of w 'a)))))
       (list (mnode-revision n) (mnode-state n) (map msnap-revision (mnode-snaps n)) (mnode-updated n)
             (msnap-title (car (mnode-snaps n)))
             (list (mchange-seq c) (mchange-revision c) (mchange-op c) (mchange-created c)))))))

(test-equal "oracle: a purge leaves node 5 purged at 3 with no snapshot, created kept, its purge row a's last (G6, G9, G16)"
  (list 'purged 3 '() (+ t0 8) (list 9 3 "purge" (+ t0 10))
        '((1 "create") (2 "update") (3 "create") (4 "archive") (5 "create") (6 "trash") (7 "create") (8 "trash") (9 "purge")))
  (attempt
   (lambda ()
     (let ((n (node-in hand 5)) (cs (world-changes-of hand 'a)))
       (list (mnode-state n) (mnode-revision n) (mnode-snaps n) (mnode-created n)
             (let ((c (car (reverse cs)))) (list (mchange-seq c) (mchange-revision c) (mchange-op c) (mchange-created c)))
             (map (lambda (c) (list (mchange-seq c) (mchange-op c))) cs))))))

(test-equal "oracle: a purged node is gone to every route, its owner's and the other account's: 404; a create on its id 412 (G6, G14)"
  (let ((gone (append (repeat 5 '(404 "not_found")) (repeat 5 '(404 "not_found")) (list '(412 "precondition_failed")))))
    (list gone gone))
  (map (lambda (tag)
         (append (list (status-code (read-at at tag 'get-node 5 #f))
                       (status-code (read-at at tag 'list-revisions 5 #f))
                       (status-code (read-at at tag 'get-snapshot 5 1))
                       (status-code (replace-at at tag (key-of tag) 5 3 #f "x"))
                       (status-code (restore-at at tag (key-of tag) 5 3 1)))
                 (map (lambda (ev) (status-code (life-at at tag (key-of tag) 5 3 ev))) lifecycle-events)
                 (list (status-code (create-at at tag (key-of tag) 5 "project" "x")))))
       '(a b)))

;; titles : Expectation -> (Listof (List Title State))
(define (titles x)
  (map (lambda (item) (list (member-of item "title") (member-of item "state"))) (expectation-items x)))

(test-equal "oracle: a list is the account's own nodes in the state asked, active when none is named; never the purged one (L6, G8, G14)"
  '((("second" "active")) (("second" "active")) (("kept" "archived")) (("binned" "trashed")) (("theirs" "active")) ())
  (attempt
   (lambda ()
     (map (lambda (e) (titles (expect as-planned hand e)))
          (list (list-at at 'a #f) (list-at at 'a "active") (list-at at 'a "archived") (list-at at 'a "trashed")
                (list-at at 'b #f) (list-at at 'b "trashed"))))))

(test-equal "oracle: a ?state= of purged, of another case, that names no state, or given twice, is 400"
  (repeat 4 '(400 "invalid_request"))
  (map (lambda (q) (status-code (list-at at 'a q))) (list "purged" "Archived" "deleted" 'twice)))

(test-equal "oracle: reads of archived node 3: the node with its newest snapshot's body and its own revision; its revisions 1 alone; its gap a 404"
  '((200 "\"2\"" "archived" "a body" 2) (1) (404 "not_found"))
  (attempt
   (lambda ()
     (let ((x (lambda (e) (expect as-planned hand e))))
       (list (let ((r (x (read-at at 'a 'get-node 3 #f))))
               (list (expectation-status r) (expectation-etag r) (member-of (expectation-json r) "state")
                     (member-of (expectation-json r) "body") (member-of (expectation-json r) "revision")))
             (map (lambda (item) (member-of item "revision")) (expectation-items (x (read-at at 'a 'list-revisions 3 #f))))
             (status-code (read-at at 'a 'get-snapshot 3 2)))))))

(test-equal "oracle: no list item holds a body; a node's answer does; a state change's does not"
  '(absent "a new body" absent)
  (attempt
   (lambda ()
     (list (member-of (car (expectation-items (expect as-planned hand (list-at at 'a #f)))) "body")
           (member-of (expectation-json (expect as-planned hand (replace-at at 'a a1 1 2 #f "x"))) "body")
           (member-of (expectation-json (expect as-planned hand (life-at at 'a a1 1 2 'trash))) "body")))))

;; D6: a1 was first used at t0+1. A write a day later is not due; a day
;; and a ms later it is; a refusal then leaves last_used as it was.
(test-equal "oracle: last_used is set by the first write, again only past a day, never by a refusal or a read"
  (list (+ t0 1) (+ t0 1) (+ t0 1 day 1) (+ t0 1) (+ t0 1))
  (attempt
   (lambda ()
     (let ((lu (lambda (e) (world-key-last-used (expectation-world (expect as-planned hand e)) a1))))
       (list (world-key-last-used hand a1)
             (lu (replace-at (+ t0 1 day) 'a a1 1 2 #f "a day on"))
             (lu (replace-at (+ t0 1 day 1) 'a a1 1 2 #f "a day and a ms on"))
             (lu (replace-at (+ t0 1 day 1) 'a a1 1 1 #f "stale, a day and a ms on"))
             (lu (read-at (+ t0 1 day 1) 'a 'get-node 1 #f)))))))

(test-equal "oracle: a state change and a purge set last_used when due, as any write; their refusals do not (G13)"
  (list (+ t0 1 day 1) (+ t0 1 day 1) (+ t0 1) (+ t0 1))
  (attempt
   (lambda ()
     (let ((lu (lambda (e) (world-key-last-used (expectation-world (expect as-planned hand e)) a1)))
           (t (+ t0 1 day 1)))
       (list (lu (life-at t 'a a1 1 2 'archive)) (lu (life-at t 'a a1 4 2 'purge))
             (lu (life-at t 'a a1 1 2 'untrash)) (lu (life-at t 'a a1 4 1 'purge)))))))

(test-equal "oracle: the asking key alone is touched: a2's first write sets a2's, not a1's"
  (list (+ t0 1) at)
  (attempt
   (lambda ()
     (let ((w (expectation-world (expect as-planned hand (life-at at 'a a2 1 2 'archive)))))
       (list (world-key-last-used w a1) (world-key-last-used w a2))))))

;; Twisted rules, for the oracle and for the teeth below.

;; trashed-writable : a replace of a trashed node at its revision is written.
(define (trashed-writable cell decision)
  (if (equal? cell '(match trashed replace)) '(write) decision))

;; stale-wrong-state : a stale purge of a node that is not trashed is wrong_state.
(define (stale-wrong-state cell decision)
  (if (and cell (eq? (car cell) 'differ) (eq? (caddr cell) 'purge) (memq (cadr cell) '(active archived)))
      '(refuse 409 "wrong_state")
      decision))

;; untrash-to-archived : untrash lands on archived.
(define (untrash-to-archived cell decision)
  (if (equal? cell '(match trashed untrash)) '(set-state archived) decision))

;; state-on-put : a replace at the revision is a state change.
(define (state-on-put cell decision)
  (if (equal? cell '(match active replace)) '(set-state archived) decision))

(test-equal "oracle: its answer is its rules': a twist that writes a trashed node answers 200, the node still trashed"
  '((200 #f "\"3\"" ((match trashed replace)) #f) trashed)
  (attempt
   (lambda ()
     (let ((x (expect trashed-writable hand (replace-at at 'a a1 4 2 #f "x"))))
       (list (summary x) (mnode-state (node-in (expectation-world x) 4)))))))

(test-equal "oracle: a decision that makes no sense for the request is a step the model cannot take"
  '(#t)
  (attempt
   (lambda ()
     (list (contains? (expectation-problem (expect state-on-put hand (replace-at at 'a a1 1 2 #f "x")))
                      "which only a state change performs")))))

;;; The store every sequence runs on, emptied by each

(define dir (attempt (lambda () (fresh-dir "test-nodes-model"))))
(define store (attempt (lambda () (open-test-store dir "model.db"))))

;; run-one : Twist Natural Boolean -> (U Verdict (List 'raised String))
(define (run-one twist seed trace?)
  (attempt (lambda () (run-sequence store twist seed trace?))))

(define (raised? x) (and (pair? x) (eq? (car x) 'raised)))

;; failure : (U Verdict (List 'raised String)) -> (U String #f)
(define (failure v)
  (cond ((raised? v) (string-append "a sequence raised: " (cadr v)))
        ((verdict-report v) => (lambda (r) r))
        (else #f)))

(define (env-number name)
  (let ((s (getenv name)))
    (and s (string->number s))))

(define replay-seed (env-number "TECHO_NODES_MODEL_SEED"))
(define first-seed (or (env-number "TECHO_NODES_MODEL_FIRST") 1))

;;; Replay: one seed, traced

(define replayed (and replay-seed (failure (run-one as-planned replay-seed #t))))

(when replay-seed
  (when replayed (display replayed))
  (test-equal (format "replay of seed ~a: every request agrees" replay-seed) #f replayed))

;;; 2. The run

(define sequences 300)
(define verdicts
  (if replay-seed
      '()
      (map (lambda (s) (run-one as-planned s #f)) (from-to first-seed (+ first-seed sequences -1)))))
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

(define d5-events '(create replace replace-other-kind restore restore-unknown))
(define writable '(active archived))

;; project : (Cell -> (U K #f)) -> Hashtable     cells-hit counted under F's key
(define (project f)
  (let ((t (make-hashtable equal-hash equal?)))
    (let-values (((ks vs) (hashtable-entries cells-hit)))
      (vector-for-each (lambda (k v) (let ((p (f k))) (when p (hashtable-update! t p (lambda (c) (+ c v)) 0))))
                       ks vs))
    t))

;; d5-of : Cell -> (U (List Found Event) #f)
;; D5's cell, when D5 answers: none and differ, and match in a state that
;; allows a write. On a trashed node at its revision the lifecycle answers.
(define (d5-of cell)
  (and (memq (caddr cell) d5-events)
       (or (not (eq? (car cell) 'match)) (memq (cadr cell) writable))
       (list (car cell) (caddr cell))))

;; lifecycle-of : Cell -> (U (List State Event) #f)
;; The lifecycle's cell, which only a match steps: a replace or a restore
;; is its write.
(define (lifecycle-of cell)
  (and (eq? (car cell) 'match)
       (list (cadr cell) (if (memq (caddr cell) d5-events) 'write (caddr cell)))))

(define d5-hit (project d5-of))
(define lifecycle-hit (project lifecycle-of))

;; lifecycle-cells : the plan's table: each live state by the five events and write
(define lifecycle-cells
  (apply append (map (lambda (s) (map (lambda (e) (list s e)) (append lifecycle-events '(write))))
                     '(active archived trashed))))

;; reachable-cells : node-command's cells a request can reach, in the plan's words.
;;   none, no state: a create of a free id; a replace, a restore and each
;;     state change of a node the account has not got (no kind to differ
;;     from, no snapshot to restore)
;;   differ, no state: a create on an id in use (a create's job reads no state)
;;   differ and match, each live state: every event but a create
(define reachable-cells
  (append (map (lambda (e) (list 'none #f e))
               (append '(create replace restore-unknown) lifecycle-events))
          (list (list 'differ #f 'create))
          (apply append
                 (map (lambda (f)
                        (apply append
                               (map (lambda (s)
                                      (map (lambda (e) (list f s e))
                                           (append '(replace replace-other-kind restore restore-unknown)
                                                   lifecycle-events)))
                                    '(active archived trashed))))
                      '(differ match)))))

;; purged-routes : every route a request at a purged id can take
(define purged-routes
  '(get-node list-revisions get-snapshot replace restore archive unarchive trash untrash purge create))

(define (purged-count route whose) (hashtable-ref aims-hit (string->symbol (format "purged-~a-~a" route whose)) 0))

;; The floors. Slice 4's are as it set them. Slice 4b's are about half the
;; fewest seen over seeds 1 to 300 and five other runs of 300 (FIRST 1001
;; to 5001): a lifecycle cell 24, a node-command cell 13, a purged route
;; 10 (a create by one account), an aim of some-aims 45.
(define cell-floor 100)
(define lifecycle-floor 12)
(define command-floor 6)
(define purged-floor 5)
(define aim-floor 100)
(define some-floor 25)
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
    last-used-set refused-while-due id-in-capitals
    ;; slice 4b
    replace-own-archived replace-own-trashed restore-own-archived restore-own-trashed
    restore-snap-gap get-snap-gap
    list-state-default list-state-active list-state-archived list-state-trashed))

;; Slice 4b's aims that share the run with the rest: a state change by the
;; other account at the node's own revision (G7), a stale one at the
;; account's own node (G5), each also held by node-command's none and
;; differ cells; and a ?state= that names no state.
(define some-aims
  '(archive-other-current unarchive-other-current trash-other-current untrash-other-current
    purge-other-current
    archive-own-stale unarchive-own-stale trash-own-stale untrash-own-stale purge-own-stale
    list-state-invalid))

(define rare-aims
  '(no-precondition-put no-precondition-restore bad-precondition-put bad-precondition-restore
    bad-star bad-weak bad-list bad-bare bad-twice bad-both bad-zero bad-leading-zero bad-inner-space
    bad-none-match-tag bad-none-match-twice bad-create-on-restore
    ;; slice 4b
    no-precondition-archive no-precondition-unarchive no-precondition-trash no-precondition-untrash
    no-precondition-purge bad-precondition-archive bad-precondition-unarchive bad-precondition-trash
    bad-precondition-untrash bad-precondition-purge bad-create-on-lifecycle))

(define (at-least floor n) (if (>= n floor) (list 'at-least floor) (list 'only n)))

(define (cell-name c) (format "~a x ~a x ~a" (car c) (or (cadr c) "-") (caddr c)))

(unless replay-seed
  (test-equal "the run: every sequence agrees with the model's rules and the laws (the first three that do not)"
    '()
    (take* failures 3))

  (test-equal "the run: every one of the sequences ran and agreed" sequences (length agreed))

  (test-equal "the run: every sequence is at least 45 requests" '(at-least 45) (at-least 45 shortest))

  (test-equal "the run: at least 15,000 requests" '(at-least 15000) (at-least 15000 steps))

  ;;; 3. Coverage

  (for-each
   (lambda (row)
     (test-equal (format "coverage: D5's ~a x ~a (~a) is stepped at least ~a times"
                         (car row) (cadr row) (cadddr row) cell-floor)
       (list 'at-least cell-floor)
       (at-least cell-floor (hashtable-ref d5-hit (list (car row) (cadr row)) 0))))
   write-rows)

  (test-equal "coverage: the model steps no D5 cell the table has not"
    '()
    (filter (lambda (k) (not (exists (lambda (row) (equal? k (list (car row) (cadr row)))) write-rows)))
            (vector->list (hashtable-keys d5-hit))))

  (for-each
   (lambda (c)
     (test-equal (format "coverage: the lifecycle's ~a x ~a is stepped at least ~a times" (car c) (cadr c)
                         lifecycle-floor)
       (list 'at-least lifecycle-floor)
       (at-least lifecycle-floor (hashtable-ref lifecycle-hit c 0))))
   lifecycle-cells)

  (for-each
   (lambda (c)
     (test-equal (format "coverage: node-command's ~a is stepped at least ~a times" (cell-name c) command-floor)
       (list 'at-least command-floor)
       (at-least command-floor (hashtable-ref cells-hit c 0))))
   reachable-cells)

  (test-equal "coverage: the model steps no cell of node-command's but the reachable ones"
    '()
    (filter (lambda (k) (not (member k reachable-cells))) (vector->list (hashtable-keys cells-hit))))

  (for-each
   (lambda (route)
     (test-equal (format "coverage: a request at a purged id by ~a at least ~a times" route purged-floor)
       (list 'at-least purged-floor)
       (at-least purged-floor (+ (purged-count route "own") (purged-count route "other")))))
   purged-routes)

  (for-each
   (lambda (whose)
     (test-equal (format "coverage: a create on a purged id by the ~a account at least ~a times"
                         (if (string=? whose "own") "owning" "other") purged-floor)
       (list 'at-least purged-floor)
       (at-least purged-floor (purged-count 'create whose))))
   '("own" "other"))

  (for-each
   (lambda (aim)
     (test-equal (format "coverage: ~a at least ~a times" aim aim-floor)
       (list 'at-least aim-floor)
       (at-least aim-floor (hashtable-ref aims-hit aim 0))))
   aims)

  (for-each
   (lambda (aim)
     (test-equal (format "coverage: ~a at least ~a times" aim some-floor)
       (list 'at-least some-floor)
       (at-least some-floor (hashtable-ref aims-hit aim 0))))
   some-aims)

  (for-each
   (lambda (aim)
     (test-equal (format "coverage: ~a at least ~a times" aim rare-floor)
       (list 'at-least rare-floor)
       (at-least rare-floor (hashtable-ref aims-hit aim 0))))
   rare-aims)

  (display (format "nodes-model: seeds ~a to ~a: ~a sequences, ~a requests made, ~a HTTP requests sent, the shortest ~a\n"
                   first-seed (+ first-seed sequences -1) (length agreed) steps requests shortest))
  (display "  the cells of D5 stepped:\n")
  (for-each (lambda (row)
              (display (format "    ~a x ~a (~a): ~a\n" (car row) (cadr row) (cadddr row)
                               (hashtable-ref d5-hit (list (car row) (cadr row)) 0))))
            write-rows)
  (display "  the lifecycle's cells stepped (state x event):\n")
  (for-each (lambda (s)
              (display (format "    ~a:~a\n" s
                               (apply string-append
                                      (map (lambda (e) (format " ~a ~a" e (hashtable-ref lifecycle-hit (list s e) 0)))
                                           (append lifecycle-events '(write)))))))
            '(active archived trashed))
  (display "  node-command's cells stepped (found x state x event):\n")
  (for-each (lambda (c) (display (format "    ~a: ~a\n" (cell-name c) (hashtable-ref cells-hit c 0))))
            reachable-cells)
  (display "  requests at a purged id, by route (the owner's, the other account's):\n")
  (for-each (lambda (route)
              (display (format "    ~a: ~a, ~a\n" route (purged-count route "own") (purged-count route "other"))))
            purged-routes)
  (display "  the aims:\n")
  (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0))))
            (append aims some-aims rare-aims))
  (display "  and with no floor:\n")
  (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0))))
            (list-sort (lambda (x y) (string<? (symbol->string x) (symbol->string y)))
                       (filter (lambda (aim) (not (or (memq aim aims) (memq aim some-aims) (memq aim rare-aims))))
                               (vector->list (hashtable-keys aims-hit))))))

;;; 4. Teeth: the oracle with a twisted rule, the handlers as they are

;; first-difference : Twist (Listof Natural) -> (U String #f)
(define (first-difference twist seeds)
  (let loop ((ss seeds))
    (if (null? ss)
        #f
        (or (failure (run-one twist (car ss) #f)) (loop (cdr ss))))))

(unless replay-seed
  (test-equal "teeth: a rule that writes a trashed node disagrees with the handlers' 409"
    #t
    (let ((f (first-difference trashed-writable (from-to 1 30))))
      (and f
           (contains? f "stepping match x trashed x replace")
           (contains? f "status: the model has 200, the handlers answered 409")
           #t)))

  (test-equal "teeth: a rule that answers a stale purge with wrong_state disagrees with the handlers' 412"
    #t
    (let ((f (first-difference stale-wrong-state (from-to 1 30))))
      (and f
           (or (contains? f "stepping differ x active x purge") (contains? f "stepping differ x archived x purge"))
           (contains? f "status: the model has 409, the handlers answered 412")
           #t)))

  (test-equal "teeth: a rule that untrashes to archived disagrees with the handlers' JSON"
    #t
    (let ((f (first-difference untrash-to-archived (from-to 1 30))))
      (and f
           (contains? f "stepping match x trashed x untrash")
           (contains? f "the JSON: the model has")
           #t))))

(unless (raised? store) (close-test-store! store))

(display (format "nodes-model: ~a ms\n" (- (real-time) started)))

(test-end "nodes-model")

(exit (suite-exit-status runner))
