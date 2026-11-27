#!r6rs
;;; (nodes-model): the model-based test of nodes, ADR-0007's third layer,
;;; for tests/test-nodes-model.sps: D5's versioned write (slice 4, task 5a),
;;; the node lifecycle (slice 4b, task 4a) and the tree (slice 5a, task 4a).
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path.
;;;
;;; The model (pure)
;;; ----------------
;;; A world is two accounts, a and b (fixed), each with two keys and each
;;; key's last_used; every node made, with its owner, kind, created, state,
;;; revision, updated and its snapshots, newest first, each (revision title
;;; body content-type props created author); and each owner's change rows
;;; (seq node revision op created). A live node's title, content type,
;;; props and body are its newest snapshot's (H2'); its revision runs ahead
;;; of that snapshot by each change of state and each move since (L4, T4).
;;; A purged node has no snapshot, no parent, and its row is emptied (L7,
;;; P8). Each node has a parent, a node of its owner's, or none: the top
;;; level.
;;;
;;; `expect` answers a request from the world alone: never the database,
;;; and never (techo nodes), whose tables are what is under test. `decide`
;;; is the plan's rules written again here, in the plan's order (D4, D5, D7,
;;; D8, L1 to L10 and the review's answers): no precondition is 428, a bad
;;; one 400; a create is 412 on an id any account has used, a purged one's
;;; too; else the account's live node, or 404; stale is 412, whatever the
;;; state; then the state's refusal, 409 wrong_state; then kind_fixed and a
;;; missing snapshot's 404; else the change. The decision is performed on
;;; the world: insert, write and copy add a snapshot; a state change bumps
;;; the revision and adds none; a purge drops the snapshots and empties the
;;; row. Each adds a change row with the owner's next number, and sets the
;;; asking key's last_used when it is due (D6). A refusal changes nothing.
;;;
;;; The tree (slice 5a) is the brief's rules written again here too: what
;;; may hold what (may-contain?), the verdict on a new parent (judge), in
;;; its order (the top level; missing, another account's or purged; trashed;
;;; the node kept out is the parent or among its first 64 ancestors; the
;;; kind; more than 63 ancestors), and which children a bulk move takes. A
;;; create judges its parent after the 412 of an id in use; a move, after
;;; the 404, the 412 and a trashed node's wrong_state; a bulk move, after
;;; the 404 and the 412, from any live state. A purge of a node with a
;;; child, in any state, is 409 has_children. A move bumps the node with a
;;; change row move and no snapshot; a bulk move bumps each child it takes,
;;; in id order, and leaves the node. The model walks its own tree: it
;;; never asks (techo nodes) or the store's ancestors.
;;;
;;; A Twist stands between the decision and its performance. The run uses
;;; `as-planned`, which changes nothing; the suite's teeth pass a twisted
;;; rule, and the model must then disagree with the handlers. A Twist sees
;;; the cell, the decision and the Situation: what the model read of the
;;; tree (the verdict, the parent, where the node kept out sits above it,
;;; its depth, the node's children, and what the decision would be were the
;;; verdict ok).
;;;
;;; Each write names the cell it would step, in node-command's terms
;;; (Found State Event), by the model's own reading: what the job finds
;;; (none, match, differ), the state of the node it finds (#f when none,
;;; and for a create, whose job reads no state), and the event (D5's five,
;;; the lifecycle's five, move or move-children). The suite counts them,
;;; and what the tree's rules looked at (tree-aims).
;;;
;;; The run (the shell)
;;; -------------------
;;; `run-sequence` empties one migrated file, seeds the two accounts and
;;; their four keys through the store, generates a seeded sequence of 60 to
;;; 87 requests (xorshift32), and sends each as raw HTTP through make-app
;;; inside wrap-server, in a test host, with a wall clock the sequence
;;; steps. After every request it compares the status, the code of a
;;; refusal, the ETag, Location and the body of a 2xx (every page of a
;;; list, for the ?state= and ?parent= asked) with the model's; holds the
;;; answer to laws that need no model (G14, H6, H14, H18', and P12: every
;;; refusal of one code in a sequence has one body); reads the three tables
;;; and every key's last_used whole, and holds them to laws that need no
;;; model (H1 to H6, H11, H2', H3', H15', H16, G3, G6, G9, G11, G12, G16,
;;; P4, P15, P16, and the bulk move's, against the tables before the
;;; request; P1, P2, P3 and P8 on every row, by its own walk) and to the
;;; model's world. The first request with a difference ends the sequence
;;; with a report that replays from its seed.
;;;
;;; One seed in fifteen (a multiple of fifteen) is deep: it first makes a
;;; chain of 65 Projects by creates with a parent, one under the last, so
;;; the 65th is made under a parent with 63 ancestors and a 66th is refused
;;; under one with 64; then a short script of creates, moves and bulk
;;; moves reaches the boundary from both sides, a loop at the 64th ancestor
;;; and one above it; then 10 to 20 requests (a request in a deep world
;;; costs four of another's). One in five (ending in 3 or 7) is a family:
;;; it first makes a mixed tree (family-event), so that bulk moves meet
;;; children of every state and kind and loops close two and three levels
;;; down; then its 60 to 87. No sequence reaches a bulk move's cap of
;;; 1,000 children: the route suite holds it.
(library (nodes-model)
  (export model-accounts start-keys model-start kinds
          make-event make-content node-id-of
          as-planned lifecycle-events
          expect expectation-status expectation-code expectation-etag expectation-location
          expectation-json expectation-items expectation-world expectation-cells
          expectation-problem expectation-touched expectation-clause
          world-nodes world-changes-of world-key-last-used world-node
          mnode-id mnode-kind mnode-created mnode-state mnode-revision mnode-updated mnode-snaps mnode-parent
          expectation-situation situation-verdict situation-judged? situation-parent situation-kind
          situation-loop-at situation-depth situation-if-ok situation-children situation-by-kind
          msnap-revision msnap-title msnap-body msnap-type msnap-created
          mchange-seq mchange-node mchange-revision mchange-op mchange-created
          run-sequence verdict-seed verdict-steps verdict-requests verdict-cells
          verdict-aims verdict-report verdict-style deep-seed? family-seed?)
  (import (rnrs)
          (only (chezscheme) format)
          (only (chez-sqlite3) sql-null?)
          (only (chez-sodium) blake2b)
          (only (jsonparse easy) json->string)
          (techo-testing)
          (http-support)
          (only (techo keys) key-secret)
          (only (techo store) insert-account! insert-key!)
          (only (techo doorway) tx-query tx-execute!)
          (only (techo app) make-app wrap-server))

  ;;; Helpers

  (define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))

  (define (join strings sep)
    (if (null? strings)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car strings) (cdr strings))))

  (define (sym . parts)
    (string->symbol
     (apply string-append (map (lambda (p) (if (symbol? p) (symbol->string p) p)) parts))))

  ;; bytevector<? : Bytevector Bytevector -> Boolean   unsigned, byte by byte, as SQLite orders a BLOB
  (define (bytevector<? a b)
    (let ((n (min (bytevector-length a) (bytevector-length b))))
      (let loop ((i 0))
        (cond ((= i n) (< (bytevector-length a) (bytevector-length b)))
              ((< (bytevector-u8-ref a i) (bytevector-u8-ref b i)) #t)
              ((> (bytevector-u8-ref a i) (bytevector-u8-ref b i)) #f)
              (else (loop (+ i 1)))))))

  (define hex-digits "0123456789abcdef")

  ;; hex-of : Bytevector Natural Natural -> String    lower case, bytes FROM to TO
  ;; (number->string writes hex in capitals: the traps)
  (define (hex-of bv from to)
    (let loop ((i (- to 1)) (acc '()))
      (if (< i from)
          (list->string acc)
          (let ((b (bytevector-u8-ref bv i)))
            (loop (- i 1) (cons (string-ref hex-digits (div b 16))
                                (cons (string-ref hex-digits (mod b 16)) acc)))))))

  ;; id-text : Bytevector -> String     8-4-4-4-12, lower case
  (define (id-text bv)
    (string-append (hex-of bv 0 4) "-" (hex-of bv 4 6) "-" (hex-of bv 6 8) "-"
                   (hex-of bv 8 10) "-" (hex-of bv 10 16)))

  ;; secret-hash : String -> Bytevector    D3: BLAKE2b-256 of the secret's bytes,
  ;; from chez-sodium itself, not (techo auth)
  (define (secret-hash secret) (blake2b (string->utf8 secret) 32))

  (define day-ms 86400000)

  ;; touch-due? : (U Natural #f) Natural -> Boolean
  ;; D6 as written: a write sets last_used when it is null or more than a day old.
  (define (touch-due? last-used now)
    (or (not last-used) (> (- now last-used) day-ms)))

  (define (etag-of n) (string-append "\"" (number->string n) "\""))

  (define (sorted alist) (list-sort (lambda (x y) (string<? (car x) (car y))) alist))
  (define (sorted-json j)
    (if (and (list? j) (for-all (lambda (p) (and (pair? p) (string? (car p)))) j)) (sorted j) j))

  ;;; Randomness: xorshift32, seeded, as the key and login models have it.
  ;;; Every call to the generator is sequenced by a let* or let*-values:
  ;;; Chez's order of arguments is unspecified.

  (define mask32 #xFFFFFFFF)

  (define (xorshift32 x)
    (let* ((x (bitwise-and mask32 (bitwise-xor x (bitwise-arithmetic-shift-left x 13))))
           (x (bitwise-xor x (bitwise-arithmetic-shift-right x 17)))
           (x (bitwise-and mask32 (bitwise-xor x (bitwise-arithmetic-shift-left x 5)))))
      x))

  ;; Rng = (-> Natural), 32 bits a call
  (define (make-rng seed)
    (let ((x (let ((s (bitwise-and mask32 (+ (* (+ seed 1) 2654435761) 12345))))
               (if (= s 0) 1 s))))
      (for-each (lambda (i) (set! x (xorshift32 x))) (from-to 1 8))
      (lambda () (set! x (xorshift32 x)) x)))

  (define (rng-below! rng n) (mod (rng) n))
  (define (rng-pick! rng xs) (list-ref xs (rng-below! rng (length xs))))
  (define (rng-bytes! rng n)
    (let ((bv (make-bytevector n 0)))
      (for-each (lambda (i)
                  (bytevector-u8-set! bv i (bitwise-and 255 (bitwise-arithmetic-shift-right (rng) 11))))
                (from-to 0 (- n 1)))
      bv))
  ;; rng-weighted! : Rng (Listof (Pair Natural A)) -> A
  (define (rng-weighted! rng options)
    (let loop ((r (rng-below! rng (apply + (map car options)))) (os options))
      (if (< r (caar os)) (cdar os) (loop (- r (caar os)) (cdr os)))))

  ;;; The world

  ;; kinds : (Listof String)     the plan's five (D7), written here, not imported
  (define kinds '("project" "journal" "note" "task" "contact"))

  ;; MAccount: tag ('a or 'b), id, username, email, password hash, created
  ;; model-accounts : (Listof MAccount)     a (alice) and b (bob), as every sequence seeds them
  (define-record-type macct (fields tag id username email password-hash created))

  (define model-accounts
    (list (make-macct 'a (make-bytevector 16 #xA1) "alice" "alice@example.com"
                      "argon2id-hash-of-alice" 1000)
          (make-macct 'b (make-bytevector 16 #xB2) "bob" "bob@example.com"
                      "argon2id-hash-of-bob" 2000)))

  (define (account-of tag) (find (lambda (a) (eq? (macct-tag a) tag)) model-accounts))
  (define (account-id-of tag) (macct-id (account-of tag)))
  (define (other-tag tag) (if (eq? tag 'a) 'b 'a))
  (define (account-label id)
    (let ((a (find (lambda (a) (bytevector=? (macct-id a) id)) model-accounts)))
      (if a (symbol->string (macct-tag a)) "no account")))

  ;; MKey: id tag label secret created last-used
  (define-record-type mkey (fields id tag label secret created last-used))

  ;; start-keys : (Listof MKey)
  ;; a1 and a2 for a, b1 and b2 for b: key n's id is 16 bytes of n, its
  ;; secret key-secret of 32 bytes of n; none has been used.
  (define start-keys
    (map (lambda (spec)
           (let ((n (car spec)))
             (make-mkey (make-bytevector 16 n) (cadr spec) (caddr spec)
                        (key-secret (make-bytevector 32 n)) (+ 1100 n) #f)))
         '((1 a "a1") (2 a "a2") (3 b "b1") (4 b "b2"))))

  (define (key-ids-of tag)
    (map mkey-id (filter (lambda (k) (eq? (mkey-tag k) tag)) start-keys)))
  (define (key-label id)
    (let ((k (find (lambda (k) (bytevector=? (mkey-id k) id)) start-keys)))
      (if k (mkey-label k) "no key")))
  (define (key-secret-of id) (mkey-secret (find (lambda (k) (bytevector=? (mkey-id k) id)) start-keys)))

  ;; MSnap: revision title body type props created author (a tag)
  ;; msnap-revision, msnap-created : MSnap -> Natural
  ;; msnap-title, msnap-body, msnap-type : MSnap -> String
  (define-record-type msnap (fields revision title body type props created author))

  ;; MNode: id tag label kind created state revision updated snaps (newest first) parent
  ;; mnode-kind : MNode -> String
  ;; mnode-state : MNode -> Symbol      active, archived, trashed or purged
  ;; mnode-created, mnode-revision, mnode-updated : MNode -> Natural
  ;; mnode-snaps : MNode -> (Listof MSnap)
  ;; mnode-parent : MNode -> (U Bytevector #f)     the node it is under; #f at the top level
  (define-record-type mnode (fields id tag label kind created state revision updated snaps parent))

  ;; MChange: seq node revision op created
  ;; mchange-seq, mchange-revision, mchange-created : MChange -> Natural
  ;; mchange-node : MChange -> Bytevector
  ;; mchange-op : MChange -> String
  (define-record-type mchange (fields seq node revision op created))

  ;; World: nodes (in the order made), keys (as start-keys, each last_used
  ;; as now), changes (an alist of tag to that owner's rows, oldest first),
  ;; held (the id of every node that has had a child, for the generator and
  ;; the counts alone: no answer depends on it)
  ;; world-nodes : World -> (Listof MNode)
  (define-record-type world (fields nodes keys changes held))

  ;; model-start : World      no node, no change, no key used
  (define model-start (make-world '() start-keys '((a) (b)) '()))

  ;;; The plan's rules, in the model's own words (L1, L2, L5, L6, L8)

  ;; live-states : (Listof Symbol)    the states a client sees (L1)
  (define live-states '(active archived trashed))

  ;; writable-states : (Listof Symbol)    where a replace or a restore is allowed (L5)
  (define writable-states '(active archived))

  ;; lifecycle-moves : (Listof (List Symbol (Listof Symbol) Symbol))
  ;; Each state change, the states it is allowed from, and where it lands:
  ;; L2 (archive and unarchive; trash and untrash, which always lands on
  ;; active) and L8 (a purge only from trashed).
  (define lifecycle-moves
    '((archive (active) archived)
      (unarchive (archived) active)
      (trash (active archived) trashed)
      (untrash (trashed) active)
      (purge (trashed) purged)))

  ;; lifecycle-events : (Listof Symbol)    the five, each its own route (L3)
  (define lifecycle-events (map car lifecycle-moves))

  (define write-kinds (append '(put restore) lifecycle-events '(move move-children)))
  (define (write-kind? k) (and (memq k write-kinds) #t))
  (define (life-kind? k) (and (memq k lifecycle-events) #t))

  ;; What a purge leaves in the row (L7, the review): no title, no props,
  ;; and a content type that is not the client's.
  (define purged-type "application/octet-stream")

  (define (node-top n) (let ((ss (mnode-snaps n))) (and (pair? ss) (car ss))))
  (define (node-rev n) (mnode-revision n))
  (define (live? n) (not (eq? (mnode-state n) 'purged)))

  ;; world-node : World Bytevector -> (U MNode #f)     any account's, purged or not
  (define (world-node w id) (find (lambda (n) (bytevector=? (mnode-id n) id)) (world-nodes w)))
  ;; own-node : the account's node as its routes find it: a purged one is none (L7)
  (define (own-node w tag id)
    (let ((n (world-node w id))) (and n (eq? (mnode-tag n) tag) (live? n) n)))
  (define (nodes-of w tag) (filter (lambda (n) (and (eq? (mnode-tag n) tag) (live? n))) (world-nodes w)))
  (define (purged-of w tag)
    (filter (lambda (n) (and (eq? (mnode-tag n) tag) (not (live? n)))) (world-nodes w)))
  (define (live-nodes w) (filter live? (world-nodes w)))
  (define (by-id ns) (list-sort (lambda (x y) (bytevector<? (mnode-id x) (mnode-id y))) ns))
  (define (snap-of n k) (find (lambda (s) (= (msnap-revision s) k)) (mnode-snaps n)))

  ;; world-changes-of : World Tag -> (Listof MChange)     oldest first
  (define (world-changes-of w tag) (cdr (assq tag (world-changes w))))

  (define (key-of w id) (find (lambda (k) (bytevector=? (mkey-id k) id)) (world-keys w)))

  ;; world-key-last-used : World Bytevector -> (U Natural #f)
  (define (world-key-last-used w id) (mkey-last-used (key-of w id)))

  (define (next-label w) (string-append "n" (number->string (+ 1 (length (world-nodes w))))))

  (define (world-with-node w n)
    (make-world (if (world-node w (mnode-id n))
                    (map (lambda (x) (if (bytevector=? (mnode-id x) (mnode-id n)) n x)) (world-nodes w))
                    (append (world-nodes w) (list n)))
                (world-keys w) (world-changes w)
                (let ((p (mnode-parent n)))
                  (if (and p (not (member p (world-held w)))) (cons p (world-held w)) (world-held w)))))

  ;; world-with-change : World Tag Bytevector Natural String Natural -> World
  ;; The owner's next change row: one more than the rows it has (H4).
  (define (world-with-change w tag id rev op now)
    (let* ((old (world-changes-of w tag))
           (c (make-mchange (+ 1 (length old)) id rev op now)))
      (make-world (world-nodes w) (world-keys w)
                  (map (lambda (p) (if (eq? (car p) tag) (cons tag (append old (list c))) p))
                       (world-changes w))
                  (world-held w))))

  (define (world-touched w id now)
    (make-world (world-nodes w)
                (map (lambda (k)
                       (if (bytevector=? (mkey-id k) id)
                           (make-mkey (mkey-id k) (mkey-tag k) (mkey-label k) (mkey-secret k)
                                      (mkey-created k) now)
                           k))
                     (world-keys w))
                (world-changes w)
                (world-held w)))

  ;; with-snap : MNode String String String String Natural -> MNode
  ;; N at its next revision, the content given as its newest snapshot, made
  ;; NOW, by its owner; its state kept (G12).
  (define (with-snap n title body type props now)
    (let ((rev (+ 1 (node-rev n))))
      (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                  (mnode-state n) rev now
                  (cons (make-msnap rev title body type props now (mnode-tag n)) (mnode-snaps n))
                  (mnode-parent n))))

  ;; with-state : MNode Symbol Natural -> MNode
  ;; N at its next revision in STATE, NOW, with no new snapshot (L4), under
  ;; its parent still (P15).
  (define (with-state n state now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                state (+ 1 (node-rev n)) now (mnode-snaps n) (mnode-parent n)))

  ;; with-parent : MNode (U Bytevector #f) Natural -> MNode
  ;; N at its next revision under PARENT (#f: the top level), NOW, with no
  ;; new snapshot, its state and content kept (T4, P4).
  (define (with-parent n parent now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                (mnode-state n) (+ 1 (node-rev n)) now (mnode-snaps n) parent))

  ;; emptied : MNode Natural -> MNode
  ;; N purged (L7): its next revision, NOW, no snapshot left and no parent
  ;; (P8).
  (define (emptied n now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                'purged (+ 1 (node-rev n)) now '() #f))

  ;;; The tree's rules, in the model's own words (slice 5a: T2, T5, T7, T8)

  ;; may-contain? : String String -> Boolean
  ;; T2: a Project holds every kind, Projects too; a Journal holds Notes
  ;; only; a Note, a Task and a Contact hold nothing.
  (define (may-contain? parent-kind child-kind)
    (cond ((string=? parent-kind "project") #t)
          ((string=? parent-kind "journal") (string=? child-kind "note"))
          (else #f)))

  ;; container? : String -> Boolean     a kind that may hold some kind
  (define (container? kind) (exists (lambda (k) (may-contain? kind k)) kinds))

  ;; most-ancestors : Natural     T5: a new parent may have 63 ancestors, and no more
  (define most-ancestors 63)

  ;; movable-states : (Listof Symbol)
  ;; T8: a node is moved from these; a trashed one is not. A bulk move is
  ;; allowed from every live state, and takes the children in these.
  (define movable-states '(active archived))

  (define (id-hash bv) (bytevector-u32-ref bv 12 (endianness big)))
  (define (make-id-table) (make-hashtable id-hash bytevector=?))

  ;; parent-node : World MNode -> (U MNode #f)
  (define (parent-node w n) (let ((p (mnode-parent n))) (and p (world-node w p))))

  ;; ancestors-of : World MNode -> (Listof MNode)
  ;; N's ancestors, nearest first, every one: the model's own walk, not the
  ;; store's. A walk that comes round (a loop only a twist could make)
  ;; stops after as many steps as the world has nodes.
  (define (ancestors-of w n)
    (let loop ((x n) (k (length (world-nodes w))) (acc '()))
      (let ((p (and (> k 0) (parent-node w x))))
        (if p (loop p (- k 1) (cons p acc)) (reverse acc)))))

  ;; children-of : World Bytevector -> (Listof MNode)
  ;; The live nodes under ID, by id: any state but purged (a purged node
  ;; has no parent).
  (define (children-of w id)
    (by-id (filter (lambda (n) (and (live? n) (mnode-parent n) (bytevector=? (mnode-parent n) id)))
                   (world-nodes w))))

  ;; Verdict = (U 'ok 'missing 'trashed 'loop 'wrong-kind 'too-deep)
  ;; judge : World Tag (U Bytevector #f) Bytevector (U String #f)
  ;;         -> (values Verdict (U MNode #f) (U Natural #f) Natural)
  ;; The verdict on PARENT, the new parent (#f: the top level), of TAG's
  ;; request that keeps KEEP out (the node made or moved, or the node whose
  ;; children move), KIND going in (#f for a bulk move); the parent found;
  ;; where KEEP sits above it (0: it is the parent; k: its k-th ancestor;
  ;; #f: nowhere); and how many ancestors the parent has, all of them. The
  ;; first that applies: the top level is ok; no live node of TAG's (none,
  ;; the other account's, a purged one) is missing; a trashed one, trashed;
  ;; KEEP the parent or among its first 64 ancestors, a loop; a kind it may
  ;; not hold (for a bulk move, a kind that holds nothing), wrong-kind; more
  ;; than 63 ancestors, too deep; else ok. So KEEP above the 64th ancestor
  ;; is too deep, not a loop.
  (define (judge w tag parent keep kind)
    (let ((p (and parent (own-node w tag parent))))
      (cond
       ((not parent) (values 'ok #f #f 0))
       ((not p) (values 'missing #f #f 0))
       (else
        (let* ((above (ancestors-of w p))
               (depth (length above))
               (at (if (bytevector=? parent keep)
                       0
                       (let loop ((as above) (k 1))
                         (cond ((null? as) #f)
                               ((bytevector=? (mnode-id (car as)) keep) k)
                               (else (loop (cdr as) (+ k 1))))))))
          (values (cond ((eq? (mnode-state p) 'trashed) 'trashed)
                        ((and at (<= at (+ most-ancestors 1))) 'loop)
                        ((if kind (not (may-contain? (mnode-kind p) kind)) (not (container? (mnode-kind p))))
                         'wrong-kind)
                        ((> depth most-ancestors) 'too-deep)
                        (else 'ok))
                  p at depth))))))

  ;;; Requests

  ;; ParentRef: a parent as a request names it.
  ;;   'absent                    no parent member, or no ?parent=
  ;;   'null                      JSON null, or ?parent=null: the top level
  ;;   (List 'id Bytevector Boolean)  an id, in capitals when the boolean is #t
  ;;   (List 'bad String)         a ?parent= of another spelling, sent as it is
  ;;   'twice                     ?parent=null twice
  ;; ref-meaning : ParentRef -> (U 'any #f Bytevector 'invalid)
  ;; What the brief says each means: no parent ('any: a create's top level,
  ;; a list's every node); the top level; that id; or the 400.
  (define (ref-meaning r)
    (cond ((eq? r 'absent) 'any)
          ((eq? r 'null) #f)
          ((and (pair? r) (eq? (car r) 'id)) (cadr r))
          (else 'invalid)))

  ;; ref-text : ParentRef -> (U String 'null)     the JSON value, or the query's text
  (define (ref-text r)
    (cond ((eq? r 'null) 'null)
          ((and (pair? r) (eq? (car r) 'id)) (let ((t (id-text (cadr r)))) (if (caddr r) (string-upcase t) t)))
          ((and (pair? r) (eq? (car r) 'bad)) (cadr r))
          (else "null")))

  ;; Content: kind (U String #f), title, body, type, whether `"props": {}`
  ;; is sent, and a create's parent (a ParentRef, 'absent for none).
  ;; make-content : (U String #f) String String String Boolean ParentRef -> Content
  (define-record-type content (fields kind title body type props? parent))

  ;; Event: kind now tag key id pre headers content snap limit query upper? aims parent
  ;;   kind      put, restore, archive, unarchive, trash, untrash, purge,
  ;;             move, move-children, get-node, list-nodes, list-revisions,
  ;;             get-snapshot
  ;;   now       the wall clock for the request
  ;;   tag, key  the asking account and key's id
  ;;   id        the node's id (#f for list-nodes)
  ;;   pre       for a write, what the generator meant its headers to say:
  ;;             'create, a revision, 'missing or 'invalid
  ;;   headers   the If-Match and If-None-Match fields sent, in order
  ;;   content   a PUT's Content
  ;;   snap      the snapshot named by a restore or a snapshot read
  ;;   limit     a walk's page size, #f for the default
  ;;   query     a list's ?state=: #f for none, a String, or 'twice (the
  ;;             field twice, active both times)
  ;;   upper?    whether the path's id is written in capitals
  ;;   aims      what the generator aimed at, for counting
  ;;   parent    a move's and a bulk move's new parent, 'null or an id; a
  ;;             list's ?parent=; 'absent for every other request
  ;; make-event : Symbol Natural Tag Bytevector (U Bytevector #f) Any (Listof Header)
  ;;              (U Content #f) (U Natural #f) (U Natural #f) (U String 'twice #f)
  ;;              Boolean (Listof Symbol) ParentRef -> Event
  (define-record-type event (fields kind now tag key id pre headers content snap limit query upper? aims parent))

  ;; tree-kind? : Event -> Boolean     a request whose new parent is judged
  (define (tree-kind? e)
    (or (memq (event-kind e) '(move move-children))
        (and (eq? (event-kind e) 'put) (eq? (event-pre e) 'create))))

  ;; event-parent-id : Event -> (U Bytevector #f)
  ;; A create's, a move's or a bulk move's new parent; #f for the top level.
  (define (event-parent-id e)
    (let ((m (ref-meaning (if (eq? (event-kind e) 'put)
                              (content-parent (event-content e))
                              (event-parent e)))))
      (and (bytevector? m) m)))

  ;; node-id-of : Natural -> Bytevector
  ;; A v7 id for a hand-made world: N in its last bytes.
  (define (node-id-of n)
    (let ((bv (make-bytevector 16 0)))
      (bytevector-u8-set! bv 0 1)
      (bytevector-u8-set! bv 6 #x70)
      (bytevector-u8-set! bv 8 #x80)
      (bytevector-u8-set! bv 15 (mod n 256))
      (bytevector-u8-set! bv 14 (div n 256))
      bv))

  ;;; The oracle

  ;; Expectation: status code etag location json items world cells problem touched clause
  ;;              situation
  ;;   status, code   the answer, and a refusal's code
  ;;   etag, location the headers a 2xx carries, or #f
  ;;   json           a single 2xx's JSON, sorted, or 'empty for a 204;
  ;;                  items, a walk's items
  ;;   world          the world after
  ;;   cells          the (Found State Event) cell a write steps, or none
  ;;   problem        why the model cannot take this step, or #f
  ;;   touched        whether the asking key's last_used was set
  ;;   clause         the rule that gives the answer, in the plan's words
  ;; expectation-status : Expectation -> (U Natural #f)
  ;; expectation-code, expectation-etag, expectation-location, expectation-problem,
  ;;   expectation-clause : Expectation -> (U String #f)
  ;; expectation-json : Expectation -> (U Alist 'empty #f)
  ;; expectation-items : Expectation -> (U (Listof Alist) #f)
  ;; expectation-world : Expectation -> World
  ;; expectation-cells : Expectation -> (Listof Cell)
  ;; expectation-touched : Expectation -> Boolean
  ;; expectation-situation : Expectation -> Situation
  (define-record-type expectation
    (fields status code etag location json items world cells problem touched clause situation))

  ;; Situation: what the model read of the tree for a write
  ;;   verdict    judge's verdict on the new parent, #f for a write that has none
  ;;   judged?    whether the rules looked at it: a create of a free id; a
  ;;              move at the node's revision, not trashed; a bulk move at it
  ;;   parent     the new parent found, #f for the top level or none
  ;;   kind       the kind going in, #f for a bulk move
  ;;   loop-at    where the node kept out sits above the parent (judge's)
  ;;   depth      the parent's ancestors, all of them
  ;;   if-ok      the decision, were the verdict ok and the state allowed
  ;;   children   the node's children, by id, every live state
  ;;   by-kind    those the new parent may hold, every live state, by id
  ;; situation-verdict : Situation -> (U Verdict #f)
  ;; situation-judged? : Situation -> Boolean
  ;; situation-parent : Situation -> (U MNode #f)
  ;; situation-kind : Situation -> (U String #f)
  ;; situation-loop-at : Situation -> (U Natural #f)
  ;; situation-depth : Situation -> Natural
  ;; situation-if-ok : Situation -> (U Decision #f)
  ;; situation-children, situation-by-kind : Situation -> (Listof MNode)
  (define-record-type situation (fields verdict judged? parent kind loop-at depth if-ok children by-kind))

  (define no-situation (make-situation #f #f #f #f #f 0 #f '() '()))

  (define (refused w cells status code clause s)
    (make-expectation status code #f #f #f #f w cells #f #f clause s))
  (define (cannot w cells why) (make-expectation #f #f #f #f #f #f w cells why #f #f no-situation))
  (define (read-answer w json items etag clause)
    (make-expectation 200 #f etag #f json items w '() #f #f clause no-situation))

  ;; props-json : String -> Any     the stored text "{}" is the empty object
  (define (props-json text) (if (string=? text "{}") '() (list 'props text)))

  ;; node-json : MNode Boolean -> Alist
  ;; A live node as the plan shows it: its title, content type, props and
  ;; body its newest snapshot's (H2'), the body only when BODY?; its
  ;; revision, updated, state and parent its own: the parent's id in lower
  ;; case, or null at the top level.
  (define (node-json n body?)
    (let ((s (node-top n)))
      (sorted (append (list (cons "id" (id-text (mnode-id n))) (cons "kind" (mnode-kind n))
                            (cons "state" (symbol->string (mnode-state n)))
                            (cons "parent" (if (mnode-parent n) (id-text (mnode-parent n)) 'null))
                            (cons "title" (msnap-title s)))
                      (if body? (list (cons "body" (msnap-body s))) '())
                      (list (cons "content_type" (msnap-type s)) (cons "props" (props-json (msnap-props s)))
                            (cons "revision" (node-rev n)) (cons "created" (mnode-created n))
                            (cons "updated" (mnode-updated n)))))))

  ;; snap-json : MSnap Boolean -> Alist
  (define (snap-json s body?)
    (sorted (append (list (cons "revision" (msnap-revision s)) (cons "title" (msnap-title s)))
                    (if body? (list (cons "body" (msnap-body s))) '())
                    (list (cons "content_type" (msnap-type s)) (cons "props" (props-json (msnap-props s)))
                          (cons "created" (msnap-created s))))))

  ;; Cell = (List Found (U Symbol #f) Symbol)
  ;; Decision = (List 'refuse Natural String) | (List 'insert) | (List 'write)
  ;;          | (List 'copy) | (List 'set-state Symbol) | (List 'purge)
  ;;          | (List 'move) | (List 'move-children (Listof Bytevector))
  ;; Twist = (U Cell #f) Decision Situation -> Decision

  ;; as-planned : Twist     the decision as the rules make it, unchanged
  (define (as-planned cell decision situation) decision)

  (define (refusal status code) (list 'refuse status code))
  (define not-found (refusal 404 "not_found"))
  (define stale (refusal 412 "precondition_failed"))
  (define wrong-state (refusal 409 "wrong_state"))
  (define invalid-parent (refusal 409 "invalid_parent"))
  (define would-loop (refusal 409 "would_loop"))
  (define has-children (refusal 409 "has_children"))

  (define (cell-text cell)
    (if cell
        (format "~a x ~a x ~a" (car cell) (or (cadr cell) "-") (caddr cell))
        "no cell"))

  ;; write-event-of : Event (U MNode #f) -> Symbol
  ;; The event a write names, as the plan words it: a PUT's create; a
  ;; replace that names a kind its node has not, replace-other-kind; a
  ;; replace; a restore of a snapshot its node has, restore, else
  ;; restore-unknown (a gap, a revision past the node's, no node); or the
  ;; state change, the move or the bulk move itself.
  (define (write-event-of e own)
    (case (event-kind e)
      ((put)
       (let ((kind (content-kind (event-content e))))
         (cond ((eq? (event-pre e) 'create) 'create)
               ((and kind own (not (string=? kind (mnode-kind own)))) 'replace-other-kind)
               (else 'replace))))
      ((restore) (if (and own (snap-of own (event-snap e))) 'restore 'restore-unknown))
      (else (event-kind e))))

  ;; situation-of : World Event (U MNode #f) Boolean -> Situation
  ;; What the model reads of the tree for E: for a create, a move or a bulk
  ;; move, judge's verdict on its new parent (the id E names kept out; the
  ;; content's kind going in for a create, the node's for a move, none for
  ;; a bulk move), JUDGED? saying whether the rules look at it; and the
  ;; children of OWN, the account's node E names (#f for none). A move or a
  ;; bulk move of no node of the account's judges nothing.
  (define (situation-of w e own judged?)
    (let* ((kind (event-kind e))
           (children (if (and own (not (eq? kind 'put))) (children-of w (mnode-id own)) '())))
      (if (not (and (tree-kind? e) (or own (eq? kind 'put))))
          (make-situation #f #f #f #f #f 0 #f children '())
          (let ((going (case kind
                         ((move) (mnode-kind own))
                         ((move-children) #f)
                         (else (content-kind (event-content e))))))
            (let-values (((verdict p at depth) (judge w (event-tag e) (event-parent-id e) (event-id e) going)))
              (let* ((by-kind (filter (lambda (c) (or (not p) (may-contain? (mnode-kind p) (mnode-kind c))))
                                      children))
                     (movable (filter (lambda (c) (memq (mnode-state c) movable-states)) by-kind))
                     (if-ok (case kind
                              ((move) '(move))
                              ((move-children) (list 'move-children (map mnode-id movable)))
                              (else '(insert)))))
                (make-situation verdict judged? p going at depth if-ok children by-kind)))))))

  ;; verdict-decision : Verdict Decision -> (values Decision String)
  ;; What a verdict the rules look at answers (T10): IF-OK for ok, 409
  ;; would_loop for a loop, 409 invalid_parent for every other.
  (define (verdict-decision verdict if-ok)
    (case verdict
      ((ok) (values if-ok (string-append "the new parent passes: the top level, or the account's live node,"
                                         " not trashed, not the node nor under it, that may hold it,"
                                         " with at most 63 ancestors")))
      ((missing) (values invalid-parent (string-append "a new parent that is no live node of the account's,"
                                                       " another account's or a purged one, is 409 invalid_parent,"
                                                       " as a missing one (P12)")))
      ((trashed) (values invalid-parent "a trashed new parent is 409 invalid_parent (T8)"))
      ((loop) (values would-loop (string-append "a new parent that is the node kept out, or has it among its"
                                                " first 64 ancestors, is 409 would_loop (T5)")))
      ((wrong-kind) (values invalid-parent (string-append "a new parent that may not hold the kind (for a bulk move,"
                                                          " that holds no kind) is 409 invalid_parent (T2)")))
      (else (values invalid-parent "a new parent with more than 63 ancestors is 409 invalid_parent (T5)"))))

  ;; decide : World Event -> (values (U Cell #f) Decision String Situation)
  ;; A write's answer by the plan's rules, the first that applies, the
  ;; clause that gives it, and what the model read of the tree.
  (define (decide w e)
    (let* ((pre (event-pre e)) (id (event-id e)) (own (own-node w (event-tag e) id)))
      (cond
       ((eq? pre 'missing)
        (values #f (refusal 428 "precondition_required") "a write with no precondition is 428, before its job"
                no-situation))
       ((eq? pre 'invalid)
        (values #f (refusal 400 "invalid_request")
                "a precondition of any other shape, If-None-Match on any route but a PUT among them, is 400"
                no-situation))
       ((eq? pre 'create)
        (if (world-node w id)
            (values (list 'differ #f 'create) stale
                    "a create on an id in use, any account's, a purged one's too, is 412, before its parent is judged"
                    (situation-of w e #f #f))
            (let ((s (situation-of w e #f #t)))
              (let-values (((decision clause) (verdict-decision (situation-verdict s) '(insert))))
                (values (list 'none #f 'create) decision
                        (if (eq? (car decision) 'insert)
                            (string-append "a create of an id no account has used makes it, active, at 1: " clause)
                            clause)
                        s)))))
       (else
        (let* ((ev (write-event-of e own))
               (state (and own (mnode-state own)))
               (found (cond ((not own) 'none) ((= (node-rev own) pre) 'match) (else 'differ)))
               (cell (list found state ev))
               (move (assq ev lifecycle-moves))
               (judged? (and (eq? found 'match)
                             (or (eq? ev 'move-children) (and (eq? ev 'move) (memq state movable-states) #t))))
               (s (if own (situation-of w e own judged?) no-situation)))
          (cond
           ((not own) (values cell not-found "a node the account has not got, another's or a purged one, is 404" s))
           ((eq? found 'differ) (values cell stale "a request at a revision the node is not at is 412, whatever its state" s))
           ((memq ev '(move move-children))
            (if judged?
                (let-values (((decision clause) (verdict-decision (situation-verdict s) (situation-if-ok s))))
                  (values cell decision clause s))
                (values cell wrong-state "a move of a trashed node is 409 wrong_state, before its new parent (T8)" s)))
           (move
            (cond ((not (memq state (cadr move)))
                   (values cell wrong-state (format "~a from ~a is 409 wrong_state" ev state) s))
                  ((eq? ev 'purge)
                   (if (pair? (situation-children s))
                       (values cell has-children "a purge of a trashed node with a child, in any state, is 409 has_children (T7)" s)
                       (values cell '(purge) "a purge of a trashed node at its revision, with no child, empties it: 204" s)))
                  (else
                   (values cell (list 'set-state (caddr move))
                           (format "~a moves ~a to ~a at the next revision, with no snapshot, under its parent still"
                                   ev state (caddr move))
                           s))))
           ((not (memq state writable-states))
            (values cell wrong-state
                    "a replace or a restore of a trashed node is 409 wrong_state, before the kind and the snapshot" s))
           ((eq? ev 'replace-other-kind)
            (values cell (refusal 409 "kind_fixed") "a replace that names another kind is 409 kind_fixed" s))
           ((eq? ev 'restore-unknown)
            (values cell not-found "a restore of a revision with no snapshot is 404" s))
           ((eq? ev 'replace)
            (values cell '(write) "a replace at the node's revision is its next, in the same state and parent" s))
           (else
            (values cell '(copy) "a restore of a snapshot the node has, at its revision, is its next, in the same state and parent" s))))))))

  ;; expect : Twist World Event -> Expectation
  ;; TWIST is as-planned, or a changed rule for the suite's teeth.
  (define (expect twist w e)
    (if (write-kind? (event-kind e))
        (let-values (((cell decision clause s) (decide w e)))
          (perform w e cell (twist cell decision s) clause s))
        (expect-read w e)))

  ;; perform : World Event (U Cell #f) Decision String Situation -> Expectation
  ;; The decision done to the world. One that makes no sense for the
  ;; request (a copy on a PUT, a change at a revision the node is not at,
  ;; an insert on an id in use, a bulk move of a node that is no child) is
  ;; a step the model cannot take.
  (define (perform w e cell decision clause s)
    (let* ((tag (event-tag e)) (id (event-id e)) (now (event-now e)) (pre (event-pre e))
           (kind (event-kind e))
           (own (own-node w tag id))
           (cells (if cell (list cell) '()))
           (at (format "~a names ~s" (cell-text cell) decision))
           (at-pre? (and own (integer? pre) (= (node-rev own) pre)))
           (off-pre (string-append at ", but the account's node is not at the revision given")))
      (case (car decision)
        ((refuse) (refused w cells (cadr decision) (caddr decision) clause s))
        ((insert)
         (cond ((not (and (eq? kind 'put) (eq? pre 'create)))
                (cannot w cells (string-append at ", which only a create performs")))
               ((world-node w id) (cannot w cells (string-append at " on an id in use")))
               (else
                (let ((c (event-content e)))
                  (accepted w e (make-mnode id tag (next-label w) (content-kind c) now 'active 1 now
                                            (list (make-msnap 1 (content-title c) (content-body c)
                                                              (content-type c) "{}" now tag))
                                            (event-parent-id e))
                            "create" 201 #t cells clause s)))))
        ((write)
         (cond ((not (eq? kind 'put)) (cannot w cells (string-append at ", which only a PUT performs")))
               ((not at-pre?) (cannot w cells off-pre))
               (else
                (let ((c (event-content e)))
                  (accepted w e (with-snap own (content-title c) (content-body c) (content-type c) "{}" now)
                            "update" 200 #t cells clause s)))))
        ((copy)
         (let ((snap (and own (eq? kind 'restore) (snap-of own (event-snap e)))))
           (cond ((not (eq? kind 'restore)) (cannot w cells (string-append at ", which only a restore performs")))
                 ((not at-pre?) (cannot w cells off-pre))
                 ((not snap) (cannot w cells (string-append at " of a snapshot the node does not have")))
                 (else
                  (accepted w e (with-snap own (msnap-title snap) (msnap-body snap) (msnap-type snap)
                                           (msnap-props snap) now)
                            "restore" 200 #t cells clause s)))))
        ((set-state)
         (cond ((not (and (life-kind? kind) (not (eq? kind 'purge))))
                (cannot w cells (string-append at ", which only a state change performs")))
               ((not at-pre?) (cannot w cells off-pre))
               ((not (memq (cadr decision) live-states))
                (cannot w cells (string-append at ", a state no client sees")))
               (else
                (accepted w e (with-state own (cadr decision) now) (symbol->string kind) 200 #f cells clause s))))
        ((purge)
         (cond ((not (eq? kind 'purge)) (cannot w cells (string-append at ", which only a DELETE performs")))
               ((not at-pre?) (cannot w cells off-pre))
               (else (accepted w e (emptied own now) "purge" 204 #f cells clause s))))
        ((move)
         (cond ((not (eq? kind 'move)) (cannot w cells (string-append at ", which only a move performs")))
               ((not at-pre?) (cannot w cells off-pre))
               (else (accepted w e (with-parent own (event-parent-id e) now) "move" 200 #f cells clause s))))
        ((move-children)
         (cond ((not (eq? kind 'move-children))
                (cannot w cells (string-append at ", which only a bulk move performs")))
               ((not at-pre?) (cannot w cells off-pre))
               ((not (for-all (lambda (c) (let ((n (own-node w tag c)))
                                            (and n (mnode-parent n) (bytevector=? (mnode-parent n) id))))
                              (cadr decision)))
                (cannot w cells (string-append at ", which names a node that is no child of the node")))
               (else (bulk-accepted w e own (cadr decision) cells clause s))))
        (else (cannot w cells (string-append at ", which no write performs"))))))

  ;; accepted : World Event MNode String Natural Boolean Cells String Situation -> Expectation
  ;; N stored, the owner's next change row with OP at N's revision, the
  ;; asking key's last_used set when due. A 201 or a 200 answers N's JSON,
  ;; with its body when BODY?, and its ETag, and Location for a 201; a 204
  ;; answers neither body nor ETag.
  (define (accepted w e n op status body? cells clause s)
    (let* ((w1 (world-with-node w n))
           (w2 (world-with-change w1 (mnode-tag n) (mnode-id n) (node-rev n) op (event-now e)))
           (due (touch-due? (world-key-last-used w (event-key e)) (event-now e)))
           (w3 (if due (world-touched w2 (event-key e) (event-now e)) w2)))
      (if (= status 204)
          (make-expectation 204 #f #f #f 'empty #f w3 cells #f due clause s)
          (make-expectation status #f (etag-of (node-rev n))
                            (and (= status 201) (string-append "/v1/nodes/" (id-text (mnode-id n))))
                            (node-json n body?) #f w3 cells #f due clause s))))

  ;; bulk-accepted : World Event MNode (Listof Bytevector) Cells String Situation -> Expectation
  ;; The children IDS of N, in id order, each under the bulk move's new
  ;; parent at its next revision with the owner's next change row `move`;
  ;; N itself as it was (P16); the asking key's last_used set when due. A
  ;; 200 of {"moved": how many, "left": the children N has after}, every
  ;; live state counted, and no ETag (H14).
  (define (bulk-accepted w e n ids cells clause s)
    (let* ((now (event-now e))
           (tag (mnode-tag n))
           (parent (event-parent-id e))
           (w1 (fold-left (lambda (w c)
                            (let ((moved (with-parent c parent now)))
                              (world-with-change (world-with-node w moved) tag (mnode-id moved) (node-rev moved)
                                                 "move" now)))
                          w (by-id (map (lambda (id) (world-node w id)) ids))))
           (due (touch-due? (world-key-last-used w (event-key e)) now))
           (w2 (if due (world-touched w1 (event-key e) now) w1)))
      (make-expectation 200 #f #f #f
                        (sorted (list (cons "moved" (length ids))
                                      (cons "left" (length (children-of w2 (mnode-id n))))))
                        #f w2 cells #f due clause s)))

  ;; list-state : (U String 'twice #f) -> (U Symbol 'invalid)
  ;; L6 and the review: no ?state= is active; a live state's name is that
  ;; state; anything else, purged among them, or the field twice, is 400.
  (define (list-state q)
    (cond ((not q) 'active)
          ((and (string? q) (find (lambda (s) (string=? (symbol->string s) q)) live-states)))
          (else 'invalid)))

  ;; under? : MNode (U 'any #f Bytevector) -> Boolean     a list's ?parent= filter (T9)
  (define (under? n p)
    (cond ((eq? p 'any) #t)
          ((not p) (not (mnode-parent n)))
          (else (and (mnode-parent n) (bytevector=? (mnode-parent n) p) #t))))

  (define (expect-read w e)
    (let ((own (and (event-id e) (own-node w (event-tag e) (event-id e))))
          (gone "a node the account has not got, another's or a purged one, is 404"))
      (case (event-kind e)
        ((get-node)
         (if own
             (read-answer w (node-json own #t) #f (etag-of (node-rev own))
                          "the account's own node is shown, with its newest snapshot's body")
             (refused w '() 404 "not_found" gone no-situation)))
        ((list-nodes)
         (let ((s (list-state (event-query e)))
               (p (ref-meaning (event-parent e))))
           (cond
            ((or (eq? s 'invalid) (eq? p 'invalid))
             (refused w '() 400 "invalid_request"
                      (string-append "a ?state= that names no live state, or a ?parent= that is neither null"
                                     " nor one v7 id, is 400")
                      no-situation))
            ((and (bytevector? p) (not (own-node w (event-tag e) p)))
             (refused w '() 404 "not_found"
                      "a ?parent= that is no live node of the account's, another's or a purged one, is 404"
                      no-situation))
            (else
             (read-answer w #f
                          (map (lambda (n) (node-json n #f))
                               (by-id (filter (lambda (n) (and (eq? (mnode-state n) s) (under? n p)))
                                              (nodes-of w (event-tag e)))))
                          #f (format "a list is the account's own ~a nodes~a, by id, with no bodies" s
                                     (cond ((eq? p 'any) "") ((not p) " at the top level") (else " under the parent"))))))))
        ((list-revisions)
         (if own
             (read-answer w #f (map (lambda (s) (snap-json s #f)) (mnode-snaps own)) #f
                          "a node's snapshots, newest first, gaps where its state changed")
             (refused w '() 404 "not_found" gone no-situation)))
        ((get-snapshot)
         (let ((s (and own (snap-of own (event-snap e)))))
           (if s
               (read-answer w (snap-json s #t) #f #f "a snapshot of the account's own node is shown")
               (refused w '() 404 "not_found"
                        "a snapshot no live node of the account's has, a gap's among them, is 404" no-situation))))
        (else (cannot w '() (format "no such request: ~a" (event-kind e)))))))

  ;;; Labels, for reports

  (define (node-label w id)
    (let ((n (world-node w id)))
      (if n
          (format "~a's ~a (~a, ~a, at ~a, ~a)" (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-state n)
                  (node-rev n)
                  (let ((p (parent-node w n)))
                    (if p (format "under ~a, ~a deep" (mnode-label p) (length (ancestors-of w n))) "at the top")))
          (format "a fresh id ~a" (substring (id-text id) 24 36)))))

  ;; ref-label : World ParentRef -> String
  (define (ref-label w r)
    (cond ((eq? r 'absent) "no parent")
          ((eq? r 'null) "the top level")
          ((eq? r 'twice) "null twice")
          ((eq? (car r) 'id) (string-append (node-label w (cadr r)) (if (caddr r) ", in capitals" "")))
          (else (format "~s" (cadr r)))))

  (define (show w v)
    (cond ((and (bytevector? v) (= (bytevector-length v) 16))
           (let ((n (world-node w v)))
             (cond (n (mnode-label n))
                   ((find (lambda (a) (bytevector=? (macct-id a) v)) model-accounts)
                    => (lambda (a) (symbol->string (macct-tag a))))
                   ((find (lambda (k) (bytevector=? (mkey-id k) v)) start-keys) => mkey-label)
                   (else (id-text v)))))
          (else (format "~s" v))))

  (define (row-text w r) (string-append "(" (join (map (lambda (v) (show w v)) r) " ") ")"))

  (define (content-text w c)
    (if c
        (format " ~a~s ~s ~s~a~a" (if (content-kind c) (string-append (content-kind c) " ") "")
                (content-title c) (content-body c) (content-type c) (if (content-props? c) " {}" "")
                (if (eq? (content-parent c) 'absent) "" (string-append ", parent " (ref-label w (content-parent c)))))
        ""))

  (define (headers-text hs)
    (if (null? hs) "(no precondition)" (join (map (lambda (h) (format "~a: ~a" (car h) (cdr h))) hs) ", ")))

  (define (describe-event w e t0)
    (let ((at (format "t+~a ~a" (- (event-now e) t0) (key-label (event-key e))))
          (target (if (event-id e) (node-label w (event-id e)) "")))
      (case (event-kind e)
        ((put) (format "~a PUT ~a ~a~a" at target (headers-text (event-headers e)) (content-text w (event-content e))))
        ((restore) (format "~a restore ~a snapshot ~a, ~a" at target (event-snap e) (headers-text (event-headers e))))
        ((archive unarchive trash untrash)
         (format "~a POST ~a /~a, ~a" at target (event-kind e) (headers-text (event-headers e))))
        ((purge) (format "~a DELETE ~a, ~a" at target (headers-text (event-headers e))))
        ((get-node) (format "~a GET ~a" at target))
        ((move move-children)
         (format "~a POST ~a /~a to ~a, ~a" at target (event-kind e) (ref-label w (event-parent e))
                 (headers-text (event-headers e))))
        ((list-nodes) (format "~a GET /v1/nodes state=~a parent=~a limit=~a" at (event-query e)
                              (ref-label w (event-parent e)) (event-limit e)))
        ((list-revisions) (format "~a GET revisions of ~a limit=~a" at target (event-limit e)))
        ((get-snapshot) (format "~a GET ~a snapshot ~a" at target (event-snap e)))
        (else (format "~a ~a" at (event-kind e))))))

  ;;; The generator

  (define title-pool
    '("" "Groceries" "T\xe2;ches \xe0; faire" "\x4f1a;\x8b70;\x30e1;\x30e2;" "Plan \"B\"" "\x2211; of notes"))

  (define body-pool
    '("" "milk, eggs, bread" "caf\xe9; cr\xe8;me \x2014; na\xef;ve"
      "\x65e5;\x672c;\x8a9e;\x306e;\x672c;\x6587;\x3067;\x3059;" "\x1d11e; and \x1f389;"
      "one\ntwo\tthree \"quoted\" back\\slash" "* TODO heading\n:PROPERTIES:\n:END:\n"))

  (define type-pool
    '("text/plain" "text/markdown" "text/org; charset=utf-8" "application/x-techo" "text/x-org"))

  ;; fresh-node-id : Rng World -> Bytevector     a v7 id, RFC variant, no node's, purged or not
  (define (fresh-node-id rng w)
    (let ((bv (rng-bytes! rng 16)))
      (bytevector-u8-set! bv 6 (bitwise-ior #x70 (bitwise-and (bytevector-u8-ref bv 6) #x0f)))
      (bytevector-u8-set! bv 8 (bitwise-ior #x80 (bitwise-and (bytevector-u8-ref bv 8) #x3f)))
      (if (world-node w bv) (fresh-node-id rng w) bv)))

  ;; v4-text : Rng World -> String     a fresh id's text with version 4: no id to the API
  (define (v4-text rng w)
    (let ((bv (bytevector-copy (fresh-node-id rng w))))
      (bytevector-u8-set! bv 6 (bitwise-ior #x40 (bitwise-and (bytevector-u8-ref bv 6) #x0f)))
      (id-text bv)))

  ;; next-time : Rng Natural (U Natural #f) -> (values Natural Symbol)
  ;; Mostly a few ms on; sometimes a day exactly (not yet due), a day and a
  ;; ms (due), or two days and more; and sometimes to D6's edge for the
  ;; asking key, LAST-USED: exactly a day after it (not due), or a day and
  ;; a ms (due), when that is still ahead.
  (define (next-time rng now last-used)
    (let* ((r (rng-below! rng 100))
           (small (+ 1 (rng-below! rng 1000)))
           (long (rng-below! rng day-ms))
           (edge (and last-used (> (+ last-used day-ms) now) (+ last-used day-ms))))
      (cond ((and edge (< r 7)) (values edge 'wait-to-a-day-after-use))
            ((and edge (< r 14)) (values (+ edge 1) 'wait-past-a-day-after-use))
            ((< r 82) (values (+ now small) 'wait-ms))
            ((< r 88) (values (+ now day-ms) 'wait-a-day))
            ((< r 94) (values (+ now day-ms 1) 'wait-a-day-and-a-ms))
            (else (values (+ now (* 2 day-ms) long) 'wait-days)))))

  ;; random-content : Rng (U String #f) ParentRef -> Content
  (define (random-content rng kind parent)
    (let* ((title (rng-pick! rng title-pool))
           (body (rng-pick! rng body-pool))
           (type (rng-pick! rng type-pool))
           (props? (= 0 (rng-below! rng 2))))
      (make-content kind title body type props? parent)))

  ;; Forest: the world's tree as the generator walks it, built once a request.
  ;;   depth   Bytevector -> Natural          how many ancestors
  ;;   kids    Bytevector -> (Listof MNode)   the live children, by id
  ;;   below   Bytevector -> (Listof (Pair MNode Natural))
  ;;                                          every node under it and how far, nearest first
  (define-record-type forest (fields depth kids below))

  ;; forest-of : World -> Forest     each walk bounded by the world's size
  (define (forest-of w)
    (let ((by (make-id-table)) (memo (make-id-table)) (kids (make-id-table)) (limit (length (world-nodes w))))
      (for-each (lambda (n) (hashtable-set! by (mnode-id n) n)) (world-nodes w))
      (for-each (lambda (n)
                  (when (and (live? n) (mnode-parent n))
                    (hashtable-update! kids (mnode-parent n) (lambda (l) (cons n l)) '())))
                (world-nodes w))
      (letrec ((depth (lambda (id k)
                        (or (hashtable-ref memo id #f)
                            (let* ((n (hashtable-ref by id #f))
                                   (p (and n (mnode-parent n)))
                                   (d (if (and p (< k limit)) (+ 1 (depth p (+ k 1))) 0)))
                              (hashtable-set! memo id d)
                              d))))
               (kids-of (lambda (id) (by-id (hashtable-ref kids id '())))))
        (make-forest (lambda (id) (depth id 0))
                     kids-of
                     (lambda (id)
                       (let loop ((frontier (list id)) (d 1) (acc '()) (k limit))
                         (if (or (null? frontier) (= k 0))
                             (reverse acc)
                             (let ((next (apply append (map kids-of frontier))))
                               (loop (map mnode-id next) (+ d 1)
                                     (fold-left (lambda (acc n) (cons (cons n d) acc)) acc next)
                                     (- k 1))))))))))

  (define (depth-in f n) ((forest-depth f) (mnode-id n)))
  (define (kids-in f n) ((forest-kids f) (mnode-id n)))
  (define (below-in f n) ((forest-below f) (mnode-id n)))

  (define (in-state s ns) (filter (lambda (n) (eq? (mnode-state n) s)) ns))
  (define (open-nodes ns) (filter (lambda (n) (not (eq? (mnode-state n) 'trashed))) ns))
  (define (holders ns) (filter (lambda (n) (container? (mnode-kind n))) ns))
  (define (leaves ns) (filter (lambda (n) (not (container? (mnode-kind n)))) ns))
  (define (of-kind k ns) (filter (lambda (n) (string=? (mnode-kind n) k)) ns))
  (define (same-node? a b) (bytevector=? (mnode-id a) (mnode-id b)))

  ;; ref-of : Rng MNode -> ParentRef     N's id, one time in six in capitals
  (define (ref-of rng n) (list 'id (mnode-id n) (= 0 (rng-below! rng 6))))

  ;; pick-ref : Rng (Listof MNode) -> ParentRef
  (define (pick-ref rng ns) (let ((n (rng-pick! rng ns))) (ref-of rng n)))

  ;; kind-first-ref : Rng (Listof MNode) -> ParentRef
  ;; One of NS, its kind chosen first among the kinds they have: so a Task
  ;; and a Contact are parents as often as a Note, of which there are more.
  (define (kind-first-ref rng ns)
    (let* ((present (filter (lambda (k) (exists (lambda (n) (string=? (mnode-kind n) k)) ns)) kinds))
           (k (rng-pick! rng present)))
      (pick-ref rng (of-kind k ns))))

  ;; choose-create-parent : Rng World Forest Tag Bytevector -> (values ParentRef Symbol)
  ;; A create's parent: none; null; the account's node, not trashed, that
  ;; holds some kind (most often, so that trees grow, and half of those
  ;; times the deepest, so that they grow deep) or that holds none; a
  ;; trashed node of its; an archived one that holds some kind; a fresh id;
  ;; the id being made; a purged node's; the other account's; and a node
  ;; that holds some kind with exactly 63 ancestors, or 64 or more, when
  ;; there is one.
  (define (choose-create-parent rng w f tag id)
    (let* ((own (nodes-of w tag))
           (open (open-nodes own))
           (hold (holders open))
           (leaf (leaves open))
           (trashed (in-state 'trashed own))
           (archived (in-state 'archived hold))
           (theirs (nodes-of w (other-tag tag)))
           (gone (filter (lambda (n) (not (live? n))) (world-nodes w)))
           (d63 (filter (lambda (n) (= (depth-in f n) 63)) hold))
           (d64 (filter (lambda (n) (>= (depth-in f n) 64)) hold))
           (aim (rng-weighted! rng (append '((14 . absent) (6 . null))
                                           (if (pair? hold) '((60 . holder)) '())
                                           (if (pair? leaf) '((26 . leaf)) '())
                                           (if (pair? trashed) '((6 . trashed)) '())
                                           (if (pair? archived) '((6 . archived)) '())
                                           '((4 . missing) (2 . self))
                                           (if (pair? gone) '((6 . purged)) '())
                                           (if (pair? theirs) '((6 . other)) '())
                                           (if (pair? d63) '((10 . deep63)) '())
                                           (if (pair? d64) '((10 . deep64)) '())))))
      (values (case aim
                ((absent) 'absent)
                ((null) 'null)
                ((holder) (ref-of rng (pick-node rng hold (lambda (n) (depth-in f n)))))
                ((leaf) (kind-first-ref rng leaf))
                ((trashed) (pick-ref rng trashed))
                ((archived) (pick-ref rng archived))
                ((missing) (list 'id (fresh-node-id rng w) #f))
                ((self) (list 'id id #f))
                ((purged) (pick-ref rng gone))
                ((other) (pick-ref rng theirs))
                ((deep63) (pick-ref rng d63))
                (else (pick-ref rng d64)))
              (sym "create-parent-" aim))))

  ;; choose-move-parent : Rng World Forest Tag (U MNode #f) -> (values ParentRef Symbol)
  ;; A move's new parent, for N when it is the account's: the top level;
  ;; the account's node outside N's subtree, not trashed, that may hold N,
  ;; or that may not; N itself; a child of N's; a node two or more below
  ;; it; the parent N has; a trashed node; an archived one that may hold N;
  ;; a fresh id; a purged node's; the other account's; a holder with 63
  ;; ancestors, or 64 or more.
  (define (choose-move-parent rng w f tag n)
    (let* ((mine (and n (eq? (mnode-tag n) tag) (live? n) n))
           (under (if mine (below-in f mine) '()))
           (inside? (lambda (x) (or (and mine (same-node? x mine))
                                    (exists (lambda (p) (same-node? x (car p))) under))))
           (outside (filter (lambda (x) (not (inside? x))) (nodes-of w tag)))
           (open (open-nodes outside))
           (fit? (lambda (x) (if mine (may-contain? (mnode-kind x) (mnode-kind mine)) (container? (mnode-kind x)))))
           (fits (filter fit? open))
           (misfits (filter (lambda (x) (not (fit? x))) open))
           (kids (if mine (kids-in f mine) '()))
           (deep (map car (filter (lambda (p) (>= (cdr p) 2)) under)))
           (trashed (in-state 'trashed outside))
           (archived (in-state 'archived fits))
           (theirs (nodes-of w (other-tag tag)))
           (gone (filter (lambda (x) (not (live? x))) (world-nodes w)))
           (d63 (filter (lambda (x) (= (depth-in f x) 63)) (holders open)))
           (d64 (filter (lambda (x) (>= (depth-in f x) 64)) (holders open)))
           (current (and mine (mnode-parent mine)))
           (aim (rng-weighted! rng (append '((12 . top))
                                           (if (pair? fits) '((24 . fits)) '())
                                           (if (pair? misfits) '((14 . misfits)) '())
                                           (if mine '((5 . self)) '())
                                           (if (pair? kids) '((8 . child)) '())
                                           (if (pair? deep) '((10 . descendant)) '())
                                           (if current '((6 . current)) '())
                                           (if (pair? trashed) '((7 . trashed)) '())
                                           (if (pair? archived) '((12 . archived)) '())
                                           '((3 . missing))
                                           (if (pair? gone) '((9 . purged)) '())
                                           (if (pair? theirs) '((5 . other)) '())
                                           (if (pair? d63) '((8 . deep63)) '())
                                           (if (pair? d64) '((8 . deep64)) '())))))
      (values (case aim
                ((top) 'null)
                ((fits) (pick-ref rng fits))
                ((misfits) (kind-first-ref rng misfits))
                ((self) (ref-of rng mine))
                ((child) (pick-ref rng kids))
                ((descendant) (pick-ref rng deep))
                ((current) (list 'id current (= 0 (rng-below! rng 6))))
                ((trashed) (pick-ref rng trashed))
                ((archived) (pick-ref rng archived))
                ((missing) (list 'id (fresh-node-id rng w) #f))
                ((purged) (pick-ref rng gone))
                ((other) (pick-ref rng theirs))
                ((deep63) (pick-ref rng d63))
                (else (pick-ref rng d64)))
              (sym "move-to-" aim))))

  ;; choose-bulk-parent : Rng World Forest Tag (U MNode #f) -> (values ParentRef Symbol)
  ;; A bulk move's new parent, for N's children: the top level; a Project
  ;; or a Journal outside N's subtree, not trashed; a node that holds no
  ;; kind; N itself; a child of N's; a node two or more below it; a trashed
  ;; node; an archived holder; a fresh id; a purged node's; the other
  ;; account's; a holder with 63 ancestors, or 64 or more.
  (define (choose-bulk-parent rng w f tag n)
    (let* ((mine (and n (eq? (mnode-tag n) tag) (live? n) n))
           (under (if mine (below-in f mine) '()))
           (inside? (lambda (x) (or (and mine (same-node? x mine))
                                    (exists (lambda (p) (same-node? x (car p))) under))))
           (outside (filter (lambda (x) (not (inside? x))) (nodes-of w tag)))
           (open (open-nodes outside))
           (projects (of-kind "project" open))
           (journals (of-kind "journal" open))
           (leaf (leaves open))
           (kids (if mine (kids-in f mine) '()))
           (deep (map car (filter (lambda (p) (>= (cdr p) 2)) under)))
           (trashed (in-state 'trashed outside))
           (archived (in-state 'archived (holders open)))
           (theirs (nodes-of w (other-tag tag)))
           (gone (filter (lambda (x) (not (live? x))) (world-nodes w)))
           (d63 (filter (lambda (x) (= (depth-in f x) 63)) (holders open)))
           (d64 (filter (lambda (x) (>= (depth-in f x) 64)) (holders open)))
           (aim (rng-weighted! rng (append '((12 . top))
                                           (if (pair? projects) '((14 . project)) '())
                                           (if (pair? journals) '((14 . journal)) '())
                                           (if (pair? leaf) '((8 . leaf)) '())
                                           (if mine '((5 . self)) '())
                                           (if (pair? kids) '((7 . child)) '())
                                           (if (pair? deep) '((9 . descendant)) '())
                                           (if (pair? trashed) '((5 . trashed)) '())
                                           (if (pair? archived) '((4 . archived)) '())
                                           '((3 . missing))
                                           (if (pair? gone) '((9 . purged)) '())
                                           (if (pair? theirs) '((5 . other)) '())
                                           (if (pair? d63) '((6 . deep63)) '())
                                           (if (pair? d64) '((6 . deep64)) '())))))
      (values (case aim
                ((top) 'null)
                ((project) (pick-ref rng projects))
                ((journal) (pick-ref rng journals))
                ((leaf) (kind-first-ref rng leaf))
                ((self) (ref-of rng mine))
                ((child) (pick-ref rng kids))
                ((descendant) (pick-ref rng deep))
                ((trashed) (pick-ref rng trashed))
                ((archived) (pick-ref rng archived))
                ((missing) (list 'id (fresh-node-id rng w) #f))
                ((purged) (pick-ref rng gone))
                ((other) (pick-ref rng theirs))
                ((deep63) (pick-ref rng d63))
                (else (pick-ref rng d64)))
              (sym "move-children-to-" aim))))

  ;; bad-parent-texts : Rng World -> (Listof String)     ?parent= spellings T9 refuses
  (define (bad-parent-texts rng w)
    (let* ((v4 (v4-text rng w))
           (tail (string-append (id-text (fresh-node-id rng w)) "0")))
      (list "" "NULL" "Null" "nul" "none" v4 tail)))

  ;; choose-list-parent : Rng World Forest Tag -> (values ParentRef Symbol)
  ;; A list's ?parent=: none (the flat list); null; the account's node that
  ;; has children; a Note of its, which holds nothing; a trashed node of
  ;; its; a fresh id; the other account's node; a purged node's; another
  ;; spelling; null twice.
  (define (choose-list-parent rng w f tag)
    (let* ((own (nodes-of w tag))
           (holding (filter (lambda (n) (pair? (kids-in f n))) own))
           (notes (of-kind "note" own))
           (trashed (in-state 'trashed own))
           (theirs (nodes-of w (other-tag tag)))
           (gone (filter (lambda (n) (not (live? n))) (world-nodes w)))
           (aim (rng-weighted! rng (append '((26 . flat) (10 . null))
                                           (if (pair? holding) '((20 . node)) '())
                                           (if (pair? notes) '((8 . note)) '())
                                           (if (pair? trashed) '((11 . trashed)) '())
                                           '((4 . missing))
                                           (if (pair? theirs) '((5 . other)) '())
                                           (if (pair? gone) '((6 . purged)) '())
                                           '((6 . bad) (3 . twice))))))
      (values (case aim
                ((flat) 'absent)
                ((null) 'null)
                ((node) (pick-ref rng holding))
                ((note) (pick-ref rng notes))
                ((trashed) (pick-ref rng trashed))
                ((missing) (list 'id (fresh-node-id rng w) (= 0 (rng-below! rng 2))))
                ((other) (pick-ref rng theirs))
                ((purged) (pick-ref rng gone))
                ((bad) (let ((texts (bad-parent-texts rng w))) (list 'bad (rng-pick! rng texts))))
                (else 'twice))
              aim)))

  ;; choose-target : Rng World Tag (MNode -> Natural) -> (values Bytevector (U MNode #f) Symbol)
  ;; The account's own live node, its state chosen first among the states
  ;; its nodes are in, archived and trashed three times as often as active, as
  ;; they are rarer and pass sooner; the other account's live node; a
  ;; purged node's id, either account's; or an id of none. DEPTH is what
  ;; pick-node favours.
  (define (choose-target rng w tag depth)
    (let* ((own (nodes-of w tag))
           (theirs (nodes-of w (other-tag tag)))
           (gone (filter (lambda (n) (not (live? n))) (world-nodes w)))
           (aim (rng-weighted! rng (append (if (pair? own) '((65 . own)) '())
                                           (if (pair? theirs) '((23 . other)) '())
                                           (if (pair? gone) '((30 . purged)) '())
                                           '((10 . missing))))))
      (case aim
        ((own)
         (let* ((states (filter (lambda (s) (exists (lambda (n) (eq? (mnode-state n) s)) own)) live-states))
                (s (rng-weighted! rng (map (lambda (s) (cons (if (eq? s 'active) 1 3) s)) states)))
                (n (pick-node rng (filter (lambda (n) (eq? (mnode-state n) s)) own) depth)))
           (values (mnode-id n) n aim)))
        ((other) (let ((n (pick-node rng theirs depth))) (values (mnode-id n) n aim)))
        ((purged) (let ((n (rng-pick! rng gone))) (values (mnode-id n) n aim)))
        (else (values (fresh-node-id rng w) #f aim)))))

  ;; pick-node : Rng (Listof MNode) (MNode -> Natural) -> MNode
  ;; Half the time the deepest node, by DEPTH, so that history grows deep
  ;; enough for stale and earlier revisions to be common; else any. A write
  ;; and a state change measure depth by revisions (by-revisions); a
  ;; restore and a snapshot's read by snapshots (by-snapshots), which a
  ;; change of state does not add; a move by the nodes under it, so that
  ;; loops are tried; a bulk move by its children.
  (define (pick-node rng ns depth)
    (if (= 0 (rng-below! rng 2))
        (fold-left (lambda (best n) (if (> (depth n) (depth best)) n best)) (car ns) (cdr ns))
        (rng-pick! rng ns)))

  (define (by-revisions n) (node-rev n))
  (define (by-snapshots n) (length (mnode-snaps n)))

  ;; choose-revision : Rng (U MNode #f) Boolean -> (values Natural Symbol)
  ;; If-Match's revision: the node's current one (most often for another
  ;; account's node, or a purged one: H6's and G7's aim), an earlier one,
  ;; or one past it.
  (define (choose-revision rng n far?)
    (if (not n)
        (values (+ 1 (rng-below! rng 4)) 'any)
        (let* ((rev (node-rev n))
               (r (rng-below! rng 100)))
          (cond ((< r (if far? 58 60)) (values rev 'current))
                ((and (> rev 1) (< r (if far? 92 88))) (values (+ 1 (rng-below! rng (- rev 1))) 'stale))
                (else (values (+ rev 1 (rng-below! rng 3)) 'ahead))))))

  ;; choose-change : Rng (U MNode #f) Symbol -> Symbol
  ;; A state change's event. At the account's own node, often one its
  ;; state allows, so nodes move through the states and reach a purge: 60%
  ;; from active, 25% from archived and trashed, which then stay a while
  ;; for their refusals, a trashed node's a purge two times in three, for
  ;; the purged ids; else, and at any other target, any of the five.
  (define (choose-change rng n where)
    (let ((allowed (and (eq? where 'own)
                        (filter (lambda (ev) (memq (mnode-state n) (cadr (assq ev lifecycle-moves))))
                                lifecycle-events))))
      (if (and (pair? allowed) (< (rng-below! rng 100) (if (eq? (mnode-state n) 'active) 60 25)))
          (if (eq? (mnode-state n) 'trashed)
              (if (< (rng-below! rng 3) 2) 'purge 'untrash)
              (rng-pick! rng allowed))
          (rng-pick! rng lifecycle-events))))

  ;; choose-kind : Rng (U MNode #f) -> (values (U String #f) Symbol)
  ;; A replace's kind: left out, the node's own, or another.
  (define (choose-kind rng n)
    (let* ((r (rng-below! rng 100))
           (stored (if n (mnode-kind n) (rng-pick! rng kinds))))
      (cond ((< r 40) (values #f 'kind-absent))
            ((< r 70) (values stored 'kind-same))
            (else (values (rng-pick! rng (filter (lambda (k) (not (string=? k stored))) kinds))
                          'kind-other)))))

  ;; choose-snapshot : Rng (U MNode #f) -> (values Natural Symbol)
  ;; The newest snapshot; an earlier one the node has; a gap, a revision a
  ;; change of state made, which has none; or one past the node's revision.
  ;; For a purged node any revision it reached; for no node, 1 to 3.
  (define (choose-snapshot rng n)
    (cond
     ((not n) (values (+ 1 (rng-below! rng 3)) 'snap-any))
     ((not (live? n)) (values (+ 1 (rng-below! rng (node-rev n))) 'snap-purged))
     (else
      (let* ((rev (node-rev n))
             (have (map msnap-revision (mnode-snaps n)))
             (older (cdr have))
             (gaps (filter (lambda (k) (not (memv k have))) (from-to 1 rev)))
             (r (rng-below! rng 100)))
        (cond ((< r 20) (values (car have) 'snap-newest))
              ((and (pair? older) (< r 65)) (values (rng-pick! rng older) 'snap-older))
              ((and (pair? gaps) (< r 82)) (values (rng-pick! rng gaps) 'snap-gap))
              (else (values (+ rev 1 (rng-below! rng 3)) 'snap-unknown)))))))

  ;; bad-headers : Rng Symbol Natural -> (values (Listof Header) Symbol)
  ;; A precondition of a shape D4 refuses, built round revision N, the
  ;; node's own: so a reading that let it through would match.
  (define (bad-headers rng route n)
    (let* ((tag (etag-of n))
           (common (list (list 'star (cons "If-Match" "*"))
                         (list 'weak (cons "If-Match" (string-append "W/" tag)))
                         (list 'list (cons "If-Match" (string-append tag ", " (etag-of (+ n 1)))))
                         (list 'bare (cons "If-Match" (number->string n)))
                         (list 'twice (cons "If-Match" tag) (cons "If-Match" tag))
                         (list 'both (cons "If-Match" tag) (cons "If-None-Match" "*"))
                         (list 'zero (cons "If-Match" "\"0\""))
                         (list 'leading-zero (cons "If-Match" (string-append "\"0" (number->string n) "\"")))
                         (list 'inner-space (cons "If-Match" (string-append "\" " (number->string n) "\"")))))
           (choice (rng-pick! rng (append common
                                          (if (eq? route 'put)
                                              (list (list 'none-match-tag (cons "If-None-Match" tag))
                                                    (list 'none-match-twice (cons "If-None-Match" "*")
                                                          (cons "If-None-Match" "*")))
                                              (let ((c (list (case route
                                                               ((restore) 'create-on-restore)
                                                               ((move move-children) 'create-on-move)
                                                               (else 'create-on-lifecycle))
                                                             (cons "If-None-Match" "*"))))
                                                (list c c c)))))))
      (values (cdr choice) (sym "bad-" (car choice)))))

  ;; The routes a write is sent to with no precondition, or a bad one: a
  ;; PUT most, then a restore, then each state change, and each move.
  (define bare-routes
    '(put put put put put restore restore archive unarchive trash untrash purge move move-children))

  ;; list-aim : (U String 'twice #f) -> Symbol
  (define (list-aim q)
    (case (list-state q)
      ((invalid) 'list-state-invalid)
      (else (if q (sym "list-state-" q) 'list-state-default))))

  ;; at-revision : Symbol Natural Tag Bytevector MNode (Listof Symbol) ParentRef -> Event
  ;; EV of N at its own revision, a move's or a bulk move's to PARENT.
  (define (at-revision ev now tag key n aims parent)
    (make-event ev now tag key (mnode-id n) (node-rev n) (list (cons "If-Match" (etag-of (node-rev n))))
                #f #f #f #f #f aims parent))

  ;; create-of : Rng World Natural Tag Bytevector String ParentRef (Listof Symbol) -> Event
  ;; A create of a fresh id, of KIND, under PARENT.
  (define (create-of rng w now tag key kind parent aims)
    (let* ((id (fresh-node-id rng w))
           (c (random-content rng kind parent)))
      (make-event 'put now tag key id 'create (list (cons "If-None-Match" "*")) c #f #f #f #f aims 'absent)))

  ;; chore-options : World Forest Tag -> (Listof (Pair Symbol (Listof MNode)))
  ;; The tree's chores TAG's nodes offer, each with the nodes it may take:
  ;; trash a node with children; purge a trashed node with children
  ;; (refused) or one that has had children and has none now (passes);
  ;; move a trashed parent's children to the top level; archive, trash or purge
  ;; a child of a trashed parent. Only the chores some node offers.
  (define (chore-options w f tag)
    (let* ((own (nodes-of w tag))
           (parents (filter (lambda (n) (pair? (kids-in f n))) own))
           (trashed-parents (in-state 'trashed parents))
           (emptied (filter (lambda (n) (and (eq? (mnode-state n) 'trashed) (null? (kids-in f n))
                                             (member (mnode-id n) (world-held w))))
                            own))
           (orphans (apply append (map (lambda (p) (kids-in f p)) trashed-parents))))
      (filter (lambda (c) (pair? (cdr c)))
              (list (cons 'chore-trash-parent (open-nodes parents))
                    (cons 'chore-purge-parent trashed-parents)
                    (cons 'chore-empty-parent trashed-parents)
                    (cons 'chore-purge-emptied emptied)
                    (cons 'chore-clear-child orphans)))))

  ;; chore-event : Rng Natural Tag Bytevector (Pair Symbol (Listof MNode)) Symbol -> Event
  (define (chore-event rng now tag key chore wait)
    (let ((n (rng-pick! rng (cdr chore))) (aims (list (car chore) wait)))
      (case (car chore)
        ((chore-trash-parent) (at-revision 'trash now tag key n aims 'absent))
        ((chore-purge-parent chore-purge-emptied) (at-revision 'purge now tag key n aims 'absent))
        ((chore-empty-parent) (at-revision 'move-children now tag key n aims 'null))
        (else (at-revision (case (mnode-state n)
                             ((trashed) 'purge)
                             ((archived) 'trash)
                             (else (if (= 0 (rng-below! rng 2)) 'archive 'trash)))
                           now tag key n aims 'absent)))))

  ;; create-kind : Rng World Tag ParentRef String -> String
  ;; A create's kind: under the account's own Journal, three times in four
  ;; a Note; under its own Project, three times in four a Project, a
  ;; Journal or a Note, so that trees grow deep and hold Notes; at the top
  ;; level, three times in four, a Project or a Journal while the account
  ;; has no holder that is not trashed, else a Task or a Contact while it
  ;; has none such, so that every kind is there to be a parent; else K,
  ;; any.
  (define (create-kind rng w tag parent k)
    (let* ((p (and (pair? parent) (eq? (car parent) 'id) (own-node w tag (cadr parent))))
           (r (rng-below! rng 4))
           (open (open-nodes (nodes-of w tag)))
           (lacks? (lambda (kind) (null? (of-kind kind open)))))
      (cond ((and p (< r 3) (string=? (mnode-kind p) "journal")) "note")
            ((and p (< r 3) (string=? (mnode-kind p) "project")) (list-ref '("project" "journal" "note") r))
            ((or p (= r 3)) k)
            ((null? (holders open)) (if (< r 2) "project" "journal"))
            ((lacks? "task") "task")
            ((lacks? "contact") "contact")
            (else k))))

  ;; parent-target : Rng World Forest Tag Boolean (MNode -> Natural)
  ;;                 -> (values Bytevector (U MNode #f) Symbol)
  ;; A move's or a bulk move's node: three times in five, when there is
  ;; one, the account's node, any state, that has children or (for a move,
  ;; BULK? #f) a parent; else choose-target's.
  (define (parent-target rng w f tag bulk? depth)
    (let ((tied (filter (lambda (n) (or (and (not bulk?) (mnode-parent n)) (pair? (kids-in f n)))) (nodes-of w tag))))
      (if (and (pair? tied) (< (rng-below! rng 5) 3))
          (let ((n (pick-node rng tied depth))) (values (mnode-id n) n 'own))
          (choose-target rng w tag depth))))

  ;; next-event : Rng World Natural -> Event
  (define (next-event rng w now0)
    (let*-values (((tag) (rng-pick! rng '(a b)))
                  ((key) (rng-pick! rng (key-ids-of tag)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((upper? (= 0 (rng-below! rng 5)))
             (f (forest-of w))
             (many (length (live-nodes w)))
             (chores (chore-options w f tag))
             (kind (rng-weighted! rng (append (list (cons (cond ((< many 6) 30) ((< many 14) 16) (else 6)) 'create)
                                                    '(31 . replace) '(22 . restore) '(38 . lifecycle)
                                                    '(5 . no-pre) '(13 . bad-pre)
                                                    '(7 . get-node) '(12 . list-nodes) '(8 . list-revisions)
                                                    '(16 . get-snapshot) '(16 . move) '(10 . move-children))
                                              (if (pair? chores) '((8 . chore)) '())))))
        (case kind
          ((create)
           (let* ((own (nodes-of w tag))
                  (theirs (nodes-of w (other-tag tag)))
                  (gone-own (purged-of w tag))
                  (gone-theirs (purged-of w (other-tag tag)))
                  (aim (rng-weighted! rng (append '((85 . create-fresh))
                                                  (if (pair? own) '((20 . create-own)) '())
                                                  (if (pair? theirs) '((25 . create-other)) '())
                                                  (if (pair? gone-own) '((15 . create-purged-own)) '())
                                                  (if (pair? gone-theirs) '((15 . create-purged-other)) '()))))
                  (id (case aim
                        ((create-own) (mnode-id (rng-pick! rng own)))
                        ((create-other) (mnode-id (rng-pick! rng theirs)))
                        ((create-purged-own) (mnode-id (rng-pick! rng gone-own)))
                        ((create-purged-other) (mnode-id (rng-pick! rng gone-theirs)))
                        (else (fresh-node-id rng w))))
                  (k0 (rng-pick! rng kinds)))
             (let*-values (((parent p-aim) (choose-create-parent rng w f tag id)))
               (let* ((k (create-kind rng w tag parent k0))
                      (c (random-content rng k parent)))
                 (make-event 'put now tag key id 'create (list (cons "If-None-Match" "*")) c #f #f #f upper?
                             (list aim p-aim wait) 'absent)))))
          ((replace)
           (let*-values (((id n where) (choose-target rng w tag by-revisions))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged))))
                         ((k kind-aim) (choose-kind rng n)))
             (let ((c (random-content rng k 'absent)))
               (make-event 'put now tag key id rev (list (cons "If-Match" (etag-of rev))) c #f #f #f upper?
                           (append (list (sym "replace-" where "-" rev-aim) kind-aim wait)
                                   (if (eq? where 'own) (list (sym "replace-own-" (mnode-state n))) '()))
                           'absent))))
          ((restore)
           (let*-values (((id n where) (choose-target rng w tag by-snapshots))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged))))
                         ((k snap-aim) (choose-snapshot rng n)))
             (make-event 'restore now tag key id rev (list (cons "If-Match" (etag-of rev))) #f k #f #f upper?
                         (append (list (sym "restore-" where "-" rev-aim) (sym "restore-" snap-aim) wait)
                                 (if (eq? where 'own) (list (sym "restore-own-" (mnode-state n))) '()))
                         'absent)))
          ((lifecycle)
           (let*-values (((id n where) (choose-target rng w tag by-revisions))
                         ((ev) (choose-change rng n where))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged)))))
             (make-event ev now tag key id rev (list (cons "If-Match" (etag-of rev))) #f #f #f #f upper?
                         (append (list (sym ev "-" where "-" rev-aim) wait)
                                 (if (eq? where 'own) (list (sym ev "-own-" (mnode-state n))) '()))
                         'absent)))
          ((move move-children)
           (let*-values (((id n where)
                          (parent-target rng w f tag (eq? kind 'move-children)
                                         (if (eq? kind 'move)
                                                         (lambda (n) (length (below-in f n)))
                                                         (lambda (n) (length (kids-in f n))))))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged))))
                         ((parent to-aim) (if (eq? kind 'move)
                                              (choose-move-parent rng w f tag n)
                                              (choose-bulk-parent rng w f tag n))))
             (make-event kind now tag key id rev (list (cons "If-Match" (etag-of rev))) #f #f #f #f upper?
                         (append (list (sym kind "-" where "-" rev-aim) to-aim wait)
                                 (if (eq? where 'own) (list (sym kind "-own-" (mnode-state n))) '()))
                         parent)))
          ((chore)
           (chore-event rng now tag key (rng-pick! rng chores) wait))
          ((no-pre)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (let* ((route (rng-pick! rng bare-routes))
                    (c (and (eq? route 'put) (random-content rng (rng-pick! rng kinds) 'absent))))
               (make-event route now tag key id 'missing '() c (and (eq? route 'restore) 1) #f #f upper?
                           (list (sym "no-precondition-" route) wait) 'null))))
          ((bad-pre)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (let* ((route (rng-pick! rng bare-routes)))
               (let*-values (((hs aim) (bad-headers rng route (if n (node-rev n) 1))))
                 (let ((c (and (eq? route 'put) (random-content rng (rng-pick! rng kinds) 'absent))))
                   (make-event route now tag key id 'invalid hs c (and (eq? route 'restore) 1) #f #f upper?
                               (list aim (sym "bad-precondition-" route) wait) 'null))))))
          ((get-node)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (make-event 'get-node now tag key id #f '() #f #f #f #f upper? (list (sym "get-node-" where) wait)
                         'absent)))
          ((list-nodes)
           (let*-values (((limit) (rng-pick! rng '(1 2 3 #f)))
                         ((q) (rng-weighted! rng '((28 . none) (18 . "active") (21 . "archived") (21 . "trashed")
                                                   (3 . "purged") (3 . "ARCHIVED") (3 . "deleted") (3 . twice))))
                         ((parent p-aim) (choose-list-parent rng w f tag)))
             (let ((query (if (eq? q 'none) #f q)))
               (make-event 'list-nodes now tag key #f #f '() #f #f limit query #f
                           (append (list 'list-nodes (list-aim query) wait)
                                   (if (eq? p-aim 'flat)
                                       '()
                                       (list (sym "list-parent-" p-aim)
                                             (sym "list-parent-" p-aim "-"
                                                  (let ((s (list-state query)))
                                                    (cond ((eq? s 'invalid) "invalid")
                                                          (query (symbol->string s))
                                                          (else "default")))))))
                           parent))))
          ((list-revisions)
           (let*-values (((id n where) (choose-target rng w tag by-snapshots)))
             (let ((limit (rng-pick! rng '(1 2 3 #f))))
               (make-event 'list-revisions now tag key id #f '() #f #f limit #f upper?
                           (list (sym "list-revisions-" where) wait) 'absent))))
          (else
           (let*-values (((id n where) (choose-target rng w tag by-snapshots))
                         ((k snap-aim) (choose-snapshot rng n)))
             (make-event 'get-snapshot now tag key id #f '() #f k #f #f upper?
                         (list (sym "get-snapshot-" where) (sym "get-" snap-aim) wait) 'absent)))))))

  ;;; A deep sequence: the chain, then the script

  ;; chain-steps : Natural     65 Projects made, one under the last, and a 66th refused
  (define chain-steps 66)

  ;; chain-event : Rng World Natural Tag -> Event
  ;; A Project of a fresh id, made by TAG under TAG's last node made (at the
  ;; top level for the first). The 65th is made under a parent with 63
  ;; ancestors; the 66th is refused under one with 64.
  (define (chain-event rng w now0 tag)
    (let*-values (((key) (rng-pick! rng (key-ids-of tag)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((mine (filter (lambda (n) (eq? (mnode-tag n) tag)) (world-nodes w)))
             (last (and (pair? mine) (car (reverse mine)))))
        (create-of rng w now tag key "project" (if last (list 'id (mnode-id last) #f) 'absent) (list 'chain wait)))))

  ;; script-steps : Natural
  (define script-steps 12)

  ;; script-event : Rng World Natural Tag Natural -> (U Event #f)
  ;; Step K of the script that follows the chain, TAG's nodes in the order
  ;; made: P0 to P64, the chain; X and Y, the script's first two. Each at
  ;; its node's revision. #f when a node it names is not there.
  ;;   1 make X, a Project, at the top     7 bulk move P0's children into X: a loop at the 64th
  ;;   2 make Y, a Project, under X        8 bulk move Y's into P63: 63 ancestors, ok
  ;;   3 move X under P63: 63, ok          9 bulk move Y's into X: 64, too deep
  ;;   4 move P0 under Y: P0 is Y's 65th  10 make a node under X: 64, too deep
  ;;     ancestor, too deep, not a loop   11 move Y under X, its parent: 64, too deep
  ;;   5 move P0 under X: its 64th, a loop 12 make a node under P63: 63, ok
  ;;   6 bulk move P0's children into Y: too deep
  (define (script-event rng w now0 tag k)
    (let*-values (((key) (rng-pick! rng (key-ids-of tag)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((mine (list->vector (filter (lambda (n) (eq? (mnode-tag n) tag)) (world-nodes w))))
             (at (lambda (i) (and (< i (vector-length mine)) (live? (vector-ref mine i)) (vector-ref mine i))))
             (p0 (at 0)) (p63 (at 63)) (x (at 65)) (y (at 66))
             (aims (list (sym "deep-" (number->string k)) wait))
             (ref (lambda (n) (list 'id (mnode-id n) #f)))
             (move (lambda (ev n p) (and n p (at-revision ev now tag key n aims (ref p))))))
        (case k
          ((1) (create-of rng w now tag key "project" 'absent aims))
          ((2) (and x (create-of rng w now tag key "project" (ref x) aims)))
          ((3) (move 'move x p63))
          ((4) (move 'move p0 y))
          ((5) (move 'move p0 x))
          ((6) (move 'move-children p0 y))
          ((7) (move 'move-children p0 x))
          ((8) (move 'move-children y p63))
          ((9) (move 'move-children y x))
          ((10) (and x (let ((kind (rng-pick! rng kinds))) (create-of rng w now tag key kind (ref x) aims))))
          ((11) (move 'move y x))
          (else (and p63 (let ((kind (rng-pick! rng kinds))) (create-of rng w now tag key kind (ref p63) aims))))))))

  ;; deep-seed? : Natural -> Boolean     one seed in fifteen: a multiple of fifteen
  (define (deep-seed? seed) (= 0 (mod seed 15)))

  ;;; A family sequence: a mixed tree first

  ;; family-seed? : Natural -> Boolean     one in five: a seed ending in 3 or 7 (never deep)
  (define (family-seed? seed) (and (memv (mod seed 10) '(3 7)) #t))

  ;; family-steps : Natural
  (define family-steps 30)

  ;; family-event : Rng World Natural Tag Natural -> (U Event #f)
  ;; Step K of the family a family seed's TAG makes first, TAG's nodes in
  ;; the order made: P, a Project at the top, holds J, a Journal (which
  ;; holds N1, a Note), T, a Task, C, a Contact, N2, a Note, and Q, a
  ;; Project, which holds R, a Project, which holds S, a Note: P's great-
  ;; grandchild. Then N2 is archived and C trashed; G, a Journal, and X, a
  ;; Contact, are made at the top; the other account makes O, a
  ;; Project, and a Note under it. Then, each at the node's revision, P's
  ;; children are moved into G: N2 moves, J, T and Q stay for their kind, C
  ;; for its state; P is moved under S (a loop three down), its children
  ;; into S (a loop before S's kind), P under R and its children into R (a
  ;; loop two down). Then a node of any kind is made under J, T, X and N1,
  ;; so that every kind is tried under every kind; G is archived and N1
  ;; moved into it; C is purged, and T moved, P's children moved and a
  ;; Note made under it. So a bulk move of P's children meets every state
  ;; and kinds a Journal does not hold, P's moves loop through every
  ;; distance, and a purged parent is judged by each route. #f when a node
  ;; it names is not there.
  (define (family-event rng w now0 tag k)
    (let*-values (((who) (if (memv k '(14 15)) (other-tag tag) tag))
                  ((key) (rng-pick! rng (key-ids-of who)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((pick (lambda (t) (list->vector (filter (lambda (n) (eq? (mnode-tag n) t)) (world-nodes w)))))
             (mine (pick tag))
             (theirs (pick (other-tag tag)))
             (any-at (lambda (v i) (and (< i (vector-length v)) (vector-ref v i))))
             (at (lambda (v i) (let ((n (any-at v i))) (and n (live? n) n))))
             (aims (list (sym "family-" (number->string k)) wait))
             (make (lambda (kind parent)
                     (create-of rng w now who key kind (if parent (list 'id (mnode-id parent) #f) 'absent) aims)))
             (under (lambda (kind v i) (let ((p (at v i))) (and p (make kind p)))))
             (change (lambda (ev i) (let ((n (at mine i))) (and n (at-revision ev now who key n aims 'absent)))))
             (shift (lambda (ev i j)
                      (let ((n (at mine i)) (p (any-at mine j)))
                        (and n p (at-revision ev now who key n aims (list 'id (mnode-id p) #f))))))
             (any-kind (lambda (i) (let ((kind (rng-pick! rng kinds))) (under kind mine i)))))
        (case k
          ((1) (make "project" #f))
          ((2) (under "journal" mine 0))
          ((3) (under "note" mine 1))
          ((4) (under "task" mine 0))
          ((5) (under "contact" mine 0))
          ((6) (under "note" mine 0))
          ((7) (under "project" mine 0))
          ((8) (under "project" mine 6))
          ((9) (under "note" mine 7))
          ((10) (change 'archive 5))
          ((11) (change 'trash 4))
          ((12) (make "journal" #f))
          ((13) (make "contact" #f))
          ((14) (make "project" #f))
          ((15) (under "note" theirs 0))
          ((16) (shift 'move-children 0 9))
          ((17) (shift 'move 0 8))
          ((18) (shift 'move-children 0 8))
          ((19) (shift 'move 0 7))
          ((20) (shift 'move-children 0 7))
          ((21) (any-kind 1))
          ((22) (any-kind 3))
          ((23) (any-kind 10))
          ((24) (any-kind 2))
          ((25) (change 'archive 9))
          ((26) (shift 'move 2 9))
          ((27) (change 'purge 4))
          ((28) (shift 'move 3 4))
          ((29) (shift 'move-children 0 4))
          (else (let ((c (any-at mine 4)))
                  (and c (create-of rng w now who key "note" (list 'id (mnode-id c) #f) aims))))))))

  ;;; The shell: one request through the stack

  ;; Obs: what the client read. status code etag location json items
  ;; problems (a walk's own) requests
  (define-record-type obs (fields status code etag location json items problems requests))

  (define (problem-code a)
    (let ((j (answer-json a)))
      (and (>= (answer-status a) 400) (list? j)
           (let ((c (assoc "code" j))) (and c (cdr c))))))

  (define (single a)
    (make-obs (answer-status a) (problem-code a) (answer-header a "etag") (answer-header a "location")
              (answer-json a) #f '() 1))

  (define (field j name)
    (let ((p (and (list? j) (assoc name j))))
      (if p (cdr p) (assertion-violation 'field "the answer has no such field" name))))

  (define (path-id e)
    (let ((t (id-text (event-id e)))) (if (event-upper? e) (string-upcase t) t)))
  (define (node-path e) (string-append "/v1/nodes/" (path-id e)))

  ;; content->text : Content -> String     the PUT's JSON
  (define (content->text c)
    (json->string (append (if (content-kind c) (list (cons "kind" (content-kind c))) '())
                          (list (cons "title" (content-title c)) (cons "body" (content-body c))
                                (cons "content_type" (content-type c)))
                          (if (content-props? c) (list (cons "props" '())) '())
                          (if (eq? (content-parent c) 'absent) '() (list (cons "parent" (ref-text (content-parent c))))))))

  (define (cursor-text x) (if (number? x) (number->string x) (format "~a" x)))

  ;; parent-query : ParentRef -> (Listof String)     a list's ?parent= fields
  (define (parent-query r)
    (cond ((eq? r 'absent) '())
          ((memq r '(null twice)) (if (eq? r 'twice) '("parent=null" "parent=null") '("parent=null")))
          (else (list (string-append "parent=" (ref-text r))))))

  ;; state-query : (U String 'twice #f) -> (Listof String)     a list's ?state= fields
  (define (state-query q)
    (cond ((not q) '())
          ((eq? q 'twice) '("state=active" "state=active"))
          (else (list (string-append "state=" q)))))

  ;; walk : Handler Header String (Listof String) (U Natural #f) (Alist -> Any) -> Obs
  ;; A list page by page, each `next` followed as `after`, at most 250 pages
  ;; (a deep sequence's account has some 90 nodes),
  ;; with the query fields EXTRA on every page. LAST-OF is what a full
  ;; page's `next` must be, of its last item.
  (define (walk h auth base extra limit last-of)
    (let ((cap (or limit 50)))
      (let loop ((after #f) (n 1) (items '()) (problems '()))
        (let* ((q (append extra
                          (if limit (list (string-append "limit=" (number->string limit))) '())
                          (if after (list (string-append "after=" (cursor-text after))) '())))
               (target (if (null? q) base (string-append base "?" (join q "&"))))
               (a (exchange h 'GET target (list auth))))
          (if (not (= (answer-status a) 200))
              (make-obs (answer-status a) (problem-code a) (answer-header a "etag") #f (answer-json a) items
                        (if (> n 1) (cons (format "page ~a answered ~a after a 200" n (answer-status a)) problems)
                            problems)
                        n)
              (let* ((j (answer-json a))
                     (page (vector->list (field j "items")))
                     (next (field j "next"))
                     (problems
                      (append problems
                              (if (> (length page) cap)
                                  (list (format "page ~a has ~a items, over its limit ~a" n (length page) cap))
                                  '())
                              (if (and (not (eq? next 'null))
                                       (not (and (pair? page) (= (length page) cap)
                                                 (equal? next (last-of (car (reverse page)))))))
                                  (list (format "page ~a's next ~s is not the last item of a full page" n next))
                                  '())))
                     (items (append items page)))
                (cond ((eq? next 'null) (make-obs 200 #f (answer-header a "etag") #f j items problems n))
                      ((>= n 250) (make-obs 200 #f #f #f j items (cons "the walk did not end in 250 pages" problems) n))
                      (else (loop next (+ n 1) items problems)))))))))

  ;; observe : Handler Event -> Obs
  (define (observe h e)
    (let ((auth (bearer (key-secret-of (event-key e)))))
      (case (event-kind e)
        ((put)
         (single (exchange h 'PUT (node-path e)
                           (append (list auth (cons "Content-Type" "application/json")) (event-headers e))
                           (content->text (event-content e)))))
        ((restore)
         (single (exchange h 'POST (string-append (node-path e) "/revisions/" (number->string (event-snap e))
                                                  "/restore")
                           (cons auth (event-headers e)))))
        ((archive unarchive trash untrash)
         (single (exchange h 'POST (string-append (node-path e) "/" (symbol->string (event-kind e)))
                           (cons auth (event-headers e)))))
        ((purge) (single (exchange h 'DELETE (node-path e) (cons auth (event-headers e)))))
        ((move move-children)
         (single (exchange h 'POST (string-append (node-path e) "/" (symbol->string (event-kind e)))
                           (append (list auth (cons "Content-Type" "application/json")) (event-headers e))
                           (json->string (list (cons "parent" (ref-text (event-parent e))))))))
        ((get-node) (single (exchange h 'GET (node-path e) (list auth))))
        ((get-snapshot)
         (single (exchange h 'GET (string-append (node-path e) "/revisions/" (number->string (event-snap e)))
                           (list auth))))
        ((list-nodes) (walk h auth "/v1/nodes" (append (state-query (event-query e)) (parent-query (event-parent e)))
                            (event-limit e) (lambda (item) (field item "id"))))
        (else (walk h auth (string-append (node-path e) "/revisions") '() (event-limit e)
                    (lambda (item) (field item "revision")))))))

  ;;; Comparing an answer

  (define (same what want got)
    (if (equal? want got) '() (list (format "~a: the model has ~s, the handlers answered ~s" what want got))))

  ;; answer-breaks : Expectation Obs -> (Listof String)
  (define (answer-breaks x o)
    (let ((want (expectation-status x)) (got (obs-status o)))
      (append
       (if (eqv? want got) '() (list (format "status: the model has ~a, the handlers answered ~a" want got)))
       (if (and (expectation-code x) (eqv? want got) (not (equal? (expectation-code x) (obs-code o))))
           (list (format "code: the model has ~s, the handlers answered ~s" (expectation-code x) (obs-code o)))
           '())
       (same "ETag" (expectation-etag x) (obs-etag o))
       (same "Location" (expectation-location x) (obs-location o))
       (obs-problems o)
       (if (and (eqv? want got) (memv want '(200 201 204)))
           (append (let ((j (expectation-json x)))
                     (cond ((not j) '())
                           ((eq? j 'empty) (same "the body" 'empty (obs-json o)))
                           (else (same "the JSON" j (sorted-json (obs-json o))))))
                   (if (expectation-items x)
                       (same "the items" (expectation-items x) (map sorted-json (obs-items o)))
                       '()))
           '()))))

  ;; ids-rising? : (Listof Any) -> Boolean     strings, each greater than the one before
  (define (ids-rising? ids)
    (or (null? ids) (null? (cdr ids))
        (and (string? (car ids)) (string? (cadr ids)) (string<? (car ids) (cadr ids)) (ids-rising? (cdr ids)))))

  (define (natural? x) (and (integer? x) (exact? x) (>= x 0)))

  ;; law-breaks : World Event Obs -> (Listof String)
  ;; An answer held to laws that need no model. A node's answer shows a
  ;; live state (G14) and its revision as its ETag (H14); a state change's
  ;; answer and a move's have no body (the plan's choice); a bulk move's
  ;; has no ETag and is {"moved": N, "left": M} alone (H14); a purge's 204
  ;; has neither body nor ETag (G6); a list shows only the account's own
  ;; live nodes (H6, G14), each in the state asked (G8) and under the
  ;; parent asked, each once, by id (H18').
  (define (law-breaks w e o)
    (let ((status (obs-status o)) (kind (event-kind e)) (j (obs-json o)))
      (append
       (if (and (memv status '(200 201)) (memq kind (cons 'get-node write-kinds)) (not (eq? kind 'move-children))
                (list? j))
           (let ((s (guard (c (#t #f)) (field j "state")))
                 (r (guard (c (#t #f)) (field j "revision"))))
             (append
              (if (member s '("active" "archived" "trashed")) '()
                  (list (format "G14: a node's answer shows the state ~s" s)))
              (if (and (integer? r) (equal? (obs-etag o) (etag-of r))) '()
                  (list (format "H14: the ETag ~s is not the answer's revision ~s" (obs-etag o) r)))
              (if (and (or (life-kind? kind) (eq? kind 'move)) (assoc "body" j))
                  (list (format "the plan: a ~a's answer shows a body" kind))
                  '())))
           '())
       (if (and (eq? kind 'move-children) (eqv? status 200))
           (append (if (obs-etag o) (list (format "H14: a bulk move's answer has the ETag ~s" (obs-etag o))) '())
                   (if (and (list? j) (= (length j) 2)
                            (let ((m (assoc "moved" j)) (l (assoc "left" j)))
                              (and m l (natural? (cdr m)) (natural? (cdr l)))))
                       '()
                       (list (format "the plan: a bulk move answers {\"moved\": N, \"left\": M} alone, not ~s" j))))
           '())
       (if (and (eq? kind 'purge) (eqv? status 204))
           (append (if (obs-etag o) (list (format "G6: a purge's 204 has the ETag ~s" (obs-etag o))) '())
                   (if (eq? j 'empty) '() (list (format "G6: a purge's 204 has a body: ~s" j))))
           '())
       (if (and (eq? kind 'list-nodes) (eqv? status 200))
           (let* ((asked (list-state (event-query e)))
                  (ids (map (lambda (item) (guard (c (#t #f)) (field item "id"))) (obs-items o)))
                  (states (map (lambda (item) (guard (c (#t #f)) (field item "state"))) (obs-items o)))
                  (mine (map (lambda (n) (id-text (mnode-id n))) (nodes-of w (event-tag e))))
                  (strays (filter (lambda (i) (not (member i mine))) ids)))
             (append
              (if (null? strays) '()
                  (list (format "H6, G14: the list shows ~a items that are no live node of the account's" (length strays))))
              (if (and (symbol? asked) (for-all (lambda (s) (equal? s (symbol->string asked))) states)) '()
                  (list (format "G8: the list for ~a shows the states ~s" asked states)))
              (if (ids-rising? ids) '() (list "H18': the list does not show each node once, by id"))
              (let* ((p (ref-meaning (event-parent e)))
                     (want (cond ((eq? p 'any) 'any) ((not p) 'null) (else (id-text p))))
                     (parents (map (lambda (item) (guard (c (#t 'none)) (field item "parent"))) (obs-items o))))
                (if (or (eq? want 'any) (for-all (lambda (x) (equal? x want)) parents)) '()
                    (list (format "H18': the list for the parent ~s shows the parents ~s" want parents))))))
           '()))))

  ;;; The database

  ;; Db = (List Nodes Snaps Changes Keys), each a list of rows, each row a list:
  ;;   node     (id owner author kind title content_type props revision created updated state parent)
  ;;   snapshot (node revision author title content_type props created body)
  ;;   change   (owner seq node revision op created)
  ;;   key      (id account last_used)
  (define (n-id r) (list-ref r 0))
  (define (n-owner r) (list-ref r 1))
  (define (n-author r) (list-ref r 2))
  (define (n-kind r) (list-ref r 3))
  (define (n-title r) (list-ref r 4))
  (define (n-type r) (list-ref r 5))
  (define (n-props r) (list-ref r 6))
  (define (n-rev r) (list-ref r 7))
  (define (n-created r) (list-ref r 8))
  (define (n-updated r) (list-ref r 9))
  (define (n-state r) (list-ref r 10))
  (define (n-parent r) (list-ref r 11))
  (define (s-node r) (list-ref r 0))
  (define (s-rev r) (list-ref r 1))
  (define (s-author r) (list-ref r 2))
  (define (s-title r) (list-ref r 3))
  (define (s-type r) (list-ref r 4))
  (define (s-props r) (list-ref r 5))
  (define (s-created r) (list-ref r 6))
  (define (c-owner r) (list-ref r 0))
  (define (c-seq r) (list-ref r 1))
  (define (c-node r) (list-ref r 2))
  (define (c-rev r) (list-ref r 3))
  (define (c-op r) (list-ref r 4))
  (define (c-created r) (list-ref r 5))
  (define (k-account r) (list-ref r 1))

  (define (row->list v) (map (lambda (c) (if (sql-null? c) #f c)) (vector->list v)))

  ;; db-now : Store -> Db     the three tables and every key's last_used, whole
  (define (db-now store)
    (run-read store
              (lambda (tx)
                (let* ((nodes (tx-query tx (string-append "SELECT id, owner, author, kind, title, content_type,"
                                                          " props, revision, created, updated, state, parent"
                                                          " FROM nodes ORDER BY id")))
                       (snaps (tx-query tx (string-append "SELECT node, revision, author, title, content_type,"
                                                          " props, created, body FROM revisions"
                                                          " ORDER BY node, revision")))
                       (changes (tx-query tx (string-append "SELECT owner, seq, node, revision, op, created"
                                                            " FROM changes ORDER BY owner, seq")))
                       (keys (tx-query tx "SELECT id, account, last_used FROM api_keys ORDER BY id")))
                  (list (map row->list nodes) (map row->list snaps) (map row->list changes) (map row->list keys))))))

  ;;; The laws, with no model: the tables after a request, and before it

  (define (find-node rows id) (find (lambda (r) (bytevector=? (n-id r) id)) rows))
  (define (but-node rows id) (filter (lambda (r) (not (bytevector=? (n-id r) id))) rows))

  ;; The ops that write content, and so a snapshot.
  (define content-ops '("create" "update" "restore"))

  ;; feed-state : (Listof String) -> (U String #f)
  ;; The state a node's change rows leave it in, oldest first: a create
  ;; makes it active, an update, a restore or a move keeps it, a change of
  ;; state lands where lifecycle-moves says. #f for an op none of these is.
  (define (feed-state ops)
    (fold-left (lambda (state op)
                 (cond ((not state) #f)
                       ((string=? op "create") "active")
                       ((member op '("update" "restore" "move")) state)
                       ((find (lambda (m) (string=? (symbol->string (car m)) op)) lifecycle-moves)
                        => (lambda (m) (symbol->string (caddr m))))
                       (else #f)))
               "none" ops))

  ;; node-law-breaks : Row (Listof Row) (Listof Row) -> (Listof String)
  ;; One node's row, its snapshots (by revision) and its change rows (in
  ;; the feed's order): G3, G6, G16, H2', H3', H15', H16.
  (define (node-law-breaks r ss cs)
    (let* ((n (n-rev r))
           (revs (map s-rev ss))
           (crevs (map c-rev cs))
           (ops (map c-op cs))
           (state (n-state r))
           (purged? (equal? state "purged"))
           (top (and (pair? ss) (car (reverse ss))))
           (newest (and (pair? cs) (car (reverse cs))))
           (name (id-text (n-id r))))
      (append
       (if (equal? crevs (from-to 1 n)) '()
           (list (format "G3: node ~a is at revision ~a; its change rows' revisions, in the feed's order, are ~a"
                         name n crevs)))
       (if (and (pair? ops) (string=? (car ops) "create")) '()
           (list (format "H4: node ~a's first change row is ~s, not its create" name (if (pair? ops) (car ops) "none"))))
       (let ((after (member "purge" ops)))
         (if (or (not after) (null? (cdr after))) '()
             (list (format "G16: node ~a has change rows after its purge: ~a" name (cdr after)))))
       (let ((want (feed-state ops)))
         (if (equal? want state) '()
             (list (format "G3: node ~a is ~a, but its change rows ~a leave it ~a" name state ops want))))
       (let ((want (if purged? '() (map c-rev (filter (lambda (c) (member (c-op c) content-ops)) cs)))))
         (if (equal? revs want) '()
             (list (format "H3': node ~a (~a, at ~a) has snapshots ~a; its content changes are at ~a"
                           name state n revs want))))
       (cond
        (purged?
         (if (and (equal? (n-title r) "") (equal? (n-type r) purged-type) (equal? (n-props r) "{}")) '()
             (list (format "G6: purged node ~a's row is not emptied: ~s" name (list (n-title r) (n-type r) (n-props r))))))
        ((not top) (list (format "H2': node ~a (~a) has no snapshot" name state)))
        ((and (equal? (n-title r) (s-title top)) (equal? (n-type r) (s-type top)) (equal? (n-props r) (s-props top)))
         '())
        (else
         (list (format "H2': node ~a's title, content type and props are ~s; its newest snapshot's ~s" name
                       (list (n-title r) (n-type r) (n-props r)) (list (s-title top) (s-type top) (s-props top))))))
       (if (and newest (equal? (n-updated r) (c-created newest))) '()
           (list (format "H15': node ~a's updated is ~a; its newest change row's time ~a" name (n-updated r)
                         (and newest (c-created newest)))))
       (if (and (pair? cs) (equal? (n-created r) (c-created (car cs)))) '()
           (list (format "H15': node ~a's created is ~a; its create's time ~a" name (n-created r)
                         (and (pair? cs) (c-created (car cs))))))
       (if (bytevector=? (n-author r) (n-owner r)) '()
           (list (format "H16: node ~a's author is ~a, its owner ~a" name (account-label (n-author r))
                         (account-label (n-owner r)))))
       (let ((bad (filter (lambda (s) (not (bytevector=? (s-author s) (n-owner r)))) ss)))
         (if (null? bad) '()
             (list (format "H16: node ~a's snapshots ~a have an author that is not its owner ~a" name
                           (map s-rev bad) (account-label (n-owner r))))))
       (let ((bad (filter (lambda (c) (not (bytevector=? (c-owner c) (n-owner r)))) cs)))
         (if (null? bad) '()
             (list (format "H6: node ~a has change rows in another account's feed" name)))))))

  ;; forest-breaks : (Listof Row) -> (Listof String)
  ;; Every row of nodes held to the tree's laws, by this walk alone (not the
  ;; store's ancestors): P8, a purged row has no parent, and no row is under
  ;; a purged one; P3, a parent is a row of the same owner; P2, its kind
  ;; may hold the row's (may-contain?); P1, from every row a walk up reaches
  ;; a root, in no more steps than there are rows.
  (define (forest-breaks rows)
    (let ((by (make-id-table)) (limit (length rows)))
      (for-each (lambda (r) (hashtable-set! by (n-id r) r)) rows)
      (fold-right
       (lambda (r acc)
         (let* ((p (n-parent r))
                (pr (and p (hashtable-ref by p #f)))
                (name (id-text (n-id r))))
           (append
            (cond ((not p) '())
                  ((equal? (n-state r) "purged")
                   (list (format "P8: purged node ~a has the parent ~a" name (id-text p))))
                  ((not pr) (list (format "P3: node ~a's parent ~a is no row" name (id-text p))))
                  ((not (bytevector=? (n-owner pr) (n-owner r)))
                   (list (format "P3: node ~a of ~a is under ~a's node ~a" name (account-label (n-owner r))
                                 (account-label (n-owner pr)) (id-text p))))
                  ((equal? (n-state pr) "purged")
                   (list (format "P3, P8: node ~a is under the purged node ~a" name (id-text p))))
                  ((not (may-contain? (n-kind pr) (n-kind r)))
                   (list (format "P2: node ~a, a ~a, is under ~a, a ~a" name (n-kind r) (id-text p) (n-kind pr))))
                  (else '()))
            (if (let walk ((x r) (k 0))
                  (let ((q (n-parent x)))
                    (cond ((not q) #t)
                          ((>= k limit) #f)
                          (else (let ((qr (hashtable-ref by q #f))) (or (not qr) (walk qr (+ k 1))))))))
                '()
                (list (format "P1: the walk up from node ~a comes round and reaches no root" name)))
            acc)))
       '() rows)))

  ;; grouped : (Listof Row) (Row -> Bytevector) -> (Bytevector -> (Listof Row))
  ;; ROWS by the node NODE-OF names, each node's in the order given: one
  ;; pass, so a check of every node costs the rows once, not once a node.
  (define (grouped rows node-of)
    (let ((t (make-id-table)))
      (for-each (lambda (r) (hashtable-update! t (node-of r) (lambda (l) (cons r l)) '())) (reverse rows))
      (lambda (id) (hashtable-ref t id '()))))

  ;; always-breaks : Db -> (Listof String)
  (define (always-breaks db)
    (let* ((nodes (car db)) (snaps (cadr db)) (changes (caddr db))
           (snaps-of (grouped snaps s-node))
           (changes-of (grouped changes c-node)))
      (append
       (forest-breaks nodes)
       (fold-right (lambda (r acc)
                     (append (node-law-breaks r (snaps-of (n-id r)) (changes-of (n-id r))) acc))
                   '() nodes)
       (if (for-all (lambda (s) (find-node nodes (s-node s))) snaps) '()
           (list "H3': a snapshot whose node has no row"))
       (if (for-all (lambda (c) (find-node nodes (c-node c))) changes) '()
           (list "H4: a change row whose node has no row"))
       (fold-right (lambda (a acc)
                     (let ((seqs (map c-seq (filter (lambda (c) (bytevector=? (c-owner c) (macct-id a))) changes))))
                       (if (equal? seqs (from-to 1 (length seqs))) acc
                           (cons (format "H4: ~a's change numbers are ~a, not 1 to ~a" (macct-tag a) seqs (length seqs))
                                 acc))))
                   '() model-accounts))))

  ;; op-of : Event -> String     the change row's op an accepted write makes (L10)
  (define (op-of e)
    (case (event-kind e)
      ((put) (if (eq? (event-pre e) 'create) "create" "update"))
      ((restore) "restore")
      ((move) "move")
      (else (symbol->string (event-kind e)))))

  ;; key-breaks : Event String Db Db -> (Listof String)
  ;; H5: only the asking key's last_used may move, and only to now.
  (define (key-breaks e op db0 db1)
    (let ((asking (event-key e)) (now (event-now e)))
      (fold-right (lambda (k0 k1 acc)
                    (cond ((equal? k0 k1) acc)
                          ((and (bytevector=? (car k1) asking) (eqv? (caddr k1) now)) acc)
                          (else (cons (format "H5: an accepted ~a moved key ~a's last_used from ~a to ~a"
                                              op (key-label (car k0)) (caddr k0) (caddr k1))
                                      acc))))
                  '() (cadddr db0) (cadddr db1))))

  ;; rebuilt : Row (U Bytevector #f) Natural Natural -> Row     R under PARENT at REV, updated NOW
  (define (rebuilt r parent rev now)
    (list (n-id r) (n-owner r) (n-author r) (n-kind r) (n-title r) (n-type r) (n-props r) rev (n-created r)
          now (n-state r) parent))

  ;; bulk-breaks : Event Obs Db Db -> (Listof String)
  ;; An accepted bulk move, between the tables before and after: P16, the
  ;; node's own row as it was; P11, every row changed was a direct child of
  ;; the node, active or archived (T8), and is now under the new parent at
  ;; its next revision, updated the time, nothing else changed (P4); no row
  ;; made or lost; no snapshot touched; H1 and H4, one change row move for
  ;; each, the owner's next numbers, in the children's id order, and no
  ;; other; the answer's moved, the rows changed, and left, the rows under
  ;; the node after; and H5.
  (define (bulk-breaks e o db0 db1)
    (let* ((id (event-id e)) (now (event-now e)) (asker (account-id-of (event-tag e)))
           (name (id-text id)) (new (event-parent-id e))
           (rows0 (car db0)) (rows1 (car db1))
           (changed (filter (lambda (r1) (not (equal? (find-node rows0 (n-id r1)) r1))) rows1))
           (m0 (length (filter (lambda (c) (bytevector=? (c-owner c) asker)) (caddr db0))))
           (added (filter (lambda (c) (not (member c (caddr db0)))) (caddr db1)))
           (j (obs-json o))
           (moved (and (list? j) (assoc "moved" j) (cdr (assoc "moved" j))))
           (left (and (list? j) (assoc "left" j) (cdr (assoc "left" j)))))
      (append
       (if (equal? (find-node rows1 id) (find-node rows0 id)) '()
           (list (format "P16: a bulk move of ~a's children changed its own row" name)))
       (if (equal? (map n-id rows0) (map n-id rows1)) '()
           (list (format "H1: a bulk move of ~a's children made or lost a row" name)))
       (fold-right
        (lambda (r1 acc)
          (let ((r0 (find-node rows0 (n-id r1))) (child (id-text (n-id r1))))
            (append
             (cond ((not r0) '())
                   ((not (and (n-parent r0) (bytevector=? (n-parent r0) id)))
                    (list (format "P11: a bulk move of ~a's children changed ~a, which was no child of it" name child)))
                   ((not (member (n-state r0) '("active" "archived")))
                    (list (format "P11, T8: a bulk move of ~a's children moved ~a, which was ~a" name child (n-state r0))))
                   ((equal? r1 (rebuilt r0 new (+ 1 (n-rev r0)) now)) '())
                   (else (list (format "P4, P11: a bulk move of ~a's children left ~a as ~s, not under the new parent at its next revision with nothing else changed"
                                       name child r1))))
             acc)))
        '() changed)
       (if (equal? (cadr db0) (cadr db1)) '()
           (list (format "P4: a bulk move of ~a's children touched a snapshot" name)))
       (let ((want (map (lambda (r1 i) (list asker (+ m0 i) (n-id r1) (n-rev r1) "move" now))
                        (list-sort (lambda (x y) (bytevector<? (n-id x) (n-id y))) changed)
                        (from-to 1 (length changed)))))
         (if (and (equal? added want) (= (length (caddr db1)) (+ (length (caddr db0)) (length added)))) '()
             (list (format "H1, H4: a bulk move of ~a's children changed ~a rows; it adds a change row move for each, by id, numbered from ~a, and no other: it added ~a"
                           name (length changed) (+ m0 1) (length added)))))
       (if (eqv? moved (length changed)) '()
           (list (format "P11: a bulk move of ~a's children answers moved ~s; it changed ~a rows" name moved (length changed))))
       (let ((under (length (filter (lambda (r) (and (n-parent r) (bytevector=? (n-parent r) id))) rows1))))
         (if (eqv? left under) '()
             (list (format "P11: a bulk move of ~a's children answers left ~s; ~a rows are under it after" name left under))))
       (key-breaks e "bulk move" db0 db1))))

  ;; accepted-breaks : Event Obs Db Db -> (Listof String)
  ;; An accepted write, between the tables before and after: H1, H3', H4,
  ;; H6, H11, H15', H16, G3, G6, G9, G11, G12; the parent: a create's is
  ;; the one it named (T3), a move's the new one (P4), a purge leaves none
  ;; (P8), every other write keeps it (P15); and only the asking key's
  ;; last_used may move, to now. A bulk move is bulk-breaks'.
  (define (accepted-breaks e o db0 db1)
    (if (eq? (event-kind e) 'move-children)
        (bulk-breaks e o db0 db1)
        (one-node-breaks e db0 db1)))

  (define (one-node-breaks e db0 db1)
    (let* ((id (event-id e))
           (now (event-now e))
           (asker (account-id-of (event-tag e)))
           (name (id-text id))
           (op (op-of e))
           (r0 (find-node (car db0) id))
           (r1 (find-node (car db1) id)))
      (if (not r1)
          (list (format "H1: an accepted ~a left node ~a with no row" op name))
          (let* ((rev (n-rev r1))
                 (mine? (lambda (s) (bytevector=? (s-node s) id)))
                 (mine0 (filter mine? (cadr db0)))
                 (mine1 (filter mine? (cadr db1)))
                 (m0 (length (filter (lambda (c) (bytevector=? (c-owner c) asker)) (caddr db0))))
                 (want-change (list asker (+ m0 1) id rev op now))
                 (changes1 (caddr db1)))
            (append
             (if (= rev (+ 1 (if r0 (n-rev r0) 0))) '()
                 (list (format "H1: an accepted ~a moved node ~a from revision ~a to ~a" op name
                               (if r0 (n-rev r0) "none") rev)))
             (if (bytevector=? (n-owner r1) asker) '()
                 (list (format "H6: an accepted write by ~a leaves node ~a owned by ~a" (event-tag e) name
                               (account-label (n-owner r1)))))
             (if r0
                 (append (if (equal? (n-kind r1) (n-kind r0)) '()
                             (list (format "H11, G9: node ~a's kind went from ~s to ~s" name (n-kind r0) (n-kind r1))))
                         (if (equal? (n-created r1) (n-created r0)) '()
                             (list (format "H15', G9: node ~a's created went from ~a to ~a" name (n-created r0)
                                           (n-created r1))))
                         (if (equal? (n-author r1) (n-author r0)) '()
                             (list (format "G9: node ~a's author went from ~a to ~a" name (account-label (n-author r0))
                                           (account-label (n-author r1))))))
                 (append (if (equal? (n-kind r1) (content-kind (event-content e))) '()
                             (list (format "H11: node ~a was made of kind ~s, the create's ~s" name (n-kind r1)
                                           (content-kind (event-content e)))))
                         (if (equal? (n-created r1) now) '()
                             (list (format "H15': node ~a was made with created ~a, the time ~a" name (n-created r1) now)))))
             (if (equal? (n-updated r1) now) '()
                 (list (format "H15': node ~a's updated is ~a, not the ~a's time ~a" name (n-updated r1) op now)))
             (let ((p0 (and r0 (n-parent r0))) (p1 (n-parent r1)) (show-id (lambda (p) (if p (id-text p) "the top level"))))
               (cond ((member op '("create" "move"))
                      (if (equal? p1 (event-parent-id e)) '()
                          (list (format "~a: an accepted ~a left node ~a under ~a, not ~a" (if (string=? op "move") "P4" "T3")
                                        op name (show-id p1) (show-id (event-parent-id e))))))
                     ((string=? op "purge")
                      (if p1 (list (format "P8: a purge of ~a left its parent ~a" name (id-text p1))) '()))
                     ((equal? p1 p0) '())
                     (else (list (format "P15: an accepted ~a of ~a moved it from ~a to ~a" op name (show-id p0)
                                         (show-id p1))))))
             (if (equal? (but-node (car db1) id) (but-node (car db0) id)) '()
                 (list (format "H1: an accepted ~a of ~a changed another node's row" op name)))
             (if (equal? (filter (lambda (s) (not (mine? s))) (cadr db1)) (filter (lambda (s) (not (mine? s))) (cadr db0)))
                 '()
                 (list (format "H3': an accepted ~a of ~a changed another node's snapshots" op name)))
             (cond
              ((member op content-ops)
               (let ((added (filter (lambda (s) (= (s-rev s) rev)) mine1))
                     (kept (filter (lambda (s) (not (= (s-rev s) rev))) mine1))
                     (want-state (if r0 (n-state r0) "active")))
                 (append
                  (if (equal? kept mine0) '()
                      (list (format "H3': an accepted ~a of ~a changed, added or removed an earlier snapshot" op name)))
                  (if (not (= (length added) 1))
                      (list (format "H3': an accepted ~a of ~a left no snapshot at its revision ~a" op name rev))
                      (append (if (equal? (s-created (car added)) now) '()
                                  (list (format "H15': the new snapshot's created is ~a, not the write's time ~a"
                                                (s-created (car added)) now)))
                              (if (bytevector=? (s-author (car added)) asker) '()
                                  (list (format "H16: the new snapshot's author is ~a, not ~a"
                                                (account-label (s-author (car added))) (event-tag e))))))
                  (if (equal? (n-state r1) want-state) '()
                      (list (format "G12: an accepted ~a of ~a moved its state from ~a to ~a" op name want-state
                                    (n-state r1)))))))
              ((string=? op "purge")
               (append
                (if (null? mine1) '()
                    (list (format "G6: a purge of ~a left its snapshots ~a" name (map s-rev mine1))))
                (if (and (equal? (n-title r1) "") (equal? (n-props r1) "{}") (equal? (n-type r1) purged-type)
                         (equal? (n-state r1) "purged"))
                    '()
                    (list (format "G6: a purge of ~a left its row ~s" name
                                  (list (n-title r1) (n-type r1) (n-props r1) (n-state r1)))))))
              (else
               (let ((lands (if (string=? op "move")
                                (and r0 (n-state r0))
                                (symbol->string (caddr (assq (event-kind e) lifecycle-moves))))))
                 (append
                  (if (equal? mine1 mine0) '()
                      (list (format "G3: an accepted ~a of ~a wrote, changed or removed a snapshot: ~a before, ~a after"
                                    op name (map s-rev mine0) (map s-rev mine1))))
                  (if (and r0 (equal? (list (n-title r1) (n-type r1) (n-props r1)) (list (n-title r0) (n-type r0) (n-props r0))))
                      '()
                      (list (format "G11: an accepted ~a of ~a changed its content" op name)))
                  (if (equal? (n-state r1) lands) '()
                      (list (format "G3: an accepted ~a left ~a ~a, not ~a" op name (n-state r1) lands)))))))
             (if (and (= (length changes1) (+ 1 (length (caddr db0))))
                      (member want-change changes1)
                      (for-all (lambda (c) (member c changes1)) (caddr db0)))
                 '()
                 (list (format "H4: an accepted ~a adds one change row, (~a ~a ~a ~a ~s ~a); the rows before were ~a, after ~a"
                               op (event-tag e) (+ m0 1) name rev op now
                               (length (caddr db0)) (length changes1))))
             (key-breaks e op db0 db1))))))

  ;; unchanged-breaks : Event Natural Db Db -> (Listof String)
  ;; H5, G4, G13: a refused write, and any read, change nothing at all.
  (define (unchanged-breaks e status db0 db1)
    (let ((what (if (write-kind? (event-kind e))
                    (format "a refused ~a (~a)" (event-kind e) status)
                    (format "a read (~a)" status))))
      (fold-right (lambda (name t0 t1 acc)
                    (if (equal? t0 t1) acc (cons (format "H5, G13: ~a changed ~a" what name) acc)))
                  '() '("nodes" "revisions" "changes" "api_keys' last_used") db0 db1)))

  ;; other-breaks : Event Db Db -> (Listof String)
  ;; H6, G7: no request changes a row of the other account's.
  (define (other-breaks e db0 db1)
    (let* ((other (account-id-of (other-tag (event-tag e))))
           (theirs (lambda (db)
                     (let* ((nodes (filter (lambda (r) (bytevector=? (n-owner r) other)) (car db)))
                            (ids (make-id-table)))
                       (for-each (lambda (r) (hashtable-set! ids (n-id r) #t)) nodes)
                       (list nodes
                             (filter (lambda (s) (hashtable-ref ids (s-node s) #f)) (cadr db))
                             (filter (lambda (c) (bytevector=? (c-owner c) other)) (caddr db))
                             (filter (lambda (k) (bytevector=? (k-account k) other)) (cadddr db)))))))
      (if (equal? (theirs db0) (theirs db1)) '()
          (list (format "H6, G7: a request by ~a changed the rows of ~a" (event-tag e) (other-tag (event-tag e)))))))

  ;; db-law-breaks : Event Obs Db Db -> (Listof String)
  (define (db-law-breaks e o db0 db1)
    (let* ((status (obs-status o))
           (accepted? (and (write-kind? (event-kind e)) (memv status '(200 201 204)) #t)))
      (append (always-breaks db1)
              (if accepted? (accepted-breaks e o db0 db1) (unchanged-breaks e status db0 db1))
              (other-breaks e db0 db1))))

  ;;; The tables held to the model's world

  (define (model-node-rows w)
    (map (lambda (n)
           (let ((owner (account-id-of (mnode-tag n)))
                 (content (if (live? n)
                              (let ((s (node-top n))) (list (msnap-title s) (msnap-type s) (msnap-props s)))
                              (list "" purged-type "{}"))))
             (append (list (mnode-id n) owner owner (mnode-kind n))
                     content
                     (list (node-rev n) (mnode-created n) (mnode-updated n) (symbol->string (mnode-state n))
                           (mnode-parent n)))))
         (by-id (world-nodes w))))

  (define (model-snap-rows w)
    (apply append
           (map (lambda (n)
                  (map (lambda (s)
                         (list (mnode-id n) (msnap-revision s) (account-id-of (msnap-author s)) (msnap-title s)
                               (msnap-type s) (msnap-props s) (msnap-created s) (msnap-body s)))
                       (reverse (mnode-snaps n))))
                (by-id (world-nodes w)))))

  (define (model-change-rows w)
    (apply append
           (map (lambda (tag)
                  (map (lambda (c)
                         (list (account-id-of tag) (mchange-seq c) (mchange-node c) (mchange-revision c)
                               (mchange-op c) (mchange-created c)))
                       (world-changes-of w tag)))
                '(a b))))

  (define (model-key-rows w)
    (map (lambda (k) (list (mkey-id k) (account-id-of (mkey-tag k)) (mkey-last-used k))) (world-keys w)))

  ;; Column labels: which H or G a difference in that column breaks.
  (define node-columns
    '(("id" . "H1") ("owner" . "H6") ("author" . "H16") ("kind" . "H11") ("title" . "H2'")
      ("content_type" . "H2'") ("props" . "H2'") ("revision" . "H1, G3") ("created" . "H15', G9")
      ("updated" . "H15'") ("state" . "G3, G12") ("parent" . "P1 to P4, P8, P11, P15, P16")))
  (define snap-columns
    '(("node" . "H3'") ("revision" . "H3'") ("author" . "H16") ("title" . "H3'") ("content_type" . "H3'")
      ("props" . "H3'") ("created" . "H15'") ("body" . "H3'")))
  (define change-columns
    '(("owner" . "H4") ("seq" . "H4") ("node" . "H4") ("revision" . "H4") ("op" . "H4, L10") ("created" . "H4")))
  (define key-columns '(("id" . "H5") ("account" . "H5") ("last_used" . "H5")))

  ;; rows-breaks : World String (Listof Row) (Listof Row) (Row -> Any) Columns String -> (Listof String)
  ;; Every model row has its row in the database, column for column; the
  ;; database has no row the model has not. KEY-OF names a row.
  (define (rows-breaks w table want got key-of columns label)
    (if (equal? want got)
        '()
        (append
         (fold-right
          (lambda (m acc)
            (let ((r (find (lambda (r) (equal? (key-of r) (key-of m))) got)))
              (if (not r)
                  (cons (format "~a: ~a has no row ~a, which the model has" label table (row-text w m)) acc)
                  (append (fold-right (lambda (col mv rv acc)
                                        (if (equal? mv rv) acc
                                            (cons (format "~a: ~a ~a, column ~a: the model has ~a, the database ~a"
                                                          (cdr col) table (row-text w (key-of m)) (car col)
                                                          (show w mv) (show w rv))
                                                  acc)))
                                      '() columns m r)
                          acc))))
          '() want)
         (map (lambda (r) (format "~a: ~a has a row the model has not: ~a" label table (row-text w r)))
              (filter (lambda (r) (not (find (lambda (m) (equal? (key-of r) (key-of m))) want))) got))
         (if (equal? (map key-of want) (map key-of got)) '()
             (list (format "~a: ~a's rows are not the model's, or not in its order" label table))))))

  ;; model-breaks : World Db -> (Listof String)
  (define (model-breaks w db)
    (append
     (rows-breaks w "nodes" (model-node-rows w) (car db) (lambda (r) (list (n-id r))) node-columns "H1/H5")
     (rows-breaks w "revisions" (model-snap-rows w) (cadr db) (lambda (r) (list (s-node r) (s-rev r)))
                  snap-columns "H3'/H5")
     (rows-breaks w "changes" (model-change-rows w) (caddr db) (lambda (r) (list (c-owner r) (c-seq r)))
                  change-columns "H4")
     (rows-breaks w "api_keys" (model-key-rows w) (cadddr db) (lambda (r) (list (car r))) key-columns "H5")))

  ;;; One sequence

  ;; Verdict: seed steps requests cells aims report
  ;;   steps        requests the generator made
  ;;   requests     HTTP requests sent (a walk is several)
  ;;   cells, aims  (Listof (Pair Key Natural)): the (Found State Event)
  ;;                cells the model stepped, and what the generator aimed
  ;;                at and what came of it, with counts. An aim
  ;;                purged-<route>-own (or -other) counts a request that
  ;;                named a purged node's id, its owner's (or the other
  ;;                account's), and reached its job.
  ;;   report       #f when every request agreed; else the first difference
  ;;   style        deep (it began with the chain and the script), family
  ;;                (with the family), or plain
  ;; verdict-seed, verdict-steps, verdict-requests : Verdict -> Natural
  ;; verdict-cells : Verdict -> (Listof (Pair Cell Natural))
  ;; verdict-aims : Verdict -> (Listof (Pair Symbol Natural))
  ;; verdict-report : Verdict -> (U String #f)
  ;; verdict-style : Verdict -> Symbol
  (define-record-type verdict (fields seed steps requests cells aims report style))

  ;; tree-aims : World Event Expectation -> (Listof Symbol)
  ;; What the tree's rules looked at for E, by the model's own reading:
  ;;   verdict-<route>-<v>     each verdict judged, route create, move or
  ;;                           move-children; ok split into ok-top and
  ;;                           ok-parent, missing into missing-fresh,
  ;;                           missing-other and missing-purged (P12)
  ;;   pair-<parent>-<kind>    a create's or a move's kinds, once the
  ;;                           verdict reached the kind
  ;;   depth-63-<route>        a parent with 63 ancestors, passed by the depth
  ;;   depth-64-<route>        one with 64, refused for it
  ;;   loop-<where>-<route>    a loop by where the node kept out sits:
  ;;                           self, child, grandchild, deeper, at-64
  ;;   loop-above-cap-<route>  the node kept out above the 64th: too deep
  ;;   bulk-...                an accepted bulk move's outcome
  ;;   has-children-<state>    a purge refused for children, by their states
  ;;   purge-emptied-parent    a purge passed of a node that has had children
  ;;   move-same-parent, move-archived, move-into-archived,
  ;;   create-in-archived, move-trashed-would-pass (a trashed node's move
  ;;   refused, whose new parent would pass)
  (define (tree-aims w e x)
    (let* ((s (expectation-situation x))
           (kind (event-kind e))
           (route (if (eq? kind 'put) 'create kind))
           (v (situation-verdict s))
           (status (expectation-status x))
           (p (situation-parent s)))
      (append
       (if (and (situation-judged? s) v)
           (let ((pid (event-parent-id e)) (depth (situation-depth s)) (at (situation-loop-at s)))
             (append
              (list (sym "verdict-" route "-"
                         (case v
                           ((ok) (if pid "ok-parent" "ok-top"))
                           ((missing) (let ((n (world-node w pid)))
                                        (cond ((not n) "missing-fresh")
                                              ((not (live? n)) "missing-purged")
                                              (else "missing-other"))))
                           (else (symbol->string v)))))
              (if (and p (memq v '(ok wrong-kind too-deep)) (situation-kind s))
                  (list (sym "pair-" (mnode-kind p) "-" (situation-kind s)))
                  '())
              (cond ((and p (eq? v 'ok) (= depth 63)) (list (sym "depth-63-" route)))
                    ((and (eq? v 'too-deep) (= depth 64)) (list (sym "depth-64-" route)))
                    (else '()))
              (if (and (eq? v 'too-deep) at) (list (sym "loop-above-cap-" route)) '())
              (if (eq? v 'loop)
                  (list (sym "loop-" (cond ((= at 0) "self") ((= at 1) "child") ((= at 2) "grandchild")
                                           ((= at (+ most-ancestors 1)) "at-64") (else "deeper"))
                             "-" route))
                  '())))
           '())
       (if (and (eq? kind 'move-children) (eqv? status 200))
           (let* ((cs (situation-children s))
                  (fits (situation-by-kind s))
                  (fit? (lambda (c) (exists (lambda (f) (same-node? f c)) fits)))
                  (moving (filter (lambda (c) (memq (mnode-state c) movable-states)) fits)))
             (append (list (cond ((null? cs) 'bulk-no-children)
                                 ((null? moving) 'bulk-none-movable)
                                 ((= (length moving) (length cs)) 'bulk-all-move)
                                 (else 'bulk-some-move)))
                     (if (exists (lambda (c) (eq? (mnode-state c) 'trashed)) cs) '(bulk-stay-state) '())
                     (if (exists (lambda (c) (and (eq? (mnode-state c) 'trashed) (fit? c))) cs)
                         '(bulk-stay-state-fits)
                         '())
                     (if (exists (lambda (c) (and (memq (mnode-state c) movable-states) (not (fit? c)))) cs)
                         '(bulk-stay-kind)
                         '())))
           '())
       (if (and (eq? kind 'purge) (equal? (expectation-code x) "has_children"))
           (let ((states (map mnode-state (situation-children s))))
             (append (map (lambda (st) (sym "has-children-" st)) (filter (lambda (st) (memq st states)) live-states))
                     (if (memq 'active states) '() '(has-children-none-active))))
           '())
       (if (and (eq? kind 'purge) (eqv? status 204) (member (event-id e) (world-held w))) '(purge-emptied-parent) '())
       (if (and (eq? kind 'move) (eqv? status 200))
           (let ((own (own-node w (event-tag e) (event-id e))))
             (append (if (equal? (mnode-parent own) (event-parent-id e)) '(move-same-parent) '())
                     (if (eq? (mnode-state own) 'archived) '(move-archived) '())
                     (if (and p (eq? (mnode-state p) 'archived)) '(move-into-archived) '())))
           '())
       (if (and (eq? kind 'put) (eqv? status 201) p (eq? (mnode-state p) 'archived)) '(create-in-archived) '())
       (if (and (equal? (expectation-cells x) '((match trashed move))) (eq? v 'ok)) '(move-trashed-would-pass) '()))))

  (define (reset! store)
    (run-write store
               (lambda (tx)
                 (tx-execute! tx "DELETE FROM changes")
                 (tx-execute! tx "DELETE FROM revisions")
                 (tx-execute! tx "DELETE FROM nodes")
                 (tx-execute! tx "DELETE FROM api_keys")
                 (tx-execute! tx "DELETE FROM accounts")
                 (for-each (lambda (a)
                             (insert-account! tx (macct-id a) (macct-username a) (macct-email a)
                                              (macct-password-hash a) (macct-created a)))
                           model-accounts)
                 (for-each (lambda (k)
                             (insert-key! tx (mkey-id k) (account-id-of (mkey-tag k)) (mkey-label k)
                                          (secret-hash (mkey-secret k)) (mkey-created k)))
                           start-keys))))

  (define (attempt thunk)
    (guard (c (#t (list 'raised (describe c))))
      (list 'ok (thunk))))

  ;; guarded : String (-> (Listof String)) -> (Listof String)
  (define (guarded what thunk)
    (guard (c (#t (list (string-append what " raised: " (describe c)))))
      (thunk)))

  (define (hashtable->alist t)
    (let-values (((ks vs) (hashtable-entries t)))
      (map cons (vector->list ks) (vector->list vs))))

  (define (cells-text cells) (join (map cell-text cells) ", "))

  ;; route-name : Event -> Symbol     a PUT is a create or a replace; the rest their own
  (define (route-name e)
    (case (event-kind e)
      ((put) (if (eq? (event-pre e) 'create) 'create 'replace))
      (else (event-kind e))))

  ;; purged-aim : World Event -> (U Symbol #f)
  ;; purged-<route>-own or -other, when the request names a purged node's
  ;; id, its owner's or the other account's, and reaches its job: a
  ;; precondition of the right shape, or a read.
  (define (purged-aim w e)
    (let ((n (and (event-id e) (world-node w (event-id e)))))
      (and n (not (live? n))
           (not (memq (event-pre e) '(missing invalid)))
           (sym "purged-" (route-name e) "-" (if (eq? (mnode-tag n) (event-tag e)) "own" "other")))))

  ;; run-sequence : Store Twist Natural Boolean -> Verdict
  ;; The sequence SEED makes, on STORE, emptied first: a fresh app on it
  ;; (wrap-server around make-app, its wall clock set by the sequence), 60
  ;; to 87 generated requests, after the family on a family seed; or, on a
  ;; deep seed, the chain, the script and 10 to 20. TWIST is as-planned, or
  ;; a changed rule. TRACE? prints each request and its answer as it goes.
  (define (run-sequence store twist seed trace?)
    (let* ((rng (make-rng seed))
           (style (cond ((deep-seed? seed) 'deep) ((family-seed? seed) 'family) (else 'plain)))
           (n (if (eq? style 'deep) (+ 10 (rng-below! rng 11)) (+ 60 (rng-below! rng 28))))
           (t0 (+ 1795515226123 (rng-below! rng 100000)))
           (deep-tag (rng-pick! rng '(a b)))
           (total (+ n (case style ((deep) (+ chain-steps script-steps)) ((family) family-steps) (else 0))))
           (bodies (make-hashtable string-hash string=?))
           (now-cell (vector t0))
           (clock (step-clock 0 1))
           (h (wrap-server (make-app (store-reader store) (store-writer store)
                                     (lambda () (vector-ref now-cell 0))
                                     (byte-sequence) clock)
                           (lambda (line) #f) 10000 clock))
           (cells (make-hashtable equal-hash equal?))
           (aims (make-hashtable symbol-hash eq?))
           (requests 0)
           (log '()))

      (define (count! t k) (hashtable-update! t k (lambda (c) (+ c 1)) 0))

      (define (verdict steps report)
        (make-verdict seed steps requests (hashtable->alist cells) (hashtable->alist aims) report style))

      ;; event-at : World Natural Natural -> Event     step I's request
      (define (event-at w now i)
        (cond ((and (eq? style 'deep) (<= i chain-steps)) (chain-event rng w now deep-tag))
              ((and (eq? style 'deep) (<= i (+ chain-steps script-steps)))
               (or (script-event rng w now deep-tag (- i chain-steps)) (next-event rng w now)))
              ((and (eq? style 'family) (<= i family-steps))
               (or (family-event rng w now deep-tag i) (next-event rng w now)))
              (else (next-event rng w now))))

      ;; body-breaks : Obs -> (Listof String)
      ;; P12, and D7's one format: every refusal of one code in a sequence
      ;; has one body, so a parent's id tells nothing.
      (define (body-breaks o)
        (let ((code (obs-code o)))
          (if (and (string? code) (>= (obs-status o) 400))
              (let ((seen (hashtable-ref bodies code #f)) (j (sorted-json (obs-json o))))
                (cond ((not seen) (hashtable-set! bodies code j) '())
                      ((equal? seen j) '())
                      (else (list (format "P12: a refusal ~a has the body ~s; an earlier one ~s" code j seen)))))
              '())))

      (define (report i desc x o breaks)
        (string-append
         (format "seed ~a, step ~a: the sequence so far:\n" seed i)
         (apply string-append (map (lambda (l) (string-append "    " l "\n")) (reverse log)))
         (format "  this step: ~a\n" desc)
         (if x
             (format "  the model expects: ~a ~s, ETag ~s, stepping ~a~a~a\n"
                     (expectation-status x) (expectation-code x) (expectation-etag x)
                     (cells-text (expectation-cells x))
                     (if (expectation-clause x) (string-append " (" (expectation-clause x) ")") "")
                     (if (expectation-problem x) (string-append "; " (expectation-problem x)) ""))
             "")
         (if o
             (format "  the handlers answered: ~a ~s, ETag ~s, ~s\n" (obs-status o) (obs-code o) (obs-etag o)
                     (if (obs-items o) (list 'items (obs-items o)) (obs-json o)))
             "")
         (apply string-append (map (lambda (b) (string-append "  - " b "\n")) breaks))
         (format "  replay: TECHO_NODES_MODEL_SEED=~a\n" seed)))

      ;; step! : World Natural Event Db -> (U (Pair World Db) String)
      (define (step! w i e db0)
        (let* ((desc (describe-event w e t0))
               (x (expect twist w e)))
          (if (expectation-problem x)
              (report i desc x #f (list "the model cannot take this step"))
              (begin
                (vector-set! now-cell 0 (event-now e))
                (let ((seen (attempt (lambda () (observe h e)))))
                  (if (eq? (car seen) 'raised)
                      (report i desc x #f (list (string-append "the request raised: " (cadr seen))))
                      (let* ((o (cadr seen))
                             (w1 (expectation-world x))
                             (db (attempt (lambda () (db-now store))))
                             (breaks
                              (append (guarded "comparing the answer" (lambda () (answer-breaks x o)))
                                      (guarded "the answer's laws" (lambda () (law-breaks w e o)))
                                      (guarded "the refusals' bodies" (lambda () (body-breaks o)))
                                      (if (eq? (car db) 'raised)
                                          (list (string-append "reading the database raised: " (cadr db)))
                                          (append (guarded "the laws" (lambda () (db-law-breaks e o db0 (cadr db))))
                                                  (guarded "the model's tables"
                                                           (lambda () (model-breaks w1 (cadr db)))))))))
                        (set! requests (+ requests (obs-requests o)))
                        (for-each (lambda (c) (count! cells c)) (expectation-cells x))
                        (for-each (lambda (a) (count! aims a)) (event-aims e))
                        (for-each (lambda (a) (count! aims a)) (tree-aims w e x))
                        (let ((p (purged-aim w e))) (when p (count! aims p)))
                        (when (expectation-touched x) (count! aims 'last-used-set))
                        (when (and (write-kind? (event-kind e))
                                   (memv (expectation-status x) '(404 409 412))
                                   (touch-due? (world-key-last-used w (event-key e)) (event-now e)))
                          (count! aims 'refused-while-due))
                        (when (event-upper? e) (count! aims 'id-in-capitals))
                        (let ((line (format "~a. ~a -> ~a~a" i desc (obs-status o)
                                            (if (obs-code o) (format " ~a" (obs-code o)) ""))))
                          (set! log (cons line log))
                          (when trace?
                            (display (format "~a (the model: ~a, ~a)\n" line (expectation-status x)
                                             (cells-text (expectation-cells x))))))
                        (if (null? breaks)
                            (cons w1 (cadr db))
                            (report i desc x o breaks)))))))))

      (reset! store)
      (let ((db (attempt (lambda () (db-now store)))))
        (cond
         ((eq? (car db) 'raised) (verdict 0 (string-append "reading the database raised: " (cadr db))))
         ((pair? (model-breaks model-start (cadr db)))
          (verdict 0 (join (cons (format "seed ~a: the emptied file is not the model's start:" seed)
                                 (model-breaks model-start (cadr db)))
                           "\n  - ")))
         (else
          (let loop ((w model-start) (db0 (cadr db)) (now t0) (i 1))
            (if (> i total)
                (verdict total #f)
                (let* ((e (event-at w now i))
                       (r (step! w i e db0)))
                  (if (string? r)
                      (verdict i r)
                      (loop (car r) (cdr r) (event-now e) (+ i 1)))))))))))
)
