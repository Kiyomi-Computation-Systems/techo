#!r6rs
;;; The nodes model suite: ADR-0007's third layer for D5's versioned write
;;; (slice 4, task 5a), the node lifecycle (slice 4b, task 4a), the tree
;;; (slice 5a, task 4a), links (slice 5b, task 4a), props and a Task's
;;; commands (slice 6, task 4a), and tags (slice 7a, task 4a). Seeded random
;;; sequences of requests by two accounts run against the real handlers
;;; (make-app inside wrap-server, raw HTTP through a test host) and real
;;; SQLite (the test doorway on a migrated file), with a wall clock the
;;; sequence steps. After every request the answer is compared with the
;;; model's, which is the plan's rules written again in (nodes-model), never
;;; the tables of (techo nodes) nor (techo links)' link-command, nor
;;; (techo props), (techo tasks), (techo contact), (techo when), (techo
;;; tags) or (techo chars); the answers
;;; are held to laws that need no model; the four tables and every key's
;;; last_used are read whole and held to laws that need no model (H1 to H6,
;;; H11, H2', H3', H15'', H16, G3', G6', G7', G9, G11, G12, G16; P1 to P4,
;;; P8, P11, P12, P15, P16; H1', H4'', H14', Q1, Q2, Q8, Q9; R1, R2, R4,
;;; R5, R9, R13, R14, G11'; L2 to L11 and L13, and a step's own, as the
;;; bulk move's) and to the model's world, its links, props and tags among
;;; it; and every request's write jobs are counted (R15, L10).
;;;
;;;   1. the oracle on hand-made worlds, pure: the lifecycle's, then a tree
;;;      on it, then a chain to the depth's boundary, then links on it, then
;;;      props and a Task's commands on it, then tags on it; then the props
;;;      corpus and the tags corpus, each by itself and each entry once
;;;      through the real handlers
;;;   2. the run: SEQUENCES seeds of 97 to 140 requests, every one to agree;
;;;      a crowd seed (ending in 04 or 54) first holds over 500 carriers of
;;;      a tag, renames and removes it until left is 0, then 14 to 27;
;;;      a family seed (ending in 3 or 7) first makes a mixed tree; a linked
;;;      seed (ending in 1 or 9) first makes a hub of links both ways and
;;;      steps it through the states; a deep seed (a multiple of fifteen)
;;;      first makes a chain of 65 Projects and runs a script at the
;;;      depth's boundary, then 14 to 27; any other seed's file first holds
;;;      one to three Tasks written straight into its tables, props {}, as a
;;;      file from before slice 6
;;;   3. coverage, printed and held to floors: D5's cells; the lifecycle's
;;;      24 (three states by five events, a write and the two moves);
;;;      node-command's reachable cells, and no other; requests at purged
;;;      ids, by route, and a create by the owner and by the other account;
;;;      the aims; the tree's: each verdict by each route that can get it,
;;;      each kind pairing, the depth's boundary from both sides, loops by
;;;      where they close, each bulk move's outcome, has_children by the
;;;      children's states, and ?parent= by case and by ?state=; the
;;;      links': link-command's 32 reachable cells, and no other; each
;;;      outcome by its cause (201, 200 kept, 204, each 404, each 409 by
;;;      which end, each 400); purges that took links out, in and both
;;;      ways; lists both ways, typed and not, pages followed; slice 6's:
;;;      the task table's nine cells on active and on archived Tasks, each
;;;      refusal of a command by its cause, each refusal of props by kind and
;;;      by where it is answered, the 413, status_fixed, P10's restores,
;;;      P11's replaces, P14's creates, commands and reads on Tasks stored
;;;      {} and on seeded ones, R17's two orderings; slice 7a's: each kind of
;;;      tags sent and what came of it, the other writes on tagged nodes,
;;;      the filter by count, refusal and raw value, the tags list, each
;;;      command's outcome and refusal, and a crowd's steps over 500
;;;   4. teeth: the oracle given a twisted rule disagrees with the handlers;
;;;      each tree, link and slice 6 twist on the first seeds whose run
;;;      reached what it bends
;;;
;;; No sequence reaches a bulk move's cap of 1,000 children: the route
;;; suite holds it (tests/test-node-routes.sps, "bulk: of 1,005 children").
;;;
;;; Replay one seed, each request printed as it goes:
;;;   scripts/guix-env sh -c 'TECHO_NODES_MODEL_SEED=17 make test SUITES=tests/test-nodes-model.sps'
;;; Then only that seed runs, and only its agreement is asserted. The run's
;;; seeds are FIRST to FIRST + 299, FIRST 1 unless TECHO_NODES_MODEL_FIRST
;;; names another, so the floors can be held on other seeds. Set either
;;; inside the container (traps.md): scripts/guix-env sh -c 'FOO=1 make ...'.
;;;
;;; Its files are under build/test-nodes-model/<unique>/, emptied at the
;;; start. Everything that can raise is computed under `attempt`, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (only (chezscheme) getenv real-time format)
        (srfi :64)
        (techo-testing)
        (only (http-support) fresh-dir open-test-store close-test-store! contains?)
        (only (techo nodes) write-rows node-id->string)
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

(define (content kind title body) (make-content kind title body "text/plain" #f 'absent))
(define (create-at at tag key n kind title)
  (make-event 'put at tag key (nid n) 'create '() (content kind title "a body") #f #f #f #f '() 'absent))
(define (replace-at at tag key n rev kind title)
  (make-event 'put at tag key (nid n) rev '() (content kind title "a new body") #f #f #f #f '() 'absent))
(define (restore-at at tag key n rev k)
  (make-event 'restore at tag key (nid n) rev '() #f k #f #f #f '() 'absent))
(define (life-at at tag key n rev ev)
  (make-event ev at tag key (nid n) rev '() #f #f #f #f #f '() 'absent))
(define (read-at at tag kind n k)
  (make-event kind at tag (key-of tag) (and n (nid n)) #f '() #f k #f #f #f '() 'absent))
(define (list-at at tag q)
  (make-event 'list-nodes at tag (key-of tag) #f #f '() #f #f #f q #f '() 'absent))
(define (bare-at at tag kind n pre)
  (make-event kind at tag (key-of tag) (nid n) pre '()
              (and (eq? kind 'put) (content "note" "t" "b")) (and (eq? kind 'restore) 1) #f #f #f '() 'null))

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
;; walk-world : World (Listof Event) -> World     each event's world in turn
(define (walk-world w0 events)
  (fold-left (lambda (w e)
               (let ((x (expect as-planned w e)))
                 (when (expectation-problem x)
                   (assertion-violation 'hand "the model cannot take a hand step" (expectation-problem x)))
                 (expectation-world x)))
             w0 events))

(define hand
  (attempt
   (lambda ()
     (walk-world model-start
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
(define (trashed-writable cell decision s)
  (if (equal? cell '(match trashed replace)) '(write) decision))

;; stale-wrong-state : a stale purge of a node that is not trashed is wrong_state.
(define (stale-wrong-state cell decision s)
  (if (and cell (eq? (car cell) 'differ) (eq? (caddr cell) 'purge) (memq (cadr cell) '(active archived)))
      '(refuse 409 "wrong_state")
      decision))

;; untrash-to-archived : untrash lands on archived.
(define (untrash-to-archived cell decision s)
  (if (equal? cell '(match trashed untrash)) '(set-state archived) decision))

;; state-on-put : a replace at the revision is a state change.
(define (state-on-put cell decision s)
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

;;; The tree, on the hand world (slice 5a)

;; ref : Natural -> ParentRef     node N's id as a parent, in lower case
(define (ref n) (list 'id (nid n) #f))
(define (id-of n) (node-id->string (nid n)))

(define (make-in at tag key n kind parent)
  (make-event 'put at tag key (nid n) 'create '() (make-content kind "t" "b" "text/plain" #f parent)
              #f #f #f #f '() 'absent))
(define (move-at at tag key n rev parent)
  (make-event 'move at tag key (nid n) rev '() #f #f #f #f #f '() parent))
(define (bulk-at at tag key n rev parent)
  (make-event 'move-children at tag key (nid n) rev '() #f #f #f #f #f '() parent))
(define (list-in at tag q parent)
  (make-event 'list-nodes at tag (key-of tag) #f #f '() #f #f #f q #f '() parent))

;; The tree, at t0+30 to t0+40: a's 11, a Project at the top, holds 12, a
;; Journal (which holds 13, a Note), 14, a Task, and 18, a Note, trashed
;; at 2; a's 15, a Project made with "parent": null, holds 16, a Note,
;; archived at 2, and is trashed at 2; b's 17 is a Project.
(define tree
  (attempt
   (lambda ()
     (walk-world hand
                 (list (make-in (+ t0 30) 'a a1 11 "project" 'absent)
                       (make-in (+ t0 31) 'a a1 12 "journal" (ref 11))
                       (make-in (+ t0 32) 'a a1 13 "note" (ref 12))
                       (make-in (+ t0 33) 'a a1 14 "task" (ref 11))
                       (make-in (+ t0 34) 'a a1 15 "project" 'null)
                       (make-in (+ t0 35) 'a a1 16 "note" (ref 15))
                       (life-at (+ t0 36) 'a a1 16 1 'archive)
                       (life-at (+ t0 37) 'a a1 15 1 'trash)
                       (make-in (+ t0 38) 'b b1 17 "project" 'absent)
                       (make-in (+ t0 39) 'a a1 18 "note" (ref 11))
                       (life-at (+ t0 40) 'a a1 18 1 'trash))))))

(define tat (+ t0 50))

;; answer : World Event -> (List Status Code (U String 'null 'absent))     and the answer's parent
(define (answer w e)
  (attempt (lambda ()
             (let ((x (expect as-planned w e)))
               (list (expectation-status x) (expectation-code x) (member-of (expectation-json x) "parent"))))))

(define (parent-in w n) (let ((p (mnode-parent (world-node w (nid n))))) (and p (node-id->string p))))
(define (status-of w e) (let ((x (expect as-planned w e))) (list (expectation-status x) (expectation-code x))))

(test-equal "oracle: the tree is 11 at the top over 12, 14 and 18; 12 over 13; 15 at the top over 16; b's 17 at the top"
  (list #f (id-of 11) (id-of 12) (id-of 11) #f (id-of 15) #f (id-of 11))
  (attempt (lambda () (map (lambda (n) (parent-in tree n)) '(11 12 13 14 15 16 17 18)))))

(test-equal "oracle: a create under a Project is 201 with its id as the parent; a Journal takes a Note, not a Task; a Note, a trashed node, b's, a purged one and a fresh id are 409 invalid_parent; an id in use is 412 first"
  (list (list 201 #f (id-of 11)) (list 201 #f (id-of 12)) '(409 "invalid_parent" absent)
        '(409 "invalid_parent" absent) '(409 "invalid_parent" absent) '(409 "invalid_parent" absent)
        '(409 "invalid_parent" absent) '(409 "invalid_parent" absent) '(412 "precondition_failed" absent))
  (map (lambda (e) (answer tree e))
       (list (make-in tat 'a a1 20 "task" (ref 11)) (make-in tat 'a a1 20 "note" (ref 12))
             (make-in tat 'a a1 20 "task" (ref 12)) (make-in tat 'a a1 20 "note" (ref 13))
             (make-in tat 'a a1 20 "note" (ref 15)) (make-in tat 'a a1 20 "note" (ref 17))
             (make-in tat 'a a1 20 "note" (ref 5)) (make-in tat 'a a1 20 "note" (ref 99))
             (make-in tat 'a a1 11 "note" (ref 99)))))

(test-equal "oracle: a move is 200 at the next revision, the new parent, no body; to itself, a child or a grandchild 409 would_loop, where it sits above the parent 0, 1, 2; a Task into a Journal invalid_parent; a trashed node wrong_state; stale 412; b's 404"
  (list (list 200 #f (id-of 11) "\"2\"" 'absent #f)
        '(409 "would_loop" absent #f absent 0) '(409 "would_loop" absent #f absent 1) '(409 "would_loop" absent #f absent 2)
        '(409 "invalid_parent" absent #f absent #f) '(409 "wrong_state" absent #f absent #f)
        '(412 "precondition_failed" absent #f absent #f) '(404 "not_found" absent #f absent #f))
  (map (lambda (e)
         (attempt (lambda ()
                    (let ((x (expect as-planned tree e)))
                      (list (expectation-status x) (expectation-code x) (member-of (expectation-json x) "parent")
                            (expectation-etag x) (member-of (expectation-json x) "body")
                            (situation-loop-at (expectation-situation x)))))))
       (list (move-at tat 'a a1 13 1 (ref 11)) (move-at tat 'a a1 11 1 (ref 11)) (move-at tat 'a a1 11 1 (ref 12))
             (move-at tat 'a a1 11 1 (ref 13)) (move-at tat 'a a1 14 1 (ref 12)) (move-at tat 'a a1 15 2 'null)
             (move-at tat 'a a1 13 2 'null) (move-at tat 'b b1 13 1 'null))))

;; bulk : Event -> (List Status Code ETag JSON)
(define (bulk w e)
  (attempt (lambda ()
             (let ((x (expect as-planned w e)))
               (list (expectation-status x) (expectation-code x) (expectation-etag x) (expectation-json x))))))

(test-equal "oracle: a bulk move of 11's children to the top moves 12 and 14, not trashed 18: moved 2, left 1, no ETag; into Journal 3 none (kind, state): moved 0, left 3; into its child 12 would_loop; into Note 1 invalid_parent; trashed 15's archived child moves"
  (list (list 200 #f #f '(("left" . 1) ("moved" . 2))) (list 200 #f #f '(("left" . 3) ("moved" . 0)))
        '(409 "would_loop" #f #f) '(409 "invalid_parent" #f #f) (list 200 #f #f '(("left" . 0) ("moved" . 1))))
  (map (lambda (e) (bulk tree e))
       (list (bulk-at tat 'a a1 11 1 'null) (bulk-at tat 'a a1 11 1 (ref 3)) (bulk-at tat 'a a1 11 1 (ref 12))
             (bulk-at tat 'a a1 11 1 (ref 1)) (bulk-at tat 'a a1 15 2 'null))))

(test-equal "oracle: the bulk move leaves 11 at 1 and moves 12 and 14 each to 2 at the top, a change row move each, in id order"
  (list 1 '(2 #f) '(2 #f) (list (list (nid 12) 2 "move" tat) (list (nid 14) 2 "move" tat)))
  (attempt
   (lambda ()
     (let* ((w (expectation-world (expect as-planned tree (bulk-at tat 'a a1 11 1 'null))))
            (cs (reverse (world-changes-of w 'a))))
       (list (mnode-revision (world-node w (nid 11)))
             (list (mnode-revision (world-node w (nid 12))) (parent-in w 12))
             (list (mnode-revision (world-node w (nid 14))) (parent-in w 14))
             (map (lambda (c) (list (mchange-node c) (mchange-revision c) (mchange-op c) (mchange-created c)))
                  (reverse (list (car cs) (cadr cs)))))))))

(test-equal "oracle: a purge of trashed 15 with its archived child is 409 has_children; once the child is moved out it is 204, and the purged row has no parent"
  '((409 "has_children") (204 #f) #f)
  (attempt
   (lambda ()
     (let* ((w (expectation-world (expect as-planned tree (bulk-at tat 'a a1 15 2 'null))))
            (x (expect as-planned w (life-at (+ tat 1) 'a a1 15 2 'purge))))
       (list (status-of tree (life-at tat 'a a1 15 2 'purge))
             (list (expectation-status x) (expectation-code x))
             (mnode-parent (world-node (expectation-world x) (nid 15))))))))

;; ids-listed : World Event -> (U (Listof String) (List Status Code))
(define (ids-listed w e)
  (attempt (lambda ()
             (let ((x (expect as-planned w e)))
               (if (= (expectation-status x) 200)
                   (map (lambda (item) (member-of item "id")) (expectation-items x))
                   (list (expectation-status x) (expectation-code x)))))))

(test-equal "oracle: ?parent= 11 is its active children by id, trashed ones by ?state=; null the top level; a Note none; b's Project and a purged id 404; NULL and a bad ?state= before a missing parent 400"
  (list (list (id-of 12) (id-of 14)) (list (id-of 18)) (list (id-of 1) (id-of 11)) '() (list (id-of 16))
        '(404 "not_found") '(404 "not_found") '(400 "invalid_request") '(400 "invalid_request") '(400 "invalid_request"))
  (map (lambda (e) (ids-listed tree e))
       (list (list-in tat 'a #f (ref 11)) (list-in tat 'a "trashed" (ref 11)) (list-in tat 'a #f 'null)
             (list-in tat 'a #f (ref 13)) (list-in tat 'a "archived" (ref 15)) (list-in tat 'a #f (ref 17))
             (list-in tat 'a #f (ref 5)) (list-in tat 'a #f '(bad "NULL")) (list-in tat 'a "deleted" (ref 99))
             (list-in tat 'a #f 'twice))))

;; The chain: a's 100 to 164, Projects, each under the one before; node
;; 100 + k has k ancestors. Then 165 under 163 (63 ancestors), and 166, a
;; Project at the top, with 167 under it.
(define chain
  (attempt
   (lambda ()
     (walk-world hand
                 (append (map (lambda (k) (make-in (+ tat k) 'a a1 (+ 100 k) "project" (if (= k 0) 'absent (ref (+ 99 k)))))
                              (from-to 0 64))
                         (list (make-in (+ tat 70) 'a a1 166 "project" 'absent)
                               (make-in (+ tat 71) 'a a1 167 "project" (ref 166))
                               (move-at (+ tat 72) 'a a1 166 1 (ref 163))))))))

(define cat (+ tat 100))

(test-equal "oracle: depth (P18): a parent with 63 ancestors takes a create, a move and a bulk move; one with 64 refuses each, invalid_parent; 100 under 166, its 64th ancestor, would_loop; under 167, its 65th, invalid_parent"
  '((201 #f) (200 #f) (200 #f) (409 "invalid_parent") (409 "invalid_parent") (409 "invalid_parent")
    (409 "would_loop") (409 "invalid_parent") (409 "would_loop") (409 "invalid_parent"))
  (map (lambda (e) (attempt (lambda () (let ((x (expect as-planned chain e))) (list (expectation-status x) (expectation-code x))))))
       (list (make-in cat 'a a1 200 "note" (ref 163)) (move-at cat 'a a1 1 2 (ref 163))
             (bulk-at cat 'a a1 167 1 (ref 163))
             (make-in cat 'a a1 200 "note" (ref 164)) (move-at cat 'a a1 1 2 (ref 164))
             (bulk-at cat 'a a1 167 1 (ref 164))
             (move-at cat 'a a1 100 1 (ref 166)) (move-at cat 'a a1 100 1 (ref 167))
             (bulk-at cat 'a a1 100 1 (ref 166)) (bulk-at cat 'a a1 100 1 (ref 167)))))

;; Twisted rules of the tree, for the oracle and for the teeth below.

;; journal-holds-task : a Journal may hold a Task.
(define (journal-holds-task cell decision s)
  (if (and (situation-judged? s) (eq? (situation-verdict s) 'wrong-kind) (situation-parent s)
           (string=? (mnode-kind (situation-parent s)) "journal") (equal? (situation-kind s) "task"))
      (situation-if-ok s)
      decision))

;; trashed-movable : a trashed node is moved, its new parent judged as any.
(define (trashed-movable cell decision s)
  (if (and (equal? cell '(match trashed move)) (eq? (situation-verdict s) 'ok)) (situation-if-ok s) decision))

;; grandchild-loop : a new parent that is the node's grandchild is no loop.
(define (grandchild-loop cell decision s)
  (if (and (situation-judged? s) (eq? (situation-verdict s) 'loop) (eqv? (situation-loop-at s) 2))
      (situation-if-ok s)
      decision))

;; bulk-takes-trashed : a bulk move takes the trashed children of a kind the new parent holds too.
(define (bulk-takes-trashed cell decision s)
  (if (eq? (car decision) 'move-children) (list 'move-children (map mnode-id (situation-by-kind s))) decision))

;; purge-ignores-children : a trashed node at its revision purges, children or none.
(define (purge-ignores-children cell decision s)
  (if (equal? cell '(match trashed purge)) '(purge) decision))

;; depth-cap-65 : a new parent may have 64 ancestors.
(define (depth-cap-65 cell decision s)
  (if (and (situation-judged? s) (eq? (situation-verdict s) 'too-deep) (= (situation-depth s) 64))
      (situation-if-ok s)
      decision))

(test-equal "oracle: each tree twist changes the answer it bends: a Task into a Journal 201; trashed 15 moved 200; 11 under its grandchild 13 200; 11's children with trashed 18 moved 3; trashed 15 with a child purged 204; under 164 (64 ancestors) 201"
  (list 201 200 200 '(("left" . 0) ("moved" . 3)) 204 201)
  (attempt
   (lambda ()
     (list (expectation-status (expect journal-holds-task tree (make-in tat 'a a1 20 "task" (ref 12))))
           (expectation-status (expect trashed-movable tree (move-at tat 'a a1 15 2 'null)))
           (expectation-status (expect grandchild-loop tree (move-at tat 'a a1 11 1 (ref 13))))
           (expectation-json (expect bulk-takes-trashed tree (bulk-at tat 'a a1 11 1 'null)))
           (expectation-status (expect purge-ignores-children tree (life-at tat 'a a1 15 2 'purge)))
           (expectation-status (expect depth-cap-65 chain (make-in cat 'a a1 200 "note" (ref 164))))))))

;;; Links, on the hand world (slice 5b)

(define (lspec type target) (make-link-spec type target #f #f #f))
(define (put-link at tag n type m)
  (make-link-event 'link at tag (key-of tag) (nid n) '() #f #f '() (lspec type (if (bytevector? m) m (nid m)))))
(define (del-link at tag n type m)
  (make-link-event 'unlink at tag (key-of tag) (nid n) '() #f #f '() (lspec type (if (bytevector? m) m (nid m)))))
(define (links-at at tag n dir type limit after)
  (make-link-event 'list-links at tag (key-of tag) (nid n) '() limit #f '() (make-link-spec type #f #f dir after)))

;; answer3 : World Event -> (List Status Code JSON-or-'empty-or-#f)
(define (answer3 w e)
  (attempt (lambda () (let ((x (expect as-planned w e)))
                        (list (expectation-status x) (expectation-code x) (expectation-json x))))))

(define (link-rows w)
  (map (lambda (l) (list (mlink-tag l) (mlink-source l) (mlink-type l) (mlink-target l) (mlink-created l)))
       (world-links w)))

(define (last-change w tag)
  (let ((c (car (reverse (world-changes-of w tag)))))
    (list (mchange-seq c) (mchange-node c) (mchange-revision c) (mchange-op c) (mchange-created c))))

(define lat (+ t0 60))

;; made : the hand world with a's link from 1 (active at 2) to 3 (archived at 2), related, at lat
(define made (attempt (lambda () (expectation-world (expect as-planned hand (put-link lat 'a 1 "related" 3))))))

(test-equal "oracle: a link between two live nodes of the account's, neither trashed, is 201 with the link, no ETag, no Location; it is in the world, with a change row link on the source at its revision, and node 1 is as it was (H1')"
  (list (list 201 #f #f #f)
        (list (cons "created" lat) (cons "source" (id-of 1)) (cons "target" (id-of 3)) (cons "type" "related"))
        (list (list 'a (nid 1) "related" (nid 3) lat))
        (list 10 (nid 1) 2 "link" lat)
        (list 2 (+ t0 2)))
  (attempt
   (lambda ()
     (let ((x (expect as-planned hand (put-link lat 'a 1 "related" 3))))
       (list (list (expectation-status x) (expectation-code x) (expectation-etag x) (expectation-location x))
             (expectation-json x)
             (link-rows (expectation-world x))
             (last-change (expectation-world x) 'a)
             (let ((n (node-in (expectation-world x) 1))) (list (mnode-revision n) (mnode-updated n))))))))

(test-equal "oracle: a PUT of a link that is there is 200 with the first PUT's created, and writes no change row (Q3, Q15)"
  (list 200 lat 10)
  (attempt
   (lambda ()
     (let ((x (expect as-planned made (put-link (+ lat 5) 'a 1 "related" 3))))
       (list (expectation-status x) (member-of (expectation-json x) "created")
             (length (world-changes-of (expectation-world x) 'a)))))))

(test-equal "oracle: a PUT to or from a trashed node is 409 wrong_state; one of a missing, purged or other account's end is 404 at either end, before the 409; a node to itself, a type of another case, a precondition and a v4 target are 400 (K2, K6, K8)"
  '((409 "wrong_state") (409 "wrong_state") (404 "not_found") (404 "not_found") (404 "not_found")
    (404 "not_found") (404 "not_found") (404 "not_found") (404 "not_found")
    (400 "invalid_request") (400 "invalid_request") (400 "invalid_request") (400 "invalid_request"))
  (map (lambda (e) (attempt (lambda () (let ((x (expect as-planned hand e))) (list (expectation-status x) (expectation-code x))))))
       (list (put-link lat 'a 1 "related" 4) (put-link lat 'a 4 "related" 1)
             (put-link lat 'a 1 "related" 2) (put-link lat 'a 1 "related" 5) (put-link lat 'a 1 "related" 99)
             (put-link lat 'a 5 "related" 1) (put-link lat 'b 2 "related" 1) (put-link lat 'a 4 "related" 99)
             (put-link lat 'b 1 "related" 3)
             (put-link lat 'a 1 "related" 1) (put-link lat 'a 1 "Related" 3)
             (make-link-event 'link lat 'a a1 (nid 1) (list (cons "If-Match" "\"2\"")) #f #f '() (lspec "related" (nid 3)))
             (make-link-event 'link lat 'a a1 (nid 1) '() #f #f '() (lspec "related" "0198a1b2-c3d4-4e5f-8a6b-7c8d9e0f1a2b")))))

;; made-then-trashed : made, with 3 trashed (at its revision 2)
(define made-then-trashed (attempt (lambda () (walk-world made (list (life-at (+ lat 1) 'a a1 3 2 'trash))))))

(test-equal "oracle: a link there after an end is trashed: its PUT again is 200, kept, not 409; of another type 409; its DELETE 204 whatever the states"
  '((200 #f) (409 "wrong_state") (204 #f))
  (map (lambda (e) (attempt (lambda () (let ((x (expect as-planned made-then-trashed e)))
                                         (list (expectation-status x) (expectation-code x))))))
       (list (put-link (+ lat 2) 'a 1 "related" 3) (put-link (+ lat 2) 'a 1 "mentions" 3)
             (del-link (+ lat 2) 'a 1 "related" 3))))

(test-equal "oracle: a DELETE of a link that is there is 204 and removes it, with a change row unlink on the source at its revision; not there, from another account, of another type or to a target that is no node: 404 (K8)"
  (list (list 204 #f 'empty) '() (list 11 (nid 1) 2 "unlink" (+ lat 3))
        '((404 "not_found" #f) (404 "not_found" #f) (404 "not_found" #f) (404 "not_found" #f)))
  (attempt
   (lambda ()
     (let ((x (expect as-planned made (del-link (+ lat 3) 'a 1 "related" 3))))
       (list (list (expectation-status x) (expectation-code x) (expectation-json x))
             (link-rows (expectation-world x))
             (last-change (expectation-world x) 'a)
             (map (lambda (e) (answer3 made e))
                  (list (del-link (+ lat 3) 'a 3 "related" 1) (del-link (+ lat 3) 'b 1 "related" 3)
                        (del-link (+ lat 3) 'a 1 "mentions" 3) (del-link (+ lat 3) 'a 1 "related" 99))))))))

;; linked : hand, with a's 6 (a Note), and 1 mentions 6, 1 related to 3, 1 blocks 6, 6 related to 1, 3 blocks 1
(define linked
  (attempt
   (lambda ()
     (walk-world hand
                 (list (create-at (+ lat 10) 'a a1 6 "note" "six")
                       (put-link (+ lat 11) 'a 1 "mentions" 6) (put-link (+ lat 12) 'a 1 "related" 3)
                       (put-link (+ lat 13) 'a 1 "blocks" 6) (put-link (+ lat 14) 'a 6 "related" 1)
                       (put-link (+ lat 15) 'a 3 "blocks" 1))))))

;; listed : World Event -> (U (Listof (List Type Created Id)) (List Status Code))
(define (listed w e)
  (attempt (lambda ()
             (let ((x (expect as-planned w e)))
               (if (= (expectation-status x) 200)
                   (map (lambda (i) (list (member-of i "type") (member-of i "created") (member-of (member-of i "node") "id")))
                        (expectation-items x))
                   (list (expectation-status x) (expectation-code x)))))))

(define la (+ lat 20))

(test-equal "oracle: a link list is out by default, by type then the other node's id; in; of one type; after a place; an after of another type, a direction or a type of another spelling 400; a purged node's, another account's 404; a trashed node's with none, empty (K3, Q10, Q21)"
  (list (list (list "blocks" (+ lat 13) (id-of 6)) (list "mentions" (+ lat 11) (id-of 6)) (list "related" (+ lat 12) (id-of 3)))
        (list (list "blocks" (+ lat 15) (id-of 3)) (list "related" (+ lat 14) (id-of 6)))
        (list (list "mentions" (+ lat 11) (id-of 6)))
        (list (list "mentions" (+ lat 11) (id-of 6)) (list "related" (+ lat 12) (id-of 3)))
        '(400 "invalid_request") '(400 "invalid_request") '(400 "invalid_request")
        '(404 "not_found") '(404 "not_found") '())
  (map (lambda (e) (listed linked e))
       (list (links-at la 'a 1 #f #f #f #f) (links-at la 'a 1 "in" #f #f #f) (links-at la 'a 1 "out" "mentions" #f #f)
             (links-at la 'a 1 #f #f #f (cons "blocks" (nid 6)))
             (links-at la 'a 1 #f "related" #f (cons "blocks" (nid 6)))
             (links-at la 'a 1 "OUT" #f #f #f) (links-at la 'a 1 #f "Related" #f #f)
             (links-at la 'a 5 #f #f #f #f) (links-at la 'b 1 #f #f #f #f) (links-at la 'a 4 "in" #f #f #f))))

(test-equal "oracle: a link list's node is the other end as the nodes list shows it, without its body (Q14)"
  #t
  (attempt
   (lambda ()
     (let* ((item (car (expectation-items (expect as-planned linked (links-at la 'a 1 "in" "related" #f #f)))))
            (node (member-of item "node"))
            (listed (find (lambda (i) (equal? (member-of i "id") (id-of 6)))
                          (expectation-items (expect as-planned linked (list-at la 'a #f))))))
       (and (equal? (member-of node "id") (id-of 6)) (equal? node listed) (eq? (member-of node "body") 'absent))))))

(test-equal "oracle: a purge of 6 takes its three links, both ways, and leaves 1's to and from 3; a trash of 1 leaves every link (K7, Q8, Q9)"
  (list (list (list 'a (nid 1) "related" (nid 3) (+ lat 12)) (list 'a (nid 3) "blocks" (nid 1) (+ lat 15)))
        5)
  (attempt
   (lambda ()
     (list (link-rows (walk-world linked (list (life-at la 'a a1 6 1 'trash) (life-at (+ la 1) 'a a1 6 2 'purge))))
           (length (world-links (walk-world linked (list (life-at la 'a a1 1 2 'trash)))))))))

;; Twisted rules of links, for the oracle and for the teeth below. A
;; link's twist sees its LinkCell: the source's state, the target's, the
;; event, whether the link is there.

;; link-to-trashed : a link from an active source to a trashed target is made.
(define (link-to-trashed cell decision s)
  (if (equal? cell '(active trashed link #f)) '(link) decision))

;; kept-refused-when-trashed : a PUT of a link that is there, an end trashed, is 409.
(define (kept-refused-when-trashed cell decision s)
  (if (and (pair? cell) (= (length cell) 4) (eq? (caddr cell) 'link) (cadddr cell)
           (or (eq? (car cell) 'trashed) (eq? (cadr cell) 'trashed)))
      '(refuse 409 "wrong_state")
      decision))

(test-equal "oracle: each link twist changes the answer it bends: 1 to trashed 4 made, 201; 1's link to 3, there, 3 trashed, refused 409"
  '(201 409)
  (attempt
   (lambda ()
     (list (expectation-status (expect link-to-trashed hand (put-link lat 'a 1 "related" 4)))
           (expectation-status (expect kept-refused-when-trashed made-then-trashed (put-link (+ lat 2) 'a 1 "related" 3)))))))

;;; Props and a Task's commands, on the hand world (slice 6)

;; corpus : Symbol -> Entry     the corpus's entry of that name
(define (corpus name) (find (lambda (e) (eq? (entry-name e) name)) props-corpus))

(define (put-props at tag n pre kind props)
  (make-event 'put at tag (key-of tag) (nid n) pre '() (make-content kind "t" "b" "text/plain" props 'absent)
              #f #f #f #f '() 'absent))
(define (command-at at tag n rev ev)
  (make-event ev at tag (key-of tag) (nid n) rev '() #f #f #f #f #f '() 'absent))

;; outcome : World Event -> (List Status Code Jobs (U Any 'absent))     and the answer's props
(define (outcome w e)
  (attempt (lambda ()
             (let ((x (expect as-planned w e)))
               (list (expectation-status x) (expectation-code x) (expectation-jobs x)
                     (member-of (expectation-json x) "props"))))))

(define pat (+ t0 80))

;; tasks : hand, with a's 40 a Task made with no props (TODO), 41 a Task
;; made DONE with no closed at pat, 42 a Note made with at, 43 a Task made
;; WONTDO with the closed it gave, then trashed (at 2), 44 a Note trashed (at 2)
(define tasks
  (attempt
   (lambda ()
     (walk-world hand
                 (list (put-props pat 'a 40 'create "task" #f)
                       (put-props (+ pat 1) 'a 41 'create "task" (corpus 'task-done))
                       (put-props (+ pat 2) 'a 42 'create "note" (corpus 'note-local))
                       (put-props (+ pat 3) 'a 43 'create "task" (corpus 'task-wontdo-closed-0))
                       (life-at (+ pat 4) 'a a1 43 1 'trash)
                       (put-props (+ pat 5) 'a 44 'create "note" #f)
                       (life-at (+ pat 6) 'a a1 44 1 'trash))))))

(define tat6 (+ pat 20))

(test-equal "oracle: a Task made with no props is TODO, stored {}, shown {\"status\":\"TODO\"}; made DONE it has closed the write's time; made WONTDO with closed 0 keeps 0 (P9, P14)"
  (list "{}" '(("status" . "TODO")) (string-append "{\"status\":\"DONE\",\"closed\":" (number->string (+ pat 1)) "}")
        "{\"status\":\"WONTDO\",\"closed\":0}" "{\"at\":\"2026-12-01T15:00\"}")
  (attempt
   (lambda ()
     (let ((text (lambda (n) (mprops-text (msnap-props (car (mnode-snaps (node-in tasks n))))))))
       (list (text 40) (member-of (expectation-json (expect as-planned tasks (read-at tat6 'a 'get-node 40 #f))) "props")
             (text 41) (text 43) (text 42))))))

(test-equal "oracle: a create's props are judged before the job (no write job): another kind's, none's, TODO with a closed, over the cap 413; a {} create of every kind is 201"
  '((400 "invalid_request" 0 absent) (400 "invalid_request" 0 absent) (400 "invalid_request" 0 absent)
    (413 "props_too_large" 0 absent) (201 #f 1 ()))
  (map (lambda (e) (outcome tasks e))
       (list (put-props tat6 'a 50 'create "project" (corpus 'note-date))
             (put-props tat6 'a 50 'create "note" (corpus 'nothing-colour))
             (put-props tat6 'a 50 'create "task" (corpus 'task-todo-closed))
             (put-props tat6 'a 50 'create "contact" (corpus 'contact-over-cap))
             (put-props tat6 'a 50 'create "journal" (corpus 'empty)))))

(test-equal "oracle: done moves TODO to DONE, closed now, one revision and a snapshot; wontdo then keeps closed; reopen removes it; each op its name; no body in the answer"
  (list (list 200 "\"2\"" (list (cons "closed" tat6) (cons "status" "DONE")) 'absent "done" '(2 1))
        (list (cons "closed" tat6) (cons "status" "WONTDO")) "wontdo"
        '(("status" . "TODO")) "reopen" "{}")
  (attempt
   (lambda ()
     (let* ((x1 (expect as-planned tasks (command-at tat6 'a 40 1 'done)))
            (w1 (expectation-world x1))
            (x2 (expect as-planned w1 (command-at (+ tat6 1) 'a 40 2 'wontdo)))
            (w2 (expectation-world x2))
            (x3 (expect as-planned w2 (command-at (+ tat6 2) 'a 40 3 'reopen)))
            (w3 (expectation-world x3))
            (op (lambda (w) (mchange-op (car (reverse (world-changes-of w 'a)))))))
       (list (list (expectation-status x1) (expectation-etag x1) (member-of (expectation-json x1) "props")
                   (member-of (expectation-json x1) "body") (op w1) (map msnap-revision (mnode-snaps (node-in w1 40))))
             (member-of (expectation-json x2) "props") (op w2)
             (member-of (expectation-json x3) "props") (op w3)
             (mprops-text (msnap-props (car (mnode-snaps (node-in w3 40))))))))))

(test-equal "oracle: a command's order: 404 b's, 412 stale on a trashed Note, wrong_state for a trashed Note before not_a_task, not_a_task, wrong_status, 428 none, 400 If-None-Match"
  '((404 "not_found" 1 absent) (412 "precondition_failed" 1 absent) (409 "wrong_state" 1 absent)
    (409 "wrong_state" 1 absent) (409 "not_a_task" 1 absent) (409 "wrong_status" 1 absent)
    (409 "wrong_status" 1 absent) (428 "precondition_required" 0 absent) (400 "invalid_request" 0 absent))
  (map (lambda (e) (outcome tasks e))
       (list (command-at tat6 'b 40 1 'done) (command-at tat6 'a 44 1 'done) (command-at tat6 'a 44 2 'done)
             (command-at tat6 'a 43 2 'reopen) (command-at tat6 'a 42 1 'done) (command-at tat6 'a 41 1 'done)
             (command-at tat6 'a 40 1 'reopen)
             (make-event 'done tat6 'a a1 (nid 40) 'missing '() #f #f #f #f #f '() 'absent)
             (make-event 'done tat6 'a a1 (nid 40) 'invalid '() #f #f #f #f #f '() 'absent))))

(test-equal "oracle: a replace of a Task: no props keep them (P11); its status sent back is taken; another status or a closed while TODO is status_fixed in the job; the deadline sent replaces"
  (list (list 200 #f 1 (list (cons "closed" (+ pat 1)) (cons "status" "DONE")))
        (list 200 #f 1 '(("status" . "TODO")))
        '(409 "status_fixed" 1 absent) '(409 "status_fixed" 1 absent)
        (list 200 #f 1 (list (cons "closed" (+ pat 1)) (cons "deadline" "2026-12-01") (cons "status" "DONE"))))
  (map (lambda (e) (outcome tasks e))
       (list (put-props tat6 'a 41 1 #f #f) (put-props tat6 'a 40 1 #f (corpus 'task-todo))
             (put-props tat6 'a 40 1 #f (corpus 'task-done)) (put-props tat6 'a 40 1 "task" (corpus 'task-todo-closed))
             (put-props tat6 'a 41 1 #f (corpus 'task-deadline-date)))))

(test-equal "oracle: a replace's props: naming no kind, Task props on a Note are the 400 in the job; naming note, before it; no kind's before it; {} clears a Note's at; none keeps it"
  '((400 "invalid_request" 1 absent) (400 "invalid_request" 0 absent) (400 "invalid_request" 0 absent)
    (200 #f 1 ()) (200 #f 1 (("at" . "2026-12-01T15:00"))))
  (map (lambda (e) (outcome tasks e))
       (list (put-props tat6 'a 42 1 #f (corpus 'task-deadline-date)) (put-props tat6 'a 42 1 "note" (corpus 'task-deadline-date))
             (put-props tat6 'a 42 1 #f (corpus 'nothing-colour)) (put-props tat6 'a 42 1 #f (corpus 'empty))
             (put-props tat6 'a 42 1 #f #f))))

(test-equal "oracle: a restore of a Task's snapshot from before done (the deadline since cleared) keeps DONE and closed, and brings back the deadline (P10)"
  (list 200 (list (cons "closed" (+ tat6 1)) (cons "deadline" "2026-12-01") (cons "status" "DONE")))
  (attempt
   (lambda ()
     (let* ((w (walk-world tasks (list (put-props tat6 'a 40 1 #f (corpus 'task-deadline-date))
                                       (command-at (+ tat6 1) 'a 40 2 'done)
                                       (put-props (+ tat6 2) 'a 40 3 #f (corpus 'empty)))))
            (x (expect as-planned w (restore-at (+ tat6 3) 'a a1 40 4 2))))
       (list (expectation-status x) (member-of (expectation-json x) "props"))))))

(test-equal "oracle: a Task stored {} shows TODO in its snapshots and the snapshot list too (R8)"
  '((("status" . "TODO")) ((("status" . "TODO"))))
  (attempt
   (lambda ()
     (list (member-of (expectation-json (expect as-planned tasks (read-at tat6 'a 'get-snapshot 40 1))) "props")
           (map (lambda (i) (member-of i "props")) (expectation-items (expect as-planned tasks (read-at tat6 'a 'list-revisions 40 #f))))))))

;; Twisted rules of slice 6, for the oracle and for the teeth below. A
;; command's twist sees its TaskCell: (task found state kind status command).

;; wontdo-resets-closed : DONE to WONTDO sets closed to the write's time, as leaving TODO does.
(define (wontdo-resets-closed cell decision s)
  (if (equal? decision '(transition "WONTDO" keep)) '(transition "WONTDO" close) decision))

;; status-claim-taken : a replace's claim of another status or closed is written, the claim ignored.
(define (status-claim-taken cell decision s)
  (if (equal? decision '(refuse 409 "status_fixed")) '(write) decision))

(test-equal "oracle: each slice 6 twist changes the answer it bends: DONE 41 to WONTDO has closed now; 40 replaced claiming DONE, 200"
  (list (list (cons "closed" tat6) (cons "status" "WONTDO")) 200)
  (attempt
   (lambda ()
     (list (member-of (expectation-json (expect wontdo-resets-closed tasks (command-at tat6 'a 41 1 'wontdo))) "props")
           (expectation-status (expect status-claim-taken tasks (put-props tat6 'a 40 1 #f (corpus 'task-done))))))))

;;; Tags, on the hand world (slice 7a)

;; names->sent : (U 'absent (Listof Symbol)) -> TagsSent     the corpus's entries of those names, as sent
(define (names->sent names) (if (eq? names 'absent) 'absent (list 'entries (map tag-named names))))

(define (tag-put at tag n pre kind names)
  (make-event 'put at tag (key-of tag) (nid n) pre '() (make-tagged-content kind "t" "b" "text/plain" #f 'absent (names->sent names))
              #f #f #f #f '() 'absent))
(define (tag-put-props at tag n pre kind props sent)
  (make-event 'put at tag (key-of tag) (nid n) pre '() (make-tagged-content kind "t" "b" "text/plain" props 'absent sent)
              #f #f #f #f '() 'absent))

;; step-at : Natural Tag Symbol (Listof (Pair String Symbol)) [Body-or-#f (Listof Header) Boolean] -> Event
(define (step-at at tag kind members)
  (make-tag-event kind at tag (key-of tag) '() #f '()
                  (make-command-spec (list 'members (map (lambda (m) (cons (car m) (tag-named (cdr m)))) members)) #t)))
(define (step-with at tag kind body headers json?)
  (make-tag-event kind at tag (key-of tag) headers #f '() (make-command-spec body json?)))

(define (tags-of w n) (mnode-tags (node-in w n)))
(define (snap-tags w n) (map msnap-tags (mnode-snaps (node-in w n))))

(define tg (+ t0 120))

;; tagged : hand, with a's 60 a Note made with Work, home and WORK; 61 a
;; Note with work, archived at 2; 62 a Note with work and É, trashed at 2;
;; b's 63 a Note with work; a's 64 a Task with Errands
(define tagged
  (attempt
   (lambda ()
     (walk-world hand
                 (list (tag-put tg 'a 60 'create "note" '(work-capital home work-upper))
                       (tag-put (+ tg 1) 'a 61 'create "note" '(work))
                       (life-at (+ tg 2) 'a a1 61 1 'archive)
                       (tag-put (+ tg 3) 'a 62 'create "note" '(work e-acute-upper))
                       (life-at (+ tg 4) 'a a1 62 1 'trash)
                       (tag-put (+ tg 5) 'b 63 'create "note" '(work))
                       (tag-put (+ tg 6) 'a 64 'create "task" '(errands-capital)))))))

(define ta (+ tg 20))

(test-equal "oracle: a create's tags are stored folded, sorted, each once: the answer shows them, the node and its snapshot hold them (G3, L3)"
  (list 201 '#("home" "work") '("home" "work") '(("home" "work")) '#() '())
  (attempt
   (lambda ()
     (let ((x (expect as-planned hand (tag-put ta 'a 60 'create "note" '(work-capital home work-upper))))
           (y (expect as-planned hand (tag-put ta 'a 60 'create "note" 'absent))))
       (list (expectation-status x) (member-of (expectation-json x) "tags") (tags-of (expectation-world x) 60)
             (snap-tags (expectation-world x) 60) (member-of (expectation-json y) "tags") (tags-of (expectation-world y) 60))))))

(test-equal "oracle: a replace with no tags keeps them (G2, L4); [] clears them; a list replaces them whole"
  '(#("home" "work") #() #("\x1f389;"))
  (map (lambda (names)
         (attempt (lambda () (member-of (expectation-json (expect as-planned tagged (tag-put ta 'a 60 1 #f names))) "tags"))))
       (list 'absent '() '(party))))

(test-equal "oracle: a PUT's order: the props' 400 before the tags'; the tags' 400 before the props' 413; 51 entries that fold to one, a value no array, a refused tag: 400, with no write job (L10)"
  '((400 "props" 0) (400 "tags" 0) (413 "props" 0) (400 "tags" 0) (400 "tags" 0) (400 "tags" 0) (201 #f 1))
  (map (lambda (e)
         (attempt (lambda ()
                    (let ((x (expect as-planned tagged e)))
                      (list (expectation-status x)
                            (let ((c (expectation-clause x)))
                              (cond ((not (= (expectation-status x) 201)) (if (contains? c "tags that") "tags" "props"))
                                    (else #f)))
                            (expectation-jobs x))))))
       (list (tag-put-props ta 'a 70 'create "note" (corpus 'nothing-colour) (names->sent '(tab)))
             (tag-put-props ta 'a 70 'create "contact" (corpus 'contact-over-cap) (names->sent '(tab)))
             (tag-put-props ta 'a 70 'create "contact" (corpus 'contact-over-cap) (names->sent '(work)))
             (tag-put ta 'a 70 'create "note" (map (lambda (i) 'work-capital) (from-to 0 50)))
             (tag-put-props ta 'a 70 'create "note" #f '(raw "null" null))
             (tag-put ta 'a 60 1 #f '(work heart-variation-selector))
             (tag-put ta 'a 70 'create "note" (map tag-entry-name numbered-sent)))))

(test-equal "oracle: a restore brings a snapshot's tags back, as stored (L11); a Task's command keeps the node's tags and its snapshot holds them (L3); a purge leaves none (L7)"
  (list '#("home" "work") '("errands") '("errands") '())
  (attempt
   (lambda ()
     (let* ((w1 (walk-world tagged (list (tag-put ta 'a 60 1 #f '()))))
            (x (expect as-planned w1 (restore-at (+ ta 1) 'a a1 60 2 1)))
            (y (expect as-planned tagged (command-at ta 'a 64 1 'done)))
            (z (expect as-planned tagged (life-at ta 'a a1 62 2 'purge))))
       (list (member-of (expectation-json x) "tags") (tags-of (expectation-world y) 64)
             (car (snap-tags (expectation-world y) 64)) (tags-of (expectation-world z) 62))))))

(test-equal "oracle: a rename touches every carrier of the account's, in any state, by id: each at its next revision, a change row tags each in id order, no snapshot; a merge keeps one tag; left 0; the other account's untouched (L5, L6, L13)"
  (list 200 '(("left" . 0) ("renamed" . 3)) #f
        '(("home") ("home") ("home" "\xe9;")) '(2 3 3) '(1 1 1)
        (list (list (nid 60) 2 "tags" ta) (list (nid 61) 3 "tags" ta) (list (nid 62) 3 "tags" ta))
        '("work"))
  (attempt
   (lambda ()
     (let* ((x (expect as-planned tagged (step-at ta 'a 'rename-tag '(("from" . work-capital) ("to" . home)))))
            (w (expectation-world x)))
       (list (expectation-status x) (expectation-json x) (expectation-etag x)
             (map (lambda (n) (tags-of w n)) '(60 61 62))
             (map (lambda (n) (mnode-revision (node-in w n))) '(60 61 62))
             (map (lambda (n) (length (mnode-snaps (node-in w n)))) '(60 61 62))
             (map (lambda (c) (list (mchange-node c) (mchange-revision c) (mchange-op c) (mchange-created c)))
                  (list-tail (world-changes-of w 'a) (- (length (world-changes-of w 'a)) 3)))
             (tags-of w 63))))))

(test-equal "oracle: a command on a tag only the other account carries is 0 and 0, never 404, one write job; a precondition 400, text/plain 415, a body over 16 KiB 413, no JSON invalid_json, from and to one tag 400, each with none"
  '((200 (("left" . 0) ("removed" . 0)) 1) (400 "invalid_request" 0) (415 "unsupported_media_type" 0)
    (413 "payload_too_large" 0) (400 "invalid_json" 0) (400 "invalid_request" 0) (400 "invalid_request" 0))
  (map (lambda (e)
         (attempt (lambda ()
                    (let ((x (expect as-planned tagged e)))
                      (list (expectation-status x) (or (expectation-code x) (expectation-json x)) (expectation-jobs x))))))
       (list (step-at ta 'b 'remove-tag '(("tag" . home)))
             (step-with ta 'a 'remove-tag (list 'members (list (cons "tag" (tag-named 'work)))) (list (cons "If-Match" "\"1\"")) #t)
             (step-with ta 'a 'remove-tag (list 'members (list (cons "tag" (tag-named 'work)))) '() #f)
             (step-with ta 'a 'remove-tag (list 'padded (list (cons "tag" (tag-named 'work))) 20000) '() #t)
             (step-with ta 'a 'remove-tag '(text "{" not-json) '() #t)
             (step-at ta 'a 'rename-tag '(("from" . work-capital) ("to" . work-upper)))
             (step-at ta 'a 'rename-tag '(("from" . work) ("from" . home))))))

;; crowded : 502 Notes of a's carrying crowd, made from the hand world
(define crowded
  (attempt
   (lambda ()
     (walk-world hand (map (lambda (k) (tag-put (+ tg k) 'a (+ 2000 k) 'create "note" '(crowd))) (from-to 1 502))))))

(test-equal "oracle: a step takes 500 of 502 carriers, the first by id, and leaves 2; the next takes the 2 and leaves none (G8)"
  (list '(("left" . 2) ("renamed" . 500)) '(("left" . 0) ("renamed" . 2)) 500 (list (nid 2501) (nid 2502)))
  (attempt
   (lambda ()
     (let* ((x (expect as-planned crowded (step-at ta 'a 'rename-tag '(("from" . crowd) ("to" . throng)))))
            (w (expectation-world x))
            (y (expect as-planned w (step-at (+ ta 1) 'a 'rename-tag '(("from" . crowd-upper) ("to" . throng))))))
       (list (expectation-json x) (expectation-json y)
             (length (filter (lambda (n) (member "throng" (mnode-tags n))) (world-nodes w)))
             (map mnode-id (filter (lambda (n) (member "crowd" (mnode-tags n))) (world-nodes w))))))))

(define (tags-list-at at tag limit after) (make-tag-event 'list-tags at tag (key-of tag) '() limit '() (make-tags-list-spec after)))
(define (filter-at at tag state names after)
  (make-filter-event at tag (key-of tag) #f state 'absent '()
                     (make-filter-spec (map (lambda (n) (if (eq? n 'bare) n (list 'entry (tag-named n) 'strict))) names) after)))

(test-equal "oracle: the tags list counts each tag over every state, by code point; after a tag, folded; an after refused or given twice is 400; the filter takes every tag named, in the state asked, counted as sent toward ten"
  (list '((("count" . 1) ("tag" . "errands")) (("count" . 1) ("tag" . "home")) (("count" . 3) ("tag" . "work")) (("count" . 1) ("tag" . "\xe9;")))
        '((("count" . 3) ("tag" . "work")) (("count" . 1) ("tag" . "\xe9;")))
        '(400 "invalid_request") '(400 "invalid_request")
        (list (id-of 60)) (list (id-of 62)) '(400 "invalid_request") (list (id-of 60)) '(400 "invalid_request"))
  (map (lambda (e)
         (attempt (lambda ()
                    (let ((x (expect as-planned tagged e)))
                      (if (= (expectation-status x) 200)
                          (let ((items (expectation-items x)))
                            (if (and (pair? items) (assoc "id" (car items))) (map (lambda (i) (member-of i "id")) items) items))
                          (list (expectation-status x) (expectation-code x)))))))
       (list (tags-list-at ta 'a #f #f) (tags-list-at ta 'a #f (list 'entry (tag-named 'home-capital) 'strict))
             (tags-list-at ta 'a #f (list 'entry (tag-named 'tab) 'strict)) (tags-list-at ta 'a #f 'twice)
             (filter-at ta 'a #f '(work-capital home) #f) (filter-at ta 'a "trashed" '(e-acute work) #f)
             (filter-at ta 'a #f '(work bare) #f) (filter-at ta 'a #f (map (lambda (i) 'work) (from-to 1 10)) #f)
             (filter-at ta 'a #f (map (lambda (i) 'work) (from-to 0 10)) #f))))

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

;;; The props corpus (slice 6): what it says of itself, then each entry
;;; once through the real handlers, so a wrong entry is a named failure
;;; here and not a mystery mid-run.

(unless replay-seed
  (test-equal "corpus: its names, verdicts, texts, Whens, claims, the cap's two texts and R17's two orderings hold"
    '()
    (attempt corpus-self-breaks))

  (test-equal "corpus: every entry, as a create of every kind and a replace naming no kind of every kind, is answered as the corpus says, with its write jobs"
    '()
    (attempt (lambda () (corpus-breaks store))))

  (test-equal "tag corpus: its names, stored forms, fixed points (L1), raw query values and both caps hold"
    '()
    (attempt tag-corpus-self-breaks))

  (test-equal "tag corpus: every entry, as a create's tags and as a list's ?tag=, and every raw query value, is answered as the corpus says"
    '()
    (attempt (lambda () (tag-corpus-breaks store)))))

;;; Replay: one seed, traced

(define replayed (and replay-seed (failure (run-one as-planned replay-seed #t))))

(when replay-seed
  (when replayed (display replayed))
  (test-equal (format "replay of seed ~a: every request agrees" replay-seed) #f replayed))

;;; 2. The run

(define sequences 300)
(define run-ms #f)
(define verdicts
  (if replay-seed
      '()
      (map (lambda (s) (run-one as-planned s #f)) (from-to first-seed (+ first-seed sequences -1)))))
(define failures (filter (lambda (f) f) (map failure verdicts)))
(set! run-ms (- (real-time) started))
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
(define (crowd? v) (eq? (verdict-style v) 'crowd))
(define shortest (fold-left min 1000 (map verdict-steps (filter (lambda (v) (not (crowd? v))) agreed))))
(define shortest-crowd (fold-left min 1000 (map verdict-steps (filter crowd? agreed))))

(define d5-events '(create replace replace-other-kind restore restore-unknown))
(define move-events '(move move-children))
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

;; lifecycle-cells : the plan's table: each live state by the five events, write and the two moves
(define lifecycle-cells
  (apply append (map (lambda (s) (map (lambda (e) (list s e)) (append lifecycle-events '(write) move-events)))
                     '(active archived trashed))))

;; reachable-cells : node-command's cells a request can reach, in the plan's words.
;;   none, no state: a create of a free id; a replace, a restore, each
;;     state change, a move and a bulk move of a node the account has not
;;     got (no kind to differ from, no snapshot to restore)
;;   differ, no state: a create on an id in use (a create's job reads no state)
;;   differ and match, each live state: every event but a create
(define reachable-cells
  (append (map (lambda (e) (list 'none #f e))
               (append '(create replace restore-unknown) lifecycle-events move-events))
          (list (list 'differ #f 'create))
          (apply append
                 (map (lambda (f)
                        (apply append
                               (map (lambda (s)
                                      (map (lambda (e) (list f s e))
                                           (append '(replace replace-other-kind restore restore-unknown)
                                                   lifecycle-events move-events)))
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
    bad-precondition-untrash bad-precondition-purge bad-create-on-lifecycle
    ;; slice 5a
    no-precondition-move no-precondition-move-children bad-precondition-move bad-precondition-move-children
    bad-create-on-move))

;;; The tree's coverage (slice 5a)

(define tree-routes '(create move move-children))
(define (aim-of . parts) (string->symbol (apply string-append (map (lambda (p) (format "~a" p)) parts))))

;; verdict-cases : each verdict by each route that can get it (tree-aims
;; counts one when the rules looked at it). A create keeps out an id that
;; is no node's, so no new parent is under it: a create has no loop. P12's
;; three kinds of missing parent each.
(define verdict-cases
  (apply append
         (map (lambda (route)
                (map (lambda (v) (aim-of "verdict-" route "-" v))
                     (append '(ok-top ok-parent missing-fresh missing-other missing-purged trashed)
                             (if (eq? route 'create) '() '(loop))
                             '(wrong-kind too-deep))))
              tree-routes)))

;; pair-aims : each parent's kind by each kind going in, a create's or a
;; move's, once the verdict reached the kind: 6 allowed, 19 not (T2)
(define pair-aims (apply append (map (lambda (p) (map (lambda (k) (aim-of "pair-" p "-" k)) kinds)) kinds)))

;; depth-aims : the boundary from both sides by each route, a loop at the
;; 64th ancestor and one above it (P18; the deep seeds' script)
(define depth-aims
  (append (map (lambda (r) (aim-of "depth-63-" r)) tree-routes)
          (map (lambda (r) (aim-of "depth-64-" r)) tree-routes)
          '(loop-at-64-move loop-at-64-move-children loop-above-cap-move loop-above-cap-move-children)))

;; loop-aims : a loop by where the node kept out sits above the new parent
(define loop-aims
  (apply append (map (lambda (r) (map (lambda (at) (aim-of "loop-" at "-" r)) '(self child grandchild deeper)))
                     '(move move-children))))

;; bulk-aims : each accepted bulk move's outcome: no children; all move;
;; some; some stay for their state (trashed); some stay for their kind.
;; rare-bulk-aims: children, none movable; a trashed child of a kind the
;; new parent holds
(define bulk-aims '(bulk-no-children bulk-all-move bulk-some-move bulk-stay-state bulk-stay-kind))
(define rare-bulk-aims '(bulk-none-movable bulk-stay-state-fits))

;; purge-aims : has_children with an active child, and a purge that passes
;; once a parent is emptied; rare-purge-aims: has_children with an
;; archived child, a trashed one, and none active
(define purge-aims '(has-children-active purge-emptied-parent))
(define rare-purge-aims '(has-children-archived has-children-trashed has-children-none-active))

;; list-parent-aims : ?parent= by case; list-state-aims: the cases that
;; list, by ?state=, and a ?state= that is the 400 before ?parent= is asked
(define list-parent-cases '(null node note trashed missing other purged bad twice))
(define list-parent-aims (map (lambda (c) (aim-of "list-parent-" c)) list-parent-cases))
(define list-state-aims
  (append (apply append (map (lambda (c) (map (lambda (s) (aim-of "list-parent-" c "-" s))
                                               '(default active archived trashed)))
                             '(null node note trashed)))
          (map (lambda (c) (aim-of "list-parent-" c "-invalid")) '(null node missing other))))

;; other-tree-aims : another account's node moved (G7), and the rest
(define other-tree-aims
  '(move-other-current move-children-other-current move-same-parent move-archived move-into-archived
    create-in-archived move-trashed-would-pass))

;; tree-floors : (Listof (Pair (Listof Symbol) Natural))
;; Each group's floor is about half the fewest seen over seeds 1 to 300 and
;; five other runs of 300 (FIRST 1001 to 5001): a verdict 9, a pairing 10,
;; the depth's 20 (exactly the deep seeds), a loop 21, a bulk outcome 62
;; (a rare one 7), has_children with an active child or an emptied parent
;; purged 18 (the rare ones 4), a ?parent= case 15, one by ?state= 3, the
;; rest 28.
(define tree-floors
  (list (cons verdict-cases 4) (cons pair-aims 5) (cons depth-aims 10) (cons loop-aims 10)
        (cons bulk-aims 30) (cons rare-bulk-aims 3) (cons purge-aims 9) (cons rare-purge-aims 2)
        (cons list-parent-aims 7) (cons list-state-aims 1) (cons other-tree-aims 14)))
(define tree-aims-all (apply append (map car tree-floors)))

;;; The links' coverage (slice 5b)

(define link-states '(active archived trashed))

;; link-cells : link-command's cells a request reaches, by the model's
;; reading (link-aims' lc-): a PUT from no source, to a target of each
;; state or none (no link can be there); from each state to none; between
;; two of the account's live nodes, the link there or not; a DELETE from
;; no source, and from each state, there or not (its target not read).
(define link-cells
  (append (map (lambda (t) (aim-of "lc-link-none-" t "-absent")) (cons 'none link-states))
          (map (lambda (s) (aim-of "lc-link-" s "-none-absent")) link-states)
          (apply append
                 (map (lambda (s)
                        (apply append (map (lambda (t) (map (lambda (th) (aim-of "lc-link-" s "-" t "-" th)) '(there absent)))
                                           link-states)))
                      link-states))
          (list 'lc-unlink-none-any-absent)
          (apply append (map (lambda (s) (map (lambda (th) (aim-of "lc-unlink-" s "-any-" th)) '(there absent)))
                             link-states))))

(define (lc-aim? a) (let ((s (symbol->string a))) (and (> (string-length s) 3) (string=? (substring s 0 3) "lc-"))))

;; Each outcome the brief names, by its cause: 201, 200 kept (with a
;; trashed end too), 204 (whatever the states), each 404 by its cause and
;; the 404 before the 409, each 409 by which end, each 400.
(define link-outcome-aims
  '(link-made link-kept link-kept-source-trashed link-kept-target-trashed
    unlink-removed unlink-removed-source-trashed unlink-removed-source-archived unlink-removed-target-trashed))
(define link-404-aims
  '(link-404-source-missing link-404-source-purged link-404-source-other
    link-404-target-missing link-404-target-purged link-404-target-other
    link-404-target-missing-source-trashed link-404-target-purged-source-trashed link-404-target-other-source-trashed
    unlink-404-source-missing unlink-404-source-purged unlink-404-source-other
    unlink-404-absent unlink-404-absent-target-missing unlink-404-absent-target-purged unlink-404-absent-target-other))
(define link-409-aims '(link-409-source-trashed link-409-target-trashed link-409-both-trashed))
(define link-400-aims
  '(link-400-type link-400-target link-400-self link-400-precondition
    unlink-400-type unlink-400-target unlink-400-self unlink-400-precondition
    list-links-400-direction list-links-400-type list-links-400-after-other-type))
;; A purge that took links out only, in only, and both ways (K7, Q8, Q17)
(define purge-link-aims '(purge-links-out purge-links-in purge-links-both))
;; Lists both ways, typed and not, pages followed, Q21's limits, the 404s,
;; an after's place, an ignored If-Match, trashed and archived nodes and
;; other ends, an empty page, the other account's linked node
(define list-link-aims
  '(list-links-out-typed list-links-out-untyped list-links-in-typed list-links-in-untyped
    list-links-out-pages-followed list-links-in-pages-followed list-links-limit-1-followed list-links-limit-100
    list-links-404-missing list-links-404-purged list-links-404-other
    list-links-after-place list-links-precondition-ignored list-links-of-trashed list-links-of-archived
    list-links-item-trashed list-links-item-archived list-links-empty list-links-of-other-linked))
;; last_used with links (H4'', D6); the other account's link asked by this
;; one (G7'); every write that leaves links as they are, of a linked node (Q9)
(define link-other-aims
  '(link-refused-while-due link-last-used-set link-link-pair-other-link unlink-link-pair-other-link
    linked-trash linked-archive linked-unarchive linked-untrash linked-replace linked-restore linked-move
    linked-move-children))

;; link-floors : (Listof (Pair (Listof Symbol) Natural))
;; Each group's floor is about half the fewest seen over seeds 1 to 300 and
;; five other runs of 300 (FIRST 1001 to 5001): a cell 15 (an unlink of an
;; archived source's link), an outcome 15 (the same), a 404 15 (a purged
;; target from a trashed source), a 409 92, a 400 28, a purge's links 12
;; (out only), a list's 41 (an archived other end), the rest 11 (an
;; unarchive of a linked node).
(define link-floors
  (list (cons link-cells 7) (cons link-outcome-aims 7) (cons link-404-aims 7) (cons link-409-aims 45)
        (cons link-400-aims 14) (cons purge-link-aims 6) (cons list-link-aims 20) (cons link-other-aims 5)))
(define link-aims-all (apply append (map car link-floors)))

;;; Slice 6's coverage: props and a Task's commands

;; task-cells : State (Listof (List String Symbol)) -> (Listof Symbol)
;; The task table's cells (status, command) on a Task in STATE.
(define (task-cells state cells)
  (map (lambda (c) (aim-of "task-cell-" state "-" (car c) "-" (cadr c))) cells))
;; The six moves the table takes, and the three it refuses, wrong_status
(define task-moves-taken '(("TODO" done) ("TODO" wontdo) ("DONE" wontdo) ("DONE" reopen) ("WONTDO" done) ("WONTDO" reopen)))
(define task-moves-refused '(("TODO" reopen) ("DONE" done) ("WONTDO" wontdo)))

;; task-refusal-aims : a command's refusals by cause: wrong_state for a
;; trashed Task and a trashed node of another kind (before not_a_task),
;; not_a_task by each kind, 404 by cause, 412, and 412 where the state, the
;; kind or the status would refuse too
(define task-refusal-aims
  '(task-409-wrong-state-task task-409-wrong-state-other-kind
    task-409-not-a-task-project task-409-not-a-task-journal task-409-not-a-task-note task-409-not-a-task-contact
    task-404-missing task-404-purged task-404-other
    task-412 task-412-trashed task-412-not-a-task task-412-would-be-wrong-status))

;; task-pre-aims : no precondition, a bad one, and If-None-Match on each command
(define task-pre-aims
  '(no-precondition-done no-precondition-wontdo no-precondition-reopen
    bad-precondition-done bad-precondition-wontdo bad-precondition-reopen bad-create-on-task))

;; props-before-aims : props refused before the job (no write job), by the
;; kind named or by none taking them
(define props-before-aims
  '(props-400-before-project props-400-before-journal props-400-before-note props-400-before-task
    props-400-before-contact props-400-before-unnamed))

;; props-job-aims : a replace that named no kind, refused in the job by the stored kind
(define props-job-aims '(props-400-job-project props-400-job-journal props-400-job-note props-400-job-task props-400-job-contact))

;; props-413-aims : the 413, on a create, a replace naming the kind, one naming none
(define props-413-aims '(props-413-create props-413-replace-named props-413-replace-unnamed))

;; status-fixed-aims : a replace's claim of another status, another closed, a closed while TODO
(define status-fixed-aims '(status-fixed-status status-fixed-closed status-fixed-closed-while-todo))

;; props-create-aims, props-replace-aims : props stored by a create and a
;; replace of each kind; P11's replace with none, of each kind
(define props-create-aims (map (lambda (k) (aim-of "props-create-" k)) kinds))
(define props-replace-aims
  (append (map (lambda (k) (aim-of "props-replace-" k)) kinds) (map (lambda (k) (aim-of "replace-no-props-" k)) kinds)))

;; props-kept-aims : P11's replace with none of props not {}; a Task's
;; status and closed sent back; P10's restores of another status and closed
(define props-kept-aims
  '(replace-no-props-kept replace-task-claims-own restore-task-status-differs restore-task-closed-differs))

;; p14-aims : a Task made DONE or WONTDO, its closed given or the write's
;; time; and one made TODO with a closed, the 400 before the job
(define p14-aims
  '(create-task-DONE-closed-given create-task-DONE-closed-now create-task-WONTDO-closed-given create-task-WONTDO-closed-now
    create-task-todo-closed-400))

;; empty-task-aims : P9 and R8: commands and reads on a Task stored {},
;; and on a seeded one, written as a file from before this slice
(define empty-task-aims
  '(empty-task-done empty-task-wontdo empty-task-read-node empty-task-read-list empty-task-read-link-item
    empty-task-read-revisions empty-task-read-snapshot
    seeded-done seeded-wontdo seeded-reopen-wrong-status seeded-replace seeded-restore
    seeded-read-node seeded-read-list seeded-read-revisions seeded-read-snapshot))

;; entry-aims : R17's two orderings stored by a create; the cap's two
;; sides. (R17 by a replace is the corpus check's: every entry, by a
;; replace of a Contact.)
(define entry-aims
  '(entry-contact-order-a-201 entry-contact-order-b-201 entry-contact-at-cap-201 entry-contact-over-cap-413))

;; props-floors : (Listof (Pair (Listof Symbol) Natural))
;; Each group's floor is about half the fewest seen over nine runs of 300
;; (FIRST 1 to 5001 by thousands, 7001, 13001): a move the task table takes
;; on an active Task 33, on an archived one 7; a refused one on an active
;; Task 8, on an archived one 3; a command's refusal by cause 11; a bad
;; precondition 20; props refused before the job 100, in it 4; the 413 12
;; (over the six runs since any replace may send props over the cap);
;; status_fixed 7; props stored by a create 182, by a replace 4; kept 33;
;; P14's 4; on Tasks stored {} 25; R17 and the cap 3.
(define props-floors
  (list (cons (task-cells 'active task-moves-taken) 15) (cons (task-cells 'archived task-moves-taken) 3)
        (cons (task-cells 'active task-moves-refused) 4) (cons (task-cells 'archived task-moves-refused) 1)
        (cons task-refusal-aims 6) (cons task-pre-aims 10) (cons props-before-aims 45) (cons props-job-aims 2)
        (cons props-413-aims 6) (cons status-fixed-aims 3) (cons props-create-aims 90) (cons props-replace-aims 2)
        (cons props-kept-aims 15) (cons p14-aims 2) (cons empty-task-aims 12) (cons entry-aims 1)))
(define props-aims-all (apply append (map car props-floors)))

;;; Slice 7a's coverage: tags

;; tags-sent-aims : each kind of tags a create and a replace sent (the generator's aims)
(define tags-sent-aims
  '(tags-create-none tags-create-common tags-create-empty tags-create-any tags-create-folded-to-one
    tags-create-refused-entry tags-create-at-cap tags-create-over-cap tags-create-many-kinds
    tags-replace-none tags-replace-sent-back tags-replace-other-forms tags-replace-cleared tags-replace-new
    tags-replace-added tags-replace-refused-entry tags-replace-at-cap tags-replace-over-cap tags-replace-many-kinds))

;; tags-raw-values : each value that is no array of strings, a create's
;; and a replace's counted together (each alone is too rare to floor)
(define tags-raw-values '(null string object number-in-list null-in-list list-in-list true object-of-tags))
(define (raw-count v)
  (+ (hashtable-ref aims-hit (aim-of "tags-create-raw-" v) 0) (hashtable-ref aims-hit (aim-of "tags-replace-raw-" v) 0)))
(define tags-raw-aims
  (apply append (map (lambda (r) (map (lambda (k) (aim-of "tags-" r "-raw-" k)) tags-raw-values)) '(create replace))))

;; tags-put-aims : what came of a PUT's tags: refused before the job, by a
;; create and a replace (L10); stored none, some, fifty; several forms
;; stored as one; kept by a replace that sent none (L4), with props sent
;; too; cleared; replaced
(define tags-put-aims
  '(tags-400-create tags-400-replace tags-stored-none tags-stored-some tags-stored-fifty tags-folded-to-one
    tags-kept tags-kept-with-props tags-cleared tags-replaced))

;; tags-write-aims : tags met by the other writes: a restore that changed
;; them, cleared them, brought one back, after a step (L11); a Task's
;; command, a purge, a move and a change of state of a tagged node
(define tags-write-aims
  '(restore-tags-changed restore-tags-cleared restore-brings-back restore-after-a-step
    task-command-tagged purge-tagged move-tagged state-change-tagged))

;; rare-tags-aims : a PUT whose tags are refused with props over the cap
;; (the tags' 400 first); a restore of a snapshot from before migration 7
(define rare-tags-aims '(tags-400-with-props-413 restore-before-migration-7))

;; tag-filter-aims : the filter by count of tags (ten as sent, eleven the
;; 400), what it found, each refusal, with state, parent and after, pages
;; followed, spaces sent as +, and each raw query value
(define tag-filter-aims
  (append '(tag-filter-200-1 tag-filter-200-2 tag-filter-200-3 tag-filter-200-6 tag-filter-200-10 tag-filter-11
            tag-filter-found tag-filter-empty-page tag-filter-400 tag-filter-404-parent tag-filter-refused tag-filter-empty
            tag-filter-bare tag-filter-with-state tag-filter-with-parent tag-filter-with-after tag-filter-pages-followed
            tag-filter-plus-spaces)
          (map (lambda (c) (aim-of "tag-filter-" (cadr c))) (filter (lambda (c) (string? (caddr c))) query-raw-cases))))

;; list-tags-aims : the tags list from the start, after a tag, after a
;; refused one and after twice (each the 400), empty, its pages followed
;; or its first tag counted by the filter (L8)
(define list-tags-aims
  '(list-tags-from-the-start list-tags-after-a-tag list-tags-after-refused list-tags-after-twice
    list-tags-200 list-tags-400 list-tags-empty list-tags-pages-or-counted))

;; step-aims : each command on no carrier and on some; a merge; archived
;; and trashed carriers touched (L13); a tag only the other account has
;; (L6); each refusal by its cause, by each command
(define step-aims
  '(step-rename-none step-rename-some step-remove-none step-remove-some step-merge step-touched-archived
    step-touched-trashed step-theirs-only
    step-rename-400 step-remove-400 step-rename-415 step-remove-415 step-rename-413 step-remove-413
    step-rename-invalid-json step-remove-invalid-json))

;; crowd-aims : a crowd seed's (G8 over 500): a step that takes 500 and
;; leaves more, by each command; a count stopped at 1,000; each step of
;; the crowd's script
(define crowd-aims
  (append '(step-rename-cap step-remove-cap step-left-above-0 list-tags-count-capped)
          (map (lambda (k) (aim-of "crowd-" k)) (from-to 1 15))))

;; tag-floors : (Listof (Pair (Listof Symbol) Natural))
;; Each group's floor is about half the fewest seen over six runs of 300
;; (FIRST 1 to 5001 by thousands): a kind of tags sent 23 (a replace's
;; tags in other forms), a PUT's outcome 7 (a replace that cleared tags),
;; another write's 7 (a restore that cleared them), the rare ones 6, the
;; filter's 8 (pages followed), the tags list's 8 (after twice), a
;; command's 4 (no JSON), the crowd's 6 (one a crowd seed: six a run).
;; A raw value, a create's and a replace's together, 8.
(define raw-floor 4)
(define tag-floors
  (list (cons tags-sent-aims 11) (cons tags-put-aims 3) (cons tags-write-aims 3) (cons rare-tags-aims 3)
        (cons tag-filter-aims 4) (cons list-tags-aims 4) (cons step-aims 2) (cons crowd-aims 3)))
(define tag-aims-all (append tags-raw-aims (apply append (map car tag-floors))))

(define (at-least floor n) (if (>= n floor) (list 'at-least floor) (list 'only n)))

(define (cell-name c) (format "~a x ~a x ~a" (car c) (or (cadr c) "-") (caddr c)))

(unless replay-seed
  (test-equal "the run: every sequence agrees with the model's rules and the laws (the first three that do not)"
    '()
    (take* failures 3))

  (test-equal "the run: every one of the sequences ran and agreed" sequences (length agreed))

  (test-equal "the run: every sequence is at least 60 requests, a crowd's at least 29 (its script and 14 to 27)"
    '((at-least 60) (at-least 29))
    (list (at-least 60 shortest) (at-least 29 shortest-crowd)))

  (test-equal "the run: at least 20,000 requests" '(at-least 20000) (at-least 20000 steps))

  (test-equal "the run: one seed in fifteen is deep, one in five a family, one in five linked, one in fifty a crowd"
    (list (/ sequences 15) (/ sequences 5) (/ sequences 5) (/ sequences 50))
    (list (length (filter (lambda (v) (eq? (verdict-style v) 'deep)) agreed))
          (length (filter (lambda (v) (eq? (verdict-style v) 'family)) agreed))
          (length (filter (lambda (v) (eq? (verdict-style v) 'linked)) agreed))
          (length (filter crowd? agreed))))

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

  (for-each
   (lambda (group)
     (for-each
      (lambda (aim)
        (test-equal (format "coverage: ~a at least ~a times" aim (cdr group))
          (list 'at-least (cdr group))
          (at-least (cdr group) (hashtable-ref aims-hit aim 0))))
      (car group)))
   (append tree-floors link-floors props-floors tag-floors))

  (for-each
   (lambda (v)
     (test-equal (format "coverage: tags sent as the raw value ~a, by a create or a replace, at least ~a times" v raw-floor)
       (list 'at-least raw-floor)
       (at-least raw-floor (raw-count v))))
   tags-raw-values)

  (test-equal "coverage: the model steps no cell of link-command's but the reachable ones"
    '()
    (filter (lambda (a) (and (lc-aim? a) (not (memq a link-cells)))) (vector->list (hashtable-keys aims-hit))))

  (display (format "nodes-model: seeds ~a to ~a: ~a sequences (~a deep, ~a families, ~a linked), ~a requests made, ~a HTTP requests sent, the shortest ~a, in ~a ms\n"
                   first-seed (+ first-seed sequences -1) (length agreed)
                   (length (filter (lambda (v) (eq? (verdict-style v) 'deep)) agreed))
                   (length (filter (lambda (v) (eq? (verdict-style v) 'family)) agreed))
                   (length (filter (lambda (v) (eq? (verdict-style v) 'linked)) agreed))
                   steps requests shortest run-ms))
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
                                           (append lifecycle-events '(write) move-events))))))
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
  (display "  the tree's (slice 5a):\n")
  (for-each (lambda (group)
              (display (format "   at least ~a:\n" (cdr group)))
              (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0)))) (car group)))
            tree-floors)
  (display "  the links' (slice 5b):\n")
  (for-each (lambda (group)
              (display (format "   at least ~a:\n" (cdr group)))
              (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0)))) (car group)))
            link-floors)
  (display "  props and a Task's commands (slice 6):\n")
  (for-each (lambda (group)
              (display (format "   at least ~a:\n" (cdr group)))
              (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0)))) (car group)))
            props-floors)
  (display "  tags (slice 7a):\n")
  (display (format "   at least ~a, a create's and a replace's together:\n" raw-floor))
  (for-each (lambda (v) (display (format "    raw ~a: ~a\n" v (raw-count v)))) tags-raw-values)
  (for-each (lambda (group)
              (display (format "   at least ~a:\n" (cdr group)))
              (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0)))) (car group)))
            tag-floors)
  (display "  and with no floor:\n")
  (for-each (lambda (aim) (display (format "    ~a: ~a\n" aim (hashtable-ref aims-hit aim 0))))
            (list-sort (lambda (x y) (string<? (symbol->string x) (symbol->string y)))
                       (filter (lambda (aim) (not (or (memq aim aims) (memq aim some-aims) (memq aim rare-aims)
                                                      (memq aim tree-aims-all) (memq aim link-aims-all)
                                                      (memq aim props-aims-all) (memq aim tag-aims-all))))
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
    (let ((f (first-difference stale-wrong-state
                               (take* (map verdict-seed
                                           (filter (lambda (v) (exists (lambda (c) (member (car c) '((differ active purge) (differ archived purge))))
                                                                       (verdict-cells v)))
                                                   agreed))
                                      5))))
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

;; seeds-with : (Listof Symbol) -> (Listof Natural)
;; The first five seeds of the run that counted any of AIMS: where a tree
;; twist has something to bend, so its teeth need not search.
(define (seeds-with aims)
  (take* (map verdict-seed (filter (lambda (v) (exists (lambda (a) (assq a (verdict-aims v))) aims)) agreed))
         5))

;; bites? : Twist (Listof Symbol) (Listof String) -> Boolean
;; Whether TWIST, run on the seeds that reached AIMS, disagrees with the
;; handlers in a report holding each of TEXTS.
(define (bites? twist aims texts)
  (let* ((seeds (seeds-with aims))
         (f (and (pair? seeds) (first-difference twist seeds))))
    (and f (for-all (lambda (t) (contains? f t)) texts) #t)))

(unless replay-seed
  (test-equal "teeth: a rule that lets a Journal hold a Task disagrees with the handlers' 409"
    #t
    (bites? journal-holds-task '(pair-journal-task) '("the handlers answered 409")))

  (test-equal "teeth: a rule that moves a trashed node disagrees with the handlers' 409 wrong_state"
    #t
    (bites? trashed-movable '(move-trashed-would-pass)
            '("stepping match x trashed x move" "status: the model has 200, the handlers answered 409")))

  (test-equal "teeth: a rule that takes a node's grandchild as its new parent disagrees with the handlers' 409"
    #t
    (bites? grandchild-loop '(loop-grandchild-move loop-grandchild-move-children) '("the handlers answered 409")))

  (test-equal "teeth: a rule whose bulk move takes trashed children disagrees with the handlers' JSON"
    #t
    (bites? bulk-takes-trashed '(bulk-stay-state-fits) '("stepping match x" "x move-children" "the JSON: the model has")))

  (test-equal "teeth: a rule whose purge ignores children disagrees with the handlers' 409 has_children"
    #t
    (bites? purge-ignores-children '(has-children-active has-children-archived has-children-trashed)
            '("stepping match x trashed x purge" "status: the model has 204, the handlers answered 409")))

  (test-equal "teeth: a rule that lets a parent have 64 ancestors disagrees with the handlers' 409"
    #t
    (bites? depth-cap-65 '(depth-64-create depth-64-move depth-64-move-children) '("the handlers answered 409")))

  (test-equal "teeth: a rule that links to a trashed target disagrees with the handlers' 409"
    #t
    (bites? link-to-trashed '(lc-link-active-trashed-absent)
            '("link-command's active x trashed x link x absent" "status: the model has 201, the handlers answered 409")))

  (test-equal "teeth: a rule that refuses a kept link with a trashed end disagrees with the handlers' 200"
    #t
    (bites? kept-refused-when-trashed '(link-kept-source-trashed link-kept-target-trashed)
            '("x link x there" "status: the model has 409, the handlers answered 200")))

  (test-equal "teeth: a rule that resets closed on DONE to WONTDO disagrees with the handlers' JSON"
    #t
    (bites? wontdo-resets-closed '(task-cell-active-DONE-wontdo task-cell-archived-DONE-wontdo)
            '("the task table's" "x DONE x wontdo" "the JSON: the model has")))

  (test-equal "teeth: a rule that writes a replace's claim of another status or closed disagrees with the handlers' 409 status_fixed"
    #t
    (bites? status-claim-taken '(status-fixed-status status-fixed-closed status-fixed-closed-while-todo)
            '("status: the model has 200, the handlers answered 409"))))

(unless (raised? store) (close-test-store! store))

(display (format "nodes-model: ~a ms\n" (- (real-time) started)))

(test-end "nodes-model")

(exit (suite-exit-status runner))
