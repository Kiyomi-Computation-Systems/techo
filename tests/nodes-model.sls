#!r6rs
;;; (nodes-model): the model-based test of D5's versioned write, ADR-0007's
;;; third layer, for tests/test-nodes-model.sps (slice 4, task 5a). Test-only:
;;; it lives in tests/, which make test puts on Chez's library path.
;;;
;;; The model (pure)
;;; ----------------
;;; A world is two accounts, a and b (fixed), each with two keys and each
;;; key's last_used; every node made, with its owner, kind, created and its
;;; snapshots, newest first, each (revision title body content-type props
;;; created author); and each owner's change rows (seq node revision op
;;; created). A node's row is its newest snapshot's by construction: its
;;; revision, title, content type, props and updated are read from it.
;;;
;;; `expect` answers a request from the step it is handed (write-step, or a
;;; stand-in of its shape) and the world alone, never the database: what the
;;; write's job would find (none, match or differ), the event, the step's
;;; command, and that command performed on the world. insert, write and copy
;;; each add a snapshot and a change row with the owner's next number, and
;;; set the asking key's last_used when it is due (D6); a refusal changes
;;; nothing. A command that makes no sense for the request (a copy on a PUT,
;;; a write at a revision the node is not at, an insert on an id in use) is a
;;; step the model cannot take, and it says why. The step's next state is
;;; held too: it is what the same request would find if sent again.
;;;
;;; The event is named from the plan's words, as write-event documents it: a
;;; restore is `restore` when the owner's node has the snapshot, whatever
;;; revision If-Match gave. The route names it the same way: it asks
;;; snapshot-exists? whenever it finds the node, at that revision or
;;; another. So a cell counted here is the cell the handlers step, and a
;;; stale restore of a snapshot the node has is differ x restore in both.
;;;
;;; `plan-status` is D5 again in the plan's words (D5, D7, D8), with no
;;; table: what a request must be answered whatever the table says, so a
;;; table changed under both the handlers and the oracle is still caught.
;;;
;;; The run (the shell)
;;; -------------------
;;; `run-sequence` empties one migrated file, seeds the two accounts and
;;; their four keys through the store, generates a seeded sequence of at
;;; least 40 requests (xorshift32), and sends each as raw HTTP through
;;; make-app inside wrap-server, in a test host, with a wall clock the
;;; sequence steps. After every request it compares the status, the code of
;;; a refusal, the ETag, Location and the JSON of a 2xx (every page of a
;;; list) with the model's; holds the answer to plan-status; reads the three
;;; tables and every key's last_used whole, and holds them to laws that need
;;; no model (H1 to H6, H11, H15, H16, against the tables before the
;;; request) and to the model's world. The first request with a difference
;;; ends the sequence with a report that replays from its seed.
(library (nodes-model)
  (export model-accounts start-keys model-start kinds
          make-event make-content node-id-of
          expect expectation-status expectation-code expectation-etag expectation-location
          expectation-json expectation-items expectation-world expectation-cells
          expectation-problem expectation-touched
          world-nodes world-changes-of world-key-last-used world-node
          mnode-kind mnode-created mnode-snaps msnap-revision msnap-title msnap-body
          msnap-type msnap-created mchange-seq mchange-node mchange-revision mchange-op mchange-created
          plan-status
          run-sequence verdict-seed verdict-steps verdict-requests verdict-cells
          verdict-aims verdict-cant-happen verdict-report)
  (import (rnrs)
          (only (chezscheme) format)
          (only (chez-sqlite3) sql-null?)
          (only (chez-sodium) blake2b)
          (only (jsonparse easy) json->string)
          (techo-testing)
          (http-support)
          (only (techo keys) key-secret)
          (only (techo nodes) write-cant-happen)
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

  ;; MNode: id tag label kind created snaps (newest first)
  ;; mnode-kind : MNode -> String
  ;; mnode-created : MNode -> Natural
  ;; mnode-snaps : MNode -> (Listof MSnap)
  (define-record-type mnode (fields id tag label kind created snaps))

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

  (define (node-top n) (car (mnode-snaps n)))
  (define (node-rev n) (msnap-revision (node-top n)))

  ;; world-node : World Bytevector -> (U MNode #f)     any account's
  (define (world-node w id) (find (lambda (n) (bytevector=? (mnode-id n) id)) (world-nodes w)))
  (define (own-node w tag id) (let ((n (world-node w id))) (and n (eq? (mnode-tag n) tag) n)))
  (define (nodes-of w tag) (filter (lambda (n) (eq? (mnode-tag n) tag)) (world-nodes w)))
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
  ;; N at its next revision, the content given, made NOW, by its owner.
  (define (with-snap n title body type props now)
    (make-mnode (mnode-id n) (mnode-tag n) (mnode-label n) (mnode-kind n) (mnode-created n)
                (cons (make-msnap (+ 1 (node-rev n)) title body type props now (mnode-tag n))
                      (mnode-snaps n))))

  ;;; Requests

  ;; Content: kind (U String #f), title, body, type, and whether `"props": {}`
  ;; is sent. make-content : (U String #f) String String String Boolean -> Content
  (define-record-type content (fields kind title body type props?))

  ;; Event: kind now tag key id pre headers content snap limit upper? aims
  ;;   kind      put, restore, get-node, list-nodes, list-revisions, get-snapshot
  ;;   now       the wall clock for the request
  ;;   tag, key  the asking account and key's id
  ;;   id        the node's id (#f for list-nodes)
  ;;   pre       for a write, what the generator meant its headers to say:
  ;;             'create, a revision, 'missing or 'invalid
  ;;   headers   the If-Match and If-None-Match fields sent, in order
  ;;   content   a PUT's Content
  ;;   snap      the snapshot named by a restore or a snapshot read
  ;;   limit     a walk's page size, #f for the default
  ;;   upper?    whether the path's id is written in capitals
  ;;   aims      what the generator aimed at, for counting
  ;; make-event : Symbol Natural Tag Bytevector (U Bytevector #f) Any (Listof Header)
  ;;              (U Content #f) (U Natural #f) (U Natural #f) Boolean (Listof Symbol) -> Event
  (define-record-type event (fields kind now tag key id pre headers content snap limit upper? aims))

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

  ;; Expectation: status code etag location json items world cells problem touched
  ;;   status, code   the answer, and a refusal's code
  ;;   etag, location the headers a 2xx carries, or #f
  ;;   json           a single 2xx's JSON, sorted; items, a walk's items
  ;;   world          the world after
  ;;   cells          the (Found EventKind) pairs stepped
  ;;   problem        why the model cannot take this step, or #f
  ;;   touched        whether the asking key's last_used was set
  ;; expectation-status : Expectation -> (U Natural #f)
  ;; expectation-code, expectation-etag, expectation-location, expectation-problem
  ;;   : Expectation -> (U String #f)
  ;; expectation-json : Expectation -> (U Alist #f)
  ;; expectation-items : Expectation -> (U (Listof Alist) #f)
  ;; expectation-world : Expectation -> World
  ;; expectation-cells : Expectation -> (Listof (List Found EventKind))
  ;; expectation-touched : Expectation -> Boolean
  (define-record-type expectation
    (fields status code etag location json items world cells problem touched))

  (define (refused w cells status code) (make-expectation status code #f #f #f #f w cells #f #f))
  (define (cannot w cells why) (make-expectation #f #f #f #f #f #f w cells why #f))
  (define (read-answer w json items etag) (make-expectation 200 #f etag #f json items w '() #f #f))

  (define refusal-answers
    '((refuse-404 404 "not_found") (refuse-409 409 "kind_fixed") (refuse-412 412 "precondition_failed")))

  ;; props-json : String -> Any     the stored text "{}" is the empty object
  (define (props-json text) (if (string=? text "{}") '() (list 'props text)))

  ;; node-json : MNode Boolean -> Alist     as the plan's smaller choices show a node
  (define (node-json n body?)
    (let ((s (node-top n)))
      (sorted (append (list (cons "id" (id-text (mnode-id n))) (cons "kind" (mnode-kind n))
                            (cons "title" (msnap-title s)))
                      (if body? (list (cons "body" (msnap-body s))) '())
                      (list (cons "content_type" (msnap-type s)) (cons "props" (props-json (msnap-props s)))
                            (cons "revision" (msnap-revision s)) (cons "created" (mnode-created n))
                            (cons "updated" (msnap-created s)))))))

  ;; snap-json : MSnap Boolean -> Alist
  (define (snap-json s body?)
    (sorted (append (list (cons "revision" (msnap-revision s)) (cons "title" (msnap-title s)))
                    (if body? (list (cons "body" (msnap-body s))) '())
                    (list (cons "content_type" (msnap-type s)) (cons "props" (props-json (msnap-props s)))
                          (cons "created" (msnap-created s))))))

  ;; stepped : Step Found EventKind -> (U (List 'ok Found CommandKind) (List 'cannot String))
  (define (stepped step found ev)
    (if (exists (lambda (c) (and (eq? (car c) found) (eq? (cadr c) ev))) write-cant-happen)
        (list 'cannot (format "asked ~a x ~a, which D5 says cannot happen" found ev))
        (guard (e (#t (list 'cannot (format "the step raised for ~a x ~a: ~a" found ev (describe e)))))
          (call-with-values (lambda () (step found ev))
            (lambda (next command) (list 'ok next command))))))

  ;; found-in : World Event -> Found
  ;; What a write's job finds. A create: differ when any account holds the
  ;; id (D8), else none. Else the asking account's node: none when it has
  ;; none, match at the revision given, else differ.
  (define (found-in w e)
    (let ((pre (event-pre e)) (id (event-id e)))
      (if (eq? pre 'create)
          (if (world-node w id) 'differ 'none)
          (let ((own (own-node w (event-tag e) id)))
            (cond ((not own) 'none) ((= (node-rev own) pre) 'match) (else 'differ))))))

  ;; event-in : World Event -> EventKind
  ;; A PUT's create, or replace-other-kind when it names a kind and the
  ;; account's node has another, else replace. A restore is restore when the
  ;; account's node has the snapshot, else restore-unknown.
  (define (event-in w e)
    (let ((own (own-node w (event-tag e) (event-id e))))
      (if (eq? (event-kind e) 'put)
          (let ((kind (content-kind (event-content e))))
            (cond ((eq? (event-pre e) 'create) 'create)
                  ((and kind own (not (string=? kind (mnode-kind own)))) 'replace-other-kind)
                  (else 'replace)))
          (if (and own (snap-of own (event-snap e))) 'restore 'restore-unknown))))

  ;; expect : Step World Event -> Expectation
  ;; STEP is write-step, or a stand-in of its shape.
  (define (expect step w e)
    (if (memq (event-kind e) '(put restore)) (expect-write step w e) (expect-read w e)))

  (define (expect-write step w e)
    (let ((pre (event-pre e)))
      (cond
       ((eq? pre 'missing) (refused w '() 428 "precondition_required"))
       ((eq? pre 'invalid) (refused w '() 400 "invalid_request"))
       (else
        (let* ((found (found-in w e))
               (ev (event-in w e))
               (cells (list (list found ev)))
               (s (stepped step found ev)))
          (if (eq? (car s) 'cannot)
              (cannot w cells (cadr s))
              (let* ((next (cadr s))
                     (x (perform w e found ev (caddr s) cells)))
                (if (expectation-problem x)
                    x
                    (let ((again (found-in (expectation-world x) e)))
                      (if (eq? again next)
                          x
                          (cannot w cells
                                  (format "~a x ~a names next ~a, but the same request sent again finds ~a"
                                          found ev next again))))))))))))

  ;; perform : World Event Found EventKind CommandKind Cells -> Expectation
  (define (perform w e found ev command cells)
    (let ((tag (event-tag e)) (id (event-id e)) (now (event-now e)) (pre (event-pre e))
          (at (format "~a x ~a names ~a" found ev command)))
      (case command
        ((refuse-404 refuse-409 refuse-412)
         (let ((a (assq command refusal-answers))) (refused w cells (cadr a) (caddr a))))
        ((insert)
         (cond ((not (and (eq? (event-kind e) 'put) (eq? pre 'create)))
                (cannot w cells (string-append at ", which only a create performs")))
               ((world-node w id) (cannot w cells (string-append at " on an id in use")))
               (else
                (let ((c (event-content e)))
                  (accepted w e (make-mnode id tag (next-label w) (content-kind c) now
                                            (list (make-msnap 1 (content-title c) (content-body c)
                                                              (content-type c) "{}" now tag)))
                            "create" 201 cells)))))
        ((write)
         (let ((own (own-node w tag id)))
           (cond ((not (eq? (event-kind e) 'put))
                  (cannot w cells (string-append at ", which only a PUT performs")))
                 ((not (and own (integer? pre) (= (node-rev own) pre)))
                  (cannot w cells (string-append at ", but the account's node is not at the revision given")))
                 (else
                  (let ((c (event-content e)))
                    (accepted w e (with-snap own (content-title c) (content-body c) (content-type c) "{}" now)
                              "update" 200 cells))))))
        ((copy)
         (let* ((own (own-node w tag id))
                (s (and own (eq? (event-kind e) 'restore) (snap-of own (event-snap e)))))
           (cond ((not (eq? (event-kind e) 'restore))
                  (cannot w cells (string-append at ", which only a restore performs")))
                 ((not (and own (= (node-rev own) pre)))
                  (cannot w cells (string-append at ", but the account's node is not at the revision given")))
                 ((not s) (cannot w cells (string-append at " of a snapshot the node does not have")))
                 (else
                  (accepted w e (with-snap own (msnap-title s) (msnap-body s) (msnap-type s) (msnap-props s) now)
                            "restore" 200 cells)))))
        (else (cannot w cells (string-append at ", which no write performs"))))))

  ;; accepted : World Event MNode String Natural Cells -> Expectation
  ;; N stored, the owner's next change row with OP, the asking key's
  ;; last_used set when due; the node whole and its ETag, Location for a 201.
  (define (accepted w e n op status cells)
    (let* ((w1 (world-with-node w n))
           (w2 (world-with-change w1 (mnode-tag n) (mnode-id n) (node-rev n) op (event-now e)))
           (due (touch-due? (world-key-last-used w (event-key e)) (event-now e)))
           (w3 (if due (world-touched w2 (event-key e) (event-now e)) w2)))
      (make-expectation status #f (etag-of (node-rev n))
                        (and (= status 201) (string-append "/v1/nodes/" (id-text (mnode-id n))))
                        (node-json n #t) #f w3 cells #f due)))

  (define (expect-read w e)
    (let ((own (and (event-id e) (own-node w (event-tag e) (event-id e)))))
      (case (event-kind e)
        ((get-node)
         (if own (read-answer w (node-json own #t) #f (etag-of (node-rev own))) (refused w '() 404 "not_found")))
        ((list-nodes)
         (read-answer w #f (map (lambda (n) (node-json n #f)) (by-id (nodes-of w (event-tag e)))) #f))
        ((list-revisions)
         (if own
             (read-answer w #f (map (lambda (s) (snap-json s #f)) (mnode-snaps own)) #f)
             (refused w '() 404 "not_found")))
        ((get-snapshot)
         (let ((s (and own (snap-of own (event-snap e)))))
           (if s (read-answer w (snap-json s #t) #f #f) (refused w '() 404 "not_found"))))
        (else (cannot w '() (format "no such request: ~a" (event-kind e)))))))

  ;;; D5 in the plan's words, with no table

  ;; plan-status : World Event -> (List (U Natural #f) String)
  ;; The status the plan's words give (D3, D4, D5, D7, D8), and the clause
  ;; that gives it. W is the world before the request, already held to the
  ;; database.
  (define (plan-status w e)
    (let* ((pre (event-pre e))
           (id (event-id e))
           (own (and id (own-node w (event-tag e) id))))
      (case (event-kind e)
        ((put restore)
         (cond ((eq? pre 'missing) '(428 "a write with neither header is 428"))
               ((eq? pre 'invalid) '(400 "a precondition of any other shape is 400"))
               ((eq? pre 'create)
                (if (world-node w id)
                    '(412 "a create on an id in use, any account's, is 412")
                    '(201 "a create of an id no account holds makes the node")))
               ((not own) '(404 "a write to a node the account does not hold is 404"))
               ((not (= (node-rev own) pre)) '(412 "a stale write is 412 before anything else"))
               ((eq? (event-kind e) 'put)
                (let ((kind (content-kind (event-content e))))
                  (if (and kind (not (string=? kind (mnode-kind own))))
                      '(409 "a replace that names another kind is 409")
                      '(200 "a replace at the node's revision is its next revision"))))
               ((snap-of own (event-snap e))
                '(200 "a restore of a snapshot the node has, at its revision, is its next revision"))
               (else '(404 "a restore of a snapshot the node does not have is 404"))))
        ((get-node list-revisions)
         (if own '(200 "the account's own node is shown") '(404 "another account's node is a missing node")))
        ((get-snapshot)
         (if (and own (snap-of own (event-snap e)))
             '(200 "a snapshot of the account's own node is shown")
             '(404 "a snapshot of no node of the account's is missing")))
        ((list-nodes) '(200 "a list is the account's own nodes"))
        (else '(#f "no such request")))))

  ;;; Labels, for reports

  (define (node-label w id)
    (let ((n (world-node w id)))
      (if n
          (format "~a's ~a (~a, at ~a)" (mnode-tag n) (mnode-label n) (mnode-kind n) (node-rev n))
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
        ((get-node) (format "~a GET ~a" at target))
        ((list-nodes) (format "~a GET /v1/nodes limit=~a" at (event-limit e)))
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

  ;; fresh-node-id : Rng World -> Bytevector     a v7 id, RFC variant, no node's
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

  ;; choose-target : Rng World Tag -> (values Bytevector (U MNode #f) Symbol)
  ;; The account's own node, the other account's, or an id of none.
  (define (choose-target rng w tag)
    (let* ((own (nodes-of w tag))
           (theirs (nodes-of w (other-tag tag)))
           (aim (rng-weighted! rng (append (if (pair? own) '((65 . own)) '())
                                           (if (pair? theirs) '((23 . other)) '())
                                           '((12 . missing))))))
      (case aim
        ((own) (let ((n (pick-node rng own))) (values (mnode-id n) n aim)))
        ((other) (let ((n (pick-node rng theirs))) (values (mnode-id n) n aim)))
        (else (values (fresh-node-id rng w) #f aim)))))

  ;; pick-node : Rng (Listof MNode) -> MNode
  ;; Half the time the node with the most revisions, so that history grows
  ;; deep enough for stale and earlier revisions to be common; else any.
  (define (pick-node rng ns)
    (if (= 0 (rng-below! rng 2))
        (fold-left (lambda (best n) (if (> (node-rev n) (node-rev best)) n best)) (car ns) (cdr ns))
        (rng-pick! rng ns)))

  ;; choose-revision : Rng (U MNode #f) Boolean -> (values Natural Symbol)
  ;; If-Match's revision: the node's current one (most often for the other
  ;; account's node: H6's aim), an earlier one, or one past it.
  (define (choose-revision rng n other?)
    (if (not n)
        (values (+ 1 (rng-below! rng 4)) 'any)
        (let* ((rev (node-rev n))
               (r (rng-below! rng 100)))
          (cond ((< r (if other? 65 60)) (values rev 'current))
                ((and (> rev 1) (< r 88)) (values (+ 1 (rng-below! rng (- rev 1))) 'stale))
                (else (values (+ rev 1 (rng-below! rng 3)) 'ahead))))))

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
  ;; The newest snapshot, an earlier one, or one the node does not have.
  (define (choose-snapshot rng n)
    (if (not n)
        (values (+ 1 (rng-below! rng 3)) 'snap-any)
        (let* ((rev (node-rev n))
               (r (rng-below! rng 100)))
          (cond ((< r 35) (values rev 'snap-newest))
                ((and (> rev 1) (< r 70)) (values (+ 1 (rng-below! rng (- rev 1))) 'snap-older))
                (else (values (+ rev 1 (rng-below! rng 3)) 'snap-unknown))))))

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
                                              (let ((c (list 'create-on-restore (cons "If-None-Match" "*")))) (list c c c)))))))
      (values (cdr choice) (sym "bad-" (car choice)))))

  ;; next-event : Rng World Natural -> Event
  (define (next-event rng w now0)
    (let*-values (((tag) (rng-pick! rng '(a b)))
                  ((key) (rng-pick! rng (key-ids-of tag)))
                  ((now wait) (next-time rng now0 (world-key-last-used w key))))
      (let* ((upper? (= 0 (rng-below! rng 5)))
             (many (length (world-nodes w)))
             (kind (rng-weighted! rng (list (cons (cond ((< many 4) 30) ((< many 8) 10) (else 5)) 'create) '(32 . replace)
                                            '(18 . restore) '(3 . no-pre) '(7 . bad-pre)
                                            '(6 . get-node) '(4 . list-nodes) '(5 . list-revisions)
                                            '(5 . get-snapshot)))))
        (case kind
          ((create)
           (let* ((own (nodes-of w tag))
                  (theirs (nodes-of w (other-tag tag)))
                  (aim (rng-weighted! rng (append '((55 . create-fresh))
                                                  (if (pair? own) '((20 . create-own)) '())
                                                  (if (pair? theirs) '((25 . create-other)) '()))))
                  (id (case aim
                        ((create-own) (mnode-id (rng-pick! rng own)))
                        ((create-other) (mnode-id (rng-pick! rng theirs)))
                        (else (fresh-node-id rng w))))
                  (k (rng-pick! rng kinds))
                  (c (random-content rng k)))
             (make-event 'put now tag key id 'create (list (cons "If-None-Match" "*")) c #f #f upper?
                         (list aim wait))))
          ((replace)
           (let*-values (((id n where) (choose-target rng w tag))
                         ((rev rev-aim) (choose-revision rng n (eq? where 'other)))
                         ((k kind-aim) (choose-kind rng n)))
             (let ((c (random-content rng k)))
               (make-event 'put now tag key id rev (list (cons "If-Match" (etag-of rev))) c #f #f upper?
                           (list (sym "replace-" where "-" rev-aim) kind-aim wait)))))
          ((restore)
           (let*-values (((id n where) (choose-target rng w tag))
                         ((rev rev-aim) (choose-revision rng n (eq? where 'other)))
                         ((k snap-aim) (choose-snapshot rng n)))
             (make-event 'restore now tag key id rev (list (cons "If-Match" (etag-of rev))) #f k #f upper?
                         (list (sym "restore-" where "-" rev-aim) (sym "restore-" snap-aim) wait))))
          ((no-pre)
           (let*-values (((id n where) (choose-target rng w tag)))
             (let* ((route (rng-pick! rng '(put put restore)))
                    (c (and (eq? route 'put) (random-content rng (rng-pick! rng kinds)))))
               (make-event route now tag key id 'missing '() c (and (eq? route 'restore) 1) #f upper?
                           (list (sym "no-precondition-" route) wait)))))
          ((bad-pre)
           (let*-values (((id n where) (choose-target rng w tag)))
             (let* ((route (rng-pick! rng '(put put restore))))
               (let*-values (((hs aim) (bad-headers rng route (if n (node-rev n) 1))))
                 (let ((c (and (eq? route 'put) (random-content rng (rng-pick! rng kinds)))))
                   (make-event route now tag key id 'invalid hs c (and (eq? route 'restore) 1) #f upper?
                               (list aim (sym "bad-precondition-" route) wait)))))))
          ((get-node)
           (let*-values (((id n where) (choose-target rng w tag)))
             (make-event 'get-node now tag key id #f '() #f #f #f upper? (list (sym "get-node-" where) wait))))
          ((list-nodes)
           (let ((limit (rng-pick! rng '(1 2 3 #f))))
             (make-event 'list-nodes now tag key #f #f '() #f #f limit #f (list 'list-nodes wait))))
          ((list-revisions)
           (let*-values (((id n where) (choose-target rng w tag)))
             (let ((limit (rng-pick! rng '(1 2 3 #f))))
               (make-event 'list-revisions now tag key id #f '() #f #f limit upper?
                           (list (sym "list-revisions-" where) wait)))))
          (else
           (let*-values (((id n where) (choose-target rng w tag))
                         ((k snap-aim) (choose-snapshot rng n)))
             (make-event 'get-snapshot now tag key id #f '() #f k #f upper?
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

  ;; content-text : Content -> String     the PUT's JSON
  (define (content->text c)
    (json->string (append (if (content-kind c) (list (cons "kind" (content-kind c))) '())
                          (list (cons "title" (content-title c)) (cons "body" (content-body c))
                                (cons "content_type" (content-type c)))
                          (if (content-props? c) (list (cons "props" '())) '()))))

  (define (cursor-text x) (if (number? x) (number->string x) (format "~a" x)))

  ;; walk : Handler Header String (U Natural #f) (Alist -> Any) -> Obs
  ;; A list page by page, each `next` followed as `after`, at most 60 pages.
  ;; LAST-OF is what a full page's `next` must be, of its last item.
  (define (walk h auth base limit last-of)
    (let ((cap (or limit 50)))
      (let loop ((after #f) (n 1) (items '()) (problems '()))
        (let* ((q (append (if limit (list (string-append "limit=" (number->string limit))) '())
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
        ((get-node) (single (exchange h 'GET (node-path e) (list auth))))
        ((get-snapshot)
         (single (exchange h 'GET (string-append (node-path e) "/revisions/" (number->string (event-snap e)))
                           (list auth))))
        ((list-nodes) (walk h auth "/v1/nodes" (event-limit e) (lambda (item) (field item "id"))))
        (else (walk h auth (string-append (node-path e) "/revisions") (event-limit e)
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
       (if (and (eqv? want got) (memv want '(200 201)))
           (append (if (expectation-json x) (same "the JSON" (expectation-json x) (sorted-json (obs-json o))) '())
                   (if (expectation-items x)
                       (same "the items" (expectation-items x) (map sorted-json (obs-items o)))
                       '()))
           '()))))

  ;; law-breaks : World Event Obs -> (Listof String)
  ;; The answer held to plan-status; and a list shows only the account's own (H6).
  (define (law-breaks w e o)
    (let ((p (plan-status w e)))
      (append
       (if (eqv? (car p) (obs-status o))
           '()
           (list (format "D5 in the plan's words (~a): ~a, but the handlers answered ~a"
                         (cadr p) (car p) (obs-status o))))
       (if (and (eq? (event-kind e) 'list-nodes) (eqv? (obs-status o) 200))
           (let* ((mine (map (lambda (n) (id-text (mnode-id n))) (nodes-of w (event-tag e))))
                  (strays (filter (lambda (item) (not (member (guard (c (#t #f)) (field item "id")) mine)))
                                  (obs-items o))))
             (if (null? strays) '() (list (format "H6: the list shows ~a items that are not the account's" (length strays)))))
           '()))))

  ;;; The database

  ;; Db = (List Nodes Snaps Changes Keys), each a list of rows, each row a list:
  ;;   node     (id owner author kind title content_type props revision created updated)
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
  (define (s-node r) (list-ref r 0))
  (define (s-rev r) (list-ref r 1))
  (define (s-author r) (list-ref r 2))
  (define (s-title r) (list-ref r 3))
  (define (s-type r) (list-ref r 4))
  (define (s-props r) (list-ref r 5))
  (define (s-created r) (list-ref r 6))
  (define (c-owner r) (list-ref r 0))
  (define (c-seq r) (list-ref r 1))
  (define (k-account r) (list-ref r 1))

  (define (row->list v) (map (lambda (c) (if (sql-null? c) #f c)) (vector->list v)))

  ;; db-now : Store -> Db     the three tables and every key's last_used, whole
  (define (db-now store)
    (run-read store
              (lambda (tx)
                (let* ((nodes (tx-query tx (string-append "SELECT id, owner, author, kind, title, content_type,"
                                                          " props, revision, created, updated FROM nodes ORDER BY id")))
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

  ;; node-law-breaks : Row (Listof Row) -> (Listof String)
  ;; H2, H3, H15 and H16 of one node's row and its snapshots.
  (define (node-law-breaks r ss)
    (let* ((n (n-rev r))
           (revs (map s-rev ss))
           (top (find (lambda (s) (= (s-rev s) n)) ss))
           (name (id-text (n-id r))))
      (append
       (if (equal? revs (from-to 1 n)) '()
           (list (format "H3: node ~a is at revision ~a; its snapshots are ~a" name n revs)))
       (if (not top)
           (list (format "H2: node ~a has no snapshot at its revision ~a" name n))
           (append
            (if (and (equal? (n-title r) (s-title top)) (equal? (n-type r) (s-type top))
                     (equal? (n-props r) (s-props top)))
                '()
                (list (format "H2: node ~a's title, content type and props are ~s; its newest snapshot's ~s" name
                              (list (n-title r) (n-type r) (n-props r)) (list (s-title top) (s-type top) (s-props top)))))
            (if (equal? (n-updated r) (s-created top)) '()
                (list (format "H15: node ~a's updated is ~a; its newest snapshot's created ~a" name
                              (n-updated r) (s-created top))))))
       (if (bytevector=? (n-author r) (n-owner r)) '()
           (list (format "H16: node ~a's author is ~a, its owner ~a" name (account-label (n-author r))
                         (account-label (n-owner r)))))
       (let ((bad (filter (lambda (s) (not (bytevector=? (s-author s) (n-owner r)))) ss)))
         (if (null? bad) '()
             (list (format "H16: node ~a's snapshots ~a have an author that is not its owner ~a" name
                           (map s-rev bad) (account-label (n-owner r)))))))))

  ;; always-breaks : Db -> (Listof String)
  (define (always-breaks db)
    (let ((nodes (car db)) (snaps (cadr db)) (changes (caddr db)))
      (append
       (fold-right (lambda (r acc)
                     (append (node-law-breaks r (filter (lambda (s) (bytevector=? (s-node s) (n-id r))) snaps)) acc))
                   '() nodes)
       (if (for-all (lambda (s) (find-node nodes (s-node s))) snaps) '()
           (list "H3: a snapshot whose node has no row"))
       (fold-right (lambda (a acc)
                     (let ((seqs (map c-seq (filter (lambda (c) (bytevector=? (c-owner c) (macct-id a))) changes))))
                       (if (equal? seqs (from-to 1 (length seqs))) acc
                           (cons (format "H4: ~a's change numbers are ~a, not 1 to ~a" (macct-tag a) seqs (length seqs))
                                 acc))))
                   '() model-accounts))))

  ;; op-of : Event -> String     the change row's op an accepted write makes
  (define (op-of e)
    (cond ((eq? (event-kind e) 'restore) "restore")
          ((eq? (event-pre e) 'create) "create")
          (else "update")))

  ;; accepted-breaks : Event Db Db -> (Listof String)
  ;; An accepted write: H1, H3, H4, H6, H11, H15, H16 between the tables
  ;; before and after, and only the asking key's last_used may move, to now.
  (define (accepted-breaks e db0 db1)
    (let* ((id (event-id e))
           (now (event-now e))
           (asker (account-id-of (event-tag e)))
           (name (id-text id))
           (r0 (find-node (car db0) id))
           (r1 (find-node (car db1) id)))
      (if (not r1)
          (list (format "H1: an accepted write left node ~a with no row" name))
          (let* ((rev (n-rev r1))
                 (new? (lambda (s) (and (bytevector=? (s-node s) id) (= (s-rev s) rev))))
                 (added (filter new? (cadr db1)))
                 (kept (filter (lambda (s) (not (new? s))) (cadr db1)))
                 (m0 (length (filter (lambda (c) (bytevector=? (c-owner c) asker)) (caddr db0))))
                 (want-change (list asker (+ m0 1) id rev (op-of e) now))
                 (changes1 (caddr db1)))
            (append
             (if (= rev (+ 1 (if r0 (n-rev r0) 0))) '()
                 (list (format "H1: an accepted write moved node ~a from revision ~a to ~a" name
                               (if r0 (n-rev r0) "none") rev)))
             (if (bytevector=? (n-owner r1) asker) '()
                 (list (format "H6: an accepted write by ~a leaves node ~a owned by ~a" (event-tag e) name
                               (account-label (n-owner r1)))))
             (if r0
                 (append (if (equal? (n-kind r1) (n-kind r0)) '()
                             (list (format "H11: node ~a's kind went from ~s to ~s" name (n-kind r0) (n-kind r1))))
                         (if (equal? (n-created r1) (n-created r0)) '()
                             (list (format "H15: node ~a's created went from ~a to ~a" name (n-created r0) (n-created r1)))))
                 (append (if (equal? (n-kind r1) (content-kind (event-content e))) '()
                             (list (format "H11: node ~a was made of kind ~s, the create's ~s" name (n-kind r1)
                                           (content-kind (event-content e)))))
                         (if (equal? (n-created r1) now) '()
                             (list (format "H15: node ~a was made with created ~a, the time ~a" name (n-created r1) now)))))
             (if (equal? (n-updated r1) now) '()
                 (list (format "H15: node ~a's updated is ~a, not the write's time ~a" name (n-updated r1) now)))
             (if (equal? (but-node (car db1) id) (but-node (car db0) id)) '()
                 (list (format "H1: an accepted write to ~a changed another node's row" name)))
             (if (equal? kept (cadr db0)) '()
                 (list (format "H3: an accepted write to ~a changed, added or removed an earlier snapshot" name)))
             (if (not (= (length added) 1))
                 (list (format "H3: an accepted write to ~a left no snapshot at its revision ~a" name rev))
                 (append (if (equal? (s-created (car added)) now) '()
                             (list (format "H15: the new snapshot's created is ~a, not the write's time ~a"
                                           (s-created (car added)) now)))
                         (if (bytevector=? (s-author (car added)) asker) '()
                             (list (format "H16: the new snapshot's author is ~a, not ~a"
                                           (account-label (s-author (car added))) (event-tag e))))))
             (if (and (= (length changes1) (+ 1 (length (caddr db0))))
                      (member want-change changes1)
                      (for-all (lambda (c) (member c changes1)) (caddr db0)))
                 '()
                 (list (format "H4: an accepted ~a adds one change row, (~a ~a ~a ~a ~s ~a); the rows before were ~a, after ~a"
                               (op-of e) (event-tag e) (+ m0 1) name rev (op-of e) now
                               (length (caddr db0)) (length changes1))))
             (let ((asking (event-key e)))
               (fold-right (lambda (k0 k1 acc)
                             (cond ((equal? k0 k1) acc)
                                   ((and (bytevector=? (car k1) asking) (eqv? (caddr k1) now)) acc)
                                   (else (cons (format "H5: an accepted write moved key ~a's last_used from ~a to ~a"
                                                       (key-label (car k0)) (caddr k0) (caddr k1))
                                               acc))))
                           '() (cadddr db0) (cadddr db1))))))))

  ;; unchanged-breaks : Event Natural Db Db -> (Listof String)
  ;; H5: a refused write, and any read, change nothing at all.
  (define (unchanged-breaks e status db0 db1)
    (let ((what (if (memq (event-kind e) '(put restore))
                    (format "a refused write (~a)" status)
                    (format "a read (~a)" status))))
      (fold-right (lambda (name t0 t1 acc)
                    (if (equal? t0 t1) acc (cons (format "H5: ~a changed ~a" what name) acc)))
                  '() '("nodes" "revisions" "changes" "api_keys' last_used") db0 db1)))

  ;; other-breaks : Event Db Db -> (Listof String)
  ;; H6: no request changes a row of the other account's.
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
          (list (format "H6: a request by ~a changed the rows of ~a" (event-tag e) (other-tag (event-tag e)))))))

  ;; db-law-breaks : Event Obs Db Db -> (Listof String)
  (define (db-law-breaks e o db0 db1)
    (let* ((status (obs-status o))
           (accepted? (and (memq (event-kind e) '(put restore)) (memv status '(200 201)) #t)))
      (append (always-breaks db1)
              (if accepted? (accepted-breaks e db0 db1) (unchanged-breaks e status db0 db1))
              (other-breaks e db0 db1))))

  ;;; The tables held to the model's world

  (define (model-node-rows w)
    (map (lambda (n)
           (let ((s (node-top n)) (owner (account-id-of (mnode-tag n))))
             (list (mnode-id n) owner owner (mnode-kind n) (msnap-title s) (msnap-type s) (msnap-props s)
                   (msnap-revision s) (mnode-created n) (msnap-created s))))
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

  ;; Column labels: which H a difference in that column breaks.
  (define node-columns
    '(("id" . "H1") ("owner" . "H6") ("author" . "H16") ("kind" . "H11") ("title" . "H2")
      ("content_type" . "H2") ("props" . "H2") ("revision" . "H1") ("created" . "H15") ("updated" . "H15")))
  (define snap-columns
    '(("node" . "H3") ("revision" . "H3") ("author" . "H16") ("title" . "H3") ("content_type" . "H3")
      ("props" . "H3") ("created" . "H15") ("body" . "H3")))
  (define change-columns
    '(("owner" . "H4") ("seq" . "H4") ("node" . "H4") ("revision" . "H4") ("op" . "H4") ("created" . "H4")))
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
                  snap-columns "H3/H5")
     (rows-breaks w "changes" (model-change-rows w) (caddr db) (lambda (r) (list (c-owner r) (c-seq r)))
                  change-columns "H4")
     (rows-breaks w "api_keys" (model-key-rows w) (cadddr db) (lambda (r) (list (car r))) key-columns "H5")))

  ;;; One sequence

  ;; Verdict: seed steps requests cells aims cant-happen report
  ;;   steps        requests the generator made
  ;;   requests     HTTP requests sent (a walk is several)
  ;;   cells, aims  (Listof (Pair Key Natural)): D5's (Found EventKind)
  ;;                pairs the model stepped, and what the generator aimed at
  ;;                and what came of it, with counts
  ;;   cant-happen  how many pairs of write-cant-happen the model was asked
  ;;   report       #f when every request agreed; else the first difference
  ;; verdict-seed, verdict-steps, verdict-requests, verdict-cant-happen : Verdict -> Natural
  ;; verdict-cells : Verdict -> (Listof (Pair (List Found EventKind) Natural))
  ;; verdict-aims : Verdict -> (Listof (Pair Symbol Natural))
  ;; verdict-report : Verdict -> (U String #f)
  (define-record-type verdict (fields seed steps requests cells aims cant-happen report))

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

  (define (cells-text cells) (join (map (lambda (c) (format "~a x ~a" (car c) (cadr c))) cells) ", "))

  ;; run-sequence : Store Step Natural Boolean -> Verdict
  ;; The sequence SEED makes, on STORE, emptied first: a fresh app on it
  ;; (wrap-server around make-app, its wall clock set by the sequence), 40
  ;; to 60 generated requests. STEP is the oracle's step (write-step, or a
  ;; stand-in). TRACE? prints each request and its answer as it goes.
  (define (run-sequence store step seed trace?)
    (let* ((rng (make-rng seed))
           (n (+ 40 (rng-below! rng 21)))
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
           (cant 0)
           (log '()))

      (define (count! t k) (hashtable-update! t k (lambda (c) (+ c 1)) 0))

      (define (verdict steps report)
        (make-verdict seed steps requests (hashtable->alist cells) (hashtable->alist aims) cant report))

      (define (report i desc x o breaks)
        (string-append
         (format "seed ~a, step ~a: the sequence so far:\n" seed i)
         (apply string-append (map (lambda (l) (string-append "    " l "\n")) (reverse log)))
         (format "  this step: ~a\n" desc)
         (if x
             (format "  the model expects: ~a ~s, ETag ~s, stepping ~a~a\n"
                     (expectation-status x) (expectation-code x) (expectation-etag x)
                     (cells-text (expectation-cells x))
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
               (x (expect step w e)))
          (for-each (lambda (c)
                      (when (exists (lambda (k) (and (eq? (car k) (car c)) (eq? (cadr k) (cadr c))))
                                    write-cant-happen)
                        (set! cant (+ cant 1))))
                    (expectation-cells x))
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
                                      (guarded "the plan's words" (lambda () (law-breaks w e o)))
                                      (if (eq? (car db) 'raised)
                                          (list (string-append "reading the database raised: " (cadr db)))
                                          (append (guarded "the laws" (lambda () (db-law-breaks e o db0 (cadr db))))
                                                  (guarded "the model's tables"
                                                           (lambda () (model-breaks w1 (cadr db)))))))))
                        (set! requests (+ requests (obs-requests o)))
                        (for-each (lambda (c) (count! cells c)) (expectation-cells x))
                        (for-each (lambda (a) (count! aims a)) (event-aims e))
                        (when (expectation-touched x) (count! aims 'last-used-set))
                        (when (and (memq (event-kind e) '(put restore))
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
