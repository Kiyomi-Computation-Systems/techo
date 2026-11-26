#!r6rs
;;; (nodes-model): the model-based test of nodes, ADR-0007's third layer,
;;; for tests/test-nodes-model.sps: D5's versioned write (slice 4, task 5a)
;;; and the node lifecycle (slice 4b, task 4a). Test-only: it lives in
;;; tests/, which make test puts on Chez's library path.
;;;
;;; The model (pure)
;;; ----------------
;;; A world is two accounts, a and b (fixed), each with two keys and each
;;; key's last_used; every node made, with its owner, kind, created, state,
;;; revision, updated and its snapshots, newest first, each (revision title
;;; body content-type props created author); and each owner's change rows
;;; (seq node revision op created). A live node's title, content type,
;;; props and body are its newest snapshot's (H2'); its revision runs ahead
;;; of that snapshot by each change of state since (L4). A purged node has
;;; no snapshot, and its row is emptied (L7).
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
;;; A Twist stands between the decision and its performance. The run uses
;;; `as-planned`, which changes nothing; the suite's teeth pass a twisted
;;; rule, and the model must then disagree with the handlers.
;;;
;;; Each write names the cell it would step, in node-command's terms
;;; (Found State Event), by the model's own reading: what the job finds
;;; (none, match, differ), the state of the node it finds (#f when none,
;;; and for a create, whose job reads no state), and the event (D5's five,
;;; or the lifecycle's five). The suite counts them.
;;;
;;; The run (the shell)
;;; -------------------
;;; `run-sequence` empties one migrated file, seeds the two accounts and
;;; their four keys through the store, generates a seeded sequence of 45 to
;;; 65 requests (xorshift32), and sends each as raw HTTP through make-app
;;; inside wrap-server, in a test host, with a wall clock the sequence
;;; steps. After every request it compares the status, the code of a
;;; refusal, the ETag, Location and the body of a 2xx (every page of a
;;; list, for the ?state= asked) with the model's; holds the answer to laws
;;; that need no model (G14, H6, H14, H18'); reads the three tables and
;;; every key's last_used whole, and holds them to laws that need no model
;;; (H1 to H6, H11, H2', H3', H15', H16, G3, G6, G9, G11, G12, G16, against
;;; the tables before the request) and to the model's world. The first
;;; request with a difference ends the sequence with a report that replays
;;; from its seed.
(library (nodes-model)
  (export model-accounts start-keys model-start kinds
          make-event make-content node-id-of
          as-planned lifecycle-events
          expect expectation-status expectation-code expectation-etag expectation-location
          expectation-json expectation-items expectation-world expectation-cells
          expectation-problem expectation-touched expectation-clause
          world-nodes world-changes-of world-key-last-used world-node
          mnode-kind mnode-created mnode-state mnode-revision mnode-updated mnode-snaps
          msnap-revision msnap-title msnap-body msnap-type msnap-created
          mchange-seq mchange-node mchange-revision mchange-op mchange-created
          run-sequence verdict-seed verdict-steps verdict-requests verdict-cells
          verdict-aims verdict-report)
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

  ;; MNode: id tag label kind created state revision updated snaps (newest first)
  ;; mnode-kind : MNode -> String
  ;; mnode-state : MNode -> Symbol      active, archived, trashed or purged
  ;; mnode-created, mnode-revision, mnode-updated : MNode -> Natural
  ;; mnode-snaps : MNode -> (Listof MSnap)
  (define-record-type mnode (fields id tag label kind created state revision updated snaps))

  ;; MChange: seq node revision op created
  ;; mchange-seq, mchange-revision, mchange-created : MChange -> Natural
  ;; mchange-node : MChange -> Bytevector
  ;; mchange-op : MChange -> String
  (define-record-type mchange (fields seq node revision op created))

  ;; World: nodes (in the order made), keys (as start-keys, each last_used
  ;; as now), changes (an alist of tag to that owner's rows, oldest first)
  ;; world-nodes : World -> (Listof MNode)
  (define-record-type world (fields nodes keys changes))

  ;; model-start : World      no node, no change, no key used
  (define model-start (make-world '() start-keys '((a) (b))))

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

  (define write-kinds (append '(put restore) lifecycle-events))
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
                (world-keys w) (world-changes w)))

  ;; world-with-change : World Tag Bytevector Natural String Natural -> World
  ;; The owner's next change row: one more than the rows it has (H4).
  (define (world-with-change w tag id rev op now)
    (let* ((old (world-changes-of w tag))
           (c (make-mchange (+ 1 (length old)) id rev op now)))
      (make-world (world-nodes w) (world-keys w)
                  (map (lambda (p) (if (eq? (car p) tag) (cons tag (append old (list c))) p))
                       (world-changes w)))))

  (define (world-touched w id now)
    (make-world (world-nodes w)
                (map (lambda (k)
                       (if (bytevector=? (mkey-id k) id)
                           (make-mkey (mkey-id k) (mkey-tag k) (mkey-label k) (mkey-secret k)
                                      (mkey-created k) now)
                           k))
                     (world-keys w))
                (world-changes w)))

  ;; with-snap : MNode String String String String Natural -> MNode
  ;; N at its next revision, the content given as its newest snapshot, made
  ;; NOW, by its owner; its state kept (G12).
  (define (with-snap n title body type props now)
    (let ((rev (+ 1 (node-rev n))))
      (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                  (mnode-state n) rev now
                  (cons (make-msnap rev title body type props now (mnode-tag n)) (mnode-snaps n)))))

  ;; with-state : MNode Symbol Natural -> MNode
  ;; N at its next revision in STATE, NOW, with no new snapshot (L4).
  (define (with-state n state now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                state (+ 1 (node-rev n)) now (mnode-snaps n)))

  ;; emptied : MNode Natural -> MNode
  ;; N purged (L7): its next revision, NOW, and no snapshot left.
  (define (emptied n now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                'purged (+ 1 (node-rev n)) now '()))

  ;;; Requests

  ;; Content: kind (U String #f), title, body, type, and whether `"props": {}`
  ;; is sent. make-content : (U String #f) String String String Boolean -> Content
  (define-record-type content (fields kind title body type props?))

  ;; Event: kind now tag key id pre headers content snap limit query upper? aims
  ;;   kind      put, restore, archive, unarchive, trash, untrash, purge,
  ;;             get-node, list-nodes, list-revisions, get-snapshot
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
  ;; make-event : Symbol Natural Tag Bytevector (U Bytevector #f) Any (Listof Header)
  ;;              (U Content #f) (U Natural #f) (U Natural #f) (U String 'twice #f)
  ;;              Boolean (Listof Symbol) -> Event
  (define-record-type event (fields kind now tag key id pre headers content snap limit query upper? aims))

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
  (define-record-type expectation
    (fields status code etag location json items world cells problem touched clause))

  (define (refused w cells status code clause)
    (make-expectation status code #f #f #f #f w cells #f #f clause))
  (define (cannot w cells why) (make-expectation #f #f #f #f #f #f w cells why #f #f))
  (define (read-answer w json items etag clause)
    (make-expectation 200 #f etag #f json items w '() #f #f clause))

  ;; props-json : String -> Any     the stored text "{}" is the empty object
  (define (props-json text) (if (string=? text "{}") '() (list 'props text)))

  ;; node-json : MNode Boolean -> Alist
  ;; A live node as the plan shows it: its title, content type, props and
  ;; body its newest snapshot's (H2'), the body only when BODY?; its
  ;; revision, updated and state its own.
  (define (node-json n body?)
    (let ((s (node-top n)))
      (sorted (append (list (cons "id" (id-text (mnode-id n))) (cons "kind" (mnode-kind n))
                            (cons "state" (symbol->string (mnode-state n))) (cons "title" (msnap-title s)))
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
  ;; Twist = (U Cell #f) Decision -> Decision

  ;; as-planned : Twist     the decision as the rules make it, unchanged
  (define (as-planned cell decision) decision)

  (define (refusal status code) (list 'refuse status code))
  (define not-found (refusal 404 "not_found"))
  (define stale (refusal 412 "precondition_failed"))
  (define wrong-state (refusal 409 "wrong_state"))

  (define (cell-text cell)
    (if cell
        (format "~a x ~a x ~a" (car cell) (or (cadr cell) "-") (caddr cell))
        "no cell"))

  ;; write-event-of : Event (U MNode #f) -> Symbol
  ;; The event a write names, as the plan words it: a PUT's create; a
  ;; replace that names a kind its node has not, replace-other-kind; a
  ;; replace; a restore of a snapshot its node has, restore, else
  ;; restore-unknown (a gap, a revision past the node's, no node); or the
  ;; state change itself.
  (define (write-event-of e own)
    (case (event-kind e)
      ((put)
       (let ((kind (content-kind (event-content e))))
         (cond ((eq? (event-pre e) 'create) 'create)
               ((and kind own (not (string=? kind (mnode-kind own)))) 'replace-other-kind)
               (else 'replace))))
      ((restore) (if (and own (snap-of own (event-snap e))) 'restore 'restore-unknown))
      (else (event-kind e))))

  ;; decide : World Event -> (values (U Cell #f) Decision String)
  ;; A write's answer by the plan's rules, the first that applies, and the
  ;; clause that gives it.
  (define (decide w e)
    (let* ((pre (event-pre e)) (id (event-id e)) (own (own-node w (event-tag e) id)))
      (cond
       ((eq? pre 'missing)
        (values #f (refusal 428 "precondition_required") "a write with no precondition is 428, before its job"))
       ((eq? pre 'invalid)
        (values #f (refusal 400 "invalid_request")
                "a precondition of any other shape, If-None-Match on any route but a PUT among them, is 400"))
       ((eq? pre 'create)
        (if (world-node w id)
            (values (list 'differ #f 'create) stale
                    "a create on an id in use, any account's, a purged one's too, is 412")
            (values (list 'none #f 'create) '(insert) "a create of an id no account has used makes it, active, at 1")))
       (else
        (let* ((ev (write-event-of e own))
               (state (and own (mnode-state own)))
               (found (cond ((not own) 'none) ((= (node-rev own) pre) 'match) (else 'differ)))
               (cell (list found state ev))
               (move (assq ev lifecycle-moves)))
          (cond
           ((not own) (values cell not-found "a node the account has not got, another's or a purged one, is 404"))
           ((eq? found 'differ) (values cell stale "a request at a revision the node is not at is 412, whatever its state"))
           (move
            (cond ((not (memq state (cadr move)))
                   (values cell wrong-state (format "~a from ~a is 409 wrong_state" ev state)))
                  ((eq? ev 'purge)
                   (values cell '(purge) "a purge of a trashed node at its revision empties it: 204"))
                  (else
                   (values cell (list 'set-state (caddr move))
                           (format "~a moves ~a to ~a at the next revision, with no snapshot" ev state
                                   (caddr move))))))
           ((not (memq state writable-states))
            (values cell wrong-state
                    "a replace or a restore of a trashed node is 409 wrong_state, before the kind and the snapshot"))
           ((eq? ev 'replace-other-kind)
            (values cell (refusal 409 "kind_fixed") "a replace that names another kind is 409 kind_fixed"))
           ((eq? ev 'restore-unknown)
            (values cell not-found "a restore of a revision with no snapshot is 404"))
           ((eq? ev 'replace)
            (values cell '(write) "a replace at the node's revision is its next, in the same state"))
           (else
            (values cell '(copy) "a restore of a snapshot the node has, at its revision, is its next, in the same state"))))))))

  ;; expect : Twist World Event -> Expectation
  ;; TWIST is as-planned, or a changed rule for the suite's teeth.
  (define (expect twist w e)
    (if (write-kind? (event-kind e))
        (let-values (((cell decision clause) (decide w e)))
          (perform w e cell (twist cell decision) clause))
        (expect-read w e)))

  ;; perform : World Event (U Cell #f) Decision String -> Expectation
  ;; The decision done to the world. One that makes no sense for the
  ;; request (a copy on a PUT, a change at a revision the node is not at,
  ;; an insert on an id in use) is a step the model cannot take.
  (define (perform w e cell decision clause)
    (let* ((tag (event-tag e)) (id (event-id e)) (now (event-now e)) (pre (event-pre e))
           (kind (event-kind e))
           (own (own-node w tag id))
           (cells (if cell (list cell) '()))
           (at (format "~a names ~s" (cell-text cell) decision))
           (at-pre? (and own (integer? pre) (= (node-rev own) pre))))
      (case (car decision)
        ((refuse) (refused w cells (cadr decision) (caddr decision) clause))
        ((insert)
         (cond ((not (and (eq? kind 'put) (eq? pre 'create)))
                (cannot w cells (string-append at ", which only a create performs")))
               ((world-node w id) (cannot w cells (string-append at " on an id in use")))
               (else
                (let ((c (event-content e)))
                  (accepted w e (make-mnode id tag (next-label w) (content-kind c) now 'active 1 now
                                            (list (make-msnap 1 (content-title c) (content-body c)
                                                              (content-type c) "{}" now tag)))
                            "create" 201 #t cells clause)))))
        ((write)
         (cond ((not (eq? kind 'put)) (cannot w cells (string-append at ", which only a PUT performs")))
               ((not at-pre?)
                (cannot w cells (string-append at ", but the account's node is not at the revision given")))
               (else
                (let ((c (event-content e)))
                  (accepted w e (with-snap own (content-title c) (content-body c) (content-type c) "{}" now)
                            "update" 200 #t cells clause)))))
        ((copy)
         (let ((s (and own (eq? kind 'restore) (snap-of own (event-snap e)))))
           (cond ((not (eq? kind 'restore)) (cannot w cells (string-append at ", which only a restore performs")))
                 ((not at-pre?)
                  (cannot w cells (string-append at ", but the account's node is not at the revision given")))
                 ((not s) (cannot w cells (string-append at " of a snapshot the node does not have")))
                 (else
                  (accepted w e (with-snap own (msnap-title s) (msnap-body s) (msnap-type s) (msnap-props s) now)
                            "restore" 200 #t cells clause)))))
        ((set-state)
         (cond ((not (and (life-kind? kind) (not (eq? kind 'purge))))
                (cannot w cells (string-append at ", which only a state change performs")))
               ((not at-pre?)
                (cannot w cells (string-append at ", but the account's node is not at the revision given")))
               ((not (memq (cadr decision) live-states))
                (cannot w cells (string-append at ", a state no client sees")))
               (else
                (accepted w e (with-state own (cadr decision) now) (symbol->string kind) 200 #f cells clause))))
        ((purge)
         (cond ((not (eq? kind 'purge)) (cannot w cells (string-append at ", which only a DELETE performs")))
               ((not at-pre?)
                (cannot w cells (string-append at ", but the account's node is not at the revision given")))
               (else (accepted w e (emptied own now) "purge" 204 #f cells clause))))
        (else (cannot w cells (string-append at ", which no write performs"))))))

  ;; accepted : World Event MNode String Natural Boolean Cells String -> Expectation
  ;; N stored, the owner's next change row with OP at N's revision, the
  ;; asking key's last_used set when due. A 201 or a 200 answers N's JSON,
  ;; with its body when BODY?, and its ETag, and Location for a 201; a 204
  ;; answers neither body nor ETag.
  (define (accepted w e n op status body? cells clause)
    (let* ((w1 (world-with-node w n))
           (w2 (world-with-change w1 (mnode-tag n) (mnode-id n) (node-rev n) op (event-now e)))
           (due (touch-due? (world-key-last-used w (event-key e)) (event-now e)))
           (w3 (if due (world-touched w2 (event-key e) (event-now e)) w2)))
      (if (= status 204)
          (make-expectation 204 #f #f #f 'empty #f w3 cells #f due clause)
          (make-expectation status #f (etag-of (node-rev n))
                            (and (= status 201) (string-append "/v1/nodes/" (id-text (mnode-id n))))
                            (node-json n body?) #f w3 cells #f due clause))))

  ;; list-state : (U String 'twice #f) -> (U Symbol 'invalid)
  ;; L6 and the review: no ?state= is active; a live state's name is that
  ;; state; anything else, purged among them, or the field twice, is 400.
  (define (list-state q)
    (cond ((not q) 'active)
          ((and (string? q) (find (lambda (s) (string=? (symbol->string s) q)) live-states)))
          (else 'invalid)))

  (define (expect-read w e)
    (let ((own (and (event-id e) (own-node w (event-tag e) (event-id e))))
          (gone "a node the account has not got, another's or a purged one, is 404"))
      (case (event-kind e)
        ((get-node)
         (if own
             (read-answer w (node-json own #t) #f (etag-of (node-rev own))
                          "the account's own node is shown, with its newest snapshot's body")
             (refused w '() 404 "not_found" gone)))
        ((list-nodes)
         (let ((s (list-state (event-query e))))
           (if (eq? s 'invalid)
               (refused w '() 400 "invalid_request" "a ?state= that names no live state is 400")
               (read-answer w #f
                            (map (lambda (n) (node-json n #f))
                                 (by-id (filter (lambda (n) (eq? (mnode-state n) s)) (nodes-of w (event-tag e)))))
                            #f (format "a list is the account's own ~a nodes, by id, with no bodies" s)))))
        ((list-revisions)
         (if own
             (read-answer w #f (map (lambda (s) (snap-json s #f)) (mnode-snaps own)) #f
                          "a node's snapshots, newest first, gaps where its state changed")
             (refused w '() 404 "not_found" gone)))
        ((get-snapshot)
         (let ((s (and own (snap-of own (event-snap e)))))
           (if s
               (read-answer w (snap-json s #t) #f #f "a snapshot of the account's own node is shown")
               (refused w '() 404 "not_found"
                        "a snapshot no live node of the account's has, a gap's among them, is 404"))))
        (else (cannot w '() (format "no such request: ~a" (event-kind e)))))))

  ;;; Labels, for reports

  (define (node-label w id)
    (let ((n (world-node w id)))
      (if n
          (format "~a's ~a (~a, ~a, at ~a)" (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-state n)
                  (node-rev n))
          (format "a fresh id ~a" (substring (id-text id) 24 36)))))

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

  (define (content-text c)
    (if c
        (format " ~a~s ~s ~s~a" (if (content-kind c) (string-append (content-kind c) " ") "")
                (content-title c) (content-body c) (content-type c) (if (content-props? c) " {}" ""))
        ""))

  (define (headers-text hs)
    (if (null? hs) "(no precondition)" (join (map (lambda (h) (format "~a: ~a" (car h) (cdr h))) hs) ", ")))

  (define (describe-event w e t0)
    (let ((at (format "t+~a ~a" (- (event-now e) t0) (key-label (event-key e))))
          (target (if (event-id e) (node-label w (event-id e)) "")))
      (case (event-kind e)
        ((put) (format "~a PUT ~a ~a~a" at target (headers-text (event-headers e)) (content-text (event-content e))))
        ((restore) (format "~a restore ~a snapshot ~a, ~a" at target (event-snap e) (headers-text (event-headers e))))
        ((archive unarchive trash untrash)
         (format "~a POST ~a /~a, ~a" at target (event-kind e) (headers-text (event-headers e))))
        ((purge) (format "~a DELETE ~a, ~a" at target (headers-text (event-headers e))))
        ((get-node) (format "~a GET ~a" at target))
        ((list-nodes) (format "~a GET /v1/nodes state=~a limit=~a" at (event-query e) (event-limit e)))
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

  (define (random-content rng kind)
    (let* ((title (rng-pick! rng title-pool))
           (body (rng-pick! rng body-pool))
           (type (rng-pick! rng type-pool))
           (props? (= 0 (rng-below! rng 2))))
      (make-content kind title body type props?)))

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
  ;; change of state does not add.
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
                                              (let ((c (list (if (eq? route 'restore) 'create-on-restore
                                                                 'create-on-lifecycle)
                                                             (cons "If-None-Match" "*"))))
                                                (list c c c)))))))
      (values (cdr choice) (sym "bad-" (car choice)))))

  ;; The routes a write is sent to with no precondition, or a bad one: a
  ;; PUT most, then a restore, then each state change.
  (define bare-routes '(put put put put put restore restore archive unarchive trash untrash purge))

  ;; list-aim : (U String 'twice #f) -> Symbol
  (define (list-aim q)
    (case (list-state q)
      ((invalid) 'list-state-invalid)
      (else (if q (sym "list-state-" q) 'list-state-default))))

  ;; next-event : Rng World Natural -> Event
  (define (next-event rng w now0)
    (let*-values (((tag) (rng-pick! rng '(a b)))
                  ((key) (rng-pick! rng (key-ids-of tag)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((upper? (= 0 (rng-below! rng 5)))
             (many (length (live-nodes w)))
             (kind (rng-weighted! rng (list (cons (cond ((< many 4) 30) ((< many 8) 10) (else 5)) 'create)
                                            '(28 . replace) '(16 . restore) '(38 . lifecycle)
                                            '(4 . no-pre) '(8 . bad-pre)
                                            '(7 . get-node) '(7 . list-nodes) '(6 . list-revisions)
                                            '(12 . get-snapshot)))))
        (case kind
          ((create)
           (let* ((own (nodes-of w tag))
                  (theirs (nodes-of w (other-tag tag)))
                  (gone-own (purged-of w tag))
                  (gone-theirs (purged-of w (other-tag tag)))
                  (aim (rng-weighted! rng (append '((55 . create-fresh))
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
                  (k (rng-pick! rng kinds))
                  (c (random-content rng k)))
             (make-event 'put now tag key id 'create (list (cons "If-None-Match" "*")) c #f #f #f upper?
                         (list aim wait))))
          ((replace)
           (let*-values (((id n where) (choose-target rng w tag by-revisions))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged))))
                         ((k kind-aim) (choose-kind rng n)))
             (let ((c (random-content rng k)))
               (make-event 'put now tag key id rev (list (cons "If-Match" (etag-of rev))) c #f #f #f upper?
                           (append (list (sym "replace-" where "-" rev-aim) kind-aim wait)
                                   (if (eq? where 'own) (list (sym "replace-own-" (mnode-state n))) '()))))))
          ((restore)
           (let*-values (((id n where) (choose-target rng w tag by-snapshots))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged))))
                         ((k snap-aim) (choose-snapshot rng n)))
             (make-event 'restore now tag key id rev (list (cons "If-Match" (etag-of rev))) #f k #f #f upper?
                         (append (list (sym "restore-" where "-" rev-aim) (sym "restore-" snap-aim) wait)
                                 (if (eq? where 'own) (list (sym "restore-own-" (mnode-state n))) '())))))
          ((lifecycle)
           (let*-values (((id n where) (choose-target rng w tag by-revisions))
                         ((ev) (choose-change rng n where))
                         ((rev rev-aim) (choose-revision rng n (memq where '(other purged)))))
             (make-event ev now tag key id rev (list (cons "If-Match" (etag-of rev))) #f #f #f #f upper?
                         (append (list (sym ev "-" where "-" rev-aim) wait)
                                 (if (eq? where 'own) (list (sym ev "-own-" (mnode-state n))) '())))))
          ((no-pre)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (let* ((route (rng-pick! rng bare-routes))
                    (c (and (eq? route 'put) (random-content rng (rng-pick! rng kinds)))))
               (make-event route now tag key id 'missing '() c (and (eq? route 'restore) 1) #f #f upper?
                           (list (sym "no-precondition-" route) wait)))))
          ((bad-pre)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (let* ((route (rng-pick! rng bare-routes)))
               (let*-values (((hs aim) (bad-headers rng route (if n (node-rev n) 1))))
                 (let ((c (and (eq? route 'put) (random-content rng (rng-pick! rng kinds)))))
                   (make-event route now tag key id 'invalid hs c (and (eq? route 'restore) 1) #f #f upper?
                               (list aim (sym "bad-precondition-" route) wait)))))))
          ((get-node)
           (let*-values (((id n where) (choose-target rng w tag by-revisions)))
             (make-event 'get-node now tag key id #f '() #f #f #f #f upper? (list (sym "get-node-" where) wait))))
          ((list-nodes)
           (let* ((limit (rng-pick! rng '(1 2 3 #f)))
                  (q (rng-weighted! rng '((28 . none) (18 . "active") (21 . "archived") (21 . "trashed")
                                          (3 . "purged") (3 . "ARCHIVED") (3 . "deleted") (3 . twice))))
                  (query (if (eq? q 'none) #f q)))
             (make-event 'list-nodes now tag key #f #f '() #f #f limit query #f
                         (list 'list-nodes (list-aim query) wait))))
          ((list-revisions)
           (let*-values (((id n where) (choose-target rng w tag by-snapshots)))
             (let ((limit (rng-pick! rng '(1 2 3 #f))))
               (make-event 'list-revisions now tag key id #f '() #f #f limit #f upper?
                           (list (sym "list-revisions-" where) wait)))))
          (else
           (let*-values (((id n where) (choose-target rng w tag by-snapshots))
                         ((k snap-aim) (choose-snapshot rng n)))
             (make-event 'get-snapshot now tag key id #f '() #f k #f #f upper?
                         (list (sym "get-snapshot-" where) (sym "get-" snap-aim) wait))))))))

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
                          (if (content-props? c) (list (cons "props" '())) '()))))

  (define (cursor-text x) (if (number? x) (number->string x) (format "~a" x)))

  ;; state-query : (U String 'twice #f) -> (Listof String)     a list's ?state= fields
  (define (state-query q)
    (cond ((not q) '())
          ((eq? q 'twice) '("state=active" "state=active"))
          (else (list (string-append "state=" q)))))

  ;; walk : Handler Header String (Listof String) (U Natural #f) (Alist -> Any) -> Obs
  ;; A list page by page, each `next` followed as `after`, at most 60 pages,
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
                      ((>= n 60) (make-obs 200 #f #f #f j items (cons "the walk did not end in 60 pages" problems) n))
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
        ((get-node) (single (exchange h 'GET (node-path e) (list auth))))
        ((get-snapshot)
         (single (exchange h 'GET (string-append (node-path e) "/revisions/" (number->string (event-snap e)))
                           (list auth))))
        ((list-nodes) (walk h auth "/v1/nodes" (state-query (event-query e)) (event-limit e)
                            (lambda (item) (field item "id"))))
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

  ;; law-breaks : World Event Obs -> (Listof String)
  ;; An answer held to laws that need no model. A node's answer shows a
  ;; live state (G14) and its revision as its ETag (H14); a state change's
  ;; answer has no body (the plan's choice); a purge's 204 has neither body
  ;; nor ETag (G6); a list shows only the account's own live nodes (H6,
  ;; G14), each in the state asked (G8), each once, by id (H18').
  (define (law-breaks w e o)
    (let ((status (obs-status o)) (kind (event-kind e)) (j (obs-json o)))
      (append
       (if (and (memv status '(200 201)) (memq kind (cons 'get-node write-kinds)) (list? j))
           (let ((s (guard (c (#t #f)) (field j "state")))
                 (r (guard (c (#t #f)) (field j "revision"))))
             (append
              (if (member s '("active" "archived" "trashed")) '()
                  (list (format "G14: a node's answer shows the state ~s" s)))
              (if (and (integer? r) (equal? (obs-etag o) (etag-of r))) '()
                  (list (format "H14: the ETag ~s is not the answer's revision ~s" (obs-etag o) r)))
              (if (and (life-kind? kind) (assoc "body" j))
                  (list "the plan: a state change's answer shows a body")
                  '())))
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
              (if (ids-rising? ids) '() (list "H18': the list does not show each node once, by id"))))
           '()))))

  ;;; The database

  ;; Db = (List Nodes Snaps Changes Keys), each a list of rows, each row a list:
  ;;   node     (id owner author kind title content_type props revision created updated state)
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
                                                          " props, revision, created, updated, state"
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
  ;; makes it active, an update or a restore keeps it, a change of state
  ;; lands where lifecycle-moves says. #f for an op none of these is.
  (define (feed-state ops)
    (fold-left (lambda (state op)
                 (cond ((not state) #f)
                       ((string=? op "create") "active")
                       ((member op '("update" "restore")) state)
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

  ;; always-breaks : Db -> (Listof String)
  (define (always-breaks db)
    (let ((nodes (car db)) (snaps (cadr db)) (changes (caddr db)))
      (append
       (fold-right (lambda (r acc)
                     (append (node-law-breaks r
                                              (filter (lambda (s) (bytevector=? (s-node s) (n-id r))) snaps)
                                              (filter (lambda (c) (bytevector=? (c-node c) (n-id r))) changes))
                             acc))
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
      (else (symbol->string (event-kind e)))))

  ;; accepted-breaks : Event Db Db -> (Listof String)
  ;; An accepted write, between the tables before and after: H1, H3', H4,
  ;; H6, H11, H15', H16, G3, G6, G9, G11, G12; and only the asking key's
  ;; last_used may move, to now.
  (define (accepted-breaks e db0 db1)
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
               (let ((lands (symbol->string (caddr (assq (event-kind e) lifecycle-moves)))))
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
             (let ((asking (event-key e)))
               (fold-right (lambda (k0 k1 acc)
                             (cond ((equal? k0 k1) acc)
                                   ((and (bytevector=? (car k1) asking) (eqv? (caddr k1) now)) acc)
                                   (else (cons (format "H5: an accepted ~a moved key ~a's last_used from ~a to ~a"
                                                       op (key-label (car k0)) (caddr k0) (caddr k1))
                                               acc))))
                           '() (cadddr db0) (cadddr db1))))))))

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
                            (ids (map n-id nodes)))
                       (list nodes
                             (filter (lambda (s) (member (s-node s) ids)) (cadr db))
                             (filter (lambda (c) (bytevector=? (c-owner c) other)) (caddr db))
                             (filter (lambda (k) (bytevector=? (k-account k) other)) (cadddr db)))))))
      (if (equal? (theirs db0) (theirs db1)) '()
          (list (format "H6, G7: a request by ~a changed the rows of ~a" (event-tag e) (other-tag (event-tag e)))))))

  ;; db-law-breaks : Event Obs Db Db -> (Listof String)
  (define (db-law-breaks e o db0 db1)
    (let* ((status (obs-status o))
           (accepted? (and (write-kind? (event-kind e)) (memv status '(200 201 204)) #t)))
      (append (always-breaks db1)
              (if accepted? (accepted-breaks e db0 db1) (unchanged-breaks e status db0 db1))
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
                     (list (node-rev n) (mnode-created n) (mnode-updated n) (symbol->string (mnode-state n))))))
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
      ("updated" . "H15'") ("state" . "G3, G12")))
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
  ;; verdict-seed, verdict-steps, verdict-requests : Verdict -> Natural
  ;; verdict-cells : Verdict -> (Listof (Pair Cell Natural))
  ;; verdict-aims : Verdict -> (Listof (Pair Symbol Natural))
  ;; verdict-report : Verdict -> (U String #f)
  (define-record-type verdict (fields seed steps requests cells aims report))

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
  ;; (wrap-server around make-app, its wall clock set by the sequence), 45
  ;; to 65 generated requests. TWIST is as-planned, or a changed rule.
  ;; TRACE? prints each request and its answer as it goes.
  (define (run-sequence store twist seed trace?)
    (let* ((rng (make-rng seed))
           (n (+ 45 (rng-below! rng 21)))
           (t0 (+ 1795515226123 (rng-below! rng 100000)))
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
        (make-verdict seed steps requests (hashtable->alist cells) (hashtable->alist aims) report))

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
                                      (if (eq? (car db) 'raised)
                                          (list (string-append "reading the database raised: " (cadr db)))
                                          (append (guarded "the laws" (lambda () (db-law-breaks e o db0 (cadr db))))
                                                  (guarded "the model's tables"
                                                           (lambda () (model-breaks w1 (cadr db)))))))))
                        (set! requests (+ requests (obs-requests o)))
                        (for-each (lambda (c) (count! cells c)) (expectation-cells x))
                        (for-each (lambda (a) (count! aims a)) (event-aims e))
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
            (if (> i n)
                (verdict n #f)
                (let* ((e (next-event rng w now))
                       (r (step! w i e db0)))
                  (if (string? r)
                      (verdict i r)
                      (loop (car r) (cdr r) (event-now e) (+ i 1)))))))))))
)
