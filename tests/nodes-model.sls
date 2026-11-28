#!r6rs
;;; (nodes-model): the model-based test of nodes, ADR-0007's third layer,
;;; for tests/test-nodes-model.sps: D5's versioned write (slice 4, task 5a),
;;; the node lifecycle (slice 4b, task 4a), the tree (slice 5a, task 4a),
;;; links (slice 5b, task 4a), props and a Task's commands (slice 6, task
;;; 4a), and tags (slice 7a, task 4a). Test-only: it lives in tests/, which
;;; make test puts on Chez's library path.
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
;;; Links (slice 5b) are the brief's rules written again here too, never
;;; (techo links)' link-command nor the lifecycle's table: each account's
;;; set of links, each (source type target created), directed, one per
;;; triple, of the three types. A link's PUT or DELETE is 400 before any
;;; job for a type not of the three, a target that is no v7 id, a node
;;; linked to itself, or any If-Match or If-None-Match. Then a PUT: no
;;; live source of the account's is 404; no live target of its, 404; the
;;; link there, 200 and its stored created, nothing written; either end
;;; trashed, 409 wrong_state; else 201 and the link made. A DELETE: no
;;; source, 404; the link there, 204 and removed, whatever the states; else
;;; 404, the target never read. A link made or removed changes no node and
;;; no snapshot, and adds one change row on the source at its present
;;; revision, link or unlink. A purge removes every link of the node, both
;;; ways, and writes only its own row. A link list is the node's links one
;;; way (out by default), of one type or all, by type name then the other
;;; node's id, each item that node as the nodes list shows it; paged by
;;; <type>:<id>, an after of another type than ?type= the 400. Each link's
;;; request names the cell of link-command it would step, by the model's
;;; reading (the source's state, the target's, the event, whether the link
;;; is there), which the suite counts with the outcomes (link-aims).
;;;
;;; Props and a Task's commands (slice 6) are the plan's rules written
;;; again here too, never (techo props), (techo tasks), (techo contact) or
;;; (techo when). Props are data, not a second parser: props-corpus is a
;;; list of values as a request sends them, each with its verdict for each
;;; of the five kinds written out by hand (the canonical text stored, or a
;;; 400, or a 413; for a Task, the members it claims). A PUT's props are
;;; judged before its job for the kind it names, or for every kind when a
;;; replace names none (400 when none takes them, 413 when one finds them
;;; over the cap); in the job, after 404, 412, wrong_state and kind_fixed,
;;; a replace that named no kind is the 400 when the stored kind refuses
;;; them, and a Task's claim of a status or a closed other than its own is
;;; 409 status_fixed. A replace with no props keeps them (P11). A create of
;;; a Task takes its status, and when it is not TODO the closed given or
;;; the write's time (P14). A restore copies the snapshot's props, but a
;;; Task keeps its status and closed (P10). POST done, wontdo and reopen:
;;; 404, 412, wrong_state, not_a_task, then the model's task table (P7):
;;; done from TODO or WONTDO, wontdo from TODO or DONE, reopen from DONE or
;;; WONTDO, else 409 wrong_status; closed set when a Task leaves TODO, kept
;;; between DONE and WONTDO, removed by a reopen. A command is a write of
;;; content: a snapshot with the title, body and content type copied, and a
;;; change row named for it. Each node's props are held as their canonical
;;; text, with a Task's status, closed, deadline and scheduled; an answer
;;; shows the text's value with a Task's status filled in, TODO when none
;;; is stored (P9). A plain seed's file first holds some Tasks written
;;; straight into its tables, as a file from before this slice: props {}.
;;;
;;; Tags (slice 7a) are the plan's rules written again here too, never
;;; (techo tags) nor (techo chars): each node's present tags (its rows),
;;; and each snapshot's as they were when it was written. A tag is data,
;;; not a second fold: tag-corpus is a list of tags as a client sends
;;; them, each with its stored form or 'invalid written out by hand; every
;;; stored form is an entry that stores itself, so a tag read back is in
;;; the corpus (L1), and every tag a row or an answer holds must be one of
;;; its stored forms (L2). A PUT's tags: no member is none on a create and
;;; keeps the node's on a replace (G2); more than 50 as sent, a refused
;;; entry, or a value that is no array of strings, is 400 before the job,
;;; after the props' 400 and before their 413, with no write job (L10);
;;; else the stored forms, sorted, each once. A restore copies the
;;; snapshot's tags as stored, so one from before migration 7 clears them
;;; (L11); a Task's command keeps the node's; every content write's
;;; snapshot holds the rows (L3); a purge drops them (L7). A list's ?tag=
;;; takes at most 10 as sent, each by the corpus; a + in a query is a space
;;; and bad UTF-8 one U+FFFD, data too (query-raw-cases). GET /v1/tags is
;;; the account's tags by code point, each counted over every state and
;;; stopped at 1,000 (H6). POST /v1/tags/rename and /remove: a
;;; precondition 400, a media type 415, a body over 16 KiB 413, no JSON
;;; invalid_json, not exactly its members 400, all before the job; else a
;;; step: the first min(500, carriers) by id, in any live state (L13), each
;;; at its next revision with the owner's next change row tags, in id
;;; order, no snapshot; {WORD: n, "left": m}, no ETag, never a 404.
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
;;; their four keys through the store, generates a seeded sequence of 97 to
;;; 140 requests (xorshift32; 88 to 127 before slice 7a's tags took a tenth
;;; of them, 82 to 119 before slice 6's commands took a tenth, 60 to 87
;;; before links took a quarter), and sends each as raw HTTP through make-app inside wrap-server,
;;; in a test host, with a wall clock the sequence steps. After every
;;; request it compares the status, the code of a refusal, the ETag,
;;; Location and the body of a 2xx (every page of a list, for the ?state=,
;;; ?parent= and ?tag= asked, of a link list and of the tags list, the
;;; tags list's first tag looked for by the filter in each state, L8) with
;;; the model's, and the write
;;; jobs it made with the model's (R15: none for a refusal before the job);
;;; holds the answer to laws that need no model (G14, H6, H14,
;;; H14', H18', and P12: every refusal of one code in a sequence has one
;;; body); reads the four tables and every key's last_used whole, and holds
;;; them to laws that need no model (H1 to H6, H11, H2', H3', H15'', H16,
;;; G3', G6', G7', G9, G11, G12, G16, P4, P15, P16, H1', H4'', Q9, and the
;;; bulk move's, against the tables before the request; P1, P2, P3 and P8
;;; on every row, by its own walk; Q1, Q2 and Q8 on every link; R1, R2, R5
;;; and R9 on every row's and snapshot's props, by its own reading of the
;;; text; G11', R4, R13 and R14 on an accepted write's; L2, L3, L7 and L9
;;; on every tag row and snapshot; L3, L4 and L11 on an accepted write's,
;;; and no other node's tags changed; L5, L6 and L13 on a step's, with
;;; H1, H2', H3', H4 and G6' restated for many nodes and no snapshot, as
;;; the bulk move's are) and to the model's world, its links, props and
;;; tags among it. The first request with a
;;; difference ends the sequence with a report that replays from its seed.
;;; A plain seed (neither deep, a family nor linked) first writes the Tasks
;;; seed-world makes straight into the emptied file, as rows from before
;;; slice 6, and the model starts from that world.
;;;
;;; One seed in fifteen (a multiple of fifteen) is deep: it first makes a
;;; chain of 65 Projects by creates with a parent, one under the last, so
;;; the 65th is made under a parent with 63 ancestors and a 66th is refused
;;; under one with 64; then a short script of creates, moves and bulk
;;; moves reaches the boundary from both sides, a loop at the 64th ancestor
;;; and one above it; then 14 to 27 requests (a request in a deep world
;;; costs four of another's). One in five (ending in 3 or 7) is a family:
;;; it first makes a mixed tree (family-event), so that bulk moves meet
;;; children of every state and kind and loops close two and three levels
;;; down; then its 88 to 127. One in five more (ending in 1 or 9) is
;;; linked: it first makes a hub of links both ways (linked-event), so that
;;; link lists page and a purge takes links both ways; then its 88 to 127.
;;; One in fifty (ending in 04 or 54) is a crowd: its file first holds 501
;;; to 560 Notes carrying crowd (1,001 to 1,060 for 04), in every state,
;;; written straight in (crowd-world); then a script renames crowd and
;;; removes throng, 500 a step, until left is 0, a carrier added and one
;;; restored between steps, with the tags list and the filter between
;;; them; then 14 to 27 requests. So a step leaves left above 0, a rename
;;; takes several calls, and a count stops at 1,000.
;;;
;;; No sequence reaches a bulk move's cap of 1,000 children: the route
;;; suite holds it.
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
          link-type-names make-link-spec make-link-event world-links
          mlink-tag mlink-source mlink-type mlink-target mlink-created
          run-sequence verdict-seed verdict-steps verdict-requests verdict-cells
          verdict-aims verdict-report verdict-style deep-seed? family-seed? linked-seed?
          task-events props-corpus entry-name entry-sent entry-verdict props-entry claim
          good-whens corpus-self-breaks corpus-breaks msnap-props mprops-text mprops-status
          mprops-closed expectation-jobs
          ;; slice 7a
          make-tagged-content mnode-tags msnap-tags tag-corpus tag-named tag-entry-name tag-entry-sent
          tag-entry-stored numbered-sent make-filter-spec make-filter-event
          make-tags-list-spec make-command-spec make-tag-event crowd-seed? tag-corpus-self-breaks
          tag-corpus-breaks query-raw-cases)
  (import (rnrs)
          (only (chezscheme) format)
          (only (chez-sqlite3) sql-null?)
          (only (chez-sodium) blake2b)
          (only (jsonparse easy) json->string string->json)
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
  ;; sorted-json : Any -> Any     an object's members by name, an object inside it too
  (define (sorted-json j)
    (if (and (list? j) (for-all (lambda (p) (and (pair? p) (string? (car p)))) j))
        (sorted (map (lambda (p) (cons (car p) (sorted-json (cdr p)))) j))
        j))

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

  ;; MProps: a snapshot's props (slice 6): text status closed deadline scheduled
  ;;   text       the canonical text stored, the model's
  ;;   status     a Task's status, "TODO", "DONE" or "WONTDO"; #f for another kind
  ;;   closed     a Task's closed, milliseconds, or #f
  ;;   deadline, scheduled   a Task's Whens as stored, or #f
  ;; mprops-text : MProps -> String
  ;; mprops-status : MProps -> (U String #f)
  ;; mprops-closed : MProps -> (U Natural #f)
  (define-record-type mprops (fields text status closed deadline scheduled))

  ;; plain-props : String -> MProps     a Project's, a Journal's, a Note's or a Contact's text
  (define (plain-props text) (make-mprops text #f #f #f #f))

  ;; task-text : String (U Natural #f) (U String #f) (U String #f) -> String
  ;; A Task's canonical text, in the model's own writing: status (but TODO,
  ;; the default, is not stored), closed, deadline, scheduled, each when
  ;; there, in that order, with no white space. A When is ASCII digits and
  ;; punctuation: it needs no escape.
  (define (task-text status closed deadline scheduled)
    (string-append
     "{"
     (join (append (if (string=? status "TODO") '() (list (string-append "\"status\":\"" status "\"")))
                   (if closed (list (string-append "\"closed\":" (number->string closed))) '())
                   (if deadline (list (string-append "\"deadline\":\"" deadline "\"")) '())
                   (if scheduled (list (string-append "\"scheduled\":\"" scheduled "\"")) '()))
           ",")
     "}"))

  ;; task-props : String (U Natural #f) (U String #f) (U String #f) -> MProps
  (define (task-props status closed deadline scheduled)
    (make-mprops (task-text status closed deadline scheduled) status closed deadline scheduled))

  ;; empty-props : String -> MProps     a node of KIND's props stored {}: a Task's are TODO (P9)
  (define (empty-props kind) (if (string=? kind "task") (task-props "TODO" #f #f #f) (plain-props "{}")))

  ;; MSnap: revision title body type props created author (a tag) tags
  ;; msnap-revision, msnap-created : MSnap -> Natural
  ;; msnap-title, msnap-body, msnap-type : MSnap -> String
  ;; msnap-props : MSnap -> MProps
  ;; msnap-tags : MSnap -> (Listof String)     the node's tags as they were when it was
  ;;   written (slice 7a), stored forms, sorted by code point; '() in a
  ;;   snapshot from before migration 7
  (define-record-type msnap (fields revision title body type props created author tags))

  ;; MNode: id tag label kind created state revision updated snaps (newest first) parent
  ;; mnode-kind : MNode -> String
  ;; mnode-state : MNode -> Symbol      active, archived, trashed or purged
  ;; mnode-created, mnode-revision, mnode-updated : MNode -> Natural
  ;; mnode-snaps : MNode -> (Listof MSnap)
  ;; mnode-parent : MNode -> (U Bytevector #f)     the node it is under; #f at the top level
  ;; mnode-tags : MNode -> (Listof String)
  ;;   its present tags (slice 7a): its rows in node_tags, stored forms,
  ;;   sorted by code point. After a content write they are its newest
  ;;   snapshot's; a step of a tag's rename or removal changes them and
  ;;   writes no snapshot (L3)
  (define-record-type mnode (fields id tag label kind created state revision updated snaps parent tags))

  ;; MChange: seq node revision op created
  ;; mchange-seq, mchange-revision, mchange-created : MChange -> Natural
  ;; mchange-node : MChange -> Bytevector
  ;; mchange-op : MChange -> String
  (define-record-type mchange (fields seq node revision op created))

  ;; MLink: tag source type target created     slice 5b's link, of TAG's
  ;; mlink-tag : MLink -> Tag     the account that owns it
  ;; mlink-source, mlink-target : MLink -> Bytevector
  ;; mlink-type : MLink -> String
  ;; mlink-created : MLink -> Natural     its first PUT's time (Q15)
  (define-record-type mlink (fields tag source type target created))

  ;; World: nodes (in the order made), keys (as start-keys, each last_used
  ;; as now), changes (an alist of tag to that owner's rows, oldest first),
  ;; held (the id of every node that has had a child, for the generator and
  ;; the counts alone: no answer depends on it), links (each account's, in
  ;; the order made), seeded (the id of every Task a plain seed wrote
  ;; straight into its file, for the generator and the counts alone)
  ;; world-nodes : World -> (Listof MNode)
  ;; world-links : World -> (Listof MLink)
  (define-record-type world (fields nodes keys changes held links seeded))

  ;; model-start : World      no node, no change, no key used, no link
  (define model-start (make-world '() start-keys '((a) (b)) '() '() '()))

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

  (define write-kinds (append '(put restore) lifecycle-events '(move move-children done wontdo reopen)))
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
                  (if (and p (not (member p (world-held w)))) (cons p (world-held w)) (world-held w)))
                (world-links w) (world-seeded w)))

  ;; world-with-change : World Tag Bytevector Natural String Natural -> World
  ;; The owner's next change row: one more than the rows it has (H4).
  (define (world-with-change w tag id rev op now)
    (let* ((old (world-changes-of w tag))
           (c (make-mchange (+ 1 (length old)) id rev op now)))
      (make-world (world-nodes w) (world-keys w)
                  (map (lambda (p) (if (eq? (car p) tag) (cons tag (append old (list c))) p))
                       (world-changes w))
                  (world-held w)
                  (world-links w) (world-seeded w))))

  (define (world-touched w id now)
    (make-world (world-nodes w)
                (map (lambda (k)
                       (if (bytevector=? (mkey-id k) id)
                           (make-mkey (mkey-id k) (mkey-tag k) (mkey-label k) (mkey-secret k)
                                      (mkey-created k) now)
                           k))
                     (world-keys w))
                (world-changes w)
                (world-held w)
                (world-links w) (world-seeded w)))

  ;; world-with-links : World (Listof MLink) -> World     W with LINKS as its links
  (define (world-with-links w links)
    (make-world (world-nodes w) (world-keys w) (world-changes w) (world-held w) links (world-seeded w)))

  ;; world-with-seeded : World Bytevector -> World     W with ID among the seeded
  (define (world-with-seeded w id)
    (make-world (world-nodes w) (world-keys w) (world-changes w) (world-held w) (world-links w)
                (cons id (world-seeded w))))

  ;; seeded? : World Bytevector -> Boolean     a Task a plain seed wrote straight into its file
  (define (seeded? w id) (and (member id (world-seeded w)) #t))

  ;; with-snap : MNode String String String MProps (Listof String) Natural -> MNode
  ;; N at its next revision, the content given as its newest snapshot, made
  ;; NOW, by its owner, with TAGS as its present tags and the snapshot's
  ;; (L3); its state kept (G12).
  (define (with-snap n title body type props tags now)
    (let ((rev (+ 1 (node-rev n))))
      (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                  (mnode-state n) rev now
                  (cons (make-msnap rev title body type props now (mnode-tag n) tags) (mnode-snaps n))
                  (mnode-parent n) tags)))

  ;; with-state : MNode Symbol Natural -> MNode
  ;; N at its next revision in STATE, NOW, with no new snapshot (L4), under
  ;; its parent still (P15).
  (define (with-state n state now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                state (+ 1 (node-rev n)) now (mnode-snaps n) (mnode-parent n) (mnode-tags n)))

  ;; with-parent : MNode (U Bytevector #f) Natural -> MNode
  ;; N at its next revision under PARENT (#f: the top level), NOW, with no
  ;; new snapshot, its state and content kept (T4, P4).
  (define (with-parent n parent now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                (mnode-state n) (+ 1 (node-rev n)) now (mnode-snaps n) parent (mnode-tags n)))

  ;; emptied : MNode Natural -> MNode
  ;; N purged (L7): its next revision, NOW, no snapshot left, no parent
  ;; (P8) and no tag (the plan's L7: a purge deletes its rows).
  (define (emptied n now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                'purged (+ 1 (node-rev n)) now '() #f '()))

  ;; with-retag : MNode (Listof String) Natural -> MNode
  ;; N touched by a step of a tag's rename or removal (G8, L5): its next
  ;; revision, NOW, TAGS its present tags; no new snapshot, its state,
  ;; parent and content kept.
  (define (with-retag n tags now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                (mnode-state n) (+ 1 (node-rev n)) now (mnode-snaps n) (mnode-parent n) tags))

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

  ;;; The links' rules, in the model's own words (slice 5b: K1, K2, K6, K8)

  ;; link-type-names : (Listof String)     K1's three, written here, not imported
  (define link-type-names '("related" "mentions" "blocks"))

  ;; linkable-states : (Listof Symbol)
  ;; K6: a link is made only when both ends are in these; a trashed end
  ;; refuses it. A link is removed from any live state.
  (define linkable-states '(active archived))

  (define (same-link? l tag source type target)
    (and (eq? (mlink-tag l) tag) (bytevector=? (mlink-source l) source) (string=? (mlink-type l) type)
         (bytevector=? (mlink-target l) target)))

  ;; link-in : World Tag Bytevector String Bytevector -> (U MLink #f)     TAG's link, if there
  (define (link-in w tag source type target)
    (find (lambda (l) (same-link? l tag source type target)) (world-links w)))

  ;; links-at : World Bytevector -> (Listof MLink)     every link with ID at either end
  (define (links-at w id)
    (filter (lambda (l) (or (bytevector=? (mlink-source l) id) (bytevector=? (mlink-target l) id))) (world-links w)))

  ;; world-without-links-at : World Bytevector -> World
  ;; K7: a purge takes every link of the node, both ways, and no other.
  (define (world-without-links-at w id)
    (world-with-links w (filter (lambda (l) (not (or (bytevector=? (mlink-source l) id)
                                                     (bytevector=? (mlink-target l) id))))
                                (world-links w))))

  ;; link<? : String Bytevector String Bytevector -> Boolean
  ;; A link page's order (K3, the review): the type's name, then the other
  ;; node's id, unsigned byte by byte.
  (define (link<? t1 id1 t2 id2)
    (or (string<? t1 t2) (and (string=? t1 t2) (bytevector<? id1 id2))))

  ;;; Props, as data (slice 6)
  ;;;
  ;;; Each entry is a props value as a request sends it, and its verdict
  ;;; for each of the five kinds, written out by hand: never computed by
  ;;; the code under test, nor by a parser of the model's own. A text is
  ;;; written with ' for ", and q turns it to JSON: no text here holds an
  ;;; apostrophe.

  ;; q : String -> String     ' to ", nothing else
  (define (q s) (list->string (map (lambda (c) (if (char=? c #\') #\" c)) (string->list s))))

  ;; Claim: what a Task's props value claims, each member as sent and
  ;; checked, or #f: (claim status closed deadline scheduled)
  ;; claim : (U String #f) (U Natural #f) (U String #f) (U String #f) -> Claim
  (define (claim status closed deadline scheduled) (list 'claim status closed deadline scheduled))
  (define (claim? v) (and (pair? v) (eq? (car v) 'claim)))
  (define (claim-status v) (list-ref v 1))
  (define (claim-closed v) (list-ref v 2))
  (define (claim-deadline v) (list-ref v 3))
  (define (claim-scheduled v) (list-ref v 4))

  ;; Verdict = (U String Claim 'invalid 'too-large)
  ;;   a String   a Project's, a Journal's, a Note's or a Contact's canonical
  ;;              text, as it is stored
  ;;   a Claim    a Task's: what the value says of status, closed, deadline
  ;;              and scheduled; the text stored is the model's to make
  ;;              (task-text), as a create or a replace and the stored
  ;;              status decide
  ;;   'invalid   the 400
  ;;   'too-large valid, but over 4,096 bytes as stored: the 413
  ;; taken? : Verdict -> Boolean
  (define (taken? v) (or (string? v) (claim? v)))

  ;; Entry: name sent verdicts
  ;;   name      for reports and counts
  ;;   sent      the props' JSON text, exactly as the request sends it
  ;;   verdicts  each kind's Verdict, in kinds' order
  ;; entry-name : Entry -> Symbol
  ;; entry-sent : Entry -> String
  (define-record-type entry (fields name sent verdicts))

  ;; props-entry : Symbol String (U String Claim Symbol) ... -> Entry
  ;; NAME and the text SENT (' for "), then a kind and its verdict by turns,
  ;; a text again with ' for "; a kind not named refuses the value: 'invalid.
  (define (props-entry name sent . pairs)
    (let loop ((ps pairs) (acc '()))
      (if (null? ps)
          (make-entry name (q sent)
                      (map (lambda (k) (cons k (let ((p (assoc k acc))) (if p (cdr p) 'invalid)))) kinds))
          (loop (cddr ps) (cons (cons (car ps) (let ((v (cadr ps))) (if (string? v) (q v) v))) acc)))))

  ;; entry-verdict : Entry String -> Verdict
  (define (entry-verdict e kind) (cdr (assoc kind (entry-verdicts e))))

  ;; good-whens : (Listof String)
  ;; Every When a taken entry holds, each checked by hand to be one of the
  ;; three forms and a real date (R9 by the corpus): 29 February 2024 and
  ;; 2000 are leap days; 0001 and 9999 the years' ends.
  (define good-whens
    '("2026-12-01" "2026-12-02" "2024-02-29" "0001-01-01" "2026-12-01T15:00" "2000-02-29T23:59"
      "2026-11-30T09:00" "2026-12-01T20:00:00Z" "9999-12-31T23:59:59Z"))

  ;; capped-contact : Natural Boolean -> String
  ;; A Contact's props of five emails whose canonical text is exactly
  ;; BYTES bytes of UTF-8, four of the labels 400 e-acutes (two bytes, one
  ;; character each), the fifth padded with x. SENT? #t: as a request sends
  ;; it, the emails in the reverse order, each entry's label first, every
  ;; e-acute as é: six bytes where the store has two. #f: the canonical
  ;; text, written here by the model, not computed by the code under test.
  (define (capped-contact bytes sent?)
    (let* ((acute (make-string 400 #\xe9))
           (entry (lambda (i label)
                    (let ((key (string-append "e" (number->string i)))
                          (address (string-append "a" (number->string i) "@example.com")))
                      (if sent?
                          (string-append "'" key "':{'label':'" label "','address':'" address "'}")
                          (string-append "'" key "':{'address':'" address "','label':'" label "'}")))))
           (escaped (lambda (s) (apply string-append (map (lambda (c) (if (char=? c #\xe9) "\\u00e9" (string c)))
                                                          (string->list s)))))
           (text (lambda (pad)
                   (let ((labels (list acute acute acute acute (make-string pad #\x))))
                     (q (string-append "{'emails':{"
                                       (join (map (lambda (i l) (entry i (if sent? (escaped l) l)))
                                                  (if sent? '(5 4 3 2 1) '(1 2 3 4 5))
                                                  (if sent? (reverse labels) labels))
                                             ",")
                                       "}}")))))
           (base (bytevector-length (string->utf8 (capped-contact-canonical acute 0)))))
      (text (- bytes base))))

  ;; capped-contact-canonical : String Natural -> String     the canonical text, PAD x's in the fifth label
  (define (capped-contact-canonical acute pad)
    (let ((entry (lambda (i label)
                   (string-append "\"e" (number->string i) "\":{\"address\":\"a" (number->string i)
                                  "@example.com\",\"label\":\"" label "\"}"))))
      (string-append "{\"emails\":{"
                     (join (map entry '(1 2 3 4 5) (list acute acute acute acute (make-string pad #\x))) ",")
                     "}}")))

  ;; at-cap-text, over-cap-text : String     the canonical texts of 4,096 and 4,097 bytes
  (define at-cap-text (capped-contact 4096 #f))
  (define over-cap-text (capped-contact 4097 #f))

  ;; The plan's rich contact: a name, three emails, three phones, two
  ;; addresses, an organisation, a title, pronouns, two links, a birthday.
  ;; Sent in no order and with an explicit default (kind individual).
  (define rich-sent
    (string-append
     "{'speakToAs':{'pronouns':{'p1':{'pronouns':'she/her'}}},"
     "'emails':{'work':{'pref':1,'address':'ada@analytical.example','contexts':{'work':true}},"
     "'home':{'address':'ada@home.example','contexts':{'private':true}},"
     "'old':{'label':'retired','address':'a.lovelace@old.example'}},"
     "'name':{'isOrdered':true,'components':[{'kind':'title','value':'Countess'},{'value':'Augusta','kind':'given'},"
     "{'kind':'given2','value':'Ada'},{'kind':'surname','value':'King'},{'kind':'generation','value':'II'}]},"
     "'phones':{'mobile':{'number':'+44 20 7946 0000','features':{'text':true,'mobile':true},'pref':1},"
     "'desk':{'contexts':{'work':true},'number':'+44 20 7946 0001','features':{'voice':true}},"
     "'fax':{'number':'+44 20 7946 0002','label':'office fax','features':{'fax':true}}},"
     "'addresses':{'work':{'contexts':{'work':true},'full':'Analytical Engine Works\\nMarylebone','countryCode':'GB'},"
     "'home':{'pref':1,'countryCode':'GB','contexts':{'private':true},'components':[{'kind':'number','value':'12'},"
     "{'kind':'name','value':'St James Square'},{'kind':'locality','value':'London'},{'kind':'postcode','value':'SW1Y 4LB'}]}},"
     "'organizations':{'ae':{'units':[{'name':'Programming'}],'name':'Analytical Engines'}},"
     "'titles':{'t1':{'organizationId':'ae','name':'Programmer'}},"
     "'links':{'site':{'label':'site','uri':'https://ada.example/'},'card':{'kind':'contact','uri':'https://ada.example/card.vcf'}},"
     "'anniversaries':{'born':{'date':{'day':10,'month':12,'year':1815},'kind':'birth'}},"
     "'kind':'individual'}"))

  (define rich-canonical
    (string-append
     "{'name':{'components':[{'kind':'title','value':'Countess'},{'kind':'given','value':'Augusta'},"
     "{'kind':'given2','value':'Ada'},{'kind':'surname','value':'King'},{'kind':'generation','value':'II'}],'isOrdered':true},"
     "'organizations':{'ae':{'name':'Analytical Engines','units':[{'name':'Programming'}]}},"
     "'titles':{'t1':{'name':'Programmer','organizationId':'ae'}},"
     "'emails':{'home':{'address':'ada@home.example','contexts':{'private':true}},"
     "'old':{'address':'a.lovelace@old.example','label':'retired'},"
     "'work':{'address':'ada@analytical.example','contexts':{'work':true},'pref':1}},"
     "'phones':{'desk':{'number':'+44 20 7946 0001','features':{'voice':true},'contexts':{'work':true}},"
     "'fax':{'number':'+44 20 7946 0002','features':{'fax':true},'label':'office fax'},"
     "'mobile':{'number':'+44 20 7946 0000','features':{'mobile':true,'text':true},'pref':1}},"
     "'addresses':{'home':{'components':[{'kind':'number','value':'12'},{'kind':'name','value':'St James Square'},"
     "{'kind':'locality','value':'London'},{'kind':'postcode','value':'SW1Y 4LB'}],'countryCode':'GB','contexts':{'private':true},'pref':1},"
     "'work':{'countryCode':'GB','full':'Analytical Engine Works\\nMarylebone','contexts':{'work':true}}},"
     "'anniversaries':{'born':{'kind':'birth','date':{'year':1815,'month':12,'day':10}}},"
     "'links':{'card':{'uri':'https://ada.example/card.vcf','kind':'contact'},'site':{'uri':'https://ada.example/','label':'site'}},"
     "'speakToAs':{'pronouns':{'p1':{'pronouns':'she/her'}}}}"))

  ;; a-claim : the Task's verdict of a value that claims nothing: {}
  (define no-claim (claim #f #f #f #f))

  ;; props-corpus : (Listof Entry)
  (define props-corpus
    (list
     ;; Every kind takes {}, and only {}: so a Project and a Journal take nothing else.
     (props-entry 'empty "{}" "project" "{}" "journal" "{}" "note" "{}" "task" no-claim "contact" "{}")
     (props-entry 'empty-spaced " { } " "project" "{}" "journal" "{}" "note" "{}" "task" no-claim "contact" "{}")
     ;; A Note: each form of at, and what is no When
     (props-entry 'note-date "{'at':'2026-12-01'}" "note" "{'at':'2026-12-01'}")
     (props-entry 'note-local "{'at':'2026-12-01T15:00'}" "note" "{'at':'2026-12-01T15:00'}")
     (props-entry 'note-moment "{'at':'2026-12-01T20:00:00Z'}" "note" "{'at':'2026-12-01T20:00:00Z'}")
     (props-entry 'note-leap-day "{ 'at' : '2024-02-29' }" "note" "{'at':'2024-02-29'}")
     (props-entry 'note-leap-2000 "{'at':'2000-02-29T23:59'}" "note" "{'at':'2000-02-29T23:59'}")
     (props-entry 'note-short "{'at':'2026-12-1'}")
     (props-entry 'note-30-february "{'at':'2026-02-30'}")
     (props-entry 'note-1900-leap "{'at':'1900-02-29'}")
     (props-entry 'note-hour-24 "{'at':'2026-12-01T24:00'}")
     (props-entry 'note-second-60 "{'at':'2026-12-01T20:00:60Z'}")
     (props-entry 'note-lower-t "{'at':'2026-12-01t15:00'}")
     (props-entry 'note-lower-z "{'at':'2026-12-01T20:00:00z'}")
     (props-entry 'note-space "{'at':'2026-12-01 15:00'}")
     (props-entry 'note-offset "{'at':'2026-12-01T20:00:00+01:00'}")
     (props-entry 'note-fraction "{'at':'2026-12-01T20:00:00.5Z'}")
     (props-entry 'note-sign "{'at':'+026-12-01'}")
     (props-entry 'note-year-0 "{'at':'0000-01-01'}")
     (props-entry 'note-arabic-digit "{'at':'\x662;026-12-01'}")
     (props-entry 'note-number "{'at':20261201}")
     (props-entry 'note-null "{'at':null}")
     (props-entry 'note-at-twice "{'at':'2026-12-01','at':'2026-12-02'}")
     (props-entry 'note-other-member "{'at':'2026-12-01','tz':'UTC'}")
     (props-entry 'note-when-named "{'when':'2026-12-01'}")
     ;; A Task: deadline and scheduled in each form; each status with and
     ;; without closed; what is no status, no closed, no When
     (props-entry 'task-deadline-date "{'deadline':'2026-12-01'}" "task" (claim #f #f "2026-12-01" #f))
     (props-entry 'task-deadline-local "{'deadline':'2026-12-01T15:00'}" "task" (claim #f #f "2026-12-01T15:00" #f))
     (props-entry 'task-deadline-moment "{'deadline':'2026-12-01T20:00:00Z'}" "task"
                  (claim #f #f "2026-12-01T20:00:00Z" #f))
     (props-entry 'task-scheduled-date "{'scheduled':'0001-01-01'}" "task" (claim #f #f #f "0001-01-01"))
     (props-entry 'task-scheduled-local "{'scheduled':'2026-11-30T09:00'}" "task" (claim #f #f #f "2026-11-30T09:00"))
     (props-entry 'task-scheduled-moment "{'scheduled':'9999-12-31T23:59:59Z'}" "task"
                  (claim #f #f #f "9999-12-31T23:59:59Z"))
     (props-entry 'task-both "{'deadline':'2026-12-02','scheduled':'2026-11-30T09:00'}" "task"
                  (claim #f #f "2026-12-02" "2026-11-30T09:00"))
     (props-entry 'task-both-reversed "{'scheduled':'2026-11-30T09:00','deadline':'2026-12-02'}" "task"
                  (claim #f #f "2026-12-02" "2026-11-30T09:00"))
     (props-entry 'task-todo "{'status':'TODO'}" "task" (claim "TODO" #f #f #f))
     (props-entry 'task-todo-deadline "{'deadline':'2024-02-29','status':'TODO'}" "task" (claim "TODO" #f "2024-02-29" #f))
     (props-entry 'task-done "{'status':'DONE'}" "task" (claim "DONE" #f #f #f))
     (props-entry 'task-wontdo-deadline "{'status':'WONTDO','deadline':'2026-12-01'}" "task"
                  (claim "WONTDO" #f "2026-12-01" #f))
     (props-entry 'task-done-closed "{'closed':1795515226000,'status':'DONE'}" "task" (claim "DONE" 1795515226000 #f #f))
     (props-entry 'task-wontdo-closed-0 "{'status':'WONTDO','closed':0}" "task" (claim "WONTDO" 0 #f #f))
     (props-entry 'task-done-closed-max "{'status':'DONE','closed':9007199254740991}" "task"
                  (claim "DONE" 9007199254740991 #f #f))
     (props-entry 'task-all "{'status':'DONE','closed':1795515226123,'deadline':'2026-12-01','scheduled':'2026-11-30T09:00'}"
                  "task" (claim "DONE" 1795515226123 "2026-12-01" "2026-11-30T09:00"))
     (props-entry 'task-all-shuffled
                  "{'scheduled':'2026-11-30T09:00','closed':1795515226123,'deadline':'2026-12-01','status':'DONE'}"
                  "task" (claim "DONE" 1795515226123 "2026-12-01" "2026-11-30T09:00"))
     (props-entry 'task-todo-closed "{'status':'TODO','closed':1795515226000}" "task" (claim "TODO" 1795515226000 #f #f))
     (props-entry 'task-closed-only "{'closed':1795515226000}" "task" (claim #f 1795515226000 #f #f))
     (props-entry 'task-closed-flonum "{'status':'DONE','closed':1.0}")
     (props-entry 'task-closed-exponent "{'status':'DONE','closed':1.7e12}")
     (props-entry 'task-closed-over "{'status':'DONE','closed':9007199254740992}")
     (props-entry 'task-closed-negative "{'status':'DONE','closed':-1}")
     (props-entry 'task-closed-null "{'status':'DONE','closed':null}")
     (props-entry 'task-closed-text "{'status':'DONE','closed':'1795515226000'}")
     (props-entry 'task-status-lower "{'status':'done'}")
     (props-entry 'task-status-other "{'status':'CANCELLED'}")
     (props-entry 'task-status-null "{'status':null}")
     (props-entry 'task-deadline-bad "{'deadline':'2026-02-30'}")
     (props-entry 'task-scheduled-bad "{'scheduled':'2026-11-30T9:00'}")
     (props-entry 'task-deadline-number "{'deadline':20261201}")
     (props-entry 'task-deadline-twice "{'deadline':'2026-12-01','deadline':'2026-12-02'}")
     (props-entry 'task-member-unknown "{'status':'DONE','priority':'A'}")
     (props-entry 'task-five-members
                  "{'status':'DONE','closed':1,'deadline':'2026-12-01','scheduled':'2026-12-01','deadline2':'x'}")
     ;; A Contact: what is taken, and its one text (R17: two orderings, one
     ;; text; @type and explicit defaults dropped; \/ and \u escapes written
     ;; raw); then each rule that refuses
     (props-entry 'contact-small "{'name':{'components':[{'kind':'given','value':'Ada'}]}}"
                  "contact" "{'name':{'components':[{'kind':'given','value':'Ada'}]}}")
     (props-entry 'contact-typed
                  "{'name':{'@type':'Name','isOrdered':false,'components':[{'value':'Ada','@type':'NameComponent','kind':'given'}]}}"
                  "contact" "{'name':{'components':[{'kind':'given','value':'Ada'}]}}")
     (props-entry 'contact-ordered
                  "{'name':{'isOrdered':true,'components':[{'value':'Lovelace','kind':'surname'},{'kind':'given','value':'Ada'}]}}"
                  "contact" "{'name':{'components':[{'kind':'surname','value':'Lovelace'},{'kind':'given','value':'Ada'}],'isOrdered':true}}")
     (props-entry 'contact-order-a
                  "{'emails':{'w':{'pref':2,'address':'ada@work.example','contexts':{'work':true}},'h':{'address':'ada@home.example','contexts':{'private':true,'work':true}}},'kind':'org'}"
                  "contact" "{'kind':'org','emails':{'h':{'address':'ada@home.example','contexts':{'private':true,'work':true}},'w':{'address':'ada@work.example','contexts':{'work':true},'pref':2}}}")
     (props-entry 'contact-order-b
                  "{'kind':'org','emails':{'h':{'contexts':{'work':true,'private':true},'address':'ada@home.example'},'w':{'address':'ada@work.example','contexts':{'work':true},'pref':2}}}"
                  "contact" "{'kind':'org','emails':{'h':{'address':'ada@home.example','contexts':{'private':true,'work':true}},'w':{'address':'ada@work.example','contexts':{'work':true},'pref':2}}}")
     (props-entry 'contact-defaults
                  "{'kind':'individual','titles':{'t1':{'kind':'title','name':'Countess'}},'name':{'components':[{'kind':'surname','value':'Lovelace'}],'isOrdered':false}}"
                  "contact" "{'name':{'components':[{'kind':'surname','value':'Lovelace'}]},'titles':{'t1':{'name':'Countess'}}}")
     (props-entry 'contact-kind-individual "{'kind':'individual'}" "contact" "{}")
     (props-entry 'contact-kind-org "{'kind':'org'}" "contact" "{'kind':'org'}")
     (props-entry 'contact-org-title
                  "{'titles':{'t1':{'organizationId':'o1','kind':'role','name':'Engineer'}},'organizations':{'o1':{'units':[{'name':'Engines'}],'name':'Babbage & Co'}}}"
                  "contact" "{'organizations':{'o1':{'name':'Babbage & Co','units':[{'name':'Engines'}]}},'titles':{'t1':{'name':'Engineer','kind':'role','organizationId':'o1'}}}")
     (props-entry 'contact-address-lines
                  "{'addresses':{'a1':{'full':'1 Main St\\nSpringfield','countryCode':'GB','contexts':{'delivery':true,'billing':true}}}}"
                  "contact" "{'addresses':{'a1':{'countryCode':'GB','full':'1 Main St\\nSpringfield','contexts':{'billing':true,'delivery':true}}}}")
     (props-entry 'contact-phones
                  "{'phones':{'p2':{'number':'+44 20 7946 0001','features':{'text':true,'mobile':true}},'p1':{'label':'desk','contexts':{'work':true},'features':{'voice':true},'number':'+44 20 7946 0000'}}}"
                  "contact" "{'phones':{'p1':{'number':'+44 20 7946 0000','features':{'voice':true},'contexts':{'work':true},'label':'desk'},'p2':{'number':'+44 20 7946 0001','features':{'mobile':true,'text':true}}}}")
     (props-entry 'contact-anniversaries
                  "{'anniversaries':{'w':{'kind':'wedding','date':{'day':29,'month':2}},'birth':{'date':{'day':10,'month':12,'year':1815},'kind':'birth'}}}"
                  "contact" "{'anniversaries':{'birth':{'kind':'birth','date':{'year':1815,'month':12,'day':10}},'w':{'kind':'wedding','date':{'month':2,'day':29}}}}")
     (props-entry 'contact-speak
                  "{'speakToAs':{'pronouns':{'k1':{'pref':1,'pronouns':'she/her'}},'grammaticalGender':'feminine'}}"
                  "contact" "{'speakToAs':{'grammaticalGender':'feminine','pronouns':{'k1':{'pronouns':'she/her','pref':1}}}}")
     (props-entry 'contact-links-escaped
                  "{'onlineServices':{'s1':{'user':'@ada','service':'Mastodon'}},'links':{'l1':{'kind':'contact','uri':'https:\\/\\/example.com\\/ada'}}}"
                  "contact" "{'links':{'l1':{'uri':'https://example.com/ada','kind':'contact'}},'onlineServices':{'s1':{'service':'Mastodon','user':'@ada'}}}")
     (props-entry 'contact-escaped-script
                  "{'addresses':{'tokyo':{'countryCode':'JP','components':[{'kind':'locality','value':'\\u6771\\u4eac'}]}}}"
                  "contact" "{'addresses':{'tokyo':{'components':[{'kind':'locality','value':'\x6771;\x4eac;'}],'countryCode':'JP'}}}")
     (props-entry 'contact-email "{'emails':{'e1':{'address':'a@b'}}}" "contact" "{'emails':{'e1':{'address':'a@b'}}}")
     (props-entry 'contact-rich rich-sent "contact" rich-canonical)
     (props-entry 'contact-at-cap (capped-contact 4096 #t) "contact" at-cap-text)
     (props-entry 'contact-over-cap (capped-contact 4097 #t) "contact" 'too-large)
     (props-entry 'contact-large
                  (string-append "{'emails':{"
                                 (join (map (lambda (i) (string-append "'e" (number->string i) "':{'address':'a@b','label':'"
                                                                       (make-string 900 #\y) "'}"))
                                            '(1 2 3 4 5 6))
                                       ",")
                                 "}}")
                  "contact" 'too-large)
     (props-entry 'contact-type-wrong "{'name':{'@type':'Card','components':[{'kind':'given','value':'Ada'}]}}")
     (props-entry 'contact-type-top "{'@type':'Card','name':{'components':[{'kind':'given','value':'Ada'}]}}")
     (props-entry 'contact-version "{'version':'1.0'}")
     (props-entry 'contact-empty-string "{'name':{'components':[{'kind':'given','value':''}]}}")
     (props-entry 'contact-label-line-feed "{'emails':{'e1':{'address':'a@b','label':'two\\nlines'}}}")
     (props-entry 'contact-control-bel "{'phones':{'p1':{'number':'555\\u0007'}}}")
     (props-entry 'contact-control-c1 "{'phones':{'p1':{'number':'555\\u0085'}}}")
     (props-entry 'contact-noncharacter "{'emails':{'e1':{'address':'a@b','label':'\\ufffe'}}}")
     (props-entry 'contact-empty-map "{'emails':{}}")
     (props-entry 'contact-empty-list "{'name':{'components':[]}}")
     (props-entry 'contact-empty-set "{'emails':{'e1':{'address':'a@b','contexts':{}}}}")
     (props-entry 'contact-set-false "{'emails':{'e1':{'address':'a@b','contexts':{'work':false}}}}")
     (props-entry 'contact-dangling-org "{'organizations':{'o1':{'name':'X'}},'titles':{'t1':{'name':'CEO','organizationId':'o9'}}}")
     (props-entry 'contact-dangling-org-none "{'titles':{'t1':{'name':'CEO','organizationId':'o1'}}}")
     (props-entry 'contact-uri-word "{'links':{'l1':{'uri':'hello'}}}")
     (props-entry 'contact-uri-non-ascii "{'links':{'l1':{'uri':'https://ex.com/\xe9;'}}}")
     (props-entry 'contact-email-dots "{'emails':{'e1':{'address':'a..b@c'}}}")
     (props-entry 'contact-email-at "{'emails':{'e1':{'address':'@'}}}")
     (props-entry 'contact-email-space "{'emails':{'e1':{'address':'a b@c'}}}")
     (props-entry 'contact-unknown-member "{'nicknames':{'n1':{'name':'Addie'}}}")
     (props-entry 'contact-pref-flonum "{'emails':{'e1':{'address':'a@b','pref':1.0}}}")
     (props-entry 'contact-pref-101 "{'emails':{'e1':{'address':'a@b','pref':101}}}")
     (props-entry 'contact-id-space "{'emails':{'e 1':{'address':'a@b'}}}")
     (props-entry 'contact-id-twice "{'emails':{'e1':{'address':'a@b'},'e1':{'address':'c@d'}}}")
     (props-entry 'contact-name-twice "{'kind':'org','kind':'org'}")
     (props-entry 'contact-day-alone "{'anniversaries':{'d':{'kind':'death','date':{'day':10}}}}")
     (props-entry 'contact-1900-leap "{'anniversaries':{'d':{'kind':'death','date':{'year':1900,'month':2,'day':29}}}}")
     (props-entry 'contact-country-lower "{'addresses':{'a1':{'countryCode':'gb'}}}")
     (props-entry 'contact-kind-group "{'kind':'group'}")
     ;; No kind takes these
     (props-entry 'nothing-colour "{'colour':'blue'}")
     (props-entry 'nothing-note-and-task "{'at':'2026-12-01','deadline':'2026-12-01'}")
     (props-entry 'nothing-task-and-contact "{'status':'DONE','emails':{'e1':{'address':'a@b'}}}")
     (props-entry 'nothing-array "[]")
     (props-entry 'nothing-null "null")
     (props-entry 'nothing-string "'{}'")
     (props-entry 'nothing-number "0")))

  ;; empty-entry : Entry     {}, as a create with no props is taken (request-props: "as {}")
  (define empty-entry (car props-corpus))

  ;; corpus-of : (Entry -> Boolean) -> (Listof Entry)
  (define (corpus-of pred) (filter pred props-corpus))

  ;; taken-by, refused-by : (Listof (Pair String (Listof Entry)))
  ;; Each kind's entries it takes; those it refuses that another kind takes.
  (define taken-by
    (map (lambda (k) (cons k (corpus-of (lambda (e) (taken? (entry-verdict e k)))))) kinds))
  (define refused-by
    (map (lambda (k) (cons k (corpus-of (lambda (e) (and (not (taken? (entry-verdict e k)))
                                                         (exists (lambda (j) (taken? (entry-verdict e j))) kinds))))))
         kinds))
  ;; nobody-takes : (Listof Entry)     no kind takes them: a 400, or a 413 where one finds them over the cap
  (define nobody-takes (corpus-of (lambda (e) (not (exists (lambda (k) (taken? (entry-verdict e k))) kinds)))))

  ;; json-of : String -> Any     the JSON reader's value of TEXT, remembered: the texts repeat
  (define json-memo (make-hashtable string-hash string=?))
  (define (json-of text)
    (or (hashtable-ref json-memo text #f)
        (let ((j (string->json text)))
          (hashtable-set! json-memo text j)
          j)))

  ;; whens-in : String String -> (Listof Any)
  ;; The Whens a KIND's stored TEXT holds, as the JSON reader reads them: a
  ;; Note's at; a Task's deadline and scheduled; none for another kind.
  (define (whens-in kind text)
    (let ((j (json-of text))
          (names (cond ((string=? kind "note") '("at")) ((string=? kind "task") '("deadline" "scheduled")) (else '()))))
      (if (list? j)
          (filter (lambda (x) x) (map (lambda (n) (let ((p (assoc n j))) (and p (cdr p)))) names))
          '())))

  ;; corpus-self-breaks : -> (Listof String)
  ;; The corpus held to what it says of itself, with no server: names once
  ;; each; every verdict of its forms; no value is over the cap for one
  ;; kind and taken by another (so the job's 413 cannot happen, as the
  ;; build found); every text taken is at most 4,096 bytes and a JSON
  ;; object, every When in it a good one (R9), every claim of a status one
  ;; of the three and of a closed a whole number in I-JSON's range; the cap's
  ;; texts exactly 4,096 and 4,097 bytes, their sent text over 4,096; R17's
  ;; two orderings one text, sent two ways.
  (define (corpus-self-breaks)
    (let ((names (map entry-name props-corpus)))
      (append
       (let loop ((ns names) (acc '()))
         (cond ((null? ns) (reverse acc))
               ((memq (car ns) (cdr ns)) (loop (cdr ns) (cons (format "corpus: ~a is named twice" (car ns)) acc)))
               (else (loop (cdr ns) acc))))
       (apply append
              (map (lambda (e)
                     (append
                      (if (and (exists (lambda (k) (eq? (entry-verdict e k) 'too-large)) kinds)
                               (exists (lambda (k) (taken? (entry-verdict e k))) kinds))
                          (list (format "corpus: ~a is over the cap for one kind and taken by another" (entry-name e)))
                          '())
                      (apply append
                             (map (lambda (k)
                                    (let ((v (entry-verdict e k)))
                                      (cond
                                       ((memq v '(invalid too-large)) '())
                                       ((and (string? v) (not (string=? k "task")))
                                        (append
                                         (if (<= (bytevector-length (string->utf8 v)) 4096) '()
                                             (list (format "corpus: ~a's ~a text is over 4,096 bytes" (entry-name e) k)))
                                         (if (list? (guard (c (#t #f)) (json-of v))) '()
                                             (list (format "corpus: ~a's ~a text is no JSON object" (entry-name e) k)))
                                         (if (for-all (lambda (x) (member x good-whens)) (whens-in k v)) '()
                                             (list (format "corpus: ~a's ~a text holds a When not of good-whens" (entry-name e) k)))))
                                       ((and (claim? v) (string=? k "task"))
                                        (append
                                         (if (member (claim-status v) '(#f "TODO" "DONE" "WONTDO")) '()
                                             (list (format "corpus: ~a claims the status ~s" (entry-name e) (claim-status v))))
                                         (if (or (not (claim-closed v)) (natural? (claim-closed v))) '()
                                             (list (format "corpus: ~a claims the closed ~s" (entry-name e) (claim-closed v))))
                                         (if (for-all (lambda (x) (or (not x) (member x good-whens)))
                                                      (list (claim-deadline v) (claim-scheduled v)))
                                             '()
                                             (list (format "corpus: ~a claims a When not of good-whens" (entry-name e))))))
                                       (else (list (format "corpus: ~a's verdict for a ~a is ~s" (entry-name e) k v))))))
                                  kinds))))
                   props-corpus))
       (if (and (= (bytevector-length (string->utf8 at-cap-text)) 4096)
                (= (bytevector-length (string->utf8 over-cap-text)) 4097)
                (< (string-length over-cap-text) 4096)
                (let ((e (find (lambda (e) (eq? (entry-name e) 'contact-at-cap)) props-corpus)))
                  (and e (> (bytevector-length (string->utf8 (entry-sent e))) 4096))))
           '()
           (list "corpus: the cap's texts are not 4,096 and 4,097 bytes, under 4,096 characters, the one taken sent over 4,096"))
       (let ((a (find (lambda (e) (eq? (entry-name e) 'contact-order-a)) props-corpus))
             (b (find (lambda (e) (eq? (entry-name e) 'contact-order-b)) props-corpus)))
         (if (and a b (equal? (entry-verdict a "contact") (entry-verdict b "contact"))
                  (not (equal? (entry-sent a) (entry-sent b))))
             '()
             (list "corpus: R17's two orderings are not one text sent two ways"))))))

  ;;; Tags, as data (slice 7a)
  ;;;
  ;;; The rule is G3 as the review and the owner fixed it, and his rulings
  ;;; F1 to F6: a string over 256 characters, or holding an unassigned code
  ;;; point, refused as sent; NFKC, lower case, NFKC again; each dash `-`;
  ;;; spaces trimmed from both ends and each run inside one `-`; the
  ;;; result 1 to 64 characters, not beginning with a combining mark, with
  ;;; no control character, line break, noncharacter, invisible, private
  ;;; use or unassigned character. Unicode's tables are not restated here:
  ;;; each entry is a tag as a client sends it and its stored form written
  ;;; out by hand, or 'invalid. Never computed by (techo tags), nor by a
  ;;; fold of the model's own. Every stored form is also an entry that
  ;;; stores itself, so a tag read back and sent again is in the corpus
  ;;; (L1, by the corpus), and every tag an answer or a row may hold is one
  ;;; of the corpus's stored forms (L2, by the corpus).

  ;; The plan's numbers, written here, not imported: G5's 50 a node, G6's
  ;; 10 a filter, G8's 500 a step, H6's count stopped at 1,000, and the 64
  ;; characters of a stored tag.
  (define tag-most 50)
  (define filter-most 10)
  (define step-most 500)
  (define count-most 1000)
  (define tag-chars-most 64)

  ;; TagEntry: name sent stored
  ;;   name    for reports and counts
  ;;   sent    the tag as a request sends it
  ;;   stored  its stored form, or 'invalid: the 400
  ;; tag-entry-name : TagEntry -> Symbol
  ;; tag-entry-sent : TagEntry -> String
  ;; tag-entry-stored : TagEntry -> (U String 'invalid)
  (define-record-type tag-entry (fields name sent stored))
  (define (te name sent stored) (make-tag-entry name sent stored))
  (define (tag-ok? e) (string? (tag-entry-stored e)))

  ;; U+FDFA, as NFKC writes it out, its three spaces each a `-`: 18 characters
  (define fdfa-folded "\x635;\x644;\x649;-\x627;\x644;\x644;\x647;-\x639;\x644;\x64a;\x647;-\x648;\x633;\x644;\x645;")

  (define (repeat-string s n) (if (= n 0) "" (string-append s (repeat-string s (- n 1)))))

  (define tag-corpus-written
    (list
     ;; The owner's examples (G3) and the tags most requests send
     (te 'work "work" "work") (te 'work-capital "Work" "work") (te 'work-upper "WORK" "work")
     (te 'work-full-width "\xff37;\xff2f;\xff32;\xff2b;" "work")
     (te 'home "home" "home") (te 'home-capital "Home" "home")
     (te 'errands "errands" "errands") (te 'errands-capital "Errands" "errands")
     (te 'home-life "home-life" "home-life") (te 'home-life-words "Home Life" "home-life")
     (te 'work-space "work-space" "work-space") (te 'work-space-words "Work Space" "work-space")
     (te 'work-space-padded " work  space " "work-space")
     (te 'nihon "\x65e5;\x672c;" "\x65e5;\x672c;")
     (te 'crowd "crowd" "crowd") (te 'crowd-capital "Crowd" "crowd") (te 'crowd-upper "CROWD" "crowd")
     (te 'throng "throng" "throng") (te 'throng-capital "Throng" "throng") (te 'throng-upper "THRONG" "throng")
     (te 'c-plus-plus "c++" "c++") (te 'c-plus-plus-upper "C++" "c++")
     (te 'slash "a/b" "a/b") (te 'ampersand "a&b" "a&b")
     (te 'party "\x1f389;" "\x1f389;")
     (te 'e-acute "\xe9;" "\xe9;") (te 'e-acute-upper "\xc9;" "\xe9;") (te 'e-combining "E\x301;" "\xe9;")
     (te 'a-b "a-b" "a-b") (te 'a-b-nbsp "a\xa0;b" "a-b") (te 'a-b-space "a b" "a-b")
     ;; Spaces: NFKC makes most of them U+0020; U+1680 is left, and is a space too (H2)
     (te 'a-b-ideographic "a\x3000;b" "a-b") (te 'a-b-ogham "a\x1680;b" "a-b") (te 'a-b-thin "a\x2009;b" "a-b")
     (te 'a-b-en-quad "a\x2000;b" "a-b") (te 'a-b-spaced "  a   b  " "a-b")
     ;; Hyphens sent are left; every dash, U+2010 to U+2015 and U+2212, and
     ;; what NFKC makes one, is `-` (F5): never trimmed, a run of them never one
     (te 'hyphen-u2010 "a\x2010;b" "a-b") (te 'hyphen-non-breaking "a\x2011;b" "a-b")
     (te 'minus "a\x2212;b" "a-b") (te 'trailing-hyphen "a-" "a-") (te 'hyphen "-" "-")
     (te 'spaced-hyphen "a - b" "a---b") (te 'three-hyphens "a---b" "a---b")
     (te 'en-dash "a\x2013;b" "a-b") (te 'em-dash "a\x2014;b" "a-b") (te 'small-em-dash "a\xfe58;b" "a-b")
     (te 'full-width-hyphen "a\xff0d;b" "a-b") (te 'en-dash-alone "\x2013;" "-")
     (te 'en-dashes "a\x2013;\x2013;b" "a--b") (te 'two-hyphens "a--b" "a--b")
     (te 'wave-dash "\x301c;" "\x301c;") (te 'long-vowel-mark "\x30fc;" "\x30fc;")
     ;; What a query must percent-encode (H8)
     (te 'percent "100%" "100%") (te 'hash "#tag" "#tag") (te 'question "a?b" "a?b") (te 'equals "a=b" "a=b")
     (te 'quotes "say \"hi\"" "say-\"hi\"") (te 'quotes-stored "say-\"hi\"" "say-\"hi\"")
     (te 'backslash "a\\b" "a\\b") (te 'plus "a+b" "a+b") (te 'punctuation "a,b;c" "a,b;c")
     ;; Case, and what folding keeps apart: STRASSE and Strasse, hiragana and katakana
     (te 'strasse-sharp "Stra\xdf;e" "stra\xdf;e") (te 'strasse-sharp-stored "stra\xdf;e" "stra\xdf;e")
     (te 'strasse-upper "STRASSE" "strasse") (te 'strasse "strasse" "strasse")
     (te 'capital-sharp-s "\x1e9e;" "\xdf;") (te 'sharp-s "\xdf;" "\xdf;")
     (te 'strasse-capital-sharp "STRA\x1e9e;E" "stra\xdf;e")
     (te 'hiragana "\x3072;\x3089;\x304c;\x306a;" "\x3072;\x3089;\x304c;\x306a;")
     (te 'katakana "\x30d2;\x30e9;\x30ac;\x30ca;" "\x30d2;\x30e9;\x30ac;\x30ca;")
     (te 'half-width "\xff92;\xff93;" "\x30e1;\x30e2;") (te 'memo "\x30e1;\x30e2;" "\x30e1;\x30e2;")
     ;; The second NFKC: W and a ring above lowercase to w and the ring, which compose (traps.md)
     (te 'w-ring "W\x30a;" "\x1e98;") (te 'w-ring-stored "\x1e98;" "\x1e98;")
     (te 'kabushiki "\x3231;" "(\x682a;)") (te 'kabushiki-stored "(\x682a;)" "(\x682a;)")
     (te 'circled-a "\x24b6;" "a") (te 'a "a" "a") (te 'math-bold-a "\x1d400;" "a")
     (te 'ligature-fi "\xfb01;" "fi") (te 'fi "fi" "fi")
     (te 'roman-twelve "\x216b;" "xii") (te 'xii "xii" "xii")
     (te 'superscript-two "x\xb2;" "x2") (te 'x2 "x2" "x2")
     (te 'heart "\x2764;" "\x2764;") (te 'treble-clef "\x1d11e;" "\x1d11e;") (te 'cjk-extension-b "\x20000;" "\x20000;")
     (te 'arabic "\x633;\x644;\x627;\x645;" "\x633;\x644;\x627;\x645;")
     (te 'fdfa-three "\xfdfa;\xfdfa;\xfdfa;" (repeat-string fdfa-folded 3))
     (te 'fdfa-three-stored (repeat-string fdfa-folded 3) (repeat-string fdfa-folded 3))
     (te 'greek-upper "\x39f;\x394;\x39f;\x3a3;" "\x3bf;\x3b4;\x3bf;\x3c2;")
     (te 'greek "\x3bf;\x3b4;\x3bf;\x3c2;" "\x3bf;\x3b4;\x3bf;\x3c2;")
     (te 'dotted-capital-i "\x130;" "i\x307;") (te 'dotted-i "i\x307;" "i\x307;")
     (te 'replacement "\xfffd;" "\xfffd;")
     (te 'kelvin "\x212a;" "k") (te 'k "k" "k") (te 'angstrom "\x212b;" "\xe5;") (te 'a-ring "\xe5;" "\xe5;")
     (te 'jamo "\x1100;\x1161;" "\xac00;") (te 'hangul "\xac00;" "\xac00;")
     (te 'ohm "\x2126;" "\x3c9;") (te 'omega "\x3c9;" "\x3c9;")
     (te 'one-half "\xbd;" "1\x2044;2") (te 'one-half-stored "1\x2044;2" "1\x2044;2")
     (te 'circled-one "\x2460;" "1") (te 'one "1" "1") (te 'c "c" "c")
     ;; What Unicode 17 assigned is taken (F1); a mark after a letter is kept (F4)
     (te 'unicode-17-capital "\xa7ce;" "\xa7cf;") (te 'unicode-17-small "\xa7cf;" "\xa7cf;")
     (te 'e-and-acute "e\x301;" "\xe9;") (te 'acute-after "a\xb4;b" "a-\x301;b")
     (te 'acute-after-stored "a-\x301;b" "a-\x301;b")
     ;; Both caps: 64 characters stored, 256 sent
     (te 'sixty-four (make-string 64 #\a) (make-string 64 #\a))
     (te 'sixty-four-upper (make-string 64 #\A) (make-string 64 #\a))
     (te 'sixty-four-full-width (make-string 64 #\xff21) (make-string 64 #\a))
     (te 'fi-thirty-two (make-string 32 #\xfb01) (repeat-string "fi" 32))
     (te 'fi-thirty-two-stored (repeat-string "fi" 32) (repeat-string "fi" 32))
     (te 'sent-256 (string-append (make-string 255 #\space) "a") "a")
     (te 'sixty-five (make-string 65 #\a) 'invalid)
     (te 'fdfa-four "\xfdfa;\xfdfa;\xfdfa;\xfdfa;" 'invalid)
     (te 'fi-thirty-three (make-string 33 #\xfb01) 'invalid)
     (te 'sent-257 (string-append (make-string 256 #\space) "a") 'invalid)
     ;; Refused: empty, blank, a control or line break (H2), a noncharacter,
     ;; an invisible character (H3), an emoji with its variation selector or a joiner
     (te 'empty "" 'invalid) (te 'blank "   " 'invalid) (te 'tab "a\tb" 'invalid) (te 'leading-tab "\ta" 'invalid)
     (te 'line-feed "a\nb" 'invalid) (te 'carriage-return "a\rb" 'invalid) (te 'nul "a\x0;b" 'invalid)
     (te 'delete "a\x7f;b" 'invalid) (te 'next-line "a\x85;b" 'invalid)
     (te 'line-separator "a\x2028;b" 'invalid) (te 'paragraph-separator "a\x2029;b" 'invalid)
     (te 'zero-width-space "a\x200b;b" 'invalid) (te 'zero-width-alone "\x200b;" 'invalid)
     (te 'zero-width-joiner "a\x200d;b" 'invalid) (te 'zero-width-non-joiner "a\x200c;b" 'invalid)
     (te 'soft-hyphen "a\xad;b" 'invalid) (te 'left-to-right-mark "a\x200e;b" 'invalid)
     (te 'right-to-left-override "a\x202e;b" 'invalid) (te 'byte-order-mark "a\xfeff;b" 'invalid)
     (te 'word-joiner "a\x2060;b" 'invalid) (te 'mongolian-vowel-separator "a\x180e;b" 'invalid)
     (te 'hangul-filler "\x3164;" 'invalid) (te 'tag-character "a\xe0041;" 'invalid)
     (te 'grapheme-joiner "a\x34f;b" 'invalid)
     (te 'heart-variation-selector "\x2764;\xfe0f;" 'invalid)
     (te 'family "\x1f468;\x200d;\x1f469;\x200d;\x1f467;" 'invalid)
     (te 'noncharacter "a\xfffe;b" 'invalid) (te 'noncharacter-fdd0 "\xfdd0;" 'invalid)
     (te 'noncharacter-astral "\x1fffe;" 'invalid)
     ;; The owner's rulings: unassigned (F1), format (F2), blank-looking
     ;; (F3), a mark first (F4), private use (F6)
     (te 'unassigned "a\x378;b" 'invalid) (te 'unassigned-alone "\x378;" 'invalid)
     (te 'interlinear-anchor "a\xfff9;b" 'invalid) (te 'hieroglyph-format "a\x13430;" 'invalid)
     (te 'braille-blank "\x2800;" 'invalid) (te 'khitan-filler "a\x16fe4;" 'invalid)
     (te 'acute-alone "\x301;" 'invalid) (te 'spacing-acute "\xb4;" 'invalid)
     (te 'private-use "\xe000;" 'invalid) (te 'private-use-astral "a\x10fffd;" 'invalid)))

  ;; two-digits : Natural -> String     01 to 99
  (define (two-digits k) (string-append (if (< k 10) "0" "") (number->string k)))

  ;; numbered-tags : (Listof TagEntry)
  ;; T01 to T50, stored t01 to t50, and t01 to t50 themselves: fifty tags
  ;; for G5's cap. The one rule stated here: an ASCII capital T folds to t.
  (define numbered-tags
    (apply append
           (map (lambda (k)
                  (let ((stored (string-append "t" (two-digits k))))
                    (list (te (sym "numbered-" (two-digits k)) (string-append "T" (two-digits k)) stored)
                          (te (sym "numbered-" (two-digits k) "-stored") stored stored))))
                (from-to 1 50))))

  ;; tag-corpus : (Listof TagEntry)
  (define tag-corpus (append tag-corpus-written numbered-tags))

  (define (tag-named name) (find (lambda (e) (eq? (tag-entry-name e) name)) tag-corpus))

  ;; good-tags, bad-tags : (Listof TagEntry)     the entries the rule takes, and refuses
  (define good-tags (filter tag-ok? tag-corpus))
  (define bad-tags (filter (lambda (e) (not (tag-ok? e))) tag-corpus))

  ;; stored-tag-table : Hashtable     every stored form of the corpus (L2's set)
  (define stored-tag-table
    (let ((t (make-hashtable string-hash string=?)))
      (for-each (lambda (e) (hashtable-set! t (tag-entry-stored e) #t)) good-tags)
      t))
  (define (stored-tag? s) (and (string? s) (hashtable-ref stored-tag-table s #f)))

  ;; fixed-point-of : String -> (U TagEntry #f)     the entry that sends the stored form T itself
  (define fixed-point-table
    (let ((t (make-hashtable string-hash string=?)))
      (for-each (lambda (e) (when (equal? (tag-entry-sent e) (tag-entry-stored e))
                              (hashtable-set! t (tag-entry-sent e) e)))
                good-tags)
      t))
  (define (fixed-point-of t) (hashtable-ref fixed-point-table t #f))

  ;; forms-of : String -> (Listof TagEntry)     every entry whose stored form is T
  (define forms-table
    (let ((t (make-hashtable string-hash string=?)))
      (for-each (lambda (e) (hashtable-update! t (tag-entry-stored e) (lambda (l) (cons e l)) '())) good-tags)
      t))
  (define (forms-of t) (reverse (hashtable-ref forms-table t '())))

  ;; common-tags : (Listof TagEntry)
  ;; The tags most requests send, by both accounts alike, so that a
  ;; filter, a count and a step meet carriers, and the other account's.
  (define common-tags
    (map tag-named '(work work-capital work-upper work-full-width home home-capital errands errands-capital
                     home-life home-life-words work-space work-space-words nihon c-plus-plus c-plus-plus-upper
                     slash ampersand party e-acute e-combining a-b a-b-nbsp quotes)))

  ;; tag-set : (Listof String) -> (Listof String)     sorted by code point, each once
  (define (tag-set ts)
    (let loop ((l (list-sort string<? ts)) (acc '()))
      (cond ((null? l) (reverse acc))
            ((and (pair? acc) (string=? (car acc) (car l))) (loop (cdr l) acc))
            (else (loop (cdr l) (cons (car l) acc))))))

  ;; json-string : String -> String
  ;; S as a JSON string, in the model's own writing: " and \ escaped, a
  ;; character below U+0020 as \u00XX, every other character as it is.
  (define (json-string s)
    (string-append
     "\""
     (apply string-append
            (map (lambda (c)
                   (let ((n (char->integer c)))
                     (cond ((char=? c #\") "\\\"")
                           ((char=? c #\\) "\\\\")
                           ((< n #x20) (string-append "\\u00" (string (string-ref hex-digits (div n 16)))
                                                      (string (string-ref hex-digits (mod n 16)))))
                           (else (string c)))))
                 (string->list s)))
     "\""))

  ;; tags-text : (Listof String) -> String
  ;; A snapshot's tags as SQLite's json_group_array writes them: [] for
  ;; none, else each a JSON string, no space: the model's writing, held
  ;; against the stored text byte for byte.
  (define (tags-text ts) (string-append "[" (join (map json-string ts) ",") "]"))

  ;; TagsSent: a PUT's tags member as the request sends it
  ;;   'absent                          no tags member
  ;;   (List 'entries (Listof TagEntry)) a JSON array of the entries' tags, in that order
  ;;   (List 'raw String Symbol)        a value that is no array of strings: its JSON text, its name
  ;; sent-tags : TagsSent Boolean -> (U (Listof String) 'absent 'invalid)
  ;; What a PUT stores of its tags (G1, G2, G5, the review), CREATE? for a
  ;; create: no member is none on a create and keeps the node's on a
  ;; replace; more than 50 entries, counted as sent, before any is folded,
  ;; is the 400, so 51 that fold to one are; an entry the rule refuses is
  ;; the 400; any value but an array of strings is the 400; else the
  ;; entries' stored forms, sorted by code point, each once.
  (define (sent-tags ts create?)
    (cond ((eq? ts 'absent) (if create? '() 'absent))
          ((eq? (car ts) 'entries)
           (let ((es (cadr ts)))
             (cond ((> (length es) tag-most) 'invalid)
                   ((exists (lambda (e) (not (tag-ok? e))) es) 'invalid)
                   (else (tag-set (map tag-entry-stored es))))))
          (else 'invalid)))

  ;; tags-member-text : TagsSent -> (U String #f)     the member's JSON value, #f for none
  (define (tags-member-text ts)
    (cond ((eq? ts 'absent) #f)
          ((eq? (car ts) 'entries) (string-append "[" (join (map (lambda (e) (json-string (tag-entry-sent e))) (cadr ts)) ",") "]"))
          (else (cadr ts))))

  ;; raw-tags-values : (Listof TagsSent)     tags members that are no array of strings: each the 400
  (define raw-tags-values
    (list '(raw "null" null) '(raw "\"work\"" string) '(raw "{}" object) '(raw "[1]" number-in-list)
          '(raw "[null]" null-in-list) '(raw "[[\"work\"]]" list-in-list) '(raw "true" true)
          '(raw "{\"work\":true}" object-of-tags)))

  ;; QueryTag: a ?tag= value as a request sends it (H8, the review)
  ;;   (List 'entry TagEntry Symbol)   the entry's tag percent-encoded: a space as %20 ('strict) or as + ('plus)
  ;;   (List 'raw String Symbol)       a value written into the query as it stands, and its name
  ;;   'bare                           the field with no =: an empty value
  ;; query-raw-cases : (Listof (List String Symbol (U String 'invalid)))
  ;; Values written into the query as they stand, each with what the
  ;; model says it stores, written by hand: a + is a space in a query, so
  ;; c++ is c and two spaces, which is c; %2B is a +; bad UTF-8, %FF or a
  ;; sequence cut off, is one U+FFFD, a tag the rule takes; an empty
  ;; value, or %20 alone, is the 400.
  (define query-raw-cases
    (list (list "c++" 'raw-c-plus-plus "c") (list "a+b" 'raw-a-plus-b "a-b") (list "a%2Bb" 'raw-a-escaped-plus "a+b")
          (list "Work+Space" 'raw-plus-spaces "work-space") (list "+work+" 'raw-plus-ends "work")
          (list "%FF" 'raw-bad-utf8 "\xfffd;") (list "%E6%97" 'raw-cut-off "\xfffd;")
          (list "%20" 'raw-blank 'invalid) (list "" 'raw-empty 'invalid)))

  ;; query-tag-stored : QueryTag -> (U String 'invalid)     what the server is to make of it
  (define (query-tag-stored q)
    (cond ((eq? q 'bare) 'invalid)
          ((eq? (car q) 'entry) (tag-entry-stored (cadr q)))
          (else (caddr (assoc (cadr q) query-raw-cases)))))

  ;; filter-tags-of : (Listof QueryTag) -> (U (Listof String) 'invalid)
  ;; A list's ?tag= values by the plan's rules (G6, the review): more than
  ;; 10, counted as sent, is the 400, so ?tag=Work&tag=work is two toward
  ;; ten and one tag; one refused, an empty one too, is the 400; else
  ;; their stored forms, each once.
  (define (filter-tags-of qs)
    (if (> (length qs) filter-most)
        'invalid
        (let ((ts (map query-tag-stored qs)))
          (if (memq 'invalid ts) 'invalid (tag-set ts)))))

  ;; tag-corpus-self-breaks : -> (Listof String)
  ;; The tags corpus held to what it says of itself, with no server: names
  ;; once each; every stored form 1 to 64 characters, and an entry of its
  ;; own that stores itself (L1, by the corpus); every common tag and the
  ;; raw cases' stored forms among them; both caps met from both sides.
  (define (tag-corpus-self-breaks)
    (let ((names (map tag-entry-name tag-corpus)))
      (append
       (let loop ((ns names) (acc '()))
         (cond ((null? ns) (reverse acc))
               ((memq (car ns) (cdr ns)) (loop (cdr ns) (cons (format "tag corpus: ~a is named twice" (car ns)) acc)))
               (else (loop (cdr ns) acc))))
       (apply append
              (map (lambda (e)
                     (let ((s (tag-entry-stored e)))
                       (cond ((eq? s 'invalid) '())
                             ((not (string? s)) (list (format "tag corpus: ~a's stored form is ~s" (tag-entry-name e) s)))
                             ((not (<= 1 (string-length s) tag-chars-most))
                              (list (format "tag corpus: ~a's stored form is ~a characters" (tag-entry-name e) (string-length s))))
                             ((not (fixed-point-of s))
                              (list (format "tag corpus: ~a's stored form ~s is no entry that stores itself" (tag-entry-name e) s)))
                             (else '()))))
                   tag-corpus))
       (if (for-all (lambda (e) (and e (tag-ok? e))) common-tags) '()
           (list "tag corpus: a common tag is missing or refused"))
       (filter (lambda (x) x)
               (map (lambda (c) (and (string? (caddr c)) (not (stored-tag? (caddr c)))
                                     (format "tag corpus: the raw case ~a stores ~s, no stored form of the corpus"
                                             (cadr c) (caddr c))))
                    query-raw-cases))
       (if (and (= (string-length (tag-entry-sent (tag-named 'sent-256))) 256)
                (= (string-length (tag-entry-sent (tag-named 'sent-257))) 257)
                (= (string-length (tag-entry-stored (tag-named 'sixty-four))) 64)
                (= (string-length (tag-entry-sent (tag-named 'sixty-five))) 65)
                (= (string-length (tag-entry-stored (tag-named 'fdfa-three))) 54)
                (= (length (filter (lambda (e) (memq (tag-entry-name e) (map tag-entry-name numbered-tags))) good-tags))
                   (* 2 tag-most)))
           '()
           (list "tag corpus: the caps' entries are not 256 and 257 sent, 64 and 65 stored, 54 for three U+FDFA, fifty numbered")))))

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

  ;; Content: kind (U String #f), title, body, type, the props sent (an
  ;; Entry of the corpus, or #f for no props member), a create's parent
  ;; (a ParentRef, 'absent for none), and the tags sent (a TagsSent).
  ;; make-content : (U String #f) String String String (U Entry #f) ParentRef -> Content
  ;;   one with no tags member
  ;; make-tagged-content : (U String #f) String String String (U Entry #f) ParentRef TagsSent -> Content
  (define-record-type (content make-tagged-content content?) (fields kind title body type props parent tags))
  (define (make-content kind title body type props parent)
    (make-tagged-content kind title body type props parent 'absent))

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
  ;;   link      a link's request (link, unlink, list-links): its LinkSpec;
  ;;             #f for every other
  ;;   tagq      slice 7a's: a list's FilterSpec (#f for no ?tag=), the
  ;;             tags list's TagsListSpec, a command's CommandSpec; #f for
  ;;             every other
  ;; make-event : Symbol Natural Tag Bytevector (U Bytevector #f) Any (Listof Header)
  ;;              (U Content #f) (U Natural #f) (U Natural #f) (U String 'twice #f)
  ;;              Boolean (Listof Symbol) ParentRef -> Event
  (define-record-type (event make-event* event?)
    (fields kind now tag key id pre headers content snap limit query upper? aims parent link tagq))

  (define (make-event kind now tag key id pre headers content snap limit query upper? aims parent)
    (make-event* kind now tag key id pre headers content snap limit query upper? aims parent #f #f))

  ;; FilterSpec: a list's ?tag= values, in the order sent, and its first
  ;; page's after, a node's id or #f (slice 7a)
  ;; make-filter-spec : (Listof QueryTag) (U Bytevector #f) -> FilterSpec
  (define-record-type filter-spec (fields values after))

  ;; make-filter-event : Natural Tag Bytevector (U Natural #f) (U String 'twice #f) ParentRef
  ;;                     (Listof Symbol) FilterSpec -> Event
  ;; GET /v1/nodes with ?tag=: a list's request, LIMIT, ?state= QUERY,
  ;; ?parent= PARENT, and the FilterSpec.
  (define (make-filter-event now tag key limit query parent aims spec)
    (make-event* 'list-nodes now tag key #f #f '() #f #f limit query #f aims parent #f spec))

  ;; TagsListSpec: GET /v1/tags's first after: #f, (List 'entry TagEntry
  ;; Symbol), percent-encoded as a QueryTag is, or 'twice (the field twice)
  ;; make-tags-list-spec : (U (List 'entry TagEntry Symbol) 'twice #f) -> TagsListSpec
  (define-record-type tags-list-spec (fields after))

  ;; CommandSpec: a rename's or a removal's body and media type (slice 7a)
  ;;   body    (List 'members (Listof (Pair String Value))): an object of
  ;;           these members, in order, each Value a TagEntry (its tag, a
  ;;           JSON string) or (List 'json String), a value written as it
  ;;           is; (List 'padded Members Natural): that object padded with
  ;;           spaces to N bytes; (List 'text String Symbol): a body sent as
  ;;           it is, and what the model says of it: 'not-json (invalid_json)
  ;;           or 'invalid (invalid_request)
  ;;   json?   whether the Content-Type is application/json
  ;; make-command-spec : Body Boolean -> CommandSpec
  (define-record-type command-spec (fields body json?))

  ;; make-tag-event : Symbol Natural Tag Bytevector (Listof Header) (U Natural #f) (Listof Symbol)
  ;;                  (U TagsListSpec CommandSpec) -> Event
  ;; KIND list-tags (with LIMIT), rename-tag or remove-tag, with HEADERS.
  (define (make-tag-event kind now tag key headers limit aims spec)
    (make-event* kind now tag key #f #f headers #f #f limit #f #f aims 'absent #f spec))

  ;; LinkSpec: what a link's request names beside its node (slice 5b)
  ;;   type       a PUT's or a DELETE's path type, a String sent as it is; a
  ;;              list's ?type=: #f for none, a String, or 'twice
  ;;   target     a PUT's or a DELETE's path target: an id, or a String sent
  ;;              as it is (a v4 id); #f for a list
  ;;   upper?     whether the target id is written in capitals
  ;;   direction  a list's ?direction=: #f for none, a String, or 'twice
  ;;   after      a list's first page's after: #f, or (type . id), sent as
  ;;              <type>:<id>
  ;; make-link-spec : (U String 'twice #f) (U Bytevector String #f) Boolean (U String 'twice #f)
  ;;                  (U (Pair String Bytevector) #f) -> LinkSpec
  (define-record-type (link-spec make-link-spec link-spec?) (fields type target upper? direction after))

  ;; make-link-event : Symbol Natural Tag Bytevector Bytevector (Listof Header) (U Natural #f)
  ;;                   Boolean (Listof Symbol) LinkSpec -> Event
  ;; A link's request: KIND link (its PUT), unlink (its DELETE) or
  ;; list-links (the GET), of node ID, with HEADERS, a list's LIMIT.
  (define (make-link-event kind now tag key id headers limit upper? aims spec)
    (make-event* kind now tag key id #f headers #f #f limit #f upper? aims 'absent spec #f))

  ;; link-kinds : (Listof Symbol)     a link's two writes; a list is a read
  (define link-kinds '(link unlink))
  (define (link-kind? k) (and (memq k link-kinds) #t))

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
  ;; expectation-jobs : Expectation -> Natural
  ;;   jobs           the write jobs the request makes (R15): none for a
  ;;                  read, and for a write refused before its job (a 400,
  ;;                  413 or 428 there); one for every other write
  (define-record-type expectation
    (fields status code etag location json items world cells problem touched clause situation jobs))

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
    (make-expectation status code #f #f #f #f w cells #f #f clause s 0))
  (define (cannot w cells why) (make-expectation #f #f #f #f #f #f w cells why #f #f no-situation 0))
  (define (read-answer w json items etag clause)
    (make-expectation 200 #f etag #f json items w '() #f #f clause no-situation 0))

  ;; refused-as : World Cells Decision String Situation -> Expectation
  ;; A write's refusal, DECISION (refuse status code [in-job]): no write job
  ;; for a 400, a 413 or a 428, which are answered before it, but the props'
  ;; 400 a replace that named no kind meets in its job (in-job); one for
  ;; every other.
  (define (refused-as w cells decision clause s)
    (make-expectation (cadr decision) (caddr decision) #f #f #f #f w cells #f #f clause s
                      (if (and (memv (cadr decision) '(400 413 428)) (not (memq 'in-job decision))) 0 1)))

  ;; props-shown : String MProps -> Any
  ;; What an answer shows of a KIND's props: as stored, with the kind's
  ;; defaults filled in (the plan). A Task's status, TODO when none is
  ;; stored (P9), and its closed, deadline and scheduled when there;
  ;; another kind's text as the JSON reader reads it, nothing filled in
  ;; (JSContact's defaults are the RFC's to imply). Members sorted, as
  ;; answers are compared.
  (define (props-shown kind p)
    (if (string=? kind "task")
        (sorted (append (list (cons "status" (mprops-status p)))
                        (if (mprops-closed p) (list (cons "closed" (mprops-closed p))) '())
                        (if (mprops-deadline p) (list (cons "deadline" (mprops-deadline p))) '())
                        (if (mprops-scheduled p) (list (cons "scheduled" (mprops-scheduled p))) '())))
        (sorted-json (json-of (mprops-text p)))))

  ;; node-json : MNode Boolean -> Alist
  ;; A live node as the plan shows it: its title, content type, props and
  ;; body its newest snapshot's (H2'), the body only when BODY?; its
  ;; revision, updated, state and parent its own: the parent's id in lower
  ;; case, or null at the top level; its tags its own present ones, sorted,
  ;; an array (slice 7a), [] for none.
  (define (node-json n body?)
    (let ((s (node-top n)))
      (sorted (append (list (cons "id" (id-text (mnode-id n))) (cons "kind" (mnode-kind n))
                            (cons "state" (symbol->string (mnode-state n)))
                            (cons "parent" (if (mnode-parent n) (id-text (mnode-parent n)) 'null))
                            (cons "title" (msnap-title s)))
                      (if body? (list (cons "body" (msnap-body s))) '())
                      (list (cons "content_type" (msnap-type s)) (cons "props" (props-shown (mnode-kind n) (msnap-props s)))
                            (cons "tags" (list->vector (mnode-tags n)))
                            (cons "revision" (node-rev n)) (cons "created" (mnode-created n))
                            (cons "updated" (mnode-updated n)))))))

  ;; snap-json : String MSnap Boolean -> Alist
  ;; A snapshot of a KIND's node: its props shown by its node's kind (a
  ;; Task's stored {} is TODO in every snapshot too: R8); its tags as they
  ;; were, only when BODY?: a snapshot whole shows them, the revisions list
  ;; does not (the review's blocker 7).
  (define (snap-json kind s body?)
    (sorted (append (list (cons "revision" (msnap-revision s)) (cons "title" (msnap-title s)))
                    (if body? (list (cons "body" (msnap-body s)) (cons "tags" (list->vector (msnap-tags s)))) '())
                    (list (cons "content_type" (msnap-type s)) (cons "props" (props-shown kind (msnap-props s)))
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

  ;;; The props' rules and the task table, in the model's own words (slice 6)

  ;; props-refusal : Event -> (U (List Natural String String) #f)
  ;; A PUT's props refused before its job (the plan's order, steps 4 and
  ;; 5), as (status code clause), or #f. A create with no props is as {};
  ;; a replace with none passes to its job (P11). The kind named judges
  ;; them; a replace that names none is refused only when no kind takes
  ;; them: 413 when one finds them over the cap, else 400. A create of a
  ;; Task that claims closed and no status but TODO is the 400 (P14).
  (define (props-refusal e)
    (let* ((c (event-content e))
           (create? (eq? (event-pre e) 'create))
           (entry (or (content-props c) (and create? empty-entry)))
           (kind (content-kind c)))
      (cond
       ((not entry) #f)
       (kind
        (let ((v (entry-verdict entry kind)))
          (cond ((eq? v 'invalid)
                 (list 400 "invalid_request" (format "props a ~a does not take are 400, before the job" kind)))
                ((eq? v 'too-large)
                 (list 413 "props_too_large" (format "props a ~a takes but over 4,096 bytes stored are 413, before the job" kind)))
                ((and create? (claim? v) (claim-closed v) (member (claim-status v) '(#f "TODO")))
                 (list 400 "invalid_request" "a create of a Task claiming closed with no status but TODO is 400, before the job (P14)"))
                (else #f))))
       (else
        (let ((vs (map (lambda (k) (entry-verdict entry k)) kinds)))
          (cond ((exists taken? vs) #f)
                ((memq 'too-large vs)
                 (list 413 "props_too_large" "props no kind takes, that one takes but over the cap, are 413, before the job"))
                (else (list 400 "invalid_request" "props no kind takes are 400, before the job, whatever the node"))))))))

  ;; put-refusal : Event -> (U (List Natural String String) #f)
  ;; A PUT's content refused before its job, in the routes' order (the
  ;; review's): the props' 400; then the tags' 400 (sent-tags); then the
  ;; props' 413. A request refused for its tags makes no write job (L10).
  (define (put-refusal e)
    (let ((p (props-refusal e))
          (t (sent-tags (content-tags (event-content e)) (eq? (event-pre e) 'create))))
      (cond ((and p (= (car p) 400)) p)
            ((eq? t 'invalid)
             (list 400 "invalid_request"
                   "tags that are no array of at most 50 tags the rule takes are 400, before the job, after the props' 400 and before any 413"))
            (else p))))

  ;; claim-differs? : Claim MProps -> (U Symbol #f)
  ;; Whether a replace's CLAIM of a Task's status or closed is not what is
  ;; stored, P (the stored status with its default, TODO): status, closed,
  ;; or #f when each is left out or equal.
  (define (claim-differs? v p)
    (cond ((and (claim-status v) (not (string=? (claim-status v) (mprops-status p)))) 'status)
          ((and (claim-closed v) (not (eqv? (claim-closed v) (mprops-closed p)))) 'closed)
          (else #f)))

  ;; replace-decision : MNode Content -> (values Decision String)
  ;; In the job, after 404, 412, wrong_state and kind_fixed: no props keep
  ;; the node's (P11); props the stored kind refuses (only a replace that
  ;; named no kind gets here with them) are the 400 in the job; a Task's
  ;; claim of another status or closed is 409 status_fixed; else the write.
  (define (replace-decision own c)
    (let ((entry (content-props c)))
      (if (not entry)
          (values '(write) "a replace with no props keeps the node's (P11): its next revision, in the same state and parent")
          (let ((v (entry-verdict entry (mnode-kind own))) (p (msnap-props (node-top own))))
            (cond ((not (taken? v))
                   (values (list 'refuse 400 "invalid_request" 'in-job)
                           (string-append "a replace that names no kind, with props only another kind takes, is 400 in"
                                          " the job, after 404, 412, wrong_state and kind_fixed")))
                  ((and (claim? v) (claim-differs? v p))
                   (values (refusal 409 "status_fixed")
                           "a replace's status or closed that is not the Task's own is 409 status_fixed, the last check"))
                  (else (values '(write) "a replace at the node's revision is its next, in the same state and parent")))))))

  ;; create-props : String (U Entry #f) Natural -> MProps
  ;; What a create of KIND stores: the entry's text; for a Task, the status
  ;; claimed (TODO when none) and, when that is not TODO, the closed given
  ;; or NOW, the write's time (P14); deadline and scheduled as given.
  (define (create-props kind entry now)
    (let ((v (entry-verdict (or entry empty-entry) kind)))
      (if (claim? v)
          (let ((status (or (claim-status v) "TODO")))
            (task-props status (and (not (string=? status "TODO")) (or (claim-closed v) now))
                        (claim-deadline v) (claim-scheduled v)))
          (plain-props v))))

  ;; replace-props : MNode Content -> MProps
  ;; What a replace stores: the node's own when none are sent (P11); the
  ;; entry's text for the stored kind; for a Task, its status and closed
  ;; kept, deadline and scheduled as sent (absent ones removed).
  (define (replace-props own c)
    (let ((entry (content-props c)) (p (msnap-props (node-top own))))
      (if (not entry)
          p
          (let ((v (entry-verdict entry (mnode-kind own))))
            (if (claim? v)
                (task-props (mprops-status p) (mprops-closed p) (claim-deadline v) (claim-scheduled v))
                (plain-props v))))))

  ;; restore-props : String MProps MProps -> MProps
  ;; What a restore of a KIND's snapshot SNAP stores over its PRESENT props:
  ;; the snapshot's; for a Task, the snapshot's deadline and scheduled with
  ;; the present status and closed (P10: only a command changes a status).
  (define (restore-props kind snap present)
    (if (string=? kind "task")
        (task-props (mprops-status present) (mprops-closed present) (mprops-deadline snap) (mprops-scheduled snap))
        snap))

  ;; task-moves : (Listof (List Symbol (Listof String) String))
  ;; P7's table, in the model's own words: each command, the statuses it is
  ;; taken from, and where it lands. From any other status it is 409
  ;; wrong_status: done on DONE, wontdo on WONTDO, reopen on TODO.
  (define task-moves
    '((done ("TODO" "WONTDO") "DONE")
      (wontdo ("TODO" "DONE") "WONTDO")
      (reopen ("DONE" "WONTDO") "TODO")))

  ;; task-events : (Listof Symbol)     the three commands, each its own route
  (define task-events (map car task-moves))
  (define (task-kind? k) (and (memq k task-events) #t))

  ;; closed-rule : String String -> Symbol
  ;; What a move from FROM to TO does to closed (P7): leaving TODO, close
  ;; (the write's time); landing on TODO, open (removed); between DONE and
  ;; WONTDO, keep.
  (define (closed-rule from to)
    (cond ((string=? from "TODO") 'close) ((string=? to "TODO") 'open) (else 'keep)))

  ;; TaskCell = (List 'task Found (U Symbol #f) (U String #f) (U String #f) Symbol)
  ;;   what the job finds, the node's state, its kind, a Task's status, the command
  ;; task-cell : World Event -> TaskCell
  (define (task-cell w e)
    (let* ((own (own-node w (event-tag e) (event-id e)))
           (pre (event-pre e))
           (kind (and own (mnode-kind own))))
      (list 'task
            (cond ((not own) 'none) ((and (integer? pre) (= (node-rev own) pre)) 'match) (else 'differ))
            (and own (mnode-state own))
            kind
            (and own (string=? kind "task") (mprops-status (msnap-props (node-top own))))
            (event-kind e))))

  ;; job-task-cell : World Event -> (U TaskCell #f)     #f for a command refused before its job
  (define (job-task-cell w e)
    (and (not (memq (event-pre e) '(missing invalid))) (task-cell w e)))

  (define (task-cell-text cell)
    (if cell
        (format "~a x ~a x ~a x ~a x ~a" (list-ref cell 1) (or (list-ref cell 2) "-") (or (list-ref cell 3) "-")
                (or (list-ref cell 4) "-") (list-ref cell 5))
        "no cell"))

  ;; decide-task : World Event -> (values (U TaskCell #f) Decision String)
  ;; TaskDecision = (List 'refuse Natural String) | (List 'transition String Symbol)
  ;; A command's answer by the plan's rules, the first that applies: no
  ;; precondition 428, a bad one (If-None-Match among them) 400, before its
  ;; job; no live node of the account's 404; stale 412, whatever the state
  ;; and the kind; a trashed node 409 wrong_state, whatever its kind; a node
  ;; that is no Task 409 not_a_task; a status the command is not taken from
  ;; 409 wrong_status; else the transition, to where the table lands, with
  ;; closed-rule's closed.
  (define (decide-task w e)
    (let ((pre (event-pre e)))
      (cond
       ((eq? pre 'missing)
        (values #f (refusal 428 "precondition_required") "a command with no precondition is 428, before its job"))
       ((eq? pre 'invalid)
        (values #f (refusal 400 "invalid_request")
                "a command's precondition of any other shape, If-None-Match among them, is 400"))
       (else
        (let* ((cell (task-cell w e))
               (found (list-ref cell 1)) (state (list-ref cell 2)) (kind (list-ref cell 3)) (status (list-ref cell 4))
               (move (assq (event-kind e) task-moves)))
          (cond
           ((eq? found 'none)
            (values cell not-found "a command on a node the account has not got, another's or a purged one, is 404"))
           ((eq? found 'differ)
            (values cell stale "a command at a revision the node is not at is 412, whatever its state, kind and status"))
           ((eq? state 'trashed)
            (values cell wrong-state "a command on a trashed node is 409 wrong_state, before its kind"))
           ((not (string=? kind "task"))
            (values cell (refusal 409 "not_a_task") "a command on a node that is no Task is 409 not_a_task"))
           ((not (member status (cadr move)))
            (values cell (refusal 409 "wrong_status")
                    (format "~a on a ~a Task is 409 wrong_status: it changes nothing" (event-kind e) status)))
           (else
            (values cell (list 'transition (caddr move) (closed-rule status (caddr move)))
                    (format "~a moves a ~a Task to ~a, closed ~a: its next revision, the content copied"
                            (event-kind e) status (caddr move) (closed-rule status (caddr move)))))))))))

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
       ((and (eq? (event-kind e) 'put) (put-refusal e))
        => (lambda (r) (values #f (refusal (car r) (cadr r)) (caddr r) no-situation)))
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
            (let-values (((decision clause) (replace-decision own (event-content e))))
              (values cell decision clause s)))
           (else
            (values cell '(copy) "a restore of a snapshot the node has, at its revision, is its next, in the same state and parent" s))))))))

  ;; expect : Twist World Event -> Expectation
  ;; TWIST is as-planned, or a changed rule for the suite's teeth.
  ;; A link's request is twisted as a write is: the twist sees its
  ;; LinkCell (#f for a 400) and decision, and no Situation.
  (define (expect twist w e)
    (cond ((task-kind? (event-kind e))
           (let-values (((cell decision clause) (decide-task w e)))
             (perform w e #f (twist cell decision no-situation) clause no-situation)))
          ((write-kind? (event-kind e))
           (let-values (((cell decision clause s) (decide w e)))
             (perform w e cell (twist cell decision s) clause s)))
          ((link-kind? (event-kind e))
           (let-values (((cell decision clause) (decide-link w e)))
             (perform-link w e cell (twist cell decision no-situation) clause)))
          ((step-kind? (event-kind e)) (expect-step w e))
          (else (expect-read w e))))

  ;;; The oracle of a tag's rename and removal (slice 7a)

  ;; step-kinds : (Listof Symbol)     the two commands, each its own route
  (define step-kinds '(rename-tag remove-tag))
  (define (step-kind? k) (and (memq k step-kinds) #t))

  ;; step-word : Symbol -> String     the count a command answers: renamed or removed
  (define (step-word kind) (if (eq? kind 'rename-tag) "renamed" "removed"))

  ;; members-verdict : Symbol (Listof (Pair String Value)) -> (U (List 'rename String String) (List 'remove String) 'invalid)
  ;; A command's object by the plan's rules: exactly the members it takes,
  ;; from and to for a rename, tag for a removal, by those names, in any
  ;; order, none twice, none other; each a tag the rule takes, as a JSON
  ;; string; for a rename, from and to two tags once stored. Else 'invalid.
  (define (members-verdict kind members)
    (let ((names (map car members))
          (want (if (eq? kind 'rename-tag) '("from" "to") '("tag"))))
      (if (and (= (length names) (length want))
               (for-all (lambda (n) (member n names)) want)
               (for-all (lambda (m) (and (tag-entry? (cdr m)) (tag-ok? (cdr m)))) members))
          (let ((stored (lambda (n) (tag-entry-stored (cdr (assoc n members))))))
            (cond ((eq? kind 'remove-tag) (list 'remove (stored "tag")))
                  ((string=? (stored "from") (stored "to")) 'invalid)
                  (else (list 'rename (stored "from") (stored "to")))))
          'invalid)))

  ;; command-cap : Natural     16 KiB: a command's body, as a move's (the plan's)
  (define command-cap 16384)

  ;; command-verdict : Event -> (values (U (List 'rename String String) (List 'remove String) Decision) String)
  ;; A tag's command by the review's order, the first that applies: an
  ;; If-Match or an If-None-Match, of any shape, 400, never 428 (it names no
  ;; one node); a media type that is not JSON 415; a body over 16 KiB 413
  ;; payload_too_large; one that is no JSON 400 invalid_json; one that is
  ;; not exactly what the command takes (members-verdict), or no object, or
  ;; empty, 400 invalid_request. Every one of these before the job. Else
  ;; the step; never 404, never 412.
  (define (command-verdict e)
    (let* ((spec (event-tagq e)) (body (command-spec-body spec)))
      (cond
       ((pair? (event-headers e))
        (values (refusal 400 "invalid_request") "If-Match or If-None-Match on a tag's command is 400, never 428, before any job"))
       ((not (command-spec-json? spec))
        (values (refusal 415 "unsupported_media_type") "a tag's command with a media type that is not JSON is 415, before the job"))
       ((and (eq? (car body) 'padded) (> (caddr body) command-cap))
        (values (refusal 413 "payload_too_large") "a tag's command's body over 16 KiB is 413, before the job"))
       ((and (eq? (car body) 'text) (eq? (caddr body) 'not-json))
        (values (refusal 400 "invalid_json") "a tag's command's body that is no JSON is 400 invalid_json, before the job"))
       ((eq? (car body) 'text)
        (values (refusal 400 "invalid_request") "a tag's command's body that is no object, or none, is 400, before the job"))
       (else
        (let ((v (members-verdict (event-kind e) (cadr body))))
          (if (eq? v 'invalid)
              (values (refusal 400 "invalid_request")
                      "a tag's command's object that is not exactly its members, each a tag the rule takes, from and to two tags, is 400, before the job")
              (values v (format "a step of ~a takes the first min(500, carriers) by id, in every live state, each bumped with a change row tags, no snapshot"
                                (event-kind e)))))))))

  ;; retagged-set : (Listof String) String (U String #f) -> (Listof String)
  ;; A carrier's tags after a step: FROM taken off, TO put on (a rename;
  ;; #f for a removal), each once: a rename onto a tag the node has is a
  ;; merge.
  (define (retagged-set tags from to)
    (tag-set (append (filter (lambda (t) (not (string=? t from))) tags) (if to (list to) '()))))

  ;; take* : (Listof A) Natural -> (Listof A)     the first N
  (define (take* xs n) (if (or (null? xs) (= n 0)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))

  ;; carriers-of : World Tag String -> (Listof MNode)
  ;; TAG's live nodes that carry T, by id: every live state (L13); a
  ;; purged node carries none.
  (define (carriers-of w tag t) (by-id (filter (lambda (n) (member t (mnode-tags n))) (nodes-of w tag))))

  ;; expect-step : World Event -> Expectation
  ;; A command's answer, and the step done to the world (G8, L5): the
  ;; first min(500, carriers) of FROM's by id, in any live state, each at
  ;; its next revision, updated now, with the owner's next change row tags
  ;; at it, in id order; their tags retagged; no snapshot. A tag no node of
  ;; the account carries touches none: {WORD: 0, "left": 0}, never a 404.
  ;; 200, {WORD: touched, "left": the carriers after}, no ETag, and the
  ;; asking key's last_used set when due. A refusal changes nothing and
  ;; makes no write job.
  (define (expect-step w e)
    (let-values (((v clause) (command-verdict e)))
      (if (eq? (car v) 'refuse)
          (refused w '() (cadr v) (caddr v) clause no-situation)
          (let* ((tag (event-tag e)) (now (event-now e))
                 (from (cadr v)) (to (and (eq? (car v) 'rename) (caddr v)))
                 (carriers (carriers-of w tag from))
                 (touched (take* carriers step-most))
                 (w1 (fold-left (lambda (w n)
                                  (let ((m (with-retag n (retagged-set (mnode-tags n) from to) now)))
                                    (world-with-change (world-with-node w m) tag (mnode-id m) (node-rev m) "tags" now)))
                                w touched))
                 (due (touch-due? (world-key-last-used w (event-key e)) now))
                 (w2 (if due (world-touched w1 (event-key e) now) w1)))
            (make-expectation 200 #f #f #f
                              (sorted (list (cons (step-word (event-kind e)) (length touched))
                                            (cons "left" (- (length carriers) (length touched)))))
                              #f w2 '() #f due clause no-situation 1)))))

  ;;; The oracle of a link's PUT and DELETE (slice 5b)

  ;; link-bad : Event -> (U Symbol #f)
  ;; Why a link's PUT or DELETE is the 400 before any job, the first that
  ;; applies, or #f: a type not of the three (exact case), a target that is
  ;; no v7 id, a node linked to itself (K2), an If-Match or If-None-Match
  ;; of any shape (a link takes no precondition).
  (define (link-bad e)
    (let ((spec (event-link e)))
      (cond ((not (member (link-spec-type spec) link-type-names)) 'type)
            ((not (bytevector? (link-spec-target spec))) 'target)
            ((bytevector=? (event-id e) (link-spec-target spec)) 'self)
            ((pair? (event-headers e)) 'precondition)
            (else #f))))

  ;; LinkCell = (List (U Symbol #f) (U Symbol #f) Symbol Boolean)
  ;; link-cell : World Event -> LinkCell
  ;; What a link's job finds, by the model's reading, in link-command's
  ;; terms: the source's state (#f when it is no live node of the
  ;; account's: none, another's, purged); the target's, the same, and #f
  ;; for an unlink, whose job reads no target; the event; and whether the
  ;; account has the link. For a request that passed link-bad.
  (define (link-cell w e)
    (let* ((spec (event-link e)) (tag (event-tag e)) (kind (event-kind e))
           (source (own-node w tag (event-id e)))
           (target (and (eq? kind 'link) (own-node w tag (link-spec-target spec)))))
      (list (and source (mnode-state source)) (and target (mnode-state target)) kind
            (and (link-in w tag (event-id e) (link-spec-type spec) (link-spec-target spec)) #t))))

  (define (link-cell-text cell)
    (if cell
        (format "~a x ~a x ~a x ~a" (or (car cell) "-") (or (cadr cell) "-") (caddr cell)
                (if (cadddr cell) "there" "absent"))
        "no cell"))

  ;; decide-link : World Event -> (values (U LinkCell #f) Decision String)
  ;; LinkDecision = (List 'refuse Natural String) | (List 'link) | (List 'keep) | (List 'unlink)
  ;; A link's PUT or DELETE by the brief's rules, the first that applies,
  ;; and the clause that gives it.
  (define (decide-link w e)
    (let ((bad (link-bad e)))
      (if bad
          (values #f (refusal 400 "invalid_request")
                  (case bad
                    ((type) "a link's type not of the three, in another case too, is 400, before any job")
                    ((target) "a link's target that is no v7 id is 400, before any job")
                    ((self) "a node linked to itself is 400, before any job (K2)")
                    (else "If-Match or If-None-Match on a link's PUT or DELETE is 400: a link takes no precondition")))
          (let* ((cell (link-cell w e))
                 (source (car cell)) (target (cadr cell)) (there? (cadddr cell)))
            (let-values
                (((decision clause)
                  (if (eq? (caddr cell) 'link)
                      (cond ((not source)
                             (values not-found "a link's source that is no live node of the account's, another's or a purged one, is 404 (K8)"))
                            ((not target)
                             (values not-found "a link's target that is no live node of the account's is 404, before any 409 (K8)"))
                            (there?
                             (values '(keep) "a PUT of a link that is there is 200 with its stored created, nothing written, whatever the ends' states"))
                            ((not (and (memq source linkable-states) (memq target linkable-states)))
                             (values wrong-state "a link to or from a trashed node is 409 wrong_state (K6)"))
                            (else (values '(link) "a link between two live nodes of the account's, neither trashed, is made: 201")))
                      (cond ((not source)
                             (values not-found "a DELETE whose source is no live node of the account's is 404 (K8)"))
                            (there?
                             (values '(unlink) "a DELETE of a link that is there removes it, whatever the states: 204"))
                            (else (values not-found "a DELETE of a link that is not there is 404 (K8); its target is not read"))))))
              (values cell decision clause))))))

  ;; link-json : Bytevector String Bytevector Natural -> Alist
  ;; A link in a PUT's answer: source, type, target (ids in lower case), created.
  (define (link-json source type target created)
    (sorted (list (cons "source" (id-text source)) (cons "type" type) (cons "target" (id-text target))
                  (cons "created" created))))

  ;; perform-link : World Event (U LinkCell #f) LinkDecision String -> Expectation
  ;; The decision done to the world. link adds the account's link, made
  ;; now, and its change row link on the source at the source's revision;
  ;; unlink removes it, with a change row unlink; keep changes no row. Each
  ;; of the three sets the asking key's last_used when due; a refusal
  ;; changes nothing. One that makes no sense for the request (a link made
  ;; that is there, a kept or removed link that is not, a link's event on
  ;; the other route) is a step the model cannot take.
  (define (perform-link w e cell decision clause)
    (let* ((tag (event-tag e)) (kind (event-kind e)) (now (event-now e)) (spec (event-link e))
           (source (event-id e)) (type (link-spec-type spec)) (target (link-spec-target spec))
           (own (own-node w tag source))
           (there (and cell (link-in w tag source type target)))
           (at (format "~a names ~s" (link-cell-text cell) decision))
           (due (touch-due? (world-key-last-used w (event-key e)) now))
           (touched (lambda (w) (if due (world-touched w (event-key e) now) w))))
      (case (car decision)
        ((refuse) (refused-as w '() decision clause no-situation))
        ((link)
         (cond ((not (and cell (eq? kind 'link))) (cannot w '() (string-append at ", which only a link's PUT performs")))
               ((not (and own (own-node w tag target))) (cannot w '() (string-append at ", but an end is no live node of the account's")))
               (there (cannot w '() (string-append at " of a link that is there")))
               (else
                (let ((w1 (world-with-change (world-with-links w (append (world-links w) (list (make-mlink tag source type target now))))
                                             tag source (node-rev own) "link" now)))
                  (make-expectation 201 #f #f #f (link-json source type target now) #f (touched w1) '() #f due
                                    clause no-situation 1)))))
        ((keep)
         (if (and there (eq? kind 'link))
             (make-expectation 200 #f #f #f (link-json source type target (mlink-created there)) #f (touched w) '() #f
                               due clause no-situation 1)
             (cannot w '() (string-append at ", but no such link of the account's is there, or this is no PUT"))))
        ((unlink)
         (cond ((not (and there (eq? kind 'unlink) own))
                (cannot w '() (string-append at ", but no such link of the account's is there, or this is no DELETE")))
               (else
                (let ((w1 (world-with-change (world-with-links w (filter (lambda (l) (not (eq? l there))) (world-links w)))
                                             tag source (node-rev own) "unlink" now)))
                  (make-expectation 204 #f #f #f 'empty #f (touched w1) '() #f due clause no-situation 1)))))
        (else (cannot w '() (string-append at ", which no link's request performs"))))))

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
        ((refuse) (refused-as w cells decision clause s))
        ((insert)
         (cond ((not (and (eq? kind 'put) (eq? pre 'create)))
                (cannot w cells (string-append at ", which only a create performs")))
               ((world-node w id) (cannot w cells (string-append at " on an id in use")))
               (else
                (let* ((c (event-content e)) (tags (sent-tags (content-tags c) #t)))
                  (if (eq? tags 'invalid)
                      (cannot w cells (string-append at ", whose tags the rule refuses"))
                      (accepted w e (make-mnode id tag (next-label w) (content-kind c) now 'active 1 now
                                                (list (make-msnap 1 (content-title c) (content-body c)
                                                                  (content-type c)
                                                                  (create-props (content-kind c) (content-props c) now)
                                                                  now tag tags))
                                                (event-parent-id e) tags)
                                "create" 201 #t cells clause s))))))
        ((write)
         (cond ((not (eq? kind 'put)) (cannot w cells (string-append at ", which only a PUT performs")))
               ((not at-pre?) (cannot w cells off-pre))
               (else
                (let* ((c (event-content e)) (tags (sent-tags (content-tags c) #f)))
                  (if (eq? tags 'invalid)
                      (cannot w cells (string-append at ", whose tags the rule refuses"))
                      ;; G2: no tags member keeps the node's present tags
                      (accepted w e (with-snap own (content-title c) (content-body c) (content-type c)
                                               (replace-props own c) (if (eq? tags 'absent) (mnode-tags own) tags) now)
                                "update" 200 #t cells clause s))))))
        ((copy)
         (let ((snap (and own (eq? kind 'restore) (snap-of own (event-snap e)))))
           (cond ((not (eq? kind 'restore)) (cannot w cells (string-append at ", which only a restore performs")))
                 ((not at-pre?) (cannot w cells off-pre))
                 ((not snap) (cannot w cells (string-append at " of a snapshot the node does not have")))
                 (else
                  ;; L11: the snapshot's tags as stored, never folded again; one from
                  ;; before migration 7 holds none, and clears them
                  (accepted w e (with-snap own (msnap-title snap) (msnap-body snap) (msnap-type snap)
                                           (restore-props (mnode-kind own) (msnap-props snap)
                                                          (msnap-props (node-top own)))
                                           (msnap-tags snap) now)
                            "restore" 200 #t cells clause s)))))
        ((transition)
         (cond ((not (task-kind? kind)) (cannot w cells (string-append at ", which only a Task's command performs")))
               ((not at-pre?) (cannot w cells off-pre))
               ((not (string=? (mnode-kind own) "task")) (cannot w cells (string-append at " of a node that is no Task")))
               ((not (member (cadr decision) '("TODO" "DONE" "WONTDO")))
                (cannot w cells (string-append at ", a status no Task has")))
               (else
                (let* ((top (node-top own)) (p (msnap-props top))
                       (closed (case (caddr decision) ((close) now) ((keep) (mprops-closed p)) (else #f))))
                  ;; the node's present tags, kept, into the new snapshot (L3)
                  (accepted w e (with-snap own (msnap-title top) (msnap-body top) (msnap-type top)
                                           (task-props (cadr decision) closed (mprops-deadline p) (mprops-scheduled p))
                                           (mnode-tags own) now)
                            (symbol->string kind) 200 #f cells clause s)))))
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
               (else (accepted (world-without-links-at w id) e (emptied own now) "purge" 204 #f cells clause s))))
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
          (make-expectation 204 #f #f #f 'empty #f w3 cells #f due clause s 1)
          (make-expectation status #f (etag-of (node-rev n))
                            (and (= status 201) (string-append "/v1/nodes/" (id-text (mnode-id n))))
                            (node-json n body?) #f w3 cells #f due clause s 1))))

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
                        #f w2 cells #f due clause s 1)))

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
         (let* ((s (list-state (event-query e)))
                (p (ref-meaning (event-parent e)))
                (f (event-tagq e))
                (tags (if f (filter-tags-of (filter-spec-values f)) '()))
                (after (and f (filter-spec-after f))))
           (cond
            ((or (eq? s 'invalid) (eq? p 'invalid))
             (refused w '() 400 "invalid_request"
                      (string-append "a ?state= that names no live state, or a ?parent= that is neither null"
                                     " nor one v7 id, is 400")
                      no-situation))
            ((eq? tags 'invalid)
             (refused w '() 400 "invalid_request"
                      "more than 10 ?tag= as sent, or one the rule refuses, an empty one too, is 400, after limit, after, state and parent, before the job"
                      no-situation))
            ((and (bytevector? p) (not (own-node w (event-tag e) p)))
             (refused w '() 404 "not_found"
                      "a ?parent= that is no live node of the account's, another's or a purged one, is 404"
                      no-situation))
            (else
             (read-answer w #f
                          (map (lambda (n) (node-json n #f))
                               (by-id (filter (lambda (n) (and (eq? (mnode-state n) s) (under? n p)
                                                               (for-all (lambda (t) (member t (mnode-tags n))) tags)
                                                               (or (not after) (bytevector<? after (mnode-id n)))))
                                              (nodes-of w (event-tag e)))))
                          #f (format "a list is the account's own ~a nodes~a~a, by id, with no bodies" s
                                     (cond ((eq? p 'any) "") ((not p) " at the top level") (else " under the parent"))
                                     (if (pair? tags) (format " that carry each of ~s" tags) "")))))))
        ((list-tags) (expect-tags-list w e))
        ((list-revisions)
         (if own
             (read-answer w #f (map (lambda (s) (snap-json (mnode-kind own) s #f)) (mnode-snaps own)) #f
                          "a node's snapshots, newest first, gaps where its state changed")
             (refused w '() 404 "not_found" gone no-situation)))
        ((get-snapshot)
         (let ((s (and own (snap-of own (event-snap e)))))
           (if s
               (read-answer w (snap-json (mnode-kind own) s #t) #f #f "a snapshot of the account's own node is shown")
               (refused w '() 404 "not_found"
                        "a snapshot no live node of the account's has, a gap's among them, is 404" no-situation))))
        ((list-links) (expect-links w e own))
        (else (cannot w '() (format "no such request: ~a" (event-kind e)))))))

  ;; tag-counts : World Tag -> (Listof (Pair String Natural))
  ;; TAG's tags, each once, sorted by code point, each with how many of
  ;; its live nodes carry it, in any state, stopped at 1,000 (G6, H6).
  (define (tag-counts w tag)
    (let ((t (make-hashtable string-hash string=?)))
      (for-each (lambda (n) (for-each (lambda (x) (hashtable-update! t x (lambda (c) (+ c 1)) 0)) (mnode-tags n)))
                (nodes-of w tag))
      (map (lambda (x) (cons x (min count-most (hashtable-ref t x 0))))
           (list-sort string<? (vector->list (hashtable-keys t))))))

  ;; tag-item-json : (Pair String Natural) -> Alist     {"tag", "count"}
  (define (tag-item-json p) (sorted (list (cons "tag" (car p)) (cons "count" (cdr p)))))

  ;; expect-tags-list : World Event -> Expectation
  ;; GET /v1/tags (G6, the review's blocker 5), the first that applies: an
  ;; after given twice, or one the rule refuses, is 400, before the job;
  ;; else the account's tags after the after's stored form, in order, each
  ;; with its count (tag-counts), paged by limit and after; none is an
  ;; empty page.
  (define (expect-tags-list w e)
    (let ((a (tags-list-spec-after (event-tagq e))))
      (if (or (eq? a 'twice) (and (pair? a) (not (tag-ok? (cadr a)))))
          (refused w '() 400 "invalid_request" "a tags list's after given twice, or one the rule refuses, is 400, before the job"
                   no-situation)
          (let ((after (and (pair? a) (tag-entry-stored (cadr a)))))
            (read-answer w #f
                         (map tag-item-json
                              (filter (lambda (p) (or (not after) (string<? after (car p)))) (tag-counts w (event-tag e))))
                         #f "the tags list is the account's tags, by code point, each with its count of nodes in any state, stopped at 1,000")))))

  ;; link-direction : (U String 'twice #f) -> (U 'out 'in 'invalid)
  ;; K3 and the review: none is out; out and in, exactly; anything else,
  ;; another case, twice, 400.
  (define (link-direction q)
    (cond ((not q) 'out)
          ((equal? q "out") 'out)
          ((equal? q "in") 'in)
          (else 'invalid)))

  ;; link-type-filter : (U String 'twice #f) -> (U String #f 'invalid)
  ;; None is every type; one of the three, exactly, that one; else 400.
  (define (link-type-filter q)
    (cond ((not q) #f)
          ((and (string? q) (member q link-type-names)) q)
          (else 'invalid)))

  ;; link-items : World Tag Bytevector (U 'out 'in) (U String #f) (U (Pair String Bytevector) #f)
  ;;              -> (U (Listof (Pair MLink MNode)) #f)
  ;; ID's links that way of TAG's (ID the source for out, the target for
  ;; in), of TYPE or all, each with the node at the other end, by the type's
  ;; name then that node's id, after AFTER's place; #f when an other end is
  ;; no live node of TAG's, which no rule allows.
  (define (link-items w tag id dir type after)
    (let* ((other-of (lambda (l) (if (eq? dir 'out) (mlink-target l) (mlink-source l))))
           (mine (filter (lambda (l) (and (eq? (mlink-tag l) tag)
                                          (bytevector=? (if (eq? dir 'out) (mlink-source l) (mlink-target l)) id)
                                          (or (not type) (string=? type (mlink-type l)))))
                         (world-links w)))
           (pairs (map (lambda (l) (cons l (own-node w tag (other-of l)))) mine)))
      (and (for-all cdr pairs)
           (filter (lambda (p) (or (not after)
                                   (link<? (car after) (cdr after) (mlink-type (car p)) (mnode-id (cdr p)))))
                   (list-sort (lambda (x y) (link<? (mlink-type (car x)) (mnode-id (cdr x))
                                                    (mlink-type (car y)) (mnode-id (cdr y))))
                              pairs)))))

  ;; link-item-json : (Pair MLink MNode) -> Alist
  ;; A link list's item: type, created, and the other node as the nodes
  ;; list shows it, without its body (Q14).
  (define (link-item-json p)
    (sorted (list (cons "type" (mlink-type (car p))) (cons "created" (mlink-created (car p)))
                  (cons "node" (node-json (cdr p) #f)))))

  ;; expect-links : World Event (U MNode #f) -> Expectation
  ;; GET /v1/nodes/{id}/links, the first that applies: a ?direction= or a
  ;; ?type= of another spelling is 400; an after of another type than
  ;; ?type= is 400 (Q21); both before the job. A node that is no live node
  ;; of the account's is 404, not an empty page. Else its links that way,
  ;; ordered and paged (Q10); a trashed or an archived node's too (K6). An
  ;; If-Match on it is ignored, as on every GET.
  (define (expect-links w e own)
    (let* ((spec (event-link e))
           (dir (link-direction (link-spec-direction spec)))
           (type (link-type-filter (link-spec-type spec)))
           (after (link-spec-after spec)))
      (cond
       ((or (eq? dir 'invalid) (eq? type 'invalid))
        (refused w '() 400 "invalid_request" "a ?direction= but out or in, or a ?type= not of the three, is 400"
                 no-situation))
       ((and type after (not (string=? type (car after))))
        (refused w '() 400 "invalid_request" "an after of another type than ?type= is 400, before the job (Q21)"
                 no-situation))
       ((not own)
        (refused w '() 404 "not_found"
                 "a link list of a node the account has not got, another's or a purged one, is 404, not an empty page"
                 no-situation))
       (else
        (let ((items (link-items w (event-tag e) (event-id e) dir type after)))
          (if items
              (read-answer w #f (map link-item-json items) #f
                           (format "a link list is the node's ~a links~a, by type then the other node's id, each that node as the nodes list shows it"
                                   dir (if type (string-append " of " type) "")))
              (cannot w '() "a link of the account's whose other end is no live node of its")))))))

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
        (format " ~a~s ~s ~s~a~a~a" (if (content-kind c) (string-append (content-kind c) " ") "")
                (content-title c) (content-body c) (content-type c)
                (let ((p (content-props c))) (if p (format " props ~a ~a" (entry-name p) (entry-sent p)) ""))
                (if (eq? (content-parent c) 'absent) "" (string-append ", parent " (ref-label w (content-parent c))))
                (let ((ts (content-tags c)))
                  (cond ((eq? ts 'absent) "")
                        ((eq? (car ts) 'entries)
                         (format ", tags [~a]" (join (map (lambda (e) (format "~a" (tag-entry-name e))) (cadr ts)) " ")))
                        (else (format ", tags ~a" (cadr ts))))))
        ""))

  ;; query-tag-label : QueryTag -> String
  (define (query-tag-label q)
    (cond ((eq? q 'bare) "tag (no =)")
          ((eq? (car q) 'entry) (format "~a~s~a" (tag-entry-name (cadr q)) (tag-entry-sent (cadr q))
                                        (if (eq? (caddr q) 'plus) " (spaces as +)" "")))
          (else (format "~a ~s" (caddr q) (cadr q)))))

  ;; command-body-label : Body -> String
  (define (command-body-label b)
    (case (car b)
      ((members) (string-append "{" (join (map (lambda (m) (format "~s: ~a" (car m)
                                                                 (if (tag-entry? (cdr m))
                                                                     (format "~a~s" (tag-entry-name (cdr m)) (tag-entry-sent (cdr m)))
                                                                     (cadr (cdr m)))))
                                               (cadr b))
                                          ", ")
                                "}"))
      ((padded) (format "~a padded to ~a bytes" (command-body-label (list 'members (cadr b))) (caddr b)))
      (else (format "the text ~s" (cadr b)))))

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
        ((done wontdo reopen)
         (format "~a POST ~a /~a, ~a" at target (event-kind e) (headers-text (event-headers e))))
        ((get-node) (format "~a GET ~a" at target))
        ((move move-children)
         (format "~a POST ~a /~a to ~a, ~a" at target (event-kind e) (ref-label w (event-parent e))
                 (headers-text (event-headers e))))
        ((list-nodes) (format "~a GET /v1/nodes state=~a parent=~a limit=~a~a" at (event-query e)
                              (ref-label w (event-parent e)) (event-limit e)
                              (let ((f (event-tagq e)))
                                (if f
                                    (format " tags ~a after=~a" (join (map query-tag-label (filter-spec-values f)) " ")
                                            (let ((a (filter-spec-after f))) (if a (node-label w a) "none")))
                                    ""))))
        ((list-tags) (format "~a GET /v1/tags limit=~a after=~a" at (event-limit e)
                             (let ((a (tags-list-spec-after (event-tagq e))))
                               (cond ((not a) "none") ((eq? a 'twice) "twice") (else (query-tag-label a))))))
        ((rename-tag remove-tag)
         (let ((spec (event-tagq e)))
           (format "~a POST /v1/tags/~a ~a~a~a" at (if (eq? (event-kind e) 'rename-tag) "rename" "remove")
                   (command-body-label (command-spec-body spec))
                   (if (command-spec-json? spec) "" ", text/plain")
                   (if (pair? (event-headers e)) (string-append ", " (headers-text (event-headers e))) ""))))
        ((list-revisions) (format "~a GET revisions of ~a limit=~a" at target (event-limit e)))
        ((get-snapshot) (format "~a GET ~a snapshot ~a" at target (event-snap e)))
        ((link unlink)
         (let* ((spec (event-link e)) (t (link-spec-target spec)))
           (format "~a ~a link from ~a, ~s, to ~a~a, ~a" at (if (eq? (event-kind e) 'link) "PUT" "DELETE") target
                   (link-spec-type spec) (if (bytevector? t) (node-label w t) (format "~s" t))
                   (if (link-spec-upper? spec) " (in capitals)" "") (headers-text (event-headers e)))))
        ((list-links)
         (let ((spec (event-link e)))
           (format "~a GET links of ~a direction=~a type=~a limit=~a after=~a~a" at target (link-spec-direction spec)
                   (link-spec-type spec) (event-limit e)
                   (let ((a (link-spec-after spec)))
                     (if a (string-append (car a) ":" (substring (id-text (cdr a)) 24 36)) "none"))
                   (if (pair? (event-headers e)) (string-append ", " (headers-text (event-headers e))) ""))))
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

  ;; random-content : Rng (U String #f) ParentRef (U Entry #f) -> Content     with no tags member
  (define (random-content rng kind parent props) (random-tagged-content rng kind parent props 'absent))

  ;; random-tagged-content : Rng (U String #f) ParentRef (U Entry #f) TagsSent -> Content
  (define (random-tagged-content rng kind parent props tags)
    (let* ((title (rng-pick! rng title-pool))
           (body (rng-pick! rng body-pool))
           (type (rng-pick! rng type-pool)))
      (make-tagged-content kind title body type props parent tags)))

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
                                           (if (pair? archived) '((10 . archived)) '())
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
                                           (if (pair? kids) '((10 . child)) '())
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
                                                               ((done wontdo reopen) 'create-on-task)
                                                               (else 'create-on-lifecycle))
                                                             (cons "If-None-Match" "*"))))
                                                (list c c c)))))))
      (values (cdr choice) (sym "bad-" (car choice)))))

  ;; The routes a write is sent to with no precondition, or a bad one: a
  ;; PUT most, then a restore, then each state change, each move, and each
  ;; of a Task's commands.
  (define bare-routes
    '(put put put put put restore restore archive unarchive trash untrash purge move move-children
      done wontdo reopen))

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
           (props (safe-props rng kind))
           (tags (safe-tags rng))
           (c (random-tagged-content rng kind parent props tags)))
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

  ;;; The generator's links (slice 5b)

  ;; Degree = (Bytevector -> Natural)     how many links a node has, both ways
  ;; link-degree : World -> Degree        counted once a request
  (define (link-degree w)
    (let ((t (make-id-table)))
      (for-each (lambda (l)
                  (hashtable-update! t (mlink-source l) (lambda (n) (+ n 1)) 0)
                  (hashtable-update! t (mlink-target l) (lambda (n) (+ n 1)) 0))
                (world-links w))
      (lambda (id) (hashtable-ref t id 0))))

  ;; pick-end : Rng (Listof MNode) Degree (Listof Natural) -> MNode
  ;; One of NS (not empty), its state chosen first among the states they
  ;; are in, by WEIGHTS for active, archived and trashed; then half the
  ;; time the one with the most links, so that lists page and purges take
  ;; links both ways.
  (define (pick-end rng ns degree weights)
    (let* ((states (filter (lambda (s) (exists (lambda (n) (eq? (mnode-state n) s)) ns)) live-states))
           (s (rng-weighted! rng (map (lambda (s) (cons (list-ref weights (if (eq? s 'active) 0 (if (eq? s 'archived) 1 2))) s))
                                      states))))
      (pick-node rng (in-state s ns) (lambda (n) (degree (mnode-id n))))))

  ;; A fresh pair's ends are mostly linkable, so links grow; any end of
  ;; another aim is as often trashed as archived.
  (define fresh-weights '(6 3 1))
  (define end-weights '(4 2 2))

  ;; bad-end : Rng World Tag -> (values Bytevector Symbol)
  ;; An id that is no live node of TAG's: a fresh id; a purged node's,
  ;; either account's; the other account's live node.
  ;; A purged node is the account's own half the time it can be.
  (define (bad-end rng w tag)
    (let* ((theirs (nodes-of w (other-tag tag)))
           (gone (filter (lambda (n) (not (live? n))) (world-nodes w)))
           (gone-own (purged-of w tag))
           (aim (rng-weighted! rng (append '((3 . missing))
                                           (if (pair? gone) '((2 . purged)) '())
                                           (if (pair? gone-own) '((2 . purged-own)) '())
                                           (if (pair? theirs) '((4 . other)) '())))))
      (case aim
        ((purged) (values (mnode-id (rng-pick! rng gone)) 'purged))
        ((purged-own) (values (mnode-id (rng-pick! rng gone-own)) 'purged))
        ((other) (values (mnode-id (rng-pick! rng theirs)) 'other))
        (else (values (fresh-node-id rng w) 'missing)))))

  ;; bad-link-types : (Listof String)     path types K1 refuses: other cases, other words
  (define bad-link-types '("Related" "MENTIONS" "Blocks" "blocker" "relates" "link"))

  ;; choose-link-pair : Rng World Tag Symbol Degree
  ;;                    -> (values Bytevector String Bytevector Symbol)
  ;; A PUT's (EVENT link) or a DELETE's (unlink) source, type and target:
  ;; a link of the account's that is there (most often for a DELETE); a
  ;; fresh pair of its live nodes (most often for a PUT); a source that is
  ;; no live node of its, the target its node three times in four; its
  ;; node and a target that is none; the other account's link, asked by
  ;; this one; or a node to itself. Half the time a link that is there
  ;; has an end archived or trashed (for a DELETE, its source: the target is
  ;; not read), when one has.
  (define (choose-link-pair rng w tag event degree)
    (let* ((own (nodes-of w tag))
           (mine (filter (lambda (l) (eq? (mlink-tag l) tag)) (world-links w)))
           (theirs (filter (lambda (l) (not (eq? (mlink-tag l) tag))) (world-links w)))
           (put? (eq? event 'link))
           (aim (rng-weighted! rng (append (if (pair? mine) (list (cons (if put? 16 40) 'there)) '())
                                           (if (>= (length own) 2) (list (cons (if put? 64 16) 'fresh)) '())
                                           (list (cons (if put? 8 6) 'source-bad))
                                           (if (pair? own) (list (cons (if put? 10 6) 'target-bad)) '())
                                           (if (pair? theirs) '((5 . other-link)) '())
                                           (if (pair? own) '((2 . self)) '())))))
      (case aim
        ((there other-link)
         (let* ((pool (if (eq? aim 'there) mine theirs))
                (aside (filter (lambda (l) (exists (lambda (id) (let ((n (world-node w id)))
                                                                  (and n (not (eq? (mnode-state n) 'active)))))
                                                   (if put? (list (mlink-source l) (mlink-target l)) (list (mlink-source l)))))
                               pool))
                (l (rng-pick! rng (if (and (pair? aside) (= 0 (rng-below! rng 2))) aside pool))))
           (values (mlink-source l) (mlink-type l) (mlink-target l) (sym "link-pair-" aim))))
        ((fresh)
         (let* ((hub (lambda (ns)
                       (if (= 0 (rng-below! rng 3))
                           (fold-left (lambda (best n) (if (> (degree (mnode-id n)) (degree (mnode-id best))) n best))
                                      (car ns) (cdr ns))
                           (pick-end rng ns degree fresh-weights))))
                (s (hub own))
                (t (hub (filter (lambda (n) (not (same-node? n s))) own)))
                (type (rng-pick! rng link-type-names)))
           (values (mnode-id s) type (mnode-id t) 'link-pair-fresh)))
        ((source-bad)
         (let*-values (((s why) (bad-end rng w tag))
                       ((t-own?) (and (pair? own) (< (rng-below! rng 4) 3)))
                       ((t t-why) (if t-own? (values (mnode-id (pick-end rng own degree end-weights)) 'own) (bad-end rng w tag)))
                       ((t) (if (bytevector=? s t) (fresh-node-id rng w) t))
                       ((type) (rng-pick! rng link-type-names)))
           (values s type t (sym "link-pair-source-" why))))
        ((target-bad)
         (let*-values (((s) (pick-end rng own degree end-weights))
                       ((t why) (bad-end rng w tag))
                       ((type) (rng-pick! rng link-type-names)))
           (values (mnode-id s) type t (sym "link-pair-target-" why))))
        (else
         (let* ((s (pick-end rng own degree end-weights)) (type (rng-pick! rng link-type-names)))
           (values (mnode-id s) type (mnode-id s) 'link-pair-self))))))

  ;; link-write-event : Rng World Natural Tag Bytevector Symbol Symbol Boolean Degree -> Event
  ;; A link's PUT or DELETE: the pair choose-link-pair gives; one time in
  ;; 25 a type K1 refuses, one in 33 a v4 target, one in 20 a precondition
  ;; (each the 400); the target in capitals one time in six.
  (define (link-write-event rng w now tag key event wait upper? degree)
    (let*-values (((source type target pair-aim) (choose-link-pair rng w tag event degree))
                  ((r) (rng-below! rng 100))
                  ((t-upper?) (= 0 (rng-below! rng 6)))
                  ((type) (if (< r 4) (rng-pick! rng bad-link-types) type))
                  ((target) (if (and (>= r 4) (< r 7)) (v4-text rng w) target))
                  ((headers) (if (and (>= r 7) (< r 12))
                                 (rng-pick! rng (list (list (cons "If-Match" "\"1\"")) (list (cons "If-None-Match" "*"))
                                                      (list (cons "If-Match" "*"))))
                                 '())))
      (make-link-event event now tag key source headers #f upper? (list (sym event "-" pair-aim) wait)
                       (make-link-spec type target t-upper? #f #f))))

  ;; links-list-event : Rng World Natural Tag Bytevector Symbol Degree -> Event
  ;; A link list: of the account's node that has links (most often, the
  ;; one with the most half the time), of any node of its, of no live node
  ;; of its, of a purged one of its, or of the other account's node that has
  ;; links; ?direction=
  ;; none, out, in, or another spelling; ?type= none, one of the three, or
  ;; another spelling; limit 1, 2, 3, 100 or none; one time in eleven the
  ;; first page after a place (an own node's id or a fresh one, of the type
  ;; asked or any), one in fourteen of a typed list after another type (the
  ;; 400); one in sixteen an If-Match, which a GET ignores.
  (define (links-list-event rng w now tag key wait upper? degree)
    (let* ((own (nodes-of w tag))
           (linked (filter (lambda (n) (> (degree (mnode-id n)) 0)) own))
           (theirs (filter (lambda (n) (> (degree (mnode-id n)) 0)) (nodes-of w (other-tag tag))))
           (gone-own (purged-of w tag)))
      (let*-values (((aim) (rng-weighted! rng (append (if (pair? linked) '((64 . linked)) '())
                                                      (if (pair? own) '((10 . own)) '())
                                                      '((4 . bad))
                                                      (if (pair? gone-own) '((4 . purged-own)) '())
                                                      (if (pair? theirs) '((4 . other-linked)) '()))))
                    ((id node-aim) (case aim
                                     ((linked) (values (mnode-id (pick-end rng linked degree end-weights)) 'linked))
                                     ((own) (values (mnode-id (pick-end rng own degree end-weights)) 'own))
                                     ((purged-own) (values (mnode-id (rng-pick! rng gone-own)) 'purged-own))
                                     ((other-linked) (values (mnode-id (rng-pick! rng theirs)) 'other-linked))
                                     (else (bad-end rng w tag))))
                    ((dir) (rng-weighted! rng '((22 . #f) (22 . "out") (34 . "in") (2 . "OUT") (2 . "both") (2 . twice))))
                    ((type) (rng-weighted! rng '((52 . #f) (13 . "related") (13 . "mentions") (13 . "blocks")
                                                 (2 . "Related") (2 . twice))))
                    ((steer) (rng-below! rng 3))
                    ((dir type) (steer-list rng w id dir type (and (eq? node-aim 'linked) (< steer 2))))
                    ((limit) (rng-weighted! rng '((30 . 1) (20 . 2) (14 . 3) (14 . #f) (10 . 100))))
                    ((r) (rng-below! rng 100))
                    ((place) (if (and (pair? own) (< (rng-below! rng 5) 3))
                                 (mnode-id (rng-pick! rng own))
                                 (fresh-node-id rng w)))
                    ((other-type) (rng-pick! rng link-type-names))
                    ((headers) (if (= 0 (rng-below! rng 16)) (list (cons "If-Match" "\"1\"")) '())))
        (let* ((typed (and (string? type) (member type link-type-names) type))
               (after (cond ((< r 9) (cons (or typed other-type) place))
                            ((and typed (< r 16))
                             (cons (if (string=? other-type typed)
                                       (find (lambda (t) (not (string=? t typed))) link-type-names)
                                       other-type)
                                   place))
                            (else #f))))
          (make-link-event 'list-links now tag key id headers limit upper?
                           (list (sym "list-links-of-" node-aim) wait)
                           (make-link-spec type #f #f dir after))))))

  ;; steer-list : Rng World Bytevector (U String 'twice #f) (U String 'twice #f) Boolean
  ;;              -> (values (U String 'twice #f) (U String 'twice #f))
  ;; A list's ?direction= and ?type=, when STEER?: a direction ID has links
  ;; in (none or out for out), and for a typed list a type it has that way;
  ;; else DIR and TYPE as drawn.
  (define (steer-list rng w id dir type steer?)
    (let* ((outs (filter (lambda (l) (bytevector=? (mlink-source l) id)) (world-links w)))
           (ins (filter (lambda (l) (bytevector=? (mlink-target l) id)) (world-links w))))
      (if (not (and steer? (or (pair? outs) (pair? ins))))
          (values dir type)
          (let* ((d (rng-pick! rng (append (if (pair? outs) '(#f "out") '()) (if (pair? ins) '("in" "in") '()))))
                 (ls (if (equal? d "in") ins outs)))
            (values d (if (member type link-type-names) (mlink-type (rng-pick! rng ls)) type))))))

  ;; link-chore-options : World Forest Tag Degree -> (Listof (Pair Symbol (Listof MNode)))
  ;; The links' chores TAG's nodes offer: trash a node with links and no
  ;; children, so that a purge can take its links; purge a trashed one
  ;; with links and no children, at its revision. Only those some node
  ;; offers.
  (define (link-chore-options w f tag degree)
    (let ((linked (filter (lambda (n) (and (> (degree (mnode-id n)) 0) (null? (kids-in f n)))) (nodes-of w tag))))
      (filter (lambda (c) (pair? (cdr c)))
              (list (cons 'chore-trash-linked (open-nodes linked))
                    (cons 'chore-purge-linked (in-state 'trashed linked))))))

  ;; link-chore-event : Rng Natural Tag Bytevector (Pair Symbol (Listof MNode)) Symbol Degree -> Event
  (define (link-chore-event rng now tag key chore wait degree)
    (let ((n (pick-node rng (cdr chore) (lambda (n) (degree (mnode-id n))))))
      (at-revision (if (eq? (car chore) 'chore-trash-linked) 'trash 'purge) now tag key n (list (car chore) wait)
                   'absent)))

  ;;; The generator's props and commands (slice 6)

  ;; create-refused? : Entry String -> Boolean
  ;; Whether a create of KIND refuses ENTRY before its job: a value it does
  ;; not take, or a Task's claim of closed with no status but TODO (P14).
  (define (create-refused? entry kind)
    (let ((v (entry-verdict entry kind)))
      (or (not (taken? v)) (and (claim? v) (claim-closed v) (member (claim-status v) '(#f "TODO")) #t))))

  ;; create-safe : (Listof (Pair String (Listof Entry)))     each kind's entries a create takes
  (define create-safe
    (map (lambda (k) (cons k (filter (lambda (e) (not (create-refused? e k))) (cdr (assoc k taken-by))))) kinds))

  ;; safe-props : Rng String -> (U Entry #f)
  ;; A scripted create's props (the chain's, a family's, a hub's): none (as
  ;; {}) half the time, else one a create of KIND takes, so the script's
  ;; nodes are made.
  (define (safe-props rng kind)
    (if (= 0 (rng-below! rng 2)) #f (rng-pick! rng (cdr (assoc kind create-safe)))))

  ;; too-large-for : (Listof (Pair String (Listof Entry)))     each kind's entries valid but over the cap
  (define too-large-for
    (map (lambda (k) (cons k (corpus-of (lambda (e) (eq? (entry-verdict e k) 'too-large))))) kinds))

  ;; status-claims : (Listof Entry)     a Task's entries that claim a status, TODO, DONE or WONTDO
  (define status-claims
    (corpus-of (lambda (e) (let ((v (entry-verdict e "task"))) (and (claim? v) (claim-status v) #t)))))

  ;; too-large-anywhere : (Listof Entry)     every entry a kind finds valid but over the cap
  (define too-large-anywhere (corpus-of (lambda (e) (exists (lambda (k) (eq? (entry-verdict e k) 'too-large)) kinds))))

  ;; r17-pair : (Listof Entry)     R17's two orderings of one Contact
  (define r17-pair (corpus-of (lambda (e) (memq (entry-name e) '(contact-order-a contact-order-b)))))

  ;; choose-create-props : Rng String -> (values (U Entry #f) Symbol)
  ;; A create's props: none (as {}); for a Task, often one that claims a
  ;; status (P14: a finished Task brought in, with closed or without; TODO
  ;; with a closed, the 400); for a Contact, often one of R17's two
  ;; orderings; an entry KIND takes; one over the cap a kind finds valid
  ;; (413 for it); one only another kind takes (400); one no kind takes
  ;; (400).
  (define (choose-create-props rng kind)
    (let ((r (rng-below! rng 100)) (large (cdr (assoc kind too-large-for))))
      (cond ((< r 12) (values #f 'props-none))
            ((and (string=? kind "task") (< r 52)) (values (rng-pick! rng status-claims) 'props-status-claim))
            ((and (string=? kind "contact") (< r 32)) (values (rng-pick! rng r17-pair) 'props-r17))
            ((and (pair? large) (< r 40)) (values (rng-pick! rng large) 'props-too-large))
            ((< r 86) (values (rng-pick! rng (cdr (assoc kind taken-by))) 'props-own-kind))
            ((< r 94) (values (rng-pick! rng (cdr (assoc kind refused-by))) 'props-other-kind))
            (else (values (rng-pick! rng nobody-takes) 'props-no-kind)))))

  ;; claim-entry : Symbol (U String #f) (U Natural #f) (U String #f) (U String #f) -> Entry
  ;; A Task's props as the model writes them, each member given, status
  ;; first even when it is TODO, as a client sends back what it read. Its
  ;; verdict: the claim for a Task; for every other kind none, as none has
  ;; these members; but {} (no member given) is every kind's.
  (define (claim-entry name status closed deadline scheduled)
    (let ((members (append (if status (list (string-append "\"status\":\"" status "\"")) '())
                           (if closed (list (string-append "\"closed\":" (number->string closed))) '())
                           (if deadline (list (string-append "\"deadline\":\"" deadline "\"")) '())
                           (if scheduled (list (string-append "\"scheduled\":\"" scheduled "\"")) '()))))
      (make-entry name (string-append "{" (join members ",") "}")
                  (map (lambda (k)
                         (cons k (cond ((string=? k "task") (claim status closed deadline scheduled))
                                       ((null? members) (entry-verdict empty-entry k))
                                       (else 'invalid))))
                       kinds))))

  ;; sent-back-props : Rng MProps -> (values Entry Symbol)
  ;; A Task's props P sent back by a replace: as read (status and closed as
  ;; they are, TODO written out), the status alone, the closed alone (each
  ;; left out is kept), with a new deadline; or with another status, or
  ;; another closed (a closed while TODO among them; still a whole number
  ;; from 0 to 2^53 - 1, so a valid claim): 409 status_fixed.
  (define (sent-back-props rng p)
    (let* ((s (mprops-status p)) (c (mprops-closed p)) (d (mprops-deadline p)) (sc (mprops-scheduled p))
           (how (rng-pick! rng '(as-read as-read status-only closed-only new-when other-status other-closed))))
      (values
       (case how
         ((as-read) (claim-entry 'sent-back-as-read s c d sc))
         ((status-only) (claim-entry 'sent-back-status-only s #f d sc))
         ((closed-only) (claim-entry 'sent-back-closed-only #f c d sc))
         ((new-when) (claim-entry 'sent-back-new-when s c (rng-pick! rng good-whens) sc))
         ((other-status) (claim-entry 'sent-back-other-status (rng-pick! rng (remove s '("TODO" "DONE" "WONTDO"))) c d sc))
         (else (claim-entry 'sent-back-other-closed s
                            (cond ((not c) 1795515226000) ((< c 9007199254740991) (+ c 1)) (else (- c 1)))
                            d sc)))
       (sym "props-" how))))

  ;; choose-replace-props : Rng (U MNode #f) (U String #f) -> (values (U Entry #f) Symbol)
  ;; A replace's props for N, the account's live node (#f for none), the
  ;; request naming NAMED (#f for no kind): half the time when it names
  ;; another kind, one that kind takes (so the job answers kind_fixed); else
  ;; none (P11); one over the cap (the 413 before the job, whatever the
  ;; node); for a Task of its, often its props sent back; for a Contact,
  ;; sometimes one of R17's two orderings; an entry N's
  ;; kind takes; one over the cap; one only another kind takes (400 before
  ;; the job when the kind is named, in it when not, more often then); one
  ;; no kind takes.
  (define (choose-replace-props rng n named)
    (let* ((kind (if n (mnode-kind n) "note"))
           (r (rng-below! rng 100)))
      (cond ((and named (not (string=? named kind)) (< r 50))
             (values (rng-pick! rng (cdr (assoc named taken-by))) 'props-named-kind))
            ((< r 20) (values #f 'props-none))
            ((< r 25) (values (rng-pick! rng too-large-anywhere) 'props-too-large))
            ((and n (string=? kind "task") (< r 50)) (sent-back-props rng (msnap-props (node-top n))))
            ((and (string=? kind "contact") (< r 33)) (values (rng-pick! rng r17-pair) 'props-r17))
            ((< r (if named 66 56)) (values (rng-pick! rng (cdr (assoc kind taken-by))) 'props-own-kind))
            ((< r 90) (values (rng-pick! rng (cdr (assoc kind refused-by))) 'props-other-kind))
            (else (values (rng-pick! rng nobody-takes) 'props-no-kind)))))

  ;; empty-task? : World MNode -> Boolean     a live Task whose props are stored {} (P9's)
  (define (empty-task? w n)
    (and (live? n) (string=? (mnode-kind n) "task") (string=? (mprops-text (msnap-props (node-top n))) "{}")))

  ;; choose-task-target : Rng World Tag -> (values Bytevector (U MNode #f) Symbol)
  ;; A command's node: most often the account's own Task, its state chosen
  ;; first (archived the most, as it is rarer; trashed the least); a
  ;; seeded Task still {};
  ;; the account's node of another kind, any state; else choose-target's:
  ;; its own, the other account's, a purged id, a fresh one.
  (define (choose-task-target rng w tag)
    (let* ((own (nodes-of w tag))
           (tasks (of-kind "task" own))
           (others (filter (lambda (n) (not (string=? (mnode-kind n) "task"))) own))
           (seeds (filter (lambda (n) (and (seeded? w (mnode-id n)) (empty-task? w n))) tasks))
           (aim (rng-weighted! rng (append (if (pair? tasks) '((60 . task)) '())
                                           (if (pair? seeds) '((10 . seeded)) '())
                                           (if (pair? others) '((14 . other-kind)) '())
                                           '((22 . elsewhere))))))
      (case aim
        ((task)
         (let* ((states (filter (lambda (s) (exists (lambda (n) (eq? (mnode-state n) s)) tasks)) live-states))
                (s (rng-weighted! rng (map (lambda (s) (cons (case s ((trashed) 1) ((archived) 3) (else 2)) s)) states)))
                (n (rng-pick! rng (in-state s tasks))))
           (values (mnode-id n) n 'own)))
        ((seeded) (let ((n (rng-pick! rng seeds))) (values (mnode-id n) n 'own)))
        ((other-kind) (let ((n (rng-pick! rng others))) (values (mnode-id n) n 'own)))
        (else (choose-target rng w tag by-revisions)))))

  ;; choose-task-event : Rng (U MNode #f) Symbol -> Symbol
  ;; For the account's own live Task, 11 times in 20 a command its
  ;; status is taken from, so Tasks move through the table; else, and at any
  ;; other node, any of the three.
  (define (choose-task-event rng n where)
    (let ((status (and n (eq? where 'own) (live? n) (string=? (mnode-kind n) "task")
                       (mprops-status (msnap-props (node-top n))))))
      (if (and status (< (rng-below! rng 20) 11))
          (rng-pick! rng (map car (filter (lambda (m) (member status (cadr m))) task-moves)))
          (rng-pick! rng task-events))))

  ;; task-restore-pick : Rng World Tag -> (U (Pair MNode Natural) #f)
  ;; One of the account's live Tasks with a snapshot whose status or closed
  ;; is not its own now, and that snapshot's revision: P10's restore.
  (define (task-restore-pick rng w tag)
    (let ((pairs (apply append
                        (map (lambda (n)
                               (let ((p (msnap-props (node-top n))))
                                 (map (lambda (s) (cons n (msnap-revision s)))
                                      (filter (lambda (s) (let ((sp (msnap-props s)))
                                                            (not (and (equal? (mprops-status sp) (mprops-status p))
                                                                      (equal? (mprops-closed sp) (mprops-closed p))))))
                                              (mnode-snaps n)))))
                             (of-kind "task" (nodes-of w tag))))))
      (and (pair? pairs) (rng-pick! rng pairs))))

  ;; own-task-target : Rng World Tag -> (U MNode #f)
  ;; One of the account's live Tasks, any state, or #f when it has none.
  (define (own-task-target rng w tag)
    (let ((tasks (of-kind "task" (nodes-of w tag))))
      (and (pair? tasks) (rng-pick! rng tasks))))

  ;; own-contact-target : Rng World Tag -> (U MNode #f)
  ;; One of the account's live Contacts, or #f: they are the fewest nodes,
  ;; and hold the most props.
  (define (own-contact-target rng w tag)
    (let ((cs (of-kind "contact" (nodes-of w tag))))
      (and (pair? cs) (rng-pick! rng cs))))

  ;; own-kind-first-target : Rng World Tag -> (U MNode #f)
  ;; One of the account's live nodes, its kind chosen first among the kinds
  ;; it has, so a Contact is replaced as often as a Project; #f for none.
  (define (own-kind-first-target rng w tag)
    (let* ((own (nodes-of w tag))
           (present (filter (lambda (k) (exists (lambda (n) (string=? (mnode-kind n) k)) own)) kinds)))
      (and (pair? present) (let ((k (rng-pick! rng present))) (rng-pick! rng (of-kind k own))))))

  ;; next-event : Rng World Natural -> Event
  (define (next-event rng w now0)
    (let*-values (((tag) (rng-pick! rng '(a b)))
                  ((key) (rng-pick! rng (key-ids-of tag)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((upper? (= 0 (rng-below! rng 5)))
             (f (forest-of w))
             (many (length (live-nodes w)))
             (chores (chore-options w f tag))
             (degree (link-degree w))
             (link-chores (link-chore-options w f tag degree))
             (kind (rng-weighted! rng (append (list (cons (cond ((< many 6) 30) ((< many 14) 16) (else 6)) 'create)
                                                    '(31 . replace) '(22 . restore) '(38 . lifecycle)
                                                    '(5 . no-pre) '(13 . bad-pre)
                                                    '(12 . get-node) '(12 . list-nodes) '(12 . list-revisions)
                                                    '(16 . get-snapshot) '(16 . move) '(10 . move-children))
                                              (if (pair? chores) '((8 . chore)) '())
                                              '((36 . link) (12 . unlink) (18 . list-links))
                                              (if (pair? link-chores) '((6 . link-chore)) '())
                                              '((34 . task))
                                              '((16 . tag-filter) (7 . list-tags) (9 . rename-tag) (5 . remove-tag))))))
        (case kind
          ((tag-filter) (filter-list-event rng w f now tag key wait))
          ((list-tags) (tags-list-event rng w now tag key wait))
          ((rename-tag remove-tag) (command-event rng w now tag key wait kind))
          ((link unlink) (link-write-event rng w now tag key kind wait upper? degree))
          ((list-links) (links-list-event rng w now tag key wait upper? degree))
          ((link-chore) (link-chore-event rng now tag key (rng-pick! rng link-chores) wait degree))
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
             (let*-values (((parent p-aim) (choose-create-parent rng w f tag id))
                           ((k) (create-kind rng w tag parent k0))
                           ((props props-aim) (choose-create-props rng k))
                           ((tags tags-aim) (choose-create-tags rng)))
               (let ((c (random-tagged-content rng k parent props tags)))
                 (make-event 'put now tag key id 'create (list (cons "If-None-Match" "*")) c #f #f #f upper?
                             (list aim p-aim props-aim tags-aim wait) 'absent)))))
          ((replace)
           (let*-values (((r) (rng-below! rng 100))
                         ((task) (cond ((< r 25) (own-task-target rng w tag))
                                       ((< r 40) (own-contact-target rng w tag))
                                       ((< r 60) (own-kind-first-target rng w tag))
                                       (else #f)))
                         ((id n where) (if task (values (mnode-id task) task 'own) (choose-target rng w tag by-revisions)))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged))))
                         ((k kind-aim) (choose-kind rng n))
                         ((props props-aim) (choose-replace-props rng (and (eq? where 'own) n) k))
                         ;; props over the cap, sent naming a kind: half the time the kind that
                         ;; takes them, a Contact, so the 413 is met naming the kind as well as
                         ;; naming none (another kind's name is the 400)
                         ((k kind-aim) (if (and (eq? props-aim 'props-too-large) k (not (equal? k "contact"))
                                                (= 0 (rng-below! rng 2)))
                                           (values "contact" (if (and n (equal? (mnode-kind n) "contact")) 'kind-same 'kind-other))
                                           (values k kind-aim)))
                         ((tags tags-aim) (choose-replace-tags rng (and (eq? where 'own) n))))
             (let ((c (random-tagged-content rng k 'absent props tags)))
               (make-event 'put now tag key id rev (list (cons "If-Match" (etag-of rev))) c #f #f #f upper?
                           (append (list (sym "replace-" where "-" rev-aim) kind-aim props-aim tags-aim wait)
                                   (if (eq? where 'own) (list (sym "replace-own-" (mnode-state n))) '()))
                           'absent))))
          ((restore)
           (let ((pick (and (< (rng-below! rng 100) 25) (task-restore-pick rng w tag))))
             (if pick
                 (let*-values (((n) (car pick))
                               ((rev rev-aim) (choose-revision rng n #f)))
                   (make-event 'restore now tag key (mnode-id n) rev (list (cons "If-Match" (etag-of rev))) #f (cdr pick)
                               #f #f upper?
                               (list 'restore-task-status-changed (sym "restore-own-" rev-aim)
                                     (sym "restore-own-" (mnode-state n)) wait)
                               'absent))
                 (let*-values (((id n where) (choose-target rng w tag by-snapshots))
                               ((rev rev-aim) (choose-revision rng n (memq where '(other purged))))
                               ((k snap-aim) (choose-snapshot rng n)))
                   (make-event 'restore now tag key id rev (list (cons "If-Match" (etag-of rev))) #f k #f #f upper?
                               (append (list (sym "restore-" where "-" rev-aim) (sym "restore-" snap-aim) wait)
                                       (if (eq? where 'own) (list (sym "restore-own-" (mnode-state n))) '()))
                               'absent)))))
          ((task)
           (let*-values (((id n where) (choose-task-target rng w tag))
                         ((ev) (choose-task-event rng n where))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged)))))
             (make-event ev now tag key id rev (list (cons "If-Match" (etag-of rev))) #f #f #f #f upper?
                         (append (list (sym ev "-" where "-" rev-aim) wait)
                                 (if (eq? where 'own) (list (sym ev "-own-" (mnode-state n))) '()))
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
                    (k (rng-pick! rng kinds))
                    (props (and (= 0 (rng-below! rng 2)) (rng-pick! rng props-corpus)))
                    (c (and (eq? route 'put) (random-content rng k 'absent props))))
               (make-event route now tag key id 'missing '() c (and (eq? route 'restore) 1) #f #f upper?
                           (list (sym "no-precondition-" route) wait) 'null))))
          ((bad-pre)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (let* ((route (rng-pick! rng bare-routes)))
               (let*-values (((hs aim) (bad-headers rng route (if n (node-rev n) 1))))
                 (let* ((k (rng-pick! rng kinds))
                        (props (and (= 0 (rng-below! rng 2)) (rng-pick! rng props-corpus)))
                        (c (and (eq? route 'put) (random-content rng k 'absent props))))
                   (make-event route now tag key id 'invalid hs c (and (eq? route 'restore) 1) #f #f upper?
                               (list aim (sym "bad-precondition-" route) wait) 'null))))))
          ((get-node)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (make-event 'get-node now tag key id #f '() #f #f #f #f upper? (list (sym "get-node-" where) wait)
                         'absent)))
          ((list-nodes)
           (let*-values (((limit) (rng-pick! rng (list-limits w tag)))
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

  ;;; The generator's tags (slice 7a)

  ;; pick-tags! : Rng (Listof TagEntry) Natural Natural -> (Listof TagEntry)
  ;; LO to HI entries of POOL, each drawn alone: one may come twice.
  (define (pick-tags! rng pool lo hi)
    (let loop ((k (+ lo (rng-below! rng (+ 1 (- hi lo))))) (acc '()))
      (if (= k 0) acc (loop (- k 1) (cons (rng-pick! rng pool) acc)))))

  ;; numbered-sent : (Listof TagEntry)     T01 to T50, as sent: fifty tags, G5's cap
  (define numbered-sent
    (filter (lambda (e) (char=? (string-ref (tag-entry-sent e) 0) #\T)) numbered-tags))

  (define (list-of n x) (if (= n 0) '() (cons x (list-of (- n 1) x))))

  ;; over-cap-tags! : Rng -> (Listof TagEntry)     51 entries: one tag 51 times, or 51 tags
  (define (over-cap-tags! rng)
    (if (= 0 (rng-below! rng 2))
        (list-of (+ tag-most 1) (tag-named 'work-capital))
        (cons (tag-named 'work) numbered-sent)))

  ;; folded-to-one! : Rng -> (Listof TagEntry)     every form the corpus has of one tag: one tag stored
  (define (folded-to-one! rng)
    (forms-of (rng-pick! rng '("work" "work-space" "c++" "\xe9;" "home-life" "a-b" "a" "stra\xdf;e"))))

  ;; with-refused! : Rng (Listof TagEntry) -> (Listof TagEntry)     a refused entry put among ES
  (define (with-refused! rng es)
    (let ((bad (rng-pick! rng bad-tags)) (k (rng-below! rng (+ 1 (length es)))))
      (append (take* es k) (list bad) (list-tail es k))))

  ;; safe-tags : Rng -> TagsSent
  ;; A scripted create's tags (the chain's, a family's, a hub's): none
  ;; half the time, else one or two common ones, so its nodes are made.
  (define (safe-tags rng)
    (if (= 0 (rng-below! rng 2)) 'absent (list 'entries (pick-tags! rng common-tags 1 2))))

  ;; choose-create-tags : Rng -> (values TagsSent Symbol)
  ;; A create's tags: none (so none); one to three common ones; [];
  ;; any tag the rule takes; one tag in every form (one stored); a refused
  ;; entry among common ones (400); a value that is no array of strings
  ;; (400); fifty tags (G5's cap); 51 entries (400, as sent); one to four of
  ;; any.
  (define (choose-create-tags rng)
    (let ((r (rng-below! rng 100)))
      (cond ((< r 30) (values 'absent 'tags-create-none))
            ((< r 60) (values (list 'entries (pick-tags! rng common-tags 1 3)) 'tags-create-common))
            ((< r 64) (values '(entries ()) 'tags-create-empty))
            ((< r 72) (values (list 'entries (cons (rng-pick! rng good-tags) (pick-tags! rng common-tags 0 2))) 'tags-create-any))
            ((< r 76) (values (list 'entries (folded-to-one! rng)) 'tags-create-folded-to-one))
            ((< r 84) (values (list 'entries (with-refused! rng (pick-tags! rng common-tags 0 2))) 'tags-create-refused-entry))
            ((< r 88) (let ((v (rng-pick! rng raw-tags-values))) (values v (sym "tags-create-raw-" (caddr v)))))
            ((< r 91) (values (list 'entries numbered-sent) 'tags-create-at-cap))
            ((< r 94) (values (list 'entries (over-cap-tags! rng)) 'tags-create-over-cap))
            (else (values (list 'entries (pick-tags! rng good-tags 1 4)) 'tags-create-many-kinds)))))

  ;; choose-replace-tags : Rng (U MNode #f) -> (values TagsSent Symbol)
  ;; A replace's tags for N, the account's live node (#f for none): none
  ;; (G2: kept) most often; N's own sent back as read; in other forms; [];
  ;; one to three common ones; N's own and one more; N's own with a refused
  ;; entry (400); a value that is no array (400); fifty; 51 (400); any.
  (define (choose-replace-tags rng n)
    (let* ((r (rng-below! rng 100)) (own (map fixed-point-of (if n (mnode-tags n) '())))
           (new (lambda () (values (list 'entries (pick-tags! rng common-tags 1 3)) 'tags-replace-new))))
      (cond ((< r 40) (values 'absent 'tags-replace-none))
            ((< r 50) (if (pair? own) (values (list 'entries own) 'tags-replace-sent-back) (new)))
            ((< r 55)
             (if (pair? own)
                 (values (list 'entries (map (lambda (e) (rng-pick! rng (forms-of (tag-entry-stored e)))) own))
                         'tags-replace-other-forms)
                 (new)))
            ((< r 63) (if (pair? own) (values '(entries ()) 'tags-replace-cleared) (new)))
            ((< r 66) (values '(entries ()) 'tags-replace-cleared))
            ((< r 78) (new))
            ((< r 83) (values (list 'entries (append own (pick-tags! rng common-tags 1 1))) 'tags-replace-added))
            ((< r 87) (values (list 'entries (with-refused! rng own)) 'tags-replace-refused-entry))
            ((< r 89) (let ((v (rng-pick! rng raw-tags-values))) (values v (sym "tags-replace-raw-" (caddr v)))))
            ((< r 91) (values (list 'entries numbered-sent) 'tags-replace-at-cap))
            ((< r 92) (values (list 'entries (over-cap-tags! rng)) 'tags-replace-over-cap))
            (else (values (list 'entries (pick-tags! rng good-tags 1 3)) 'tags-replace-many-kinds)))))

  ;; account-tags : World Tag -> (Listof String)     every tag TAG's live nodes carry, each once
  (define (account-tags w tag) (tag-set (apply append (map mnode-tags (nodes-of w tag)))))

  ;; list-limits : World Tag -> (Listof (U Natural #f))
  ;; A list's page sizes: 1, 2, 3 or none; 100 or none when the account has
  ;; over 200 live nodes (a crowd's), so a walk ends in its 250 pages.
  (define (list-limits w tag) (if (> (length (nodes-of w tag)) 200) '(100 #f) '(1 2 3 #f)))

  ;; query-tag-of! : Rng String -> QueryTag     one of the stored form T's entries, spaces as + a time in five
  (define (query-tag-of! rng t)
    (list 'entry (rng-pick! rng (forms-of t)) (if (= 0 (rng-below! rng 5)) 'plus 'strict)))

  ;; filter-values! : Rng World Tag Natural (U Symbol 'invalid) -> (values (Listof QueryTag) Symbol)
  ;; N ?tag= values: three times in four, when the account has a tagged
  ;; node in STATE (any state for 'invalid), that node's tags first (so
  ;; every tag is found together), then any of the account's or the common
  ;; ones; else any of those. Then, one time in eight, one of them made a
  ;; raw value (a + for a space, bad UTF-8); one in twelve a refused one,
  ;; an empty one or the field with no = (each the 400).
  (define (filter-values! rng w tag n state)
    (let* ((tagged (filter (lambda (m) (and (pair? (mnode-tags m)) (or (eq? state 'invalid) (eq? (mnode-state m) state))))
                           (nodes-of w tag)))
           (pool (tag-set (append (account-tags w tag) (map tag-entry-stored common-tags))))
           (base (if (and (pair? tagged) (< (rng-below! rng 4) 3)) (mnode-tags (rng-pick! rng tagged)) '()))
           (stored (let loop ((k 0) (acc '()))
                     (cond ((= k n) (reverse acc))
                           ((< k (length base)) (loop (+ k 1) (cons (list-ref base k) acc)))
                           ((and (pair? base) (< (rng-below! rng 3) 2)) (loop (+ k 1) (cons (rng-pick! rng base) acc)))
                           (else (loop (+ k 1) (cons (rng-pick! rng pool) acc))))))
           (qs (map (lambda (t) (query-tag-of! rng t)) stored))
           (r (rng-below! rng 24))
           (at (rng-below! rng n)))
      (cond ((< r 3)
             (let ((c (rng-pick! rng (filter (lambda (c) (string? (caddr c))) query-raw-cases))))
               (values (append (take* qs at) (list (list 'raw (car c) (cadr c))) (list-tail qs (+ at 1))) 'tag-filter-raw)))
            ((= r 3) (values (append (take* qs at) (list (list 'entry (rng-pick! rng bad-tags) 'strict)) (list-tail qs (+ at 1)))
                             'tag-filter-refused))
            ((= r 4) (values (append (take* qs at) (list (list 'raw "" 'raw-empty)) (list-tail qs (+ at 1))) 'tag-filter-empty))
            ((= r 5) (values (append (take* qs at) (list 'bare) (list-tail qs (+ at 1))) 'tag-filter-bare))
            (else (values qs (if (pair? base) 'tag-filter-from-a-node 'tag-filter-any))))))

  ;; filter-list-event : Rng World Forest Natural Tag Bytevector Symbol -> Event
  ;; GET /v1/nodes?tag=: one tag most often, then two, three, six, ten
  ;; (counted as sent, each value toward the ten) and eleven (the 400);
  ;; ?state= none, a live state, or one refused; a quarter of the time a
  ;; ?parent= as choose-list-parent draws it; a page size by list-limits;
  ;; one time in eight a first page after a place.
  (define (filter-list-event rng w f now tag key wait)
    (let*-values (((limit) (rng-pick! rng (list-limits w tag)))
                  ((q) (rng-weighted! rng '((40 . none) (22 . "active") (15 . "archived") (15 . "trashed") (2 . "ARCHIVED")
                                            (2 . twice))))
                  ((parent p-aim) (if (< (rng-below! rng 100) 25) (choose-list-parent rng w f tag) (values 'absent 'flat)))
                  ((n) (rng-weighted! rng '((55 . 1) (20 . 2) (8 . 3) (7 . 6) (5 . 10) (5 . 11))))
                  ((vals v-aim) (filter-values! rng w tag n (list-state (if (eq? q 'none) #f q))))
                  ((own) (nodes-of w tag))
                  ((after) (if (= 0 (rng-below! rng 8))
                               (if (and (pair? own) (< (rng-below! rng 4) 3)) (mnode-id (rng-pick! rng own)) (fresh-node-id rng w))
                               #f)))
      (make-filter-event now tag key limit (if (eq? q 'none) #f q) parent
                         (list (sym "tag-filter-" (number->string n)) v-aim (sym "tag-filter-parent-" p-aim) wait)
                         (make-filter-spec vals after))))

  ;; tags-list-event : Rng World Natural Tag Bytevector Symbol -> Event
  ;; GET /v1/tags: a page of 1, 2, 3, none (50) or 100; a first page after
  ;; one of the account's tags in any form, after any tag the rule takes,
  ;; after a refused one (400), or after given twice (400).
  (define (tags-list-event rng w now tag key wait)
    (let* ((limit (rng-weighted! rng '((25 . 1) (20 . 2) (15 . 3) (25 . #f) (15 . 100))))
           (mine (account-tags w tag))
           (r (rng-below! rng 100))
           (after (cond ((and (pair? mine) (< r 12)) (query-tag-of! rng (rng-pick! rng mine)))
                        ((< r 16) (list 'entry (rng-pick! rng good-tags) (if (= 0 (rng-below! rng 3)) 'plus 'strict)))
                        ((< r 19) (list 'entry (rng-pick! rng bad-tags) 'strict))
                        ((< r 21) 'twice)
                        (else #f))))
      (make-tag-event 'list-tags now tag key '() limit
                      (list (cond ((not after) 'list-tags-from-the-start) ((eq? after 'twice) 'list-tags-after-twice)
                                  ((tag-ok? (cadr after)) 'list-tags-after-a-tag) (else 'list-tags-after-refused))
                            wait)
                      (make-tags-list-spec after))))

  ;; precondition-headers : (Listof (Listof Header))     what a tag's command takes none of: each the 400
  (define precondition-headers
    (list (list (cons "If-Match" "\"1\"")) (list (cons "If-None-Match" "*")) (list (cons "If-Match" "*"))
          (list (cons "If-Match" "W/\"1\""))))

  (define (capitalised s) (string-append (string (char-upcase (string-ref s 0))) (substring s 1 (string-length s))))

  ;; malformed! : Rng (Listof (Pair String Value)) -> (values Body Symbol)
  ;; A command's body that is no request it takes: a member missing,
  ;; another beside them, one twice, a number, null, a name in another
  ;; case; or a text that is no object, or none, or no JSON.
  (define (malformed! rng members)
    (let* ((one (car members))
           (choice (rng-pick! rng
                              (list (list 'member-missing 'members (cdr members))
                                    (list 'member-extra 'members (append members (list (cons "x" '(json "1")))))
                                    (list 'member-twice 'members (cons one members))
                                    (list 'member-number 'members (cons (cons (car one) '(json "1")) (cdr members)))
                                    (list 'member-null 'members (cons (cons (car one) '(json "null")) (cdr members)))
                                    (list 'member-capitalised 'members (cons (cons (capitalised (car one)) (cdr one)) (cdr members)))
                                    (list 'text-empty 'text "" 'invalid) (list 'text-array 'text "[]" 'invalid)
                                    (list 'text-null 'text "null" 'invalid) (list 'text-string 'text "\"work\"" 'invalid)
                                    (list 'text-cut 'text "{" 'not-json) (list 'text-no-value 'text "{\"tag\":}" 'not-json)))))
      (values (cdr choice) (car choice))))

  ;; command-event : Rng World Natural Tag Bytevector Symbol Symbol -> Event
  ;; POST /v1/tags/rename (KIND rename-tag) or /remove: from (or tag) most
  ;; often a tag the account carries, in any form; a tag only the other
  ;; account carries (none of its own: 0 and 0); a common one; any; a
  ;; refused one (400). A rename's to a common tag (often a merge),
  ;; another of its own (a merge), the same once stored (400), any, a
  ;; refused one. One time in seven a malformed body, one in 25 a body
  ;; over 16 KiB (413), one in 25 text/plain (415), one in 20 a
  ;; precondition (400).
  (define (command-event rng w now tag key wait kind)
    (let*-values (((mine) (account-tags w tag))
                  ((theirs-only) (filter (lambda (t) (not (member t mine))) (account-tags w (other-tag tag))))
                  ((from-aim) (rng-weighted! rng (append (if (pair? mine) '((55 . own)) '())
                                                         (if (pair? theirs-only) '((12 . theirs-only)) '())
                                                         '((15 . common) (5 . refused) (8 . any)))))
                  ((from) (case from-aim
                            ((own) (rng-pick! rng (forms-of (rng-pick! rng mine))))
                            ((theirs-only) (rng-pick! rng (forms-of (rng-pick! rng theirs-only))))
                            ((common) (rng-pick! rng common-tags))
                            ((refused) (rng-pick! rng bad-tags))
                            (else (rng-pick! rng good-tags))))
                  ((to-aim) (rng-weighted! rng (append '((45 . common)) (if (pair? mine) '((25 . own)) '())
                                                       '((10 . same) (10 . any) (5 . refused)))))
                  ((to) (case to-aim
                          ((common) (rng-pick! rng common-tags))
                          ((own) (rng-pick! rng (forms-of (rng-pick! rng mine))))
                          ((same) (if (tag-ok? from) (rng-pick! rng (forms-of (tag-entry-stored from))) from))
                          ((refused) (rng-pick! rng bad-tags))
                          (else (rng-pick! rng good-tags))))
                  ((members) (if (eq? kind 'rename-tag)
                                 (if (= 0 (rng-below! rng 2))
                                     (list (cons "from" from) (cons "to" to))
                                     (list (cons "to" to) (cons "from" from)))
                                 (list (cons "tag" from))))
                  ((r) (rng-below! rng 100))
                  ((body body-aim) (cond ((< r 86) (values (list 'members members) 'body-exact))
                                         ((< r 96) (malformed! rng members))
                                         (else (values (list 'padded members 20000) 'body-over-cap))))
                  ((json?) (< 0 (rng-below! rng 25)))
                  ((headers) (if (= 0 (rng-below! rng 20)) (rng-pick! rng precondition-headers) '())))
      (make-tag-event kind now tag key headers #f
                      (append (list (sym kind "-from-" from-aim) (sym kind "-" body-aim) wait)
                              (if (eq? kind 'rename-tag) (list (sym kind "-to-" to-aim)) '()))
                      (make-command-spec body json?))))

  ;;; A crowd sequence: over 500 carriers of a tag (slice 7a)

  ;; crowd-seed? : Natural -> Boolean
  ;; One in fifty: a seed ending in 04 or 54, so never deep (no multiple
  ;; of fifteen ends in 4), a family nor linked.
  (define (crowd-seed? seed) (= 4 (mod seed 50)))

  ;; crowd-world : Rng Natural Natural Tag -> World
  ;; A crowd seed's start, written straight into its file as a client
  ;; filled it: TAG's 501 to 560 Notes (1,001 to 1,060 when the seed ends
  ;; in 04), each made before T0 at the top level carrying crowd, every
  ;; fourth throng too and every seventh work; one in ten archived and one
  ;; in ten trashed, each at revision 2 by its change row; and the other
  ;; account's three Notes carrying crowd and throng. So a step of crowd
  ;; takes 500 and leaves more, in every state, merges into throng where
  ;; it is, and leaves the other account's alone; and a count stops at
  ;; 1,000.
  (define (crowd-world rng t0 seed tag)
    (let* ((n (+ (if (= 4 (mod seed 100)) 1001 501) (rng-below! rng 60)))
           (seen (make-id-table))
           (fresh! (lambda ()
                     (let loop ()
                       (let ((bv (rng-bytes! rng 16)))
                         (bytevector-u8-set! bv 6 (bitwise-ior #x70 (bitwise-and (bytevector-u8-ref bv 6) #x0f)))
                         (bytevector-u8-set! bv 8 (bitwise-ior #x80 (bitwise-and (bytevector-u8-ref bv 8) #x3f)))
                         (if (hashtable-ref seen bv #f) (loop) (begin (hashtable-set! seen bv #t) bv))))))
           (other (other-tag tag)))
      (let loop ((i 1) (nodes '()) (changes '((a) (b))))
        (if (> i (+ n 3))
            (make-world (reverse nodes) start-keys
                        (map (lambda (p) (cons (car p) (reverse (cdr p)))) changes)
                        '() '() '())
            (let* ((owner (if (> i n) other tag))
                   (id (fresh!))
                   (created (- t0 (* 10 (- (+ n 4) i))))
                   (label (string-append "c" (number->string i)))
                   (tags (if (> i n)
                             '("crowd" "throng")
                             (tag-set (append '("crowd") (if (= 0 (mod i 4)) '("throng") '())
                                              (if (= 0 (mod i 7)) '("work") '())))))
                   (state (if (> i n) 'active (case (mod i 10) ((3) 'archived) ((7) 'trashed) (else 'active))))
                   (rev (if (eq? state 'active) 1 2))
                   (node (make-mnode id owner label "note" created state rev (if (= rev 1) created (+ created 1))
                                     (list (make-msnap 1 label "" "text/plain" (plain-props "{}") created owner tags))
                                     #f tags))
                   (old (cdr (assq owner changes)))
                   (rows (append (if (= rev 2)
                                     (list (make-mchange (+ 2 (length old)) id 2 (if (eq? state 'archived) "archive" "trash")
                                                         (+ created 1)))
                                     '())
                                 (list (make-mchange (+ 1 (length old)) id 1 "create" created)))))
              (loop (+ i 1) (cons node nodes)
                    (map (lambda (p) (if (eq? (car p) owner) (cons owner (append rows old)) p)) changes)))))))

  ;; crowd-steps : Natural
  (define crowd-steps 15)

  ;; crowd-event : Rng World Natural Tag Natural -> (U Event #f)
  ;; Step K of the script a crowd seed's TAG runs first, each by TAG:
  ;;    1 the tags list, two a page: crowd's count stopped at 1,000 when it has more
  ;;    2 the archived nodes that carry crowd, 100 a page
  ;;    3 rename Crowd to throng: 500 renamed, a merge where throng is, the rest left
  ;;    4 a Note made with Crowd: left rises by one
  ;;    5 a restore of a renamed node's first snapshot: crowd comes back
  ;;    6 to 8 rename CROWD to THRONG, crowd to throng, and again: until left is 0, then 0 and 0
  ;;    9 the tags list
  ;;   10 the nodes that carry throng and work, any state, 100 a page
  ;;   11 to 14 remove Throng, throng, THRONG, throng: 500 a step, then 0 and 0
  ;;   15 the tags list
  ;; #f when a node it names is not there.
  (define (crowd-event rng w now0 tag k)
    (let*-values (((key) (rng-pick! rng (key-ids-of tag)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((aims (list (sym "crowd-" (number->string k)) wait))
             (tags-list (lambda (limit) (make-tag-event 'list-tags now tag key '() limit aims (make-tags-list-spec #f))))
             (command (lambda (kind members)
                        (make-tag-event kind now tag key '() #f aims
                                        (make-command-spec (list 'members (map (lambda (m) (cons (car m) (tag-named (cdr m))))
                                                                               members))
                                                           #t))))
             (rename (lambda (from to) (command 'rename-tag (list (cons "from" from) (cons "to" to)))))
             (remove (lambda (t) (command 'remove-tag (list (cons "tag" t)))))
             (filter-of (lambda (state names)
                          (make-filter-event now tag key 100 state 'absent aims
                                             (make-filter-spec (map (lambda (n) (list 'entry (tag-named n) 'strict)) names) #f)))))
        (case k
          ((1) (tags-list 2))
          ((2) (filter-of "archived" '(crowd)))
          ((3) (rename 'crowd-capital 'throng))
          ((4) (make-event 'put now tag key (fresh-node-id rng w) 'create (list (cons "If-None-Match" "*"))
                           (make-tagged-content "note" "joined" "" "text/plain" #f 'absent
                                                (list 'entries (list (tag-named 'crowd-capital))))
                           #f #f #f #f aims 'absent))
          ((5) (let ((back (find (lambda (n) (and (memq (mnode-state n) '(active archived))
                                                  (not (member "crowd" (mnode-tags n)))
                                                  (let ((s (snap-of n 1))) (and s (member "crowd" (msnap-tags s))))))
                                 (by-id (nodes-of w tag)))))
                 (and back (make-event 'restore now tag key (mnode-id back) (node-rev back)
                                       (list (cons "If-Match" (etag-of (node-rev back)))) #f 1 #f #f #f aims 'absent))))
          ((6) (rename 'crowd-upper 'throng-upper))
          ((7 8) (rename 'crowd 'throng))
          ((9 15) (tags-list #f))
          ((10) (make-filter-event now tag key 100 #f 'absent aims
                                   (make-filter-spec (list (list 'entry (tag-named 'throng) 'strict)
                                                           (list 'entry (tag-named 'work-capital) 'plus))
                                                     #f)))
          ((11) (remove 'throng-capital))
          ((12 14) (remove 'throng))
          (else (remove 'throng-upper))))))

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

  ;;; A linked sequence: a hub of links first (slice 5b)

  ;; linked-seed? : Natural -> Boolean
  ;; One in five: a seed ending in 1 or 9 (never deep, never a family).
  (define (linked-seed? seed) (and (memv (mod seed 10) '(1 9)) #t))

  ;; linked-steps : Natural
  (define linked-steps 47)

  ;; linked-event : Rng World Natural Tag Natural -> (U Event #f)
  ;; Step K of the links a linked seed's TAG makes first, TAG's nodes in
  ;; the order made: H, a Project, then A, B, C, D and E, a Note, a Task, a
  ;; Contact, a Journal and a Note, all at the top; the other account makes
  ;; F. H links out to A (related, then blocks), B (related), C (mentions),
  ;; D (blocks) and E (mentions); A (related), B (mentions) and C (related)
  ;; link in to H; D blocks E; E is related to A. H's links are listed out
  ;; a page of one at a time, in two at a time, and its mentions one at a
  ;; time. D is trashed: H's PUT of its link to D again is 200, kept, and
  ;; of another type 409; H's links out, a page of 100, show D trashed. B
  ;; is archived. The other account asks for H's links, removes H's link to
  ;; A and links F to H: each a 404. B, archived, blocks C: 201. H's links
  ;; in are listed one at a time from after (mentions, B). D, linked both
  ;; ways, is purged, and its list is a 404; H's link to A is removed. Then
  ;; the ends of B's link to C go archived and trashed, each pair of states
  ;; met with a link there and one not: C archived, B's link to it is 200,
  ;; C's new one to B 201; B trashed, each is 200 and a new one either way
  ;; 409; C trashed, B's is 200 and a new one 409; C's link to B is removed
  ;; from a trashed source, 204, and again, 404. So a hub's lists page both
  ;; ways and by type, trashed and archived ends meet every route and every
  ;; cell of link-command, and a purge takes links both ways. #f when a
  ;; node it names is not there.
  (define (linked-event rng w now0 tag k)
    (let*-values (((who) (if (memv k '(7 27 28 29)) (other-tag tag) tag))
                  ((key) (rng-pick! rng (key-ids-of who)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((pick (lambda (t) (list->vector (filter (lambda (n) (eq? (mnode-tag n) t)) (world-nodes w)))))
             (mine (pick tag))
             (theirs (pick (other-tag tag)))
             (any-at (lambda (v i) (and (< i (vector-length v)) (vector-ref v i))))
             (at (lambda (v i) (let ((n (any-at v i))) (and n (live? n) n))))
             (aims (list (sym "linked-step-" (number->string k)) wait))
             (make (lambda (kind) (create-of rng w now who key kind 'absent aims)))
             (link (lambda (ev s type t)
                     (and s t (make-link-event ev now who key (mnode-id s) '() #f #f aims
                                               (make-link-spec type (mnode-id t) #f #f #f)))))
             (put (lambda (ev i type j) (link ev (at mine i) type (at mine j))))
             (list-of (lambda (n dir type limit after)
                        (and n (make-link-event 'list-links now who key (mnode-id n) '() limit #f aims
                                                (make-link-spec type #f #f dir after)))))
             (change (lambda (ev i) (let ((n (at mine i))) (and n (at-revision ev now who key n aims 'absent))))))
        (case k
          ((1) (make "project"))
          ((2) (make "note"))
          ((3) (make "task"))
          ((4) (make "contact"))
          ((5) (make "journal"))
          ((6) (make "note"))
          ((7) (make "project"))
          ((8) (put 'link 0 "related" 1))
          ((9) (put 'link 0 "blocks" 1))
          ((10) (put 'link 0 "related" 2))
          ((11) (put 'link 0 "mentions" 3))
          ((12) (put 'link 0 "blocks" 4))
          ((13) (put 'link 0 "mentions" 5))
          ((14) (put 'link 1 "related" 0))
          ((15) (put 'link 2 "mentions" 0))
          ((16) (put 'link 3 "related" 0))
          ((17) (put 'link 4 "blocks" 5))
          ((18) (put 'link 5 "related" 1))
          ((19) (list-of (at mine 0) "out" #f 1 #f))
          ((20) (list-of (at mine 0) "in" #f 2 #f))
          ((21) (list-of (at mine 0) #f "mentions" 1 #f))
          ((22) (change 'trash 4))
          ((23) (put 'link 0 "blocks" 4))
          ((24) (put 'link 0 "related" 4))
          ((25) (list-of (at mine 0) #f #f 100 #f))
          ((26) (change 'archive 2))
          ((27) (list-of (at mine 0) "in" #f 1 #f))
          ((28) (put 'unlink 0 "related" 1))
          ((29) (link 'link (at theirs 0) "related" (at mine 0)))
          ((30) (put 'link 2 "blocks" 3))
          ((31) (let ((b (at mine 2))) (and b (list-of (at mine 0) "in" #f 1 (cons "mentions" (mnode-id b))))))
          ((32) (change 'purge 4))
          ((33) (list-of (any-at mine 4) "in" #f #f #f))
          ((34) (put 'unlink 0 "related" 1))
          ((35) (change 'archive 3))
          ((36) (put 'link 2 "blocks" 3))
          ((37) (put 'link 3 "related" 2))
          ((38) (change 'trash 2))
          ((39) (put 'link 2 "blocks" 3))
          ((40) (put 'link 3 "related" 2))
          ((41) (put 'link 3 "mentions" 2))
          ((42) (put 'link 2 "mentions" 3))
          ((43) (change 'trash 3))
          ((44) (put 'link 2 "blocks" 3))
          ((45) (put 'link 2 "related" 3))
          ((46) (put 'unlink 3 "related" 2))
          (else (put 'unlink 3 "related" 2))))))

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

  ;; content->text : Content -> String
  ;; The PUT's JSON, with the props entry's text, when there is one, spliced
  ;; in exactly as the corpus writes it: so a name twice, a flonum and an
  ;; escape reach the server as sent; then the tags member, when there is
  ;; one, in the model's own writing (tags-member-text).
  (define (content->text c)
    (let* ((base (json->string (append (if (content-kind c) (list (cons "kind" (content-kind c))) '())
                                       (list (cons "title" (content-title c)) (cons "body" (content-body c))
                                             (cons "content_type" (content-type c)))
                                       (if (eq? (content-parent c) 'absent) '()
                                           (list (cons "parent" (ref-text (content-parent c))))))))
           (tags (tags-member-text (content-tags c)))
           (extra (append (if (content-props c) (list (string-append "\"props\":" (entry-sent (content-props c)))) '())
                          (if tags (list (string-append "\"tags\":" tags)) '()))))
      (if (null? extra)
          base
          (string-append (substring base 0 (- (string-length base) 1)) "," (join extra ",") "}"))))

  (define upper-hex "0123456789ABCDEF")

  ;; query-escape : String Symbol -> String
  ;; S as a query's value, in the model's own writing: its UTF-8 bytes,
  ;; each ASCII letter and digit and - . _ ~ as it is, a space as %20
  ;; (MODE 'strict) or + ('plus), every other byte %XX: so a + is %2B, as
  ;; the guide tells a client (H8).
  (define (query-escape s mode)
    (apply string-append
           (map (lambda (b)
                  (cond ((or (<= 48 b 57) (<= 65 b 90) (<= 97 b 122) (memv b '(45 46 95 126))) (string (integer->char b)))
                        ((and (= b 32) (eq? mode 'plus)) "+")
                        (else (string #\% (string-ref upper-hex (div b 16)) (string-ref upper-hex (mod b 16))))))
                (bytevector->u8-list (string->utf8 s)))))

  ;; tag-query-field : QueryTag -> String     a ?tag= field as the request writes it
  (define (tag-query-field q)
    (cond ((eq? q 'bare) "tag")
          ((eq? (car q) 'entry) (string-append "tag=" (query-escape (tag-entry-sent (cadr q)) (caddr q))))
          (else (string-append "tag=" (cadr q)))))

  ;; members-text : (Listof (Pair String Value)) -> String     a command's object, in the model's writing
  (define (members-text members)
    (string-append "{" (join (map (lambda (m) (string-append (json-string (car m)) ":"
                                                             (if (tag-entry? (cdr m)) (json-string (tag-entry-sent (cdr m))) (cadr (cdr m)))))
                                  members)
                             ",")
                   "}"))

  ;; command-body-text : Body -> String
  ;; A command's body: its object; that object with spaces after its { to
  ;; N bytes of UTF-8; or the text as it is.
  (define (command-body-text b)
    (case (car b)
      ((members) (members-text (cadr b)))
      ((padded) (let ((t (members-text (cadr b))))
                  (string-append "{" (make-string (- (caddr b) (bytevector-length (string->utf8 t))) #\space)
                                 (substring t 1 (string-length t)))))
      (else (cadr b))))

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
    (walk* h (list auth) base extra limit last-of #f))

  ;; walk* : Handler (Listof Header) String (Listof String) (U Natural #f) (Alist -> Any) (U String #f) -> Obs
  ;; walk's, with HEADERS on every page and the first page after FIRST
  ;; (#f: from the start).
  (define (walk* h headers base extra limit last-of first)
    (walk** h headers base extra limit last-of first cursor-text))

  ;; walk** : Handler (Listof Header) String (Listof String) (U Natural #f) (Alist -> Any) (U String #f)
  ;;          (Any -> String) -> Obs
  ;; walk*'s, each `next` written as `after` by ENCODE (a tag is
  ;; percent-encoded), FIRST as it is.
  (define (walk** h headers base extra limit last-of first encode)
    (let ((cap (or limit 50)))
      (let loop ((after first) (n 1) (items '()) (problems '()))
        (let* ((q (append extra
                          (if limit (list (string-append "limit=" (number->string limit))) '())
                          (if after (list (string-append "after=" after)) '())))
               (target (if (null? q) base (string-append base "?" (join q "&"))))
               (a (exchange h 'GET target headers)))
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
                      (else (loop (encode next) (+ n 1) items problems)))))))))

  ;; counted : Handler Header Obs -> Obs
  ;; L8 held on the handlers alone: a tags list's first tag is looked for
  ;; by the filter in each of the three states, 100 a page, and its count
  ;; must be min(1,000, the nodes found). The walks' pages are counted as
  ;; the list's requests; a difference, or a walk that is no 200, is the
  ;; list's problem.
  (define (counted h auth o)
    (if (and (eqv? (obs-status o) 200) (pair? (obs-items o)))
        (let* ((item (car (obs-items o)))
               (t (guard (c (#t #f)) (field item "tag")))
               (c (guard (c (#t #f)) (field item "count"))))
          (if (not (and (string? t) (natural? c)))
              o
              (let loop ((states '("active" "archived" "trashed")) (found 0) (requests 0) (problems '()))
                (if (null? states)
                    (make-obs 200 #f (obs-etag o) #f (obs-json o) (obs-items o)
                              (append (obs-problems o) problems
                                      (if (= c (min count-most found)) '()
                                          (list (format "L8: the tags list counts ~s on ~a nodes; the filter finds ~a in the three states"
                                                        t c found))))
                              (+ (obs-requests o) requests))
                    (let ((x (walk h auth "/v1/nodes" (list (string-append "state=" (car states))
                                                            (string-append "tag=" (query-escape t 'strict)))
                                   100 (lambda (i) (field i "id")))))
                      (loop (cdr states) (+ found (length (or (obs-items x) '()))) (+ requests (obs-requests x))
                            (append problems (obs-problems x)
                                    (if (eqv? (obs-status x) 200) '()
                                        (list (format "L8: the filter for the tag ~s answered ~a" t (obs-status x)))))))))))
        o))

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
        ((done wontdo reopen)
         (single (exchange h 'POST (string-append (node-path e) "/" (symbol->string (event-kind e)))
                           (cons auth (event-headers e)))))
        ((move move-children)
         (single (exchange h 'POST (string-append (node-path e) "/" (symbol->string (event-kind e)))
                           (append (list auth (cons "Content-Type" "application/json")) (event-headers e))
                           (json->string (list (cons "parent" (ref-text (event-parent e))))))))
        ((get-node) (single (exchange h 'GET (node-path e) (list auth))))
        ((get-snapshot)
         (single (exchange h 'GET (string-append (node-path e) "/revisions/" (number->string (event-snap e)))
                           (list auth))))
        ((list-nodes)
         (let ((f (event-tagq e)))
           (walk* h (list auth) "/v1/nodes"
                  (append (state-query (event-query e)) (parent-query (event-parent e))
                          (if f (map tag-query-field (filter-spec-values f)) '()))
                  (event-limit e) (lambda (item) (field item "id"))
                  (and f (filter-spec-after f) (id-text (filter-spec-after f))))))
        ((list-tags)
         (let ((a (tags-list-spec-after (event-tagq e))))
           (counted h auth
                    (walk** h (list auth) "/v1/tags" (if (eq? a 'twice) '("after=work" "after=work") '())
                            (event-limit e) (lambda (item) (field item "tag"))
                            (and (pair? a) (query-escape (tag-entry-sent (cadr a)) (caddr a)))
                            (lambda (next) (query-escape next 'strict))))))
        ((rename-tag remove-tag)
         (let ((spec (event-tagq e)))
           (single (exchange h 'POST (if (eq? (event-kind e) 'rename-tag) "/v1/tags/rename" "/v1/tags/remove")
                             (append (list auth (cons "Content-Type" (if (command-spec-json? spec) "application/json" "text/plain")))
                                     (event-headers e))
                             (command-body-text (command-spec-body spec))))))
        ((link unlink)
         (single (exchange h (if (eq? (event-kind e) 'link) 'PUT 'DELETE) (link-path e) (cons auth (event-headers e)))))
        ((list-links)
         (let* ((spec (event-link e)) (a (link-spec-after spec)))
           (walk* h (cons auth (event-headers e)) (string-append (node-path e) "/links")
                  (append (field-query "direction" (link-spec-direction spec) "in")
                          (field-query "type" (link-spec-type spec) "related"))
                  (event-limit e)
                  (lambda (item) (string-append (field item "type") ":" (field (field item "node") "id")))
                  (and a (string-append (car a) ":" (id-text (cdr a)))))))
        (else (walk h auth (string-append (node-path e) "/revisions") '() (event-limit e)
                    (lambda (item) (field item "revision")))))))

  ;; link-path : Event -> String     /v1/nodes/{id}/links/{type}/{target}, as the request names them
  (define (link-path e)
    (let* ((spec (event-link e)) (t (link-spec-target spec)))
      (string-append (node-path e) "/links/" (link-spec-type spec) "/"
                     (if (bytevector? t)
                         (let ((text (id-text t))) (if (link-spec-upper? spec) (string-upcase text) text))
                         t))))

  ;; field-query : String (U String 'twice #f) String -> (Listof String)
  ;; A list's NAME= fields: none, the one given, or TWICE, a good value,
  ;; given twice.
  (define (field-query name q twice)
    (cond ((not q) '())
          ((eq? q 'twice) (let ((f (string-append name "=" twice))) (list f f)))
          (else (list (string-append name "=" q)))))

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
  ;; answer, a move's and a Task's command's have no body (the plan's
  ;; choice; P7); a bulk move's
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
              (if (and (or (life-kind? kind) (task-kind? kind) (eq? kind 'move)) (assoc "body" j))
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
           '())
       (if (or (link-kind? kind) (eq? kind 'list-links)) (link-law-breaks w e o) '())
       (tag-answer-breaks e o))))

  ;; answer-tags-breaks : String Any -> (Listof String)
  ;; L2 on an answer's node or snapshot, WHAT naming it: it has tags, an
  ;; array, held by tag-list-breaks.
  (define (answer-tags-breaks what j)
    (let ((p (and (list? j) (assoc "tags" j))))
      (cond ((not p) (list (format "L2: ~a has no tags" what)))
            ((not (vector? (cdr p))) (list (format "L2: ~a's tags are ~s, no array" what (cdr p))))
            (else (tag-list-breaks what (vector->list (cdr p)))))))

  ;; tag-answer-breaks : Event Obs -> (Listof String)
  ;; An answer held to the tags' laws that need no model: every node in
  ;; it, alone, a list's item or a link list's other end, and a snapshot
  ;; whole, has tags by L2; the revisions list shows none (the review's
  ;; blocker 7); a filtered list's every item carries every tag asked (G6);
  ;; a command's 200 has no ETag and is {WORD: N, "left": M} alone, N at
  ;; most 500 (G8); a tags list's every item is {"tag", "count"} alone, its
  ;; tags rising by code point, each counted 1 to 1,000 (H6).
  (define (tag-answer-breaks e o)
    (let ((status (obs-status o)) (kind (event-kind e)) (j (obs-json o)))
      (append
       (if (and (memv status '(200 201)) (memq kind (cons 'get-node write-kinds)) (not (eq? kind 'move-children)) (list? j))
           (answer-tags-breaks (format "a ~a's answer" kind) j)
           '())
       (if (and (eqv? status 200) (eq? kind 'get-snapshot)) (answer-tags-breaks "a snapshot's answer" j) '())
       (if (and (eqv? status 200) (eq? kind 'list-revisions)
                (exists (lambda (i) (and (list? i) (assoc "tags" i))) (or (obs-items o) '())))
           (list "the review's blocker 7: the revisions list shows tags")
           '())
       (if (and (eqv? status 200) (eq? kind 'list-nodes))
           (let ((tags (let ((f (event-tagq e))) (if f (filter-tags-of (filter-spec-values f)) '()))))
             (apply append
                    (map (lambda (i)
                           (append (answer-tags-breaks "a list's item" i)
                                   (let ((p (and (list? i) (assoc "tags" i))))
                                     (if (and (list? tags) p (vector? (cdr p))
                                              (for-all (lambda (t) (member t (vector->list (cdr p)))) tags))
                                         '()
                                         (list (format "G6: a list for the tags ~s shows an item whose tags are ~s" tags (and p (cdr p))))))))
                         (or (obs-items o) '()))))
           '())
       (if (and (eqv? status 200) (eq? kind 'list-links))
           (apply append (map (lambda (i) (answer-tags-breaks "a link list's node" (and (list? i) (assoc "node" i) (cdr (assoc "node" i)))))
                              (or (obs-items o) '())))
           '())
       (if (and (step-kind? kind) (eqv? status 200))
           (let ((word (step-word kind)))
             (append (if (obs-etag o) (list (format "G8: a step's answer has the ETag ~s" (obs-etag o))) '())
                     (if (and (list? j) (= (length j) 2)
                              (let ((n (assoc word j)) (l (assoc "left" j)))
                                (and n l (natural? (cdr n)) (natural? (cdr l)) (<= (cdr n) step-most))))
                         '()
                         (list (format "G8: a step answers {~s: N, \"left\": M} alone, N at most 500, not ~s" word j)))))
           '())
       (if (and (eqv? status 200) (eq? kind 'list-tags))
           (let ((items (or (obs-items o) '())))
             (append
              (if (for-all (lambda (i) (and (list? i) (= (length i) 2) (assoc "tag" i) (assoc "count" i)
                                            (string? (cdr (assoc "tag" i))) (natural? (cdr (assoc "count" i)))
                                            (<= 1 (cdr (assoc "count" i)) count-most)))
                           items)
                  (if (ids-rising? (map (lambda (i) (cdr (assoc "tag" i))) items)) '()
                      (list "H6: a tags list's tags are not rising by code point, each once"))
                  (list (format "H6: a tags list's item is not {\"tag\", \"count\"} alone, counted 1 to 1,000: ~s" items)))))
           '()))))

  ;; link-law-breaks : World Event Obs -> (Listof String)
  ;; A link's answer held to laws that need no model: none has an ETag
  ;; (H14') or a Location; a PUT's 201 or 200 is the link the path names,
  ;; {"source", "type", "target", "created"} alone; a DELETE's 204 has no
  ;; body; a list's items are each {"type", "created", "node"}, of the
  ;; type asked, each node a live node of the account's (H6, Q1), each
  ;; link once, by type then id (Q10).
  (define (link-law-breaks w e o)
    (let* ((status (obs-status o)) (kind (event-kind e)) (j (obs-json o)) (spec (event-link e)))
      (append
       (if (obs-etag o) (list (format "H14': a link's ~a answer has the ETag ~s" status (obs-etag o))) '())
       (if (obs-location o) (list (format "a link's ~a answer has the Location ~s" status (obs-location o))) '())
       (if (and (eq? kind 'link) (memv status '(200 201)))
           (let ((t (link-spec-target spec)))
             (if (and (list? j) (= (length j) 4)
                      (equal? (assoc "source" j) (cons "source" (id-text (event-id e))))
                      (equal? (assoc "type" j) (cons "type" (link-spec-type spec)))
                      (bytevector? t) (equal? (assoc "target" j) (cons "target" (id-text t)))
                      (let ((c (assoc "created" j))) (and c (natural? (cdr c)))))
                 '()
                 (list (format "the plan: a link's ~a is {\"source\", \"type\", \"target\", \"created\"} of the path's link, not ~s"
                               status j))))
           '())
       (if (and (eq? kind 'unlink) (eqv? status 204) (not (eq? j 'empty)))
           (list (format "the plan: an unlink's 204 has a body: ~s" j))
           '())
       (if (and (eq? kind 'list-links) (eqv? status 200))
           (let* ((items (obs-items o))
                  (shape? (lambda (i) (and (list? i) (= (length i) 3) (assoc "type" i) (assoc "created" i) (assoc "node" i)
                                           (list? (cdr (assoc "node" i))) (assoc "id" (cdr (assoc "node" i))))))
                  (keys (map (lambda (i) (and (shape? i) (cons (cdr (assoc "type" i)) (cdr (assoc "id" (cdr (assoc "node" i)))))))
                             items))
                  (asked (link-type-filter (link-spec-type spec)))
                  (mine (map (lambda (n) (id-text (mnode-id n))) (nodes-of w (event-tag e)))))
             (cond
              ((not (for-all (lambda (k) k) keys))
               (list (format "the plan: a link list's item is {\"type\", \"created\", \"node\"} alone: ~s" items)))
              (else
               (append
                (if (for-all (lambda (k) (member (cdr k) mine)) keys) '()
                    (list "H6, Q1: a link list shows a node that is no live node of the account's"))
                (if (or (not (string? asked)) (for-all (lambda (k) (equal? (car k) asked)) keys)) '()
                    (list (format "Q10: a link list of type ~a shows the types ~s" asked (map car keys))))
                (if (let rising ((ks keys))
                      (or (null? ks) (null? (cdr ks))
                          (and (or (string<? (caar ks) (caadr ks))
                                   (and (string=? (caar ks) (caadr ks)) (string<? (cdar ks) (cdadr ks))))
                               (rising (cdr ks)))))
                    '()
                    (list "Q10: a link list does not show each link once, by type then the other node's id"))))))
           '()))))

  ;;; The database

  ;; Db = (List Nodes Snaps Changes Keys Links Tags), each a list of rows, each row a list:
  ;;   node     (id owner author kind title content_type props revision created updated state parent)
  ;;   snapshot (node revision author title content_type props created body tags)
  ;;   change   (owner seq node revision op created)
  ;;   key      (id account last_used)
  ;;   link     (owner source type target created), by owner, source, type, target
  ;;   tag      (owner tag node), node_tags by owner, node, tag (slice 7a)
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
  (define (s-body r) (list-ref r 7))
  (define (s-tags r) (list-ref r 8))
  (define (c-owner r) (list-ref r 0))
  (define (c-seq r) (list-ref r 1))
  (define (c-node r) (list-ref r 2))
  (define (c-rev r) (list-ref r 3))
  (define (c-op r) (list-ref r 4))
  (define (c-created r) (list-ref r 5))
  (define (k-account r) (list-ref r 1))
  (define (l-owner r) (list-ref r 0))
  (define (l-source r) (list-ref r 1))
  (define (l-type r) (list-ref r 2))
  (define (l-target r) (list-ref r 3))
  (define (db-links db) (list-ref db 4))
  (define (t-owner r) (list-ref r 0))
  (define (t-tag r) (list-ref r 1))
  (define (t-node r) (list-ref r 2))
  (define (db-tag-rows db) (list-ref db 5))

  (define (row->list v) (map (lambda (c) (if (sql-null? c) #f c)) (vector->list v)))

  ;; db-now : Store -> Db     the tables and every key's last_used, whole: node_tags and
  ;; a snapshot's tags among them (the review's blocker 8)
  (define (db-now store)
    (run-read store
              (lambda (tx)
                (let* ((nodes (tx-query tx (string-append "SELECT id, owner, author, kind, title, content_type,"
                                                          " props, revision, created, updated, state, parent"
                                                          " FROM nodes ORDER BY id")))
                       (snaps (tx-query tx (string-append "SELECT node, revision, author, title, content_type,"
                                                          " props, created, body, tags FROM revisions"
                                                          " ORDER BY node, revision")))
                       (changes (tx-query tx (string-append "SELECT owner, seq, node, revision, op, created"
                                                            " FROM changes ORDER BY owner, seq")))
                       (keys (tx-query tx "SELECT id, account, last_used FROM api_keys ORDER BY id"))
                       (links (tx-query tx (string-append "SELECT owner, source, type, target, created FROM links"
                                                          " ORDER BY owner, source, type, target")))
                       (tags (tx-query tx "SELECT owner, tag, node FROM node_tags ORDER BY owner, node, tag")))
                  (list (map row->list nodes) (map row->list snaps) (map row->list changes) (map row->list keys)
                        (map row->list links) (map row->list tags))))))

  ;;; The laws, with no model: the tables after a request, and before it

  (define (find-node rows id) (find (lambda (r) (bytevector=? (n-id r) id)) rows))
  (define (but-node rows id) (filter (lambda (r) (not (bytevector=? (n-id r) id))) rows))

  ;; The ops that write content, and so a snapshot: a Task's three
  ;; commands among them (P7: a transition writes a snapshot).
  (define content-ops '("create" "update" "restore" "done" "wontdo" "reopen"))

  ;; task-ops : the change rows a Task's commands write, each its own name
  (define task-ops '("done" "wontdo" "reopen"))

  ;; link-ops : the change rows a link writes on its source (K5)
  (define link-ops '("link" "unlink"))
  (define (link-op? op) (and (member op link-ops) #t))

  ;; feed-state : (Listof String) -> (U String #f)
  ;; The state a node's change rows leave it in, oldest first: a create
  ;; makes it active, an update, a restore, a move, a link, an unlink, a
  ;; Task's done, wontdo and reopen and a step's tags keep it (G3'), a
  ;; change of state lands where lifecycle-moves says. #f for an op none of
  ;; these is.
  (define (feed-state ops)
    (fold-left (lambda (state op)
                 (cond ((not state) #f)
                       ((string=? op "create") "active")
                       ((member op '("update" "restore" "move" "link" "unlink" "done" "wontdo" "reopen" "tags")) state)
                       ((find (lambda (m) (string=? (symbol->string (car m)) op)) lifecycle-moves)
                        => (lambda (m) (symbol->string (caddr m))))
                       (else #f)))
               "none" ops))

  ;; node-law-breaks : Row (Listof Row) (Listof Row) -> (Listof String)
  ;; One node's row, its snapshots (by revision) and its change rows (in
  ;; the feed's order): G3', G6, G16, H2', H3', H15'', H16. G3': its rows
  ;; but link and unlink run 1 to its revision; a link or unlink row
  ;; carries the revision of the newest other row before it, and keeps
  ;; the state. H15'': updated is the time of the newest row that is
  ;; neither.
  (define (node-law-breaks r ss cs)
    (let* ((n (n-rev r))
           (revs (map s-rev ss))
           (own-cs (filter (lambda (c) (not (link-op? (c-op c)))) cs))
           (crevs (map c-rev own-cs))
           (ops (map c-op cs))
           (state (n-state r))
           (purged? (equal? state "purged"))
           (top (and (pair? ss) (car (reverse ss))))
           (newest (and (pair? own-cs) (car (reverse own-cs))))
           (name (id-text (n-id r))))
      (append
       (if (equal? crevs (from-to 1 n)) '()
           (list (format "G3': node ~a is at revision ~a; its change rows' revisions but link and unlink, in the feed's order, are ~a"
                         name n crevs)))
       (let loop ((cs cs) (last #f) (acc '()))
         (cond ((null? cs) (reverse acc))
               ((link-op? (c-op (car cs)))
                (loop (cdr cs) last
                      (if (eqv? (c-rev (car cs)) last) acc
                          (cons (format "G3': node ~a's ~a row, seq ~a, is at revision ~a; the newest other row before it at ~a"
                                        name (c-op (car cs)) (c-seq (car cs)) (c-rev (car cs)) last)
                                acc))))
               (else (loop (cdr cs) (c-rev (car cs)) acc))))
       (if (and (pair? ops) (string=? (car ops) "create")) '()
           (list (format "H4: node ~a's first change row is ~s, not its create" name (if (pair? ops) (car ops) "none"))))
       (let ((after (member "purge" ops)))
         (if (or (not after) (null? (cdr after))) '()
             (list (format "G16: node ~a has change rows after its purge: ~a" name (cdr after)))))
       (let ((want (feed-state ops)))
         (if (equal? want state) '()
             (list (format "G3': node ~a is ~a, but its change rows ~a leave it ~a" name state ops want))))
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
           (list (format "H15'': node ~a's updated is ~a; its newest change row's but link and unlink, time ~a" name
                         (n-updated r) (and newest (c-created newest)))))
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

  ;; link-table-breaks : (Listof Row) (Listof Row) -> (Listof String)
  ;; Every row of links, by the rows of nodes: Q1, both ends are rows of
  ;; the link's owner; Q8, neither is purged, so a purged row has no link
  ;; either way; Q2, no row has one node at both ends, and every type is
  ;; one of the three.
  (define (link-table-breaks nodes links)
    (let ((by (make-id-table)))
      (for-each (lambda (r) (hashtable-set! by (n-id r) r)) nodes)
      (fold-right
       (lambda (l acc)
         (let* ((end (lambda (id what)
                       (let ((r (hashtable-ref by id #f)))
                         (cond ((not r) (list (format "Q1: a link's ~a ~a is no row" what (id-text id))))
                               ((not (bytevector=? (n-owner r) (l-owner l)))
                                (list (format "Q1: a link of ~a has the ~a ~a, ~a's node" (account-label (l-owner l)) what
                                              (id-text id) (account-label (n-owner r)))))
                               ((equal? (n-state r) "purged")
                                (list (format "Q1, Q8: a link's ~a ~a is purged" what (id-text id))))
                               (else '()))))))
           (append (end (l-source l) "source")
                   (end (l-target l) "target")
                   (if (bytevector=? (l-source l) (l-target l))
                       (list (format "Q2: node ~a links to itself" (id-text (l-source l))))
                       '())
                   (if (member (l-type l) link-type-names) '()
                       (list (format "Q2: a link has the type ~s" (l-type l))))
                   acc)))
       '() links)))

  ;; text-breaks : String String -> (Listof String)
  ;; A KIND's stored props TEXT held to R1, R2, R5 and R9 by the model's
  ;; own reading (the JSON reader, never (techo props)): at most 4,096
  ;; bytes and a JSON object (R1); a Task's never holds the default TODO
  ;; (R2), a status only DONE or WONTDO, and closed, a whole number, exactly
  ;; when the status, TODO when none is stored, is not TODO (R5);
  ;; every When a Note's or a Task's holds is one of the corpus's good ones
  ;; (R9, by the corpus). Remembered by kind and text: the texts repeat.
  (define text-memo (make-hashtable equal-hash equal?))
  (define (text-breaks kind text)
    (let ((key (cons kind text)))
      (or (hashtable-ref text-memo key #f)
          (let ((b (text-breaks* kind text))) (hashtable-set! text-memo key b) b))))
  (define (text-breaks* kind text)
    (let ((j (guard (c (#t 'not-json)) (json-of text))))
      (append
       (if (<= (bytevector-length (string->utf8 text)) 4096) '() (list "R1: its props are over 4,096 bytes"))
       (cond ((not (list? j)) (list "R1: its props are no JSON object"))
             ((string=? kind "task")
              (let ((status (assoc "status" j)) (closed (assoc "closed" j)))
                (append
                 (if (and status (equal? (cdr status) "TODO")) (list "R2: a Task's props store the default TODO") '())
                 (if (or (not status) (member (cdr status) '("TODO" "DONE" "WONTDO"))) '()
                     (list (format "R5: a Task's status is ~s" (cdr status))))
                 (if (eq? (and status (not (equal? (cdr status) "TODO")) #t) (and closed #t)) '()
                     (list "R5: a Task's closed is there while it is TODO, or not there while it is not"))
                 (if (or (not closed) (natural? (cdr closed))) '() (list "R5: a Task's closed is no whole number")))))
             (else '()))
       (if (and (list? j) (for-all (lambda (x) (member x good-whens)) (whens-in kind text))) '()
           (list "R9: its props hold a When that is not one of the corpus's good ones")))))

  ;; props-table-breaks : (Listof Row) (Listof Row) -> (Listof String)
  ;; Every row of nodes and every snapshot, its props by text-breaks, a
  ;; snapshot by its node's kind.
  (define (props-table-breaks nodes snaps)
    (let ((kind-of (make-id-table)))
      (for-each (lambda (r) (hashtable-set! kind-of (n-id r) (n-kind r))) nodes)
      (append
       (apply append (map (lambda (r) (map (lambda (b) (format "node ~a: ~a: ~s" (id-text (n-id r)) b (n-props r)))
                                           (text-breaks (n-kind r) (n-props r))))
                          nodes))
       (apply append (map (lambda (s) (let ((k (hashtable-ref kind-of (s-node s) #f)))
                                        (if k
                                            (map (lambda (b) (format "node ~a's snapshot ~a: ~a: ~s" (id-text (s-node s))
                                                                     (s-rev s) b (s-props s)))
                                                 (text-breaks k (s-props s)))
                                            '())))
                          snaps)))))

  ;; always-breaks : Db -> (Listof String)
  (define (always-breaks db)
    (let* ((nodes (car db)) (snaps (cadr db)) (changes (caddr db))
           (snaps-of (grouped snaps s-node))
           (changes-of (grouped changes c-node)))
      (append
       (props-table-breaks nodes snaps)
       (forest-breaks nodes)
       (link-table-breaks nodes (db-links db))
       (tag-table-breaks nodes snaps changes (db-tag-rows db))
       (fold-right (lambda (r acc)
                     (append (node-law-breaks r (snaps-of (n-id r)) (changes-of (n-id r))) acc))
                   '() nodes)
       (let ((ids (make-id-table)))
         (for-each (lambda (r) (hashtable-set! ids (n-id r) #t)) nodes)
         (append
          (if (for-all (lambda (s) (hashtable-ref ids (s-node s) #f)) snaps) '()
              (list "H3': a snapshot whose node has no row"))
          (if (for-all (lambda (c) (hashtable-ref ids (c-node c) #f)) changes) '()
              (list "H4: a change row whose node has no row"))))
       (fold-right (lambda (a acc)
                     (let ((seqs (map c-seq (filter (lambda (c) (bytevector=? (c-owner c) (macct-id a))) changes))))
                       (if (equal? seqs (from-to 1 (length seqs))) acc
                           (cons (format "H4: ~a's change numbers are ~a, not 1 to ~a" (macct-tag a) seqs (length seqs))
                                 acc))))
                   '() model-accounts))))

  ;; tags-of-text : String -> (U (Listof String) #f)
  ;; A snapshot's stored tags as the JSON reader reads them, never (techo
  ;; tags): the array's strings in order; #f for what is no array of
  ;; strings. Remembered: the texts repeat.
  (define tags-memo (make-hashtable string-hash string=?))
  (define (tags-of-text text)
    (let ((hit (hashtable-ref tags-memo text 'none)))
      (if (not (eq? hit 'none))
          hit
          (let* ((v (guard (c (#t #f)) (string->json text)))
                 (r (and (vector? v) (for-all string? (vector->list v)) (vector->list v))))
            (hashtable-set! tags-memo text r)
            r))))

  ;; tag-list-breaks : String (Listof String) -> (Listof String)
  ;; L2 on one node's or one snapshot's tags, WHAT naming it: at most 50,
  ;; each a stored form of the corpus (so 1 to 64 characters, and a fixed
  ;; point by the corpus: L1), each greater than the one before (sorted by
  ;; code point, none twice).
  (define (tag-list-breaks what ts)
    (append (if (<= (length ts) tag-most) '() (list (format "L2: ~a has ~a tags" what (length ts))))
            (if (for-all stored-tag? ts) '()
                (list (format "L2: ~a's tags ~s hold one that is no stored form of the corpus" what ts)))
            (if (ids-rising? ts) '() (list (format "L2: ~a's tags ~s are not sorted by code point, each once" what ts)))))

  ;; snapshot-tag-memo : Hashtable     tag-list-breaks of a snapshot's text, remembered
  (define snapshot-tag-memo (make-hashtable string-hash string=?))
  (define (snapshot-text-breaks text)
    (or (hashtable-ref snapshot-tag-memo text #f)
        (let* ((ts (tags-of-text text))
               (b (if ts (tag-list-breaks "a snapshot" ts) (list (format "L2: a snapshot's tags ~s are no array of strings" text)))))
          (hashtable-set! snapshot-tag-memo text b)
          b)))

  ;; tag-table-breaks : (Listof Row) (Listof Row) (Listof Row) (Listof Row) -> (Listof String)
  ;; Every row of node_tags and every snapshot's tags, by the rows of
  ;; nodes: L9, a tag row's owner is its node's; L7, no tag row's node is
  ;; purged, or no row; L2 on each node's rows and each snapshot's tags;
  ;; L3, a live node whose newest snapshot no step has followed (no change
  ;; row tags at a later revision) carries exactly that snapshot's tags.
  (define (tag-table-breaks nodes snaps changes rows)
    (let ((by (make-id-table)) (tags-of (grouped rows t-node)) (snaps-of (grouped snaps s-node))
          (changes-of (grouped changes c-node)))
      (for-each (lambda (r) (hashtable-set! by (n-id r) r)) nodes)
      (append
       (fold-right (lambda (t acc)
                     (let ((r (hashtable-ref by (t-node t) #f)))
                       (cond ((not r) (cons (format "L7, L9: a tag row ~s's node ~a is no row" (t-tag t) (id-text (t-node t))) acc))
                             ((not (bytevector=? (n-owner r) (t-owner t)))
                              (cons (format "L9: node ~a of ~a has a tag row ~s of ~a" (id-text (t-node t)) (account-label (n-owner r))
                                            (t-tag t) (account-label (t-owner t)))
                                    acc))
                             ((equal? (n-state r) "purged")
                              (cons (format "L7: purged node ~a carries ~s" (id-text (t-node t)) (t-tag t)) acc))
                             (else acc))))
                   '() rows)
       (fold-right
        (lambda (r acc)
          (let* ((id (n-id r)) (name (id-text id))
                 (ts (map t-tag (tags-of id)))
                 (ss (snaps-of id))
                 (top (and (pair? ss) (car (reverse ss)))))
            (append
             (if (null? ts) '() (tag-list-breaks (string-append "node " name) ts))
             (if (and top (not (equal? (n-state r) "purged"))
                      (not (exists (lambda (c) (and (equal? (c-op c) "tags") (> (c-rev c) (s-rev top)))) (changes-of id)))
                      (not (equal? (tags-of-text (s-tags top)) ts)))
                 (list (format "L3: node ~a carries ~s; its newest snapshot, ~a, no step since, holds ~a" name ts (s-rev top)
                               (s-tags top)))
                 '())
             acc)))
        '() nodes)
       (fold-right (lambda (s acc)
                     (append (map (lambda (b) (format "node ~a's snapshot ~a: ~a" (id-text (s-node s)) (s-rev s) b))
                                  (snapshot-text-breaks (s-tags s)))
                             acc))
                   '() snaps))))

  ;; tags-in : Db Bytevector -> (Listof String)     the node ID's rows, in tag order
  (define (tags-in db id) (map t-tag (filter (lambda (t) (bytevector=? (t-node t) id)) (db-tag-rows db))))

  ;; tag-write-breaks : Event String String Bytevector Db Db (Listof Row) Natural -> (Listof String)
  ;; An accepted write of one node, on node_tags: no other node's rows
  ;; change (G6'); a content write's new snapshot holds the node's rows
  ;; after it (L3); a replace with no tags changes none of its rows (L4); a
  ;; restore sets them to the restored snapshot's tags as stored, so one
  ;; from before migration 7 clears them (L11); a Task's command, a change
  ;; of state and a move change none (G11'); a purge leaves none (L7).
  (define (tag-write-breaks e op name id db0 db1 mine1 rev)
    (let* ((others (lambda (db) (filter (lambda (t) (not (bytevector=? (t-node t) id))) (db-tag-rows db))))
           (t0 (tags-in db0 id)) (t1 (tags-in db1 id)))
      (append
       (if (equal? (others db0) (others db1)) '()
           (list (format "G6': an accepted ~a of ~a changed another node's tag rows" op name)))
       (if (member op content-ops)
           (let ((added (find (lambda (s) (= (s-rev s) rev)) mine1)))
             (if (and added (equal? (tags-of-text (s-tags added)) t1)) '()
                 (list (format "L3: an accepted ~a of ~a wrote a snapshot whose tags ~a are not its rows after, ~s" op name
                               (and added (s-tags added)) t1))))
           '())
       (cond
        ((and (string=? op "update") (eq? (content-tags (event-content e)) 'absent))
         (if (equal? t0 t1) '() (list (format "L4: a replace of ~a with no tags changed its rows from ~s to ~s" name t0 t1))))
        ((string=? op "restore")
         (let ((snap (find (lambda (s) (and (bytevector=? (s-node s) id) (= (s-rev s) (event-snap e)))) (cadr db0))))
           (if (and snap (equal? t1 (tags-of-text (s-tags snap)))) '()
               (list (format "L11: a restore of ~a's snapshot ~a set its rows to ~s, not that snapshot's ~a" name (event-snap e) t1
                             (and snap (s-tags snap)))))))
        ((string=? op "purge") (if (null? t1) '() (list (format "L7: a purge of ~a left its tags ~s" name t1))))
        ((member op '("create" "update")) '())
        (else (if (equal? t0 t1) '() (list (format "G11': an accepted ~a of ~a changed its tags from ~s to ~s" op name t0 t1))))))))

  ;; changes-added : Db Db -> (values (Listof Row) Boolean)
  ;; The change rows of DB1 that DB0 has not, by owner and seq, in DB1's
  ;; order (one there with another value among them), and whether every
  ;; row of DB0 is in DB1 as it was. By a table, not a walk of the rows
  ;; for each row: a crowd's file has a thousand.
  (define (changes-added db0 db1)
    (let ((t0 (make-hashtable (lambda (k) (+ (id-hash (car k)) (cdr k)))
                              (lambda (a b) (and (bytevector=? (car a) (car b)) (= (cdr a) (cdr b))))))
          (t1 (make-hashtable (lambda (k) (+ (id-hash (car k)) (cdr k)))
                              (lambda (a b) (and (bytevector=? (car a) (car b)) (= (cdr a) (cdr b)))))))
      (for-each (lambda (c) (hashtable-set! t0 (cons (c-owner c) (c-seq c)) c)) (caddr db0))
      (for-each (lambda (c) (hashtable-set! t1 (cons (c-owner c) (c-seq c)) c)) (caddr db1))
      (values (filter (lambda (c) (not (equal? (hashtable-ref t0 (cons (c-owner c) (c-seq c)) #f) c))) (caddr db1))
              (for-all (lambda (c) (equal? (hashtable-ref t1 (cons (c-owner c) (c-seq c)) #f) c)) (caddr db0)))))

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
           (by0 (let ((t (make-id-table))) (for-each (lambda (r) (hashtable-set! t (n-id r) r)) rows0) t))
           (changed (filter (lambda (r1) (not (equal? (hashtable-ref by0 (n-id r1) #f) r1))) rows1))
           (m0 (length (filter (lambda (c) (bytevector=? (c-owner c) asker)) (caddr db0))))
           (added (let-values (((added kept?) (changes-added db0 db1))) added))
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
          (let ((r0 (hashtable-ref by0 (n-id r1) #f)) (child (id-text (n-id r1))))
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
       (if (equal? (db-links db0) (db-links db1)) '()
           (list (format "Q9: a bulk move of ~a's children changed links" name)))
       (if (equal? (db-tag-rows db0) (db-tag-rows db1)) '()
           (list (format "G6', L5: a bulk move of ~a's children changed tag rows" name)))
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

  ;; tag-row<? : Row Row -> Boolean     node_tags' order: owner, node, tag, as the query sorts them
  (define (tag-row<? x y)
    (cond ((not (bytevector=? (t-owner x) (t-owner y))) (bytevector<? (t-owner x) (t-owner y)))
          ((not (bytevector=? (t-node x) (t-node y))) (bytevector<? (t-node x) (t-node y)))
          (else (string<? (t-tag x) (t-tag y)))))

  ;; step-breaks : Event Obs Db Db -> (Listof String)
  ;; An accepted step of a tag's rename or removal (G8), between the
  ;; tables before and after, as the plan restates L5: the carriers of
  ;; FROM, the asker's rows of it before, by id; the first min(500, them)
  ;; are touched, whatever their state (L13); every node row changed is a
  ;; touched one and every touched one changed, each at its next revision,
  ;; updated the time, nothing else (H1, and H2': its title, content type
  ;; and props still its newest snapshot's); no row made or lost; no
  ;; snapshot written, changed or removed (H3'); one change row tags for
  ;; each, at its new revision, the owner's next numbers in id order, and
  ;; no other (H4, G6'); each touched node's tag rows its rows before less
  ;; FROM, with TO for a rename (a merge where it was), every other tag row
  ;; as it was (L5, L6); no link changed (Q9); the answer's count the
  ;; touched, its left the asker's rows of FROM after, which is the
  ;; carriers before less the touched; and H5.
  (define (step-breaks e o db0 db1)
    (let-values (((v clause) (command-verdict e)))
      (if (not (memq (car v) '(rename remove)))
          (list (format "the handlers took a step the model refuses: ~s" v))
          (let* ((now (event-now e)) (asker (account-id-of (event-tag e)))
                 (from (cadr v)) (to (and (eq? (car v) 'rename) (caddr v)))
                 (word (step-word (event-kind e)))
                 (what (format "a step of ~a ~s~a" (event-kind e) from (if to (format " to ~s" to) "")))
                 (rows0 (car db0)) (rows1 (car db1))
                 (by0 (make-id-table))
                 (carriers (list-sort bytevector<?
                                      (map t-node (filter (lambda (t) (and (bytevector=? (t-owner t) asker) (string=? (t-tag t) from)))
                                                          (db-tag-rows db0)))))
                 (touched (take* carriers step-most))
                 (touched? (make-id-table))
                 (m0 (length (filter (lambda (c) (bytevector=? (c-owner c) asker)) (caddr db0))))
                 (added (let-values (((added kept?) (changes-added db0 db1))) added))
                 (by1 (make-id-table))
                 (has-to (make-id-table))
                 (j (obs-json o))
                 (count (and (list? j) (assoc word j) (cdr (assoc word j))))
                 (left (and (list? j) (assoc "left" j) (cdr (assoc "left" j)))))
            (for-each (lambda (r) (hashtable-set! by0 (n-id r) r)) rows0)
            (for-each (lambda (r) (hashtable-set! by1 (n-id r) r)) rows1)
            (for-each (lambda (t) (when (and to (bytevector=? (t-owner t) asker) (string=? (t-tag t) to))
                                    (hashtable-set! has-to (t-node t) #t)))
                      (db-tag-rows db0))
            (for-each (lambda (id) (hashtable-set! touched? id #t)) touched)
            (let* ((changed (filter (lambda (r1) (not (equal? (hashtable-ref by0 (n-id r1) #f) r1))) rows1))
                   (want-tags (list-sort tag-row<?
                                         (append (filter (lambda (t) (not (and (hashtable-ref touched? (t-node t) #f)
                                                                               (string=? (t-tag t) from))))
                                                         (db-tag-rows db0))
                                                 (if to
                                                     (filter (lambda (t) t)
                                                             (map (lambda (id)
                                                                    (and (not (hashtable-ref has-to id #f))
                                                                         (list asker to id)))
                                                                  touched))
                                                     '())))))
              (append
               (if (equal? (map n-id rows0) (map n-id rows1)) '()
                   (list (format "H1: ~a made or lost a node's row" what)))
               (if (equal? (list-sort bytevector<? (map n-id changed)) touched) '()
                   (list (format "L5, L13: ~a changed ~a nodes' rows; it touches the first ~a of the ~a carriers by id, in any state, and no other"
                                 what (length changed) (length touched) (length carriers))))
               (fold-right
                (lambda (r1 acc)
                  (let ((r0 (hashtable-ref by0 (n-id r1) #f)))
                    (if (and r0 (equal? r1 (rebuilt r0 (n-parent r0) (+ 1 (n-rev r0)) now))) acc
                        (cons (format "L5, H2': ~a left ~a as ~s, not at its next revision, updated now, with nothing else changed"
                                      what (id-text (n-id r1)) r1)
                              acc))))
                '() changed)
               (if (equal? (cadr db0) (cadr db1)) '()
                   (list (format "H3', L5: ~a wrote, changed or removed a snapshot" what)))
               (let ((want (map (lambda (id i) (list asker (+ m0 i) id (let ((r (hashtable-ref by1 id #f))) (and r (n-rev r))) "tags" now))
                                touched (from-to 1 (length touched)))))
                 (if (and (equal? added want) (= (length (caddr db1)) (+ (length (caddr db0)) (length added)))) '()
                     (list (format "H4, G6', L5: ~a touched ~a nodes; it adds a change row tags for each, at its new revision, by id, numbered from ~a, and no other: it added ~a"
                                   what (length touched) (+ m0 1) (length added)))))
               (if (equal? (db-tag-rows db1) want-tags) '()
                   (list (format "L5, L6: ~a left ~a tag rows; the ~a before, less ~s on the touched~a, are ~a"
                                 what (length (db-tag-rows db1)) (length (db-tag-rows db0)) from
                                 (if to (format ", with ~s" to) "") (length want-tags))))
               (if (equal? (db-links db0) (db-links db1)) '()
                   (list (format "Q9: ~a changed links" what)))
               (if (eqv? count (length touched)) '()
                   (list (format "L5: ~a answers ~a ~s; it touched ~a" what word count (length touched))))
               (let ((after (length (filter (lambda (t) (and (bytevector=? (t-owner t) asker) (string=? (t-tag t) from)))
                                            (db-tag-rows db1)))))
                 (if (and (eqv? left after) (= after (- (length carriers) (length touched)))) '()
                     (list (format "L5: ~a answers left ~s; ~a carriers are left, of ~a before less the ~a touched"
                                   what left after (length carriers) (length touched)))))
               (key-breaks e "step" db0 db1)))))))

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
                 (list (format "H1, G6': an accepted ~a of ~a changed another node's row" op name)))
             (let ((l0 (db-links db0)) (l1 (db-links db1)))
               (if (string=? op "purge")
                   (let ((want (filter (lambda (l) (not (or (bytevector=? (l-source l) id) (bytevector=? (l-target l) id))))
                                       l0)))
                     (if (equal? l1 want) '()
                         (list (format "G6', Q8: a purge of ~a left ~a links of the ~a before; it takes every link of the node, both ways, and no other: ~a"
                                       name (length l1) (length l0) (length want)))))
                   (if (equal? l1 l0) '()
                       (list (format "Q9: an accepted ~a of ~a changed links: ~a before, ~a after" op name
                                     (length l0) (length l1))))))
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
             (if (let-values (((added kept?) (changes-added db0 db1))) (and kept? (equal? added (list want-change))))
                 '()
                 (list (format "H4, G6': an accepted ~a adds one change row, (~a ~a ~a ~a ~s ~a); the rows before were ~a, after ~a"
                               op (event-tag e) (+ m0 1) name rev op now
                               (length (caddr db0)) (length changes1))))
             (if r0 (props-change-breaks e op name r0 r1 mine0 mine1 rev) '())
             (tag-write-breaks e op name id db0 db1 mine1 rev)
             (key-breaks e op db0 db1))))))

  ;; status-and-closed : String -> (List String (U Any #f))
  ;; A Task's stored text read by the model: its status, TODO when none is
  ;; stored, and its closed, or #f.
  (define (status-and-closed text)
    (let* ((j (guard (c (#t '())) (json-of text)))
           (s (and (list? j) (assoc "status" j)))
           (c (and (list? j) (assoc "closed" j))))
      (list (if s (cdr s) "TODO") (and c (cdr c)))))

  ;; props-change-breaks : Event String String Row Row (Listof Row) (Listof Row) Natural -> (Listof String)
  ;; An accepted write of a node that was there, R0 before and R1 after,
  ;; its snapshots MINE0 and MINE1, at REV, held to what it may do to
  ;; props. G11': a command changes only props: its snapshot's title, body
  ;; and content type are the newest snapshot's before, the row's title and
  ;; content type are as they were, and its status after is the command's
  ;; (done DONE, wontdo WONTDO, reopen TODO). R13: a replace with no props
  ;; leaves them as they were. R4: a replace leaves a Task's status and
  ;; closed; R14: so does a restore.
  (define (props-change-breaks e op name r0 r1 mine0 mine1 rev)
    (let* ((task? (equal? (n-kind r0) "task"))
           (before (status-and-closed (n-props r0)))
           (after (status-and-closed (n-props r1))))
      (append
       (if (member op task-ops)
           (let ((top0 (fold-left (lambda (best s) (if (or (not best) (> (s-rev s) (s-rev best))) s best)) #f mine0))
                 (added (find (lambda (s) (= (s-rev s) rev)) mine1))
                 (lands (cdr (assoc op '(("done" . "DONE") ("wontdo" . "WONTDO") ("reopen" . "TODO"))))))
             (append
              (if (and top0 added (equal? (s-title added) (s-title top0)) (equal? (s-type added) (s-type top0))
                       (equal? (s-body added) (s-body top0)))
                  '()
                  (list (format "G11', R6: a ~a of ~a wrote a snapshot whose title, body or content type is not its newest's before"
                                op name)))
              (if (and (equal? (n-title r1) (n-title r0)) (equal? (n-type r1) (n-type r0))) '()
                  (list (format "G11': a ~a of ~a changed its title or content type" op name)))
              (if (and task? (equal? (car after) lands)) '()
                  (list (format "G11', P7: a ~a of ~a (a ~a) left its status ~s, not ~s" op name (n-kind r0) (car after) lands)))))
           '())
       (if (and (string=? op "update") (not (content-props (event-content e))) (not (equal? (n-props r1) (n-props r0))))
           (list (format "R13: a replace of ~a with no props changed them from ~s to ~s" name (n-props r0) (n-props r1)))
           '())
       (if (and task? (member op '("update" "restore")) (not (equal? before after)))
           (list (format "~a: a~a of Task ~a moved its status and closed from ~s to ~s"
                         (if (string=? op "update") "R4" "R14") (if (string=? op "update") " replace" " restore")
                         name before after))
           '()))))

  ;; link-breaks : Event Db Db -> (Listof String)
  ;; H1': an accepted link (201) or unlink (204), between the tables
  ;; before and after: no node row changed, no snapshot; exactly the one
  ;; link row made, created now, or removed; one change row, the asker's
  ;; next number, on the source at the source's revision, link or unlink,
  ;; now, and no other; and H5.
  (define (link-breaks e db0 db1)
    (let* ((spec (event-link e)) (source (event-id e)) (type (link-spec-type spec)) (target (link-spec-target spec))
           (now (event-now e)) (asker (account-id-of (event-tag e)))
           (op (if (eq? (event-kind e) 'link) "link" "unlink"))
           (r0 (find-node (car db0) source))
           (l0 (db-links db0)) (l1 (db-links db1))
           (key? (lambda (l) (and (bytevector=? (l-owner l) asker) (bytevector=? (l-source l) source)
                                  (equal? (l-type l) type) (bytevector? target) (bytevector=? (l-target l) target))))
           (m0 (length (filter (lambda (c) (bytevector=? (c-owner c) asker)) (caddr db0))))
           (added (let-values (((added kept?) (changes-added db0 db1))) added)))
      (append
       (if (equal? (car db0) (car db1)) '()
           (list (format "H1', Q4: an accepted ~a changed a node's row" op)))
       (if (equal? (cadr db0) (cadr db1)) '()
           (list (format "H1', Q4: an accepted ~a changed a snapshot" op)))
       (if (equal? (db-tag-rows db0) (db-tag-rows db1)) '()
           (list (format "H1', Q4: an accepted ~a changed tag rows" op)))
       (if (string=? op "link")
           (let ((made (filter (lambda (l) (not (member l l0))) l1)))
             (if (and (equal? made (list (list asker source type target now)))
                      (= (length l1) (+ 1 (length l0))) (for-all (lambda (l) (member l l1)) l0))
                 '()
                 (list (format "H1': an accepted link makes the one row (~a ~a ~s ~a ~a) and no other; it made ~a, of ~a before, ~a after"
                               (event-tag e) (id-text source) type (if (bytevector? target) (id-text target) target) now
                               (length made) (length l0) (length l1)))))
           (let ((gone (filter key? l0)))
             (if (and (= (length gone) 1) (equal? l1 (filter (lambda (l) (not (key? l))) l0))) '()
                 (list (format "H1': an accepted unlink removes the one row it names and no other: ~a such before; ~a rows before, ~a after"
                               (length gone) (length l0) (length l1))))))
       (cond
        ((not r0) (list (format "H1': an accepted ~a's source ~a has no row" op (id-text source))))
        ((and (equal? added (list (list asker (+ m0 1) source (n-rev r0) op now)))
              (= (length (caddr db1)) (+ 1 (length (caddr db0)))))
         '())
        (else
         (list (format "H1', Q5: an accepted ~a adds one change row, (~a ~a ~a ~a ~s ~a): the source's at its revision; it added ~s"
                       op (event-tag e) (+ m0 1) (id-text source) (n-rev r0) op now
                       (map (lambda (c) (list (account-label (c-owner c)) (c-seq c) (id-text (c-node c)) (c-rev c) (c-op c)
                                              (c-created c)))
                            added)))))
       (key-breaks e op db0 db1))))

  ;; kept-breaks : Event Db Db -> (Listof String)
  ;; H4'', Q3, Q16: a PUT of a link that is there (200) changes nothing but
  ;; the asking key's last_used, which may move to now (H5).
  (define (kept-breaks e db0 db1)
    (append
     (fold-right (lambda (name t0 t1 acc)
                   (if (equal? t0 t1) acc (cons (format "H4'', Q3: a 200 PUT of a link that is there changed ~a" name) acc)))
                 '() '("nodes" "revisions" "changes") (list (car db0) (cadr db0) (caddr db0))
                 (list (car db1) (cadr db1) (caddr db1)))
     (if (equal? (db-links db0) (db-links db1)) '()
         (list "H4'', Q3, Q15: a 200 PUT of a link that is there changed links"))
     (if (equal? (db-tag-rows db0) (db-tag-rows db1)) '()
         (list "H4'', Q3: a 200 PUT of a link that is there changed tag rows"))
     (key-breaks e "kept link" db0 db1)))

  ;; unchanged-breaks : Event Natural Db Db -> (Listof String)
  ;; H5, G4, G13, H4'', L10: a refused write, a refused link, a refused
  ;; command and any read change nothing at all, links and tag rows among
  ;; it.
  (define (unchanged-breaks e status db0 db1)
    (let ((what (if (or (write-kind? (event-kind e)) (link-kind? (event-kind e)) (step-kind? (event-kind e)))
                    (format "a refused ~a (~a)" (event-kind e) status)
                    (format "a read (~a)" status))))
      (fold-right (lambda (name t0 t1 acc)
                    (if (equal? t0 t1) acc (cons (format "H5, G13, H4'', L10: ~a changed ~a" what name) acc)))
                  '() '("nodes" "revisions" "changes" "api_keys' last_used" "links" "node_tags") db0 db1)))

  ;; other-breaks : Event Db Db -> (Listof String)
  ;; H6, G7, G7': no request changes a row of the other account's, its
  ;; links among them.
  (define (other-breaks e db0 db1)
    (let* ((other (account-id-of (other-tag (event-tag e))))
           (theirs (lambda (db)
                     (let* ((nodes (filter (lambda (r) (bytevector=? (n-owner r) other)) (car db)))
                            (ids (make-id-table)))
                       (for-each (lambda (r) (hashtable-set! ids (n-id r) #t)) nodes)
                       (list nodes
                             (filter (lambda (s) (hashtable-ref ids (s-node s) #f)) (cadr db))
                             (filter (lambda (c) (bytevector=? (c-owner c) other)) (caddr db))
                             (filter (lambda (k) (bytevector=? (k-account k) other)) (cadddr db))
                             (filter (lambda (l) (bytevector=? (l-owner l) other)) (db-links db))
                             (filter (lambda (t) (bytevector=? (t-owner t) other)) (db-tag-rows db)))))))
      (if (equal? (theirs db0) (theirs db1)) '()
          (list (format "H6, G7, G7', L6: a request by ~a changed the rows of ~a" (event-tag e) (other-tag (event-tag e)))))))

  ;; db-law-breaks : Event Obs Db Db -> (Listof String)
  ;; By the answer the handlers gave: an accepted write's laws; an
  ;; accepted link's or unlink's (H1'); a kept link's (H4''); else nothing
  ;; changed.
  (define (db-law-breaks e o db0 db1)
    (let* ((status (obs-status o))
           (kind (event-kind e))
           (accepted? (and (write-kind? kind) (memv status '(200 201 204)) #t)))
      (append (always-breaks db1)
              (cond (accepted? (accepted-breaks e o db0 db1))
                    ((and (step-kind? kind) (eqv? status 200)) (step-breaks e o db0 db1))
                    ((and (link-kind? kind) (memv status '(201 204))) (link-breaks e db0 db1))
                    ((and (eq? kind 'link) (eqv? status 200)) (kept-breaks e db0 db1))
                    (else (unchanged-breaks e status db0 db1)))
              (other-breaks e db0 db1))))

  ;;; The tables held to the model's world

  (define (model-node-rows w)
    (map (lambda (n)
           (let ((owner (account-id-of (mnode-tag n)))
                 (content (if (live? n)
                              (let ((s (node-top n))) (list (msnap-title s) (msnap-type s) (mprops-text (msnap-props s))))
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
                               (msnap-type s) (mprops-text (msnap-props s)) (msnap-created s) (msnap-body s)
                               (tags-text (msnap-tags s))))
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

  ;; model-tag-rows : World -> (Listof Row)     each live node's tags, by owner, node, tag, as the query orders them
  (define (model-tag-rows w)
    (list-sort tag-row<?
               (apply append
                      (map (lambda (n) (map (lambda (t) (list (account-id-of (mnode-tag n)) t (mnode-id n))) (mnode-tags n)))
                           (world-nodes w)))))

  (define (model-key-rows w)
    (map (lambda (k) (list (mkey-id k) (account-id-of (mkey-tag k)) (mkey-last-used k))) (world-keys w)))

  ;; model-link-rows : World -> (Listof Row)     by owner, source, type, target, as the query orders them
  (define (model-link-rows w)
    (list-sort (lambda (x y)
                 (cond ((not (bytevector=? (l-owner x) (l-owner y))) (bytevector<? (l-owner x) (l-owner y)))
                       ((not (bytevector=? (l-source x) (l-source y))) (bytevector<? (l-source x) (l-source y)))
                       ((not (string=? (l-type x) (l-type y))) (string<? (l-type x) (l-type y)))
                       (else (bytevector<? (l-target x) (l-target y)))))
               (map (lambda (l) (list (account-id-of (mlink-tag l)) (mlink-source l) (mlink-type l) (mlink-target l)
                                      (mlink-created l)))
                    (world-links w))))

  ;; Column labels: which H or G a difference in that column breaks.
  (define node-columns
    '(("id" . "H1") ("owner" . "H6") ("author" . "H16") ("kind" . "H11") ("title" . "H2'")
      ("content_type" . "H2'") ("props" . "H2'") ("revision" . "H1, G3', Q4") ("created" . "H15', G9")
      ("updated" . "H15'', Q4") ("state" . "G3', G12") ("parent" . "P1 to P4, P8, P11, P15, P16")))
  (define snap-columns
    '(("node" . "H3'") ("revision" . "H3'") ("author" . "H16") ("title" . "H3'") ("content_type" . "H3'")
      ("props" . "H3'") ("created" . "H15'") ("body" . "H3'") ("tags" . "L3, L11")))
  (define tag-columns '(("owner" . "L6, L9") ("tag" . "L2, L4, L5") ("node" . "L3, L5, L7, L11")))
  (define change-columns
    '(("owner" . "H4") ("seq" . "H4") ("node" . "H4") ("revision" . "H4") ("op" . "H4, L10") ("created" . "H4")))
  (define key-columns '(("id" . "H5") ("account" . "H5") ("last_used" . "H5")))
  (define link-columns
    '(("owner" . "Q1, G7'") ("source" . "H1', Q5") ("type" . "H1', Q2") ("target" . "H1', Q1") ("created" . "Q15")))

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
     (rows-breaks w "api_keys" (model-key-rows w) (cadddr db) (lambda (r) (list (car r))) key-columns "H5")
     (rows-breaks w "links" (model-link-rows w) (db-links db)
                  (lambda (r) (list (l-owner r) (l-source r) (l-type r) (l-target r))) link-columns "H1'/Q8/Q9")
     (rows-breaks w "node_tags" (model-tag-rows w) (db-tag-rows db) (lambda (r) r) tag-columns "L3/L4/L5/L11")))

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
  ;;                (with the family), linked (with the hub of links), or
  ;;                plain
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

  ;; end-why : World Tag Bytevector -> Symbol
  ;; What ID is to TAG: own (a live node of its), missing (no node's),
  ;; purged (either account's), or other (the other account's live node).
  (define (end-why w tag id)
    (let ((n (world-node w id)))
      (cond ((not n) 'missing) ((not (live? n)) 'purged) ((eq? (mnode-tag n) tag) 'own) (else 'other))))

  ;; link-aims : World Event Expectation Obs -> (Listof Symbol)
  ;; What the links' rules looked at for E, by the model's own reading:
  ;;   lc-<event>-<source>-<target>-<there|absent>
  ;;                          link-command's cell, each end's state (none
  ;;                          for no live node of the account's; any for an
  ;;                          unlink's target, which is not read)
  ;;   link-made, link-kept(-source-trashed, -target-trashed),
  ;;   unlink-removed(-source-trashed, -source-archived, -target-trashed)
  ;;   <event>-404-source-<missing|purged|other>, link-404-target-<why>
  ;;                          (-source-trashed: the 404 before the 409),
  ;;                          unlink-404-absent(-target-<why>)
  ;;   link-409-<source|target|both>-trashed
  ;;   <event>-400-<type|target|self|precondition>
  ;;   link-refused-while-due, link-last-used-set
  ;;   list-links-<out|in>-<typed|untyped>, -<out|in>-pages-followed,
  ;;   list-links-404-<why>, list-links-400-<direction|type|after-other-type>,
  ;;   list-links-after-place, -precondition-ignored, -of-<trashed|archived>,
  ;;   -item-<trashed|archived>, -empty, -limit-1-followed, -limit-100
  ;;   purge-links-<out|in|both>    a purge that took links that way
  ;;   linked-<route>         an accepted write of a node with links
  (define (link-aims w e x o)
    (let* ((kind (event-kind e)) (status (expectation-status x)) (tag (event-tag e))
           (st (lambda (s) (if s (symbol->string s) "none"))))
      (case kind
        ((link unlink)
         (let ((bad (link-bad e)))
           (if bad
               (list (sym kind "-400-" bad))
               (let* ((cell (link-cell w e))
                      (s (car cell)) (t (cadr cell)) (there? (cadddr cell))
                      (target (link-spec-target (event-link e)))
                      (t-why (end-why w tag target))
                      (tn (own-node w tag target)))
                 (append
                  (list (sym "lc-" kind "-" (st s) "-" (if (eq? kind 'link) (st t) "any") "-" (if there? "there" "absent")))
                  (case status
                    ((201) '(link-made))
                    ((200) (cons 'link-kept (append (if (eq? s 'trashed) '(link-kept-source-trashed) '())
                                                    (if (eq? t 'trashed) '(link-kept-target-trashed) '()))))
                    ((204) (cons 'unlink-removed
                                 (append (if (eq? s 'trashed) '(unlink-removed-source-trashed) '())
                                         (if (eq? s 'archived) '(unlink-removed-source-archived) '())
                                         (if (and tn (eq? (mnode-state tn) 'trashed)) '(unlink-removed-target-trashed) '()))))
                    ((404) (list (cond ((not s) (sym kind "-404-source-" (end-why w tag (event-id e))))
                                       ((eq? kind 'link) (sym "link-404-target-" t-why (if (eq? s 'trashed) "-source-trashed" "")))
                                       ((eq? t-why 'own) 'unlink-404-absent)
                                       (else (sym "unlink-404-absent-target-" t-why)))))
                    ((409) (list (sym "link-409-" (cond ((and (eq? s 'trashed) (eq? t 'trashed)) "both")
                                                        ((eq? s 'trashed) "source")
                                                        (else "target"))
                                      "-trashed")))
                    (else '()))
                  (if (and (memv status '(404 409)) (touch-due? (world-key-last-used w (event-key e)) (event-now e)))
                      '(link-refused-while-due)
                      '())
                  (if (expectation-touched x) '(link-last-used-set) '()))))))
        ((list-links)
         (let* ((spec (event-link e))
                (dir (link-direction (link-spec-direction spec)))
                (type (link-type-filter (link-spec-type spec)))
                (own (own-node w tag (event-id e))))
           (case status
             ((400) (list (cond ((eq? dir 'invalid) 'list-links-400-direction)
                                ((eq? type 'invalid) 'list-links-400-type)
                                (else 'list-links-400-after-other-type))))
             ((404) (list (sym "list-links-404-" (end-why w tag (event-id e)))))
             ((200)
              (let* ((items (or (expectation-items x) '()))
                     (pages (obs-requests o))
                     (state-of (lambda (i) (cdr (assoc "state" (cdr (assoc "node" i)))))))
                (append (list (sym "list-links-" dir (if type "-typed" "-untyped")))
                        (if (> pages 1) (list (sym "list-links-" dir "-pages-followed")) '())
                        (if (and (> pages 2) (eqv? (event-limit e) 1)) '(list-links-limit-1-followed) '())
                        (if (eqv? (event-limit e) 100) '(list-links-limit-100) '())
                        (if (null? items) '(list-links-empty) '())
                        (if (link-spec-after spec) '(list-links-after-place) '())
                        (if (pair? (event-headers e)) '(list-links-precondition-ignored) '())
                        (if (and own (memq (mnode-state own) '(trashed archived)))
                            (list (sym "list-links-of-" (mnode-state own)))
                            '())
                        (if (exists (lambda (i) (equal? (state-of i) "trashed")) items) '(list-links-item-trashed) '())
                        (if (exists (lambda (i) (equal? (state-of i) "archived")) items) '(list-links-item-archived) '()))))
             (else '()))))
        (else
         (let ((linked? (and (event-id e) (pair? (links-at w (event-id e))))))
           (cond
            ((not (and linked? (write-kind? kind) (memv status '(200 201 204)))) '())
            ((eq? kind 'purge)
             (let* ((id (event-id e))
                    (outs (exists (lambda (l) (bytevector=? (mlink-source l) id)) (world-links w)))
                    (ins (exists (lambda (l) (bytevector=? (mlink-target l) id)) (world-links w))))
               (list (cond ((and outs ins) 'purge-links-both) (outs 'purge-links-out) (else 'purge-links-in)))))
            (else (list (sym "linked-" (route-name e))))))))))

  ;;; A file from before this slice: Tasks stored {} (slice 6, P9)

  ;; seed-world : Rng Natural -> World
  ;; A plain seed's start: one to three Tasks, either account's, as a file
  ;; written before this slice holds them, every props {}: each made before
  ;; T0 at the top level, at revision 1 (a create); or 2 (and an update,
  ;; another snapshot); or 3 (and then an archive or a trash, no snapshot).
  (define (seed-world rng t0)
    (let loop ((w model-start) (i 1) (k (+ 1 (rng-below! rng 3))))
      (if (> i k)
          w
          (let* ((tag (rng-pick! rng '(a b)))
                 (id (fresh-node-id rng w))
                 (c0 (- t0 (* 100000 (- 4 i))))
                 (title (rng-pick! rng title-pool))
                 (body (rng-pick! rng body-pool))
                 (type (rng-pick! rng type-pool))
                 (title2 (rng-pick! rng title-pool))
                 (body2 (rng-pick! rng body-pool))
                 (r (rng-below! rng 3))
                 (change (rng-pick! rng '(archive trash)))
                 (n1 (make-mnode id tag (string-append "s" (number->string i)) "task" c0 'active 1 c0
                                 (list (make-msnap 1 title body type (empty-props "task") c0 tag '())) #f '()))
                 (w1 (world-with-seeded (world-with-change (world-with-node w n1) tag id 1 "create" c0) id))
                 (n2 (and (>= r 1) (with-snap n1 title2 body2 type (empty-props "task") '() (+ c0 10))))
                 (w2 (if n2 (world-with-change (world-with-node w1 n2) tag id 2 "update" (+ c0 10)) w1))
                 (n3 (and (= r 2) (with-state n2 (if (eq? change 'archive) 'archived 'trashed) (+ c0 20))))
                 (w3 (if n3 (world-with-change (world-with-node w2 n3) tag id 3 (symbol->string change) (+ c0 20)) w2)))
            (loop w3 (+ i 1) k)))))

  ;; seed-rows! : Store World -> Void
  ;; W's rows written straight into the tables, as no route writes them:
  ;; each node's (it has no parent), each snapshot's with its tags' text,
  ;; each change row, each tag's row.
  (define (seed-rows! store w)
    (run-write store
               (lambda (tx)
                 (for-each (lambda (r)
                             (tx-execute! tx (string-append "INSERT INTO nodes (id, owner, author, kind, title, content_type,"
                                                            " props, revision, created, updated, state)"
                                                            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
                                          (n-id r) (n-owner r) (n-author r) (n-kind r) (n-title r) (n-type r) (n-props r)
                                          (n-rev r) (n-created r) (n-updated r) (n-state r)))
                           (model-node-rows w))
                 (for-each (lambda (s)
                             (tx-execute! tx (string-append "INSERT INTO revisions (node, revision, author, title, content_type,"
                                                            " props, created, body, tags) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
                                          (s-node s) (s-rev s) (s-author s) (s-title s) (s-type s) (s-props s) (s-created s)
                                          (s-body s) (s-tags s)))
                           (model-snap-rows w))
                 (for-each (lambda (t)
                             (tx-execute! tx "INSERT INTO node_tags (owner, tag, node) VALUES (?, ?, ?)" (t-owner t) (t-tag t) (t-node t)))
                           (model-tag-rows w))
                 (for-each (lambda (c)
                             (tx-execute! tx "INSERT INTO changes (owner, seq, node, revision, op, created) VALUES (?, ?, ?, ?, ?, ?)"
                                          (c-owner c) (c-seq c) (c-node c) (c-rev c) (c-op c) (c-created c)))
                           (model-change-rows w)))))

  ;;; What slice 6's rules looked at

  ;; shown-empty-task? : Alist -> Boolean     an answer's node or snapshot item showing a Task stored {}: TODO, nothing else
  (define (shown-empty-task? item)
    (let ((p (assoc "props" item)))
      (and p (equal? (cdr p) '(("status" . "TODO"))))))

  ;; props-aims : World Event Expectation -> (Listof Symbol)
  ;; What the props' rules, the task table and P9 looked at for E, by the
  ;; model's own reading:
  ;;   props-400-before-<kind|unnamed>, props-413-<create|replace-named|replace-unnamed>
  ;;                          a PUT's props refused before the job, by the kind named
  ;;   create-task-todo-closed-400   P14's 400
  ;;   props-400-job-<kind>   a replace that named no kind, refused in the job by the stored kind
  ;;   status-fixed-<status|closed>, status-fixed-closed-while-todo
  ;;   props-create-<kind>, create-task-<DONE|WONTDO>-closed-<given|now>
  ;;   props-replace-<kind>, replace-no-props-<kind>, replace-no-props-kept,
  ;;   replace-task-claims-own   a Task's status or closed sent back as stored
  ;;   entry-<name>-<status>  each corpus entry by what it was answered
  ;;   restore-task-status-differs, restore-task-closed-differs   P10
  ;;   task-404-<why>, task-412(-would-be-wrong-status, -trashed, -not-a-task),
  ;;   task-409-wrong-state-<task|other-kind>, task-409-not-a-task-<kind>,
  ;;   task-cell-<state>-<status>-<command>   the nine cells, active and archived
  ;;   seeded-<command>, seeded-reopen-wrong-status, seeded-<replace|restore>,
  ;;   seeded-read-<node|list|revisions|snapshot>   on a seeded Task still {}
  ;;   empty-task-<command>, empty-task-read-<node|list|link-item|revisions|snapshot>
  ;;                          the same on any Task stored {}
  (define (props-aims w e x)
    (let* ((kind (event-kind e)) (status (expectation-status x)) (code (expectation-code x))
           (tag (event-tag e)) (id (event-id e))
           (own (and id (own-node w tag id)))
           (fresh-seed? (and own (seeded? w id) (empty-task? w own)))
           (pre-ok? (not (memq (event-pre e) '(missing invalid)))))
      (case kind
        ((put)
         (if (not pre-ok?)
             '()
             (let* ((c (event-content e)) (create? (eq? (event-pre e) 'create))
                    (entry (content-props c)) (named (content-kind c))
                    (r (props-refusal e))
                    (v (and entry own (entry-verdict entry (mnode-kind own)))))
               (append
                (if entry (list (sym "entry-" (entry-name entry) "-" (number->string status))) '())
                (cond
                 (r (cond ((and create? (= (car r) 400) (claim? (entry-verdict (or entry empty-entry) named))
                                (taken? (entry-verdict (or entry empty-entry) named)))
                           '(create-task-todo-closed-400))
                          ((= (car r) 400) (list (sym "props-400-before-" (or named "unnamed"))))
                          (create? '(props-413-create))
                          (named '(props-413-replace-named))
                          (else '(props-413-replace-unnamed))))
                 ((and (eqv? status 400) own (= (expectation-jobs x) 1)) (list (sym "props-400-job-" (mnode-kind own))))
                 ((equal? code "status_fixed")
                  (let ((p (msnap-props (node-top own))))
                    (cons (sym "status-fixed-" (claim-differs? v p))
                          (if (and (claim-closed v) (string=? (mprops-status p) "TODO")) '(status-fixed-closed-while-todo) '()))))
                 ((eqv? status 201)
                  (let ((cv (entry-verdict (or entry empty-entry) named)))
                    (cons (sym "props-create-" named)
                          (if (and (claim? cv) (member (claim-status cv) '("DONE" "WONTDO")))
                              (list (sym "create-task-" (claim-status cv) "-closed-" (if (claim-closed cv) "given" "now")))
                              '()))))
                 ((and (eqv? status 200) own)
                  (append
                   (if entry
                       (list (sym "props-replace-" (mnode-kind own)))
                       (cons (sym "replace-no-props-" (mnode-kind own))
                             (if (string=? (mprops-text (msnap-props (node-top own))) "{}") '() '(replace-no-props-kept))))
                   (if (and (claim? v) (or (claim-status v) (claim-closed v))) '(replace-task-claims-own) '())
                   (if fresh-seed? '(seeded-replace) '())))
                 (else '()))))))
        ((restore)
         (if (and (eqv? status 200) own (string=? (mnode-kind own) "task"))
             (let ((p (msnap-props (node-top own))) (sp (msnap-props (snap-of own (event-snap e)))))
               (append (if (equal? (mprops-status p) (mprops-status sp)) '() '(restore-task-status-differs))
                       (if (equal? (mprops-closed p) (mprops-closed sp)) '() '(restore-task-closed-differs))
                       (if fresh-seed? '(seeded-restore) '())))
             '()))
        ((done wontdo reopen)
         (if (not pre-ok?)
             '()
             (let* ((cell (task-cell w e))
                    (found (list-ref cell 1)) (state (list-ref cell 2)) (nk (list-ref cell 3)) (st (list-ref cell 4))
                    (move (assq kind task-moves)))
               (append
                (case status
                  ((404) (list (sym "task-404-" (end-why w tag id))))
                  ((412) (cons 'task-412
                               (cond ((eq? state 'trashed) '(task-412-trashed))
                                     ((not (equal? nk "task")) '(task-412-not-a-task))
                                     ((not (member st (cadr move))) '(task-412-would-be-wrong-status))
                                     (else '()))))
                  ((409) (cond ((equal? code "wrong_state")
                                (list (if (equal? nk "task") 'task-409-wrong-state-task 'task-409-wrong-state-other-kind)))
                               ((equal? code "not_a_task") (list (sym "task-409-not-a-task-" nk)))
                               (else (list (sym "task-cell-" state "-" st "-" kind)))))
                  ((200) (list (sym "task-cell-" state "-" st "-" kind)))
                  (else '()))
                (if (and fresh-seed? (eq? found 'match))
                    (case status
                      ((200) (list (sym "seeded-" kind)))
                      ((409) (if (equal? code "wrong_status") (list (sym "seeded-" kind "-wrong-status")) '()))
                      (else '()))
                    '())
                (if (and own (empty-task? w own) (eqv? status 200)) (list (sym "empty-task-" kind)) '())))))
        ((get-node)
         (if (and (eqv? status 200) own (empty-task? w own))
             (cons 'empty-task-read-node (if fresh-seed? '(seeded-read-node) '()))
             '()))
        ((list-nodes list-links)
         (let* ((items (or (and (eqv? status 200) (expectation-items x)) '()))
                (nodes (if (eq? kind 'list-links) (map (lambda (i) (cdr (assoc "node" i))) items) items))
                (empty (filter shown-empty-task? nodes)))
           (if (null? empty)
               '()
               (cons (if (eq? kind 'list-links) 'empty-task-read-link-item 'empty-task-read-list)
                     (if (and (eq? kind 'list-nodes)
                              (exists (lambda (i) (exists (lambda (s) (equal? (cdr (assoc "id" i)) (id-text s)))
                                                          (world-seeded w)))
                                      empty))
                         '(seeded-read-list)
                         '())))))
        ((list-revisions)
         (if (and (eqv? status 200) own (string=? (mnode-kind own) "task")
                  (exists shown-empty-task? (expectation-items x)))
             (cons 'empty-task-read-revisions (if (seeded? w id) '(seeded-read-revisions) '()))
             '()))
        ((get-snapshot)
         (if (and (eqv? status 200) own (string=? (mnode-kind own) "task") (shown-empty-task? (expectation-json x)))
             (cons 'empty-task-read-snapshot (if (seeded? w id) '(seeded-read-snapshot) '()))
             '()))
        (else '()))))

  ;;; What slice 7a's rules looked at

  ;; tag-aims : World Event Expectation Obs -> (Listof Symbol)
  ;; What the tags' rules looked at for E, by the model's own reading:
  ;;   tags-400-<create|replace>, tags-400-with-props-413   a PUT refused for its tags, no write job
  ;;   tags-stored-<none|some|fifty>, tags-folded-to-one    a PUT's tags as stored
  ;;   tags-kept, tags-kept-with-props   L4: a replace with no tags of a node that carries some
  ;;   tags-cleared, tags-replaced
  ;;   restore-tags-changed, restore-tags-cleared, restore-before-migration-7, restore-brings-back
  ;;   task-command-tagged, purge-tagged, move-tagged, state-change-tagged
  ;;   tag-filter-200-<n>, tag-filter-found, tag-filter-empty-page, tag-filter-400,
  ;;   tag-filter-404-parent, tag-filter-with-<state|parent|after>, tag-filter-pages-followed
  ;;   list-tags-200, list-tags-400, list-tags-pages-or-counted (pages followed, or its first tag
  ;;   counted by the filter), list-tags-count-capped, list-tags-empty
  ;;   step-<rename|remove>-<none|some|cap>, step-left-above-0, step-merge, step-touched-<archived|trashed>,
  ;;   step-theirs-only, step-<rename|remove>-<400|413|415|invalid-json>
  ;;   entry-tag-<name>   a corpus entry stored by a PUT
  (define (tag-aims w e x o)
    (let* ((kind (event-kind e)) (status (expectation-status x)) (tag (event-tag e))
           (id (event-id e)) (own (and id (own-node w tag id))))
      (case kind
        ((put)
         (if (memq (event-pre e) '(missing invalid))
             '()
             (let* ((c (event-content e)) (create? (eq? (event-pre e) 'create))
                    (ts (sent-tags (content-tags c) create?))
                    (p (props-refusal e)))
               (cond
                ((and (eqv? status 400) (= (expectation-jobs x) 0) (eq? ts 'invalid) (not (and p (= (car p) 400))))
                 (cons (if create? 'tags-400-create 'tags-400-replace) (if p '(tags-400-with-props-413) '())))
                ((memv status '(200 201))
                 (append
                  (cond ((eq? ts 'absent)
                         (if (and own (pair? (mnode-tags own)))
                             (cons 'tags-kept (if (content-props c) '(tags-kept-with-props) '()))
                             '()))
                        ((null? ts) (if (and own (pair? (mnode-tags own))) '(tags-cleared) '(tags-stored-none)))
                        ((= (length ts) tag-most) '(tags-stored-fifty))
                        (else (cons 'tags-stored-some (if (and own (not (equal? ts (mnode-tags own)))) '(tags-replaced) '()))))
                  (let ((es (let ((t (content-tags c))) (if (and (pair? t) (eq? (car t) 'entries)) (cadr t) '()))))
                    (append (if (and (pair? es) (pair? ts) (< (length ts) (length es))) '(tags-folded-to-one) '())
                            (map (lambda (en) (sym "entry-tag-" (tag-entry-name en))) es)))))
                (else '())))))
        ((restore)
         (if (and (eqv? status 200) own)
             (let ((snap (snap-of own (event-snap e))))
               (append (if (equal? (msnap-tags snap) (mnode-tags own)) '() '(restore-tags-changed))
                       (if (and (null? (msnap-tags snap)) (pair? (mnode-tags own))) '(restore-tags-cleared) '())
                       (if (and (seeded? w id) (pair? (mnode-tags own)) (<= (event-snap e) 2)) '(restore-before-migration-7) '())
                       (if (not (equal? (mnode-tags own) (msnap-tags (node-top own)))) '(restore-after-a-step) '())
                       (if (exists (lambda (t) (not (member t (mnode-tags own)))) (msnap-tags snap)) '(restore-brings-back) '())))
             '()))
        ((done wontdo reopen) (if (and (eqv? status 200) own (pair? (mnode-tags own))) '(task-command-tagged) '()))
        ((purge) (if (and (eqv? status 204) own (pair? (mnode-tags own))) '(purge-tagged) '()))
        ((move) (if (and (eqv? status 200) own (pair? (mnode-tags own))) '(move-tagged) '()))
        ((archive unarchive trash untrash) (if (and (eqv? status 200) own (pair? (mnode-tags own))) '(state-change-tagged) '()))
        ((list-nodes)
         (let ((f (event-tagq e)))
           (if (not f)
               '()
               (case status
                 ((400) '(tag-filter-400))
                 ((404) '(tag-filter-404-parent))
                 ((200)
                  (let ((items (or (expectation-items x) '())) (n (length (filter-spec-values f))))
                    (append (list (sym "tag-filter-200-" (number->string n))
                                  (if (null? items) 'tag-filter-empty-page 'tag-filter-found))
                            (if (event-query e) '(tag-filter-with-state) '())
                            (if (eq? (event-parent e) 'absent) '() '(tag-filter-with-parent))
                            (if (filter-spec-after f) '(tag-filter-with-after) '())
                            (if (> (obs-requests o) 1) '(tag-filter-pages-followed) '())
                            (if (exists (lambda (q) (and (pair? q) (eq? (car q) 'entry) (eq? (caddr q) 'plus)
                                                         (exists (lambda (c) (char=? c #\space)) (string->list (tag-entry-sent (cadr q))))))
                                        (filter-spec-values f))
                                '(tag-filter-plus-spaces)
                                '())
                            (filter-map-raw (filter-spec-values f)))))
                 (else '())))))
        ((list-tags)
         (case status
           ((400) '(list-tags-400))
           ((200) (let ((items (or (expectation-items x) '())))
                    (append '(list-tags-200)
                            (if (null? items) '(list-tags-empty) '())
                            (if (> (obs-requests o) 1) '(list-tags-pages-or-counted) '())
                            (if (exists (lambda (i) (= (cdr (assoc "count" i)) count-most)) items) '(list-tags-count-capped) '()))))
           (else '())))
        ((rename-tag remove-tag)
         (let ((r (if (eq? kind 'rename-tag) "rename" "remove")))
           (case status
             ((200)
              (let-values (((v clause) (command-verdict e)))
                (let* ((from (cadr v)) (to (and (eq? (car v) 'rename) (caddr v)))
                       (carriers (carriers-of w tag from))
                       (touched (take* carriers step-most)))
                  (append
                   (list (sym "step-" r "-" (cond ((null? carriers) "none") ((> (length carriers) step-most) "cap") (else "some"))))
                   (if (> (length carriers) step-most) '(step-left-above-0) '())
                   (if (and to (exists (lambda (n) (member to (mnode-tags n))) touched)) '(step-merge) '())
                   (if (exists (lambda (n) (eq? (mnode-state n) 'archived)) touched) '(step-touched-archived) '())
                   (if (exists (lambda (n) (eq? (mnode-state n) 'trashed)) touched) '(step-touched-trashed) '())
                   (if (and (null? carriers) (pair? (carriers-of w (other-tag tag) from))) '(step-theirs-only) '())))))
             ((400) (list (sym "step-" r (if (equal? (expectation-code x) "invalid_json") "-invalid-json" "-400"))))
             ((413) (list (sym "step-" r "-413")))
             ((415) (list (sym "step-" r "-415")))
             (else '()))))
        (else '()))))

  ;; filter-map-raw : (Listof QueryTag) -> (Listof Symbol)     tag-filter-<name> for each raw value
  (define (filter-map-raw qs)
    (map (lambda (q) (sym "tag-filter-" (caddr q))) (filter (lambda (q) (and (pair? q) (eq? (car q) 'raw))) qs)))

  (define (reset! store)
    (run-write store
               (lambda (tx)
                 (tx-execute! tx "DELETE FROM node_tags")
                 (tx-execute! tx "DELETE FROM links")
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
  ;; A link's request is counted by link-aims instead.
  (define (purged-aim w e)
    (let ((n (and (event-id e) (not (event-link e)) (world-node w (event-id e)))))
      (and n (not (live? n))
           (not (memq (event-pre e) '(missing invalid)))
           (sym "purged-" (route-name e) "-" (if (eq? (mnode-tag n) (event-tag e)) "own" "other")))))

  ;; run-sequence : Store Twist Natural Boolean -> Verdict
  ;; The sequence SEED makes, on STORE, emptied first: a fresh app on it
  ;; (wrap-server around make-app, its wall clock set by the sequence), 88
  ;; to 127 generated requests, after the family on a family seed; or, on a
  ;; deep seed, the chain, the script and 14 to 27. TWIST is as-planned, or
  ;; a changed rule. TRACE? prints each request and its answer as it goes.
  (define (run-sequence store twist seed trace?)
    (let* ((rng (make-rng seed))
           (style (cond ((deep-seed? seed) 'deep) ((family-seed? seed) 'family) ((linked-seed? seed) 'linked)
                        ((crowd-seed? seed) 'crowd) (else 'plain)))
           (n (if (memq style '(deep crowd)) (+ 14 (rng-below! rng 14)) (+ 97 (rng-below! rng 44))))
           (t0 (+ 1795515226123 (rng-below! rng 100000)))
           (deep-tag (rng-pick! rng '(a b)))
           (total (+ n (case style
                         ((deep) (+ chain-steps script-steps)) ((family) family-steps) ((linked) linked-steps)
                         ((crowd) crowd-steps) (else 0))))
           (bodies (make-hashtable string-hash string=?))
           (now-cell (vector t0))
           (clock (step-clock 0 1))
           (jobs (vector 0))
           (writer (let ((write (store-writer store)))
                     (lambda (job) (vector-set! jobs 0 (+ 1 (vector-ref jobs 0))) (write job))))
           (h (wrap-server (make-app (store-reader store) writer
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
              ((and (eq? style 'linked) (<= i linked-steps))
               (or (linked-event rng w now deep-tag i) (next-event rng w now)))
              ((and (eq? style 'crowd) (<= i crowd-steps))
               (or (crowd-event rng w now deep-tag i) (next-event rng w now)))
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

      (define (report w e i desc x o breaks)
        (string-append
         (format "seed ~a, step ~a: the sequence so far:\n" seed i)
         (apply string-append (map (lambda (l) (string-append "    " l "\n")) (reverse log)))
         (format "  this step: ~a\n" desc)
         (if x
             (format "  the model expects: ~a ~s, ETag ~s, stepping ~a~a~a\n"
                     (expectation-status x) (expectation-code x) (expectation-etag x)
                     (cond ((and (link-kind? (event-kind e)) (not (link-bad e)))
                            (string-append "link-command's " (link-cell-text (link-cell w e))))
                           ((task-kind? (event-kind e)) (string-append "the task table's " (task-cell-text (job-task-cell w e))))
                           (else (cells-text (expectation-cells x))))
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
              (report w e i desc x #f (list "the model cannot take this step"))
              (begin
                (vector-set! now-cell 0 (event-now e))
                (let* ((jobs0 (vector-ref jobs 0))
                       (seen (attempt (lambda () (observe h e))))
                       (made (- (vector-ref jobs 0) jobs0)))
                  (if (eq? (car seen) 'raised)
                      (report w e i desc x #f (list (string-append "the request raised: " (cadr seen))))
                      (let* ((o (cadr seen))
                             (w1 (expectation-world x))
                             (db (attempt (lambda () (db-now store))))
                             (breaks
                              (append (if (= made (expectation-jobs x)) '()
                                          (list (format "R15: the request made ~a write jobs; the model has ~a (none for a refusal before the job, the props' among them)"
                                                        made (expectation-jobs x))))
                                      (guarded "comparing the answer" (lambda () (answer-breaks x o)))
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
                        (for-each (lambda (a) (count! aims a)) (link-aims w e x o))
                        (for-each (lambda (a) (count! aims a)) (props-aims w e x))
                        (for-each (lambda (a) (count! aims a)) (tag-aims w e x o))
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
                                             (cond ((and (link-kind? (event-kind e)) (not (link-bad e)))
                                                    (link-cell-text (link-cell w e)))
                                                   ((task-kind? (event-kind e)) (task-cell-text (job-task-cell w e)))
                                                   (else (cells-text (expectation-cells x))))))))
                        (if (null? breaks)
                            (cons w1 (cadr db))
                            (report w e i desc x o breaks)))))))))

      (reset! store)
      (let* ((w0 (case style ((plain) (seed-world rng t0)) ((crowd) (crowd-world rng t0 seed deep-tag)) (else model-start)))
             (seeding (attempt (lambda () (seed-rows! store w0))))
             (db (attempt (lambda () (db-now store)))))
        (cond
         ((eq? (car seeding) 'raised) (verdict 0 (string-append "seeding the file raised: " (cadr seeding))))
         ((eq? (car db) 'raised) (verdict 0 (string-append "reading the database raised: " (cadr db))))
         ((pair? (append (model-breaks w0 (cadr db)) (always-breaks (cadr db))))
          (verdict 0 (join (cons (format "seed ~a: the emptied (or seeded) file is not the model's start:" seed)
                                 (append (model-breaks w0 (cadr db)) (always-breaks (cadr db))))
                           "\n  - ")))
         (else
          (let loop ((w w0) (db0 (cadr db)) (now t0) (i 1))
            (if (> i total)
                (verdict total #f)
                (let* ((e (event-at w now i))
                       (r (step! w i e db0)))
                  (if (string? r)
                      (verdict i r)
                      (loop (car r) (cdr r) (event-now e) (+ i 1)))))))))))

  ;;; The corpus, checked once against the server (slice 6)

  ;; corpus-breaks : Store -> (Listof String)
  ;; Every entry of the corpus through the real handlers, on STORE emptied
  ;; first, so that a wrong entry is a named failure rather than a mystery
  ;; mid-run. For each entry and each kind: a create of that kind with those
  ;; props, answered as the entry says (a 201 storing the entry's text, a
  ;; Task's made from its claim at the write's time, its answer showing it;
  ;; or the 400 or the 413 with no write job). Then a node of each kind made
  ;; with none (as {}), and each entry sent by a replace that names no
  ;; kind: when no kind takes it, the 400 (or the 413) with no write job;
  ;; when the node's kind refuses it, the 400 in the job; a Task's claim of
  ;; a status but TODO, or of any closed, 409 status_fixed in the job; else
  ;; a 200 storing its text. Each failure names the entry, the kind and the
  ;; route, the corpus's answer and the server's.
  (define (corpus-breaks store)
    (reset! store)
    (let* ((now-cell (vector 1795515300000))
           (clock (step-clock 0 1))
           (jobs (vector 0))
           (writer (let ((write (store-writer store)))
                     (lambda (job) (vector-set! jobs 0 (+ 1 (vector-ref jobs 0))) (write job))))
           (h (wrap-server (make-app (store-reader store) writer (lambda () (vector-ref now-cell 0)) (byte-sequence) clock)
                           (lambda (line) #f) 10000 clock))
           (auth (bearer (key-secret-of (make-bytevector 16 1))))
           (counter (vector 0))
           (stored (lambda (id)
                     (run-read store (lambda (tx) (let ((rows (tx-query tx "SELECT props FROM nodes WHERE id = ?" id)))
                                                    (and (pair? rows) (vector-ref (car rows) 0))))))))
      (define (next-id!) (vector-set! counter 0 (+ 1 (vector-ref counter 0))) (node-id-of (+ 1000 (vector-ref counter 0))))
      (define (tick!) (vector-set! now-cell 0 (+ 1 (vector-ref now-cell 0))) (vector-ref now-cell 0))
      ;; put! : Bytevector (U Natural 'create) Content -> (values Answer Natural Natural)     the answer, the write jobs, now
      (define (put! id pre c)
        (let* ((now (tick!)) (j0 (vector-ref jobs 0))
               (a (exchange h 'PUT (string-append "/v1/nodes/" (id-text id))
                            (list auth (cons "Content-Type" "application/json")
                                  (if (eq? pre 'create) (cons "If-None-Match" "*") (cons "If-Match" (etag-of pre))))
                            (content->text c))))
          (values a (- (vector-ref jobs 0) j0) now)))
      ;; judged : String String Answer Natural Natural (U String #f) Bytevector (U Any #f) -> (Listof String)
      ;; WHAT's answer A, with JOBS write jobs, against the corpus's STATUS,
      ;; CODE, WANT-JOBS and, for a 2xx, the TEXT stored at ID and SHOWN.
      (define (judged what a jobs status code want-jobs text id shown)
        (let ((got-code (problem-code a)))
          (append
           (if (and (= (answer-status a) status) (equal? got-code code)) '()
               (list (format "~a: the corpus has ~a ~a, the server answered ~a ~a" what status (or code "")
                             (answer-status a) (or got-code ""))))
           (if (= jobs want-jobs) '()
               (list (format "~a: the corpus has ~a write jobs, the server made ~a (R15)" what want-jobs jobs)))
           (if (and text (= (answer-status a) status))
               (append
                (let ((s (stored id)))
                  (if (equal? s text) '()
                      (list (format "~a: the corpus has the text ~s stored, the server stored ~s" what text s))))
                (let* ((j (answer-json a)) (p (and (list? j) (assoc "props" j))))
                  (if (and p (equal? (sorted-json (cdr p)) shown)) '()
                      (list (format "~a: the corpus shows ~s, the server answered ~s" what shown
                                    (and (list? j) (assoc "props" j)))))))
               '()))))
      (let* ((creates
              (apply append
                     (map (lambda (e)
                            (apply append
                                   (map (lambda (k)
                                          (let*-values (((id) (next-id!))
                                                        ((a jobs now) (put! id 'create (make-content k "corpus" "" "text/plain" e 'absent)))
                                                        ((v) (entry-verdict e k))
                                                        ((what) (format "corpus: ~a, a create of a ~a" (entry-name e) k)))
                                            (if (create-refused? e k)
                                                (judged what a jobs (if (eq? v 'too-large) 413 400)
                                                        (if (eq? v 'too-large) "props_too_large" "invalid_request") 0 #f id #f)
                                                (let ((p (create-props k e now)))
                                                  (judged what a jobs 201 #f 1 (mprops-text p) id (props-shown k p))))))
                                        kinds)))
                          props-corpus)))
             (bases (map (lambda (k)
                           (let ((id (next-id!)))
                             (let-values (((a jobs now) (put! id 'create (make-content k "base" "" "text/plain" #f 'absent))))
                               (vector k id (if (= (answer-status a) 201) 1 #f)))))
                         kinds))
             (replaces
              (apply append
                     (map (lambda (e)
                            (apply append
                                   (map (lambda (b)
                                          (let ((k (vector-ref b 0)) (id (vector-ref b 1)) (rev (vector-ref b 2)))
                                            (if (not rev)
                                                (list (format "corpus: the base ~a was not made" k))
                                                (let*-values (((a jobs now) (put! id rev (make-content #f "corpus" "" "text/plain" e 'absent)))
                                                              ((vs) (map (lambda (j) (entry-verdict e j)) kinds))
                                                              ((v) (entry-verdict e k))
                                                              ((what) (format "corpus: ~a, a replace naming no kind of a ~a" (entry-name e) k)))
                                                  (when (= (answer-status a) 200) (vector-set! b 2 (+ rev 1)))
                                                  (cond
                                                   ((not (exists taken? vs))
                                                    (let ((large? (memq 'too-large vs)))
                                                      (judged what a jobs (if large? 413 400) (if large? "props_too_large" "invalid_request")
                                                              0 #f id #f)))
                                                   ((not (taken? v)) (judged what a jobs 400 "invalid_request" 1 #f id #f))
                                                   ((and (claim? v) (or (member (claim-status v) '("DONE" "WONTDO")) (claim-closed v)))
                                                    (judged what a jobs 409 "status_fixed" 1 #f id #f))
                                                   (else
                                                    (let ((p (if (claim? v)
                                                                 (task-props "TODO" #f (claim-deadline v) (claim-scheduled v))
                                                                 (plain-props v))))
                                                      (judged what a jobs 200 #f 1 (mprops-text p) id (props-shown k p)))))))))
                                        bases)))
                          props-corpus))))
        (append creates replaces))))

  ;;; The tags corpus, checked once against the server (slice 7a)

  ;; tag-corpus-breaks : Store -> (Listof String)
  ;; Every entry of the tags corpus through the real handlers, on STORE
  ;; emptied first, so that a wrong entry is a named failure rather than a
  ;; mystery mid-run. For each entry, a create of a Note whose tags are the
  ;; entry alone: 201 with its stored form as the answer's tags, its one
  ;; row in node_tags and its snapshot's tags' text, written as the model
  ;; writes it; or the 400 with no write job. Then each entry as a list's
  ;; ?tag=, a space as %20 and, where it has one, as +; and each raw query
  ;; case, and the field with no =: 200 with exactly the Notes made with
  ;; that stored form, by id, each showing it; or the 400.
  (define (tag-corpus-breaks store)
    (reset! store)
    (let* ((now-cell (vector 1795515400000))
           (clock (step-clock 0 1))
           (jobs (vector 0))
           (writer (let ((write (store-writer store)))
                     (lambda (job) (vector-set! jobs 0 (+ 1 (vector-ref jobs 0))) (write job))))
           (h (wrap-server (make-app (store-reader store) writer (lambda () (vector-ref now-cell 0)) (byte-sequence) clock)
                           (lambda (line) #f) 10000 clock))
           (auth (bearer (key-secret-of (make-bytevector 16 1))))
           (owner (account-id-of 'a))
           (rows-of (lambda (id)
                      (run-read store
                                (lambda (tx)
                                  (list (map (lambda (r) (vector-ref r 0))
                                             (tx-query tx "SELECT tag FROM node_tags WHERE owner = ? AND node = ? ORDER BY tag" owner id))
                                        (map (lambda (r) (vector-ref r 0))
                                             (tx-query tx "SELECT tags FROM revisions WHERE node = ?" id))))))))
      (let loop ((es tag-corpus) (k 1) (made '()) (acc '()))
        (if (pair? es)
            (let* ((e (car es)) (id (node-id-of (+ 3000 k)))
                   (what (format "tag corpus: ~a ~s, a create's tags" (tag-entry-name e) (tag-entry-sent e)))
                   (tick (vector-set! now-cell 0 (+ 1 (vector-ref now-cell 0))))
                   (j0 (vector-ref jobs 0))
                   (a (exchange h 'PUT (string-append "/v1/nodes/" (id-text id))
                                (list auth (cons "Content-Type" "application/json") (cons "If-None-Match" "*"))
                                (content->text (make-tagged-content "note" "corpus" "" "text/plain" #f 'absent
                                                                    (list 'entries (list e))))))
                   (made-jobs (- (vector-ref jobs 0) j0))
                   (s (tag-entry-stored e))
                   (breaks
                    (if (string? s)
                        (let ((got (and (list? (answer-json a)) (assoc "tags" (answer-json a))))
                              (stored (rows-of id)))
                          (append
                           (if (= (answer-status a) 201) '()
                               (list (format "~a: the corpus has 201 storing ~s, the server answered ~a ~a" what s (answer-status a)
                                             (problem-code a))))
                           (if (and got (equal? (cdr got) (vector s))) '()
                               (list (format "~a: the corpus shows ~s, the server answered ~s" what (vector s) (and got (cdr got)))))
                           (if (equal? stored (list (list s) (list (tags-text (list s))))) '()
                               (list (format "~a: the corpus has the row ~s and the snapshot's ~s, the server stored ~s" what s
                                             (tags-text (list s)) stored)))))
                        (append
                         (if (and (= (answer-status a) 400) (equal? (problem-code a) "invalid_request")) '()
                             (list (format "~a: the corpus has 400, the server answered ~a ~a" what (answer-status a) (problem-code a))))
                         (if (= made-jobs 0) '()
                             (list (format "~a: a tag refused made ~a write jobs (L10)" what made-jobs)))))))
              (loop (cdr es) (+ k 1) (if (string? s) (cons (cons s id) made) made) (append acc breaks)))
            (let* ((ids-of (lambda (s) (list-sort bytevector<? (map cdr (filter (lambda (p) (string=? (car p) s)) made)))))
                   (filtered
                    (lambda (what field s)
                      (let* ((a (exchange h 'GET (string-append "/v1/nodes?limit=100&" field) (list auth)))
                             (j (answer-json a)))
                        (if (string? s)
                            (let ((items (and (= (answer-status a) 200) (list? j) (assoc "items" j) (vector->list (cdr (assoc "items" j))))))
                              (if (and items (equal? (map (lambda (i) (cdr (assoc "id" i))) items) (map id-text (ids-of s)))
                                       (for-all (lambda (i) (equal? (cdr (assoc "tags" i)) (vector s))) items)
                                       (equal? (cdr (assoc "next" j)) 'null))
                                  '()
                                  (list (format "~a: the corpus finds the ~a Notes made with ~s, the server answered ~a ~s"
                                                what (length (ids-of s)) s (answer-status a) (or items (problem-code a))))))
                            (if (and (= (answer-status a) 400) (equal? (problem-code a) "invalid_request")) '()
                                (list (format "~a: the corpus has 400, the server answered ~a" what (answer-status a)))))))))
              (append
               acc
               (apply append
                      (map (lambda (e)
                             (append
                              (filtered (format "tag corpus: ~a ~s, a filter" (tag-entry-name e) (tag-entry-sent e))
                                        (tag-query-field (list 'entry e 'strict)) (tag-entry-stored e))
                              (if (exists (lambda (c) (char=? c #\space)) (string->list (tag-entry-sent e)))
                                  (filtered (format "tag corpus: ~a ~s, a filter with spaces as +" (tag-entry-name e) (tag-entry-sent e))
                                            (tag-query-field (list 'entry e 'plus)) (tag-entry-stored e))
                                  '())))
                           tag-corpus))
               (apply append
                      (map (lambda (c) (filtered (format "tag corpus: the raw query value ~s (~a)" (car c) (cadr c))
                                                 (string-append "tag=" (car c)) (caddr c)))
                           query-raw-cases))
               (filtered "tag corpus: the field tag with no =" "tag" 'invalid)))))))

)
