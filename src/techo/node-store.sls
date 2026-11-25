#!r6rs
;;; (techo node-store): each SQL statement slice 4 needs for nodes, as a
;;; procedure of a Tx, the handle a job gets from (techo doorway). Like
;;; (techo store) it runs inside a job: it holds no connection, reads no
;;; clock and makes no id. Ids, text and times arrive as arguments. A job
;;; never begins or ends a transaction here (ADR-0013).
;;;
;;; Every statement it runs is in `node-store-statements`, by name, and each
;;; procedure takes its SQL from there, so a test reads exactly what runs.
;;; tests/test-node-store.sps reads the list, and reads this file for SQL
;;; written anywhere else.
;;;
;;; Every statement but `node-in-use?`'s, the INSERTs and `SELECT changes()`
;;; names the owner in its WHERE (ADR-0003, H19): another account's node is
;;; a node that is not there. A snapshot has no owner column; it is reached
;;; through its node's owner, by a join.
;;;
;;; The body lives only in `revisions` (D11): a node's body is its newest
;;; snapshot's. `nodes` has an integer key, `num`, that no record holds and
;;; no answer shows. A list never selects `body`, nor does `snapshot-exists?`.
;;;
;;; No condition raised here carries a title or a body: a job's raise is
;;; logged whole. A refused write holds the node id and the expected
;;; revision, nothing else.
;;;
;;; Rows.
;;;   Node = (id owner author kind title body content-type props revision
;;;           created updated)
;;;     id, owner, author: Bytevector (16)  kind, title, content-type, props:
;;;     String (props is the JSON text as stored)  body: (U String #f), #f in
;;;     a list page  revision: Natural  created, updated: Natural (whole
;;;     milliseconds since 1970, UTC)
;;;   Snapshot = (node revision author title body content-type props created)
;;;     body: (U String #f), #f in a list page
(library (techo node-store)
  (export node-in-use? node-head node-of-owner nodes-page snapshot-exists? snapshot-of
          snapshots-page insert-node! write-node! node-store-statements
          node? node-id node-owner node-author node-kind node-title node-body
          node-content-type node-props node-revision node-created node-updated
          snapshot? snapshot-node snapshot-revision snapshot-author
          snapshot-title snapshot-body snapshot-content-type snapshot-props
          snapshot-created)
  (import (rnrs)
          (only (chez-sqlite3) sql-null?)
          (only (techo doorway) tx-execute! tx-query tx-query-row))

  ;;; Rows

  ;; node? : Any -> Boolean
  ;; node-id, node-owner, node-author : Node -> Bytevector
  ;; node-kind, node-title, node-content-type, node-props : Node -> String
  ;; node-body : Node -> (U String #f)
  ;; node-revision, node-created, node-updated : Node -> Natural
  (define-record-type (node make-node node?)
    (sealed #t)
    (fields (immutable id node-id)
            (immutable owner node-owner)
            (immutable author node-author)
            (immutable kind node-kind)
            (immutable title node-title)
            (immutable body node-body)
            (immutable content-type node-content-type)
            (immutable props node-props)
            (immutable revision node-revision)
            (immutable created node-created)
            (immutable updated node-updated)))

  ;; snapshot? : Any -> Boolean
  ;; snapshot-node, snapshot-author : Snapshot -> Bytevector
  ;; snapshot-title, snapshot-content-type, snapshot-props : Snapshot -> String
  ;; snapshot-body : Snapshot -> (U String #f)
  ;; snapshot-revision, snapshot-created : Snapshot -> Natural
  (define-record-type (snapshot make-snapshot snapshot?)
    (sealed #t)
    (fields (immutable node snapshot-node)
            (immutable revision snapshot-revision)
            (immutable author snapshot-author)
            (immutable title snapshot-title)
            (immutable body snapshot-body)
            (immutable content-type snapshot-content-type)
            (immutable props snapshot-props)
            (immutable created snapshot-created)))

  ;; col : Any -> Any      NULL reads as #f
  (define (col v) (if (sql-null? v) #f v))

  ;; node-small : String
  ;; The columns of a Node's row in `nodes`, in the record's order but for
  ;; the body, which a row-reader takes from elsewhere.
  (define node-small
    "n.id, n.owner, n.author, n.kind, n.title, n.content_type, n.props, n.revision, n.created, n.updated")

  ;; row->node : (U (Vectorof Any) #f) Boolean -> (U Node #f)
  ;; A row of node-small, and the body at index 10 when BODY? .
  (define (row->node r body?)
    (and r
         (let ((c (lambda (i) (col (vector-ref r i)))))
           (make-node (c 0) (c 1) (c 2) (c 3) (c 4)
                      (and body? (c 10))
                      (c 5) (c 6) (c 7) (c 8) (c 9)))))

  ;; row->snapshot : (U (Vectorof Any) #f) Boolean -> (U Snapshot #f)
  ;; A row of: node, revision, author, title, content_type, props, created,
  ;; and the body at index 7 when BODY? .
  (define (row->snapshot r body?)
    (and r
         (let ((c (lambda (i) (col (vector-ref r i)))))
           (make-snapshot (c 0) (c 1) (c 2) (c 3)
                          (and body? (c 7))
                          (c 4) (c 5) (c 6)))))

  ;;; The statements

  ;; snapshot-small : String
  ;; The columns of a Snapshot's row in `revisions` but the body, in the
  ;; order row->snapshot reads them.
  (define snapshot-small
    "r.node, r.revision, r.author, r.title, r.content_type, r.props, r.created")

  ;; node-store-statements : (Listof (Pair Symbol String))
  ;; Every statement this library runs, by name. Each procedure takes its
  ;; SQL from here and from nowhere else. Exported so that a test can read
  ;; each one's text and ask SQLite for its plan.
  (define node-store-statements
    (list
     (cons 'node-in-use "SELECT id FROM nodes WHERE id = ?")
     (cons 'node-head "SELECT revision, kind FROM nodes WHERE owner = ? AND id = ?")
     (cons 'node-of-owner
           (string-append "SELECT " node-small ", r.body FROM nodes n"
                          " JOIN revisions r ON r.node = n.id AND r.revision = n.revision"
                          " WHERE n.owner = ? AND n.id = ?"))
     (cons 'nodes-page
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? ORDER BY n.id LIMIT ?"))
     (cons 'nodes-page-after
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? AND n.id > ? ORDER BY n.id LIMIT ?"))
     (cons 'snapshot-exists
           (string-append "SELECT r.revision FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ? AND r.revision = ?"))
     (cons 'snapshot-of
           (string-append "SELECT " snapshot-small ", r.body"
                          " FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ? AND r.revision = ?"))
     (cons 'snapshots-page
           (string-append "SELECT " snapshot-small
                          " FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ?"
                          " ORDER BY r.revision DESC LIMIT ?"))
     (cons 'snapshots-page-before
           (string-append "SELECT " snapshot-small
                          " FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ? AND r.revision < ?"
                          " ORDER BY r.revision DESC LIMIT ?"))
     (cons 'rows-changed "SELECT changes()")
     (cons 'insert-node
           (string-append "INSERT INTO nodes(id, owner, author, kind, title,"
                          " content_type, props, revision, created, updated)"
                          " VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)"))
     (cons 'insert-snapshot
           (string-append "INSERT INTO revisions(node, revision, author, title,"
                          " content_type, props, created, body)"
                          " VALUES (?, ?, ?, ?, ?, ?, ?, ?)"))
     (cons 'insert-change
           (string-append "INSERT INTO changes(owner, seq, node, revision, op, created)"
                          " SELECT ?, coalesce(max(seq), 0) + 1, ?, ?, ?, ?"
                          " FROM changes WHERE owner = ?"))
     (cons 'write-node
           (string-append "UPDATE nodes SET title = ?, content_type = ?, props = ?,"
                          " revision = ?, updated = ?"
                          " WHERE owner = ? AND id = ? AND revision = ?"))
     (cons 'written-node "SELECT author, kind, created FROM nodes WHERE owner = ? AND id = ?")))

  ;; statement : Symbol -> String
  ;; NAME's text in node-store-statements. An assertion violation, its
  ;; irritant the name, for a name not there.
  (define (statement name)
    (let ((s (assq name node-store-statements)))
      (if s (cdr s) (assertion-violation 'node-store "no such statement" name))))

  ;; changes : Tx -> Natural
  ;; Rows the last statement of this transaction changed.
  (define (changes tx)
    (vector-ref (tx-query-row tx (statement 'rows-changed)) 0))

  ;;; Reads

  ;; node-in-use? : Tx Bytevector -> Boolean
  ;; Whether any account holds this id. Selects the id only, from a covering
  ;; index. The ONE query with no owner: it is how a create tells a used id
  ;; from a free one.
  (define (node-in-use? tx id)
    (and (tx-query-row tx (statement 'node-in-use) id) #t))

  ;; node-head : Tx Bytevector Bytevector -> (U (Pair Natural String) #f)
  ;; owner id -> (revision . kind), from `nodes` alone. The write's check.
  (define (node-head tx owner id)
    (let ((r (tx-query-row tx (statement 'node-head) owner id)))
      (and r (cons (vector-ref r 0) (vector-ref r 1)))))

  ;; node-of-owner : Tx Bytevector Bytevector -> (U Node #f)
  ;; owner id -> the node with its body, read from the snapshot at the
  ;; node's revision.
  (define (node-of-owner tx owner id)
    (row->node (tx-query-row tx (statement 'node-of-owner) owner id) #t))

  ;; nodes-page : Tx Bytevector (U Bytevector #f) Natural -> (Listof Node)
  ;; owner after n -> up to n nodes with id > after, by id rising, body #f.
  ;; Never touches `revisions`.
  (define (nodes-page tx owner after n)
    (map (lambda (r) (row->node r #f))
         (if after
             (tx-query tx (statement 'nodes-page-after) owner after n)
             (tx-query tx (statement 'nodes-page) owner n))))

  ;; snapshot-exists? : Tx Bytevector Bytevector Natural -> Boolean
  ;; owner id revision -> whether the node is that owner's and has the
  ;; snapshot. An index lookup: it selects the snapshot's key alone, never
  ;; its body.
  (define (snapshot-exists? tx owner id revision)
    (and (tx-query-row tx (statement 'snapshot-exists) owner id revision) #t))

  ;; snapshot-of : Tx Bytevector Bytevector Natural -> (U Snapshot #f)
  ;; owner id revision -> the whole snapshot, body and all, only when the
  ;; node is that owner's.
  (define (snapshot-of tx owner id revision)
    (row->snapshot (tx-query-row tx (statement 'snapshot-of) owner id revision) #t))

  ;; snapshots-page : Tx Bytevector Bytevector (U Natural #f) Natural
  ;;                  -> (Listof Snapshot)
  ;; owner id before n -> up to n snapshots with revision < before, newest
  ;; first, body #f, only when the node is that owner's (else '()). It does
  ;; not select `body`.
  (define (snapshots-page tx owner id before n)
    (map (lambda (r) (row->snapshot r #f))
         (if before
             (tx-query tx (statement 'snapshots-page-before) owner id before n)
             (tx-query tx (statement 'snapshots-page) owner id n))))

  ;;; Writes

  ;; insert-snapshot! : Tx Bytevector Natural Bytevector String String String
  ;;                    String Natural -> Void
  ;; node revision author title body content-type props created
  (define (insert-snapshot! tx id revision author title body content-type props now)
    (tx-execute! tx (statement 'insert-snapshot)
                 id revision author title content-type props now body))

  ;; insert-change! : Tx Bytevector Bytevector Natural String Natural -> Void
  ;; owner node revision op now: the owner's next change number is
  ;; max(seq) + 1 over the owner's rows, 1 for the first.
  (define (insert-change! tx owner id revision op now)
    (tx-execute! tx (statement 'insert-change) owner id revision op now owner))

  ;; insert-node! : Tx Bytevector Bytevector String String String String
  ;;                String Natural -> Node
  ;; id owner kind title body content-type props now. Revision 1, author the
  ;; owner: the node's row, then its snapshot (the foreign key's order), then
  ;; a change row with op "create". The Node is built from the arguments; the
  ;; body is not read back.
  (define (insert-node! tx id owner kind title body content-type props now)
    (tx-execute! tx (statement 'insert-node)
                 id owner owner kind title content-type props now now)
    (insert-snapshot! tx id 1 owner title body content-type props now)
    (insert-change! tx owner id 1 "create" now)
    (make-node id owner owner kind title body content-type props 1 now now))

  ;; write-node! : Tx Bytevector Bytevector Natural String String String
  ;;               String String Natural -> Node
  ;; id owner expected title body content-type props op now. Moves the node
  ;; from revision EXPECTED to EXPECTED + 1 with updated = now (kind and
  ;; created untouched), only WHERE owner, id and revision match, and checks
  ;; that exactly one row changed: else an assertion violation whose
  ;; irritants are the id and EXPECTED only. Then the snapshot, then a change
  ;; row with OP. The Node is built from the arguments and the node's small
  ;; columns; the body is not read back.
  (define (write-node! tx id owner expected title body content-type props op now)
    (tx-execute! tx (statement 'write-node)
                 title content-type props (+ expected 1) now owner id expected)
    (unless (= (changes tx) 1)
      (assertion-violation 'write-node!
                           "the node is not at the expected revision"
                           id expected))
    (insert-snapshot! tx id (+ expected 1) owner title body content-type props now)
    (insert-change! tx owner id (+ expected 1) op now)
    (let ((r (tx-query-row tx (statement 'written-node) owner id)))
      (make-node id owner (vector-ref r 0) (vector-ref r 1) title body
                 content-type props (+ expected 1) (vector-ref r 2) now)))
)
