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
;;; A link (slice 5b) is a row of `links`: owner, source, type, target, created.
;;; It bumps no node's revision and writes no snapshot; it writes a change row
;;; on the source, `link` or `unlink`, at the source's revision as the job read
;;; it. Every statement that reads or deletes by target names the index
;;; `links_target`, and every out statement leaves it alone (traps.md).
;;;
;;; The body lives only in `revisions` (D11): a node's body is its newest
;;; snapshot's, which is not the one at the node's revision once a change of
;;; state (no snapshot) has bumped it. `nodes` has an integer key, `num`, that no record holds and
;;; no answer shows. A list never selects `body`, nor does `snapshot-exists?`.
;;;
;;; No condition raised here carries a title or a body: a job's raise is
;;; logged whole. A refused write holds the node id and the expected
;;; revision, nothing else.
;;;
;;; Rows.
;;;   Node = (id owner author kind title body content-type props revision
;;;           created updated state parent)
;;;     id, owner, author: Bytevector (16)  kind, title, content-type, props:
;;;     String (props is the JSON text as stored)  body: (U String #f), #f in
;;;     a list page  revision: Natural  created, updated: Natural (whole
;;;     milliseconds since 1970, UTC)  state: String, "active", "archived",
;;;     "trashed" or "purged" (a purged node is never answered to a client)
;;;     parent: (U Bytevector #f), the node it sits under, #f at the top
;;;     level (NULL in the table). A purged row has none.
;;;   Snapshot = (node revision author title body content-type props created)
;;;     body: (U String #f), #f in a list page
(library (techo node-store)
  (export node-in-use? node-head node-of-owner nodes-page snapshot-exists? snapshot-of
          snapshots-page insert-node! write-node! set-node-state! purge-node!
          move-node! ancestors has-children? count-children children-heads
          link-of insert-link! delete-link! links-page
          node-store-statements
          node? node-id node-owner node-author node-kind node-title node-body
          node-content-type node-props node-revision node-created node-updated
          node-state node-parent
          snapshot? snapshot-node snapshot-revision snapshot-author
          snapshot-title snapshot-body snapshot-content-type snapshot-props
          snapshot-created)
  (import (rnrs)
          (only (chez-sqlite3) sql-null sql-null?)
          (only (techo doorway) tx-execute! tx-query tx-query-row))

  ;;; Rows

  ;; node? : Any -> Boolean
  ;; node-id, node-owner, node-author : Node -> Bytevector
  ;; node-kind, node-title, node-content-type, node-props : Node -> String
  ;; node-body : Node -> (U String #f)
  ;; node-revision, node-created, node-updated : Node -> Natural
  ;; node-state : Node -> String
  ;; node-parent : Node -> (U Bytevector #f)
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
            (immutable updated node-updated)
            (immutable state node-state)
            (immutable parent node-parent)))

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
  ;; the body, which a row-reader takes from elsewhere. The parent is last.
  (define node-small
    "n.id, n.owner, n.author, n.kind, n.title, n.content_type, n.props, n.revision, n.created, n.updated, n.state, n.parent")

  ;; row->node : (U (Vectorof Any) #f) Boolean -> (U Node #f)
  ;; A row of node-small, and the body at index 12 when BODY? .
  (define (row->node r body?)
    (and r
         (let ((c (lambda (i) (col (vector-ref r i)))))
           (make-node (c 0) (c 1) (c 2) (c 3) (c 4)
                      (and body? (c 12))
                      (c 5) (c 6) (c 7) (c 8) (c 9) (c 10) (c 11)))))

  ;; node-with-body : Node (U String #f) -> Node
  (define (node-with-body n body)
    (make-node (node-id n) (node-owner n) (node-author n) (node-kind n)
               (node-title n) body (node-content-type n) (node-props n)
               (node-revision n) (node-created n) (node-updated n)
               (node-state n) (node-parent n)))

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
     (cons 'node-head
           "SELECT revision, kind, state, parent FROM nodes WHERE owner = ? AND id = ? AND state <> 'purged'")
     (cons 'node-of-owner
           (string-append "SELECT " node-small ", r.body FROM nodes n"
                          " JOIN revisions r ON r.node = n.id AND r.revision ="
                          " (SELECT max(revision) FROM revisions WHERE node = n.id)"
                          " WHERE n.owner = ? AND n.id = ? AND n.state <> 'purged'"))
     (cons 'nodes-page
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? AND n.state = ? AND n.state <> 'purged'"
                          " ORDER BY n.id LIMIT ?"))
     (cons 'nodes-page-after
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? AND n.state = ? AND n.state <> 'purged' AND n.id > ?"
                          " ORDER BY n.id LIMIT ?"))
     (cons 'nodes-page-top
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? AND n.state = ? AND n.state <> 'purged'"
                          " AND n.parent IS NULL ORDER BY n.id LIMIT ?"))
     (cons 'nodes-page-top-after
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? AND n.state = ? AND n.state <> 'purged'"
                          " AND n.parent IS NULL AND n.id > ? ORDER BY n.id LIMIT ?"))
     (cons 'nodes-page-of
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? AND n.state = ? AND n.state <> 'purged'"
                          " AND n.parent = ? ORDER BY n.id LIMIT ?"))
     (cons 'nodes-page-of-after
           (string-append "SELECT " node-small " FROM nodes n"
                          " WHERE n.owner = ? AND n.state = ? AND n.state <> 'purged'"
                          " AND n.parent = ? AND n.id > ? ORDER BY n.id LIMIT ?"))
     ;; The walk up. The recursive table comes FIRST, with CROSS JOIN, so
     ;; that SQLite drives from it and searches nodes by id (traps.md). The
     ;; cap is in the statement: depth stops at N, and LIMIT holds it again.
     (cons 'ancestors
           (string-append "WITH RECURSIVE up(id, depth) AS ("
                          " SELECT parent, 1 FROM nodes WHERE owner = ? AND id = ?"
                          " UNION ALL"
                          " SELECT n.parent, up.depth + 1 FROM up CROSS JOIN nodes n"
                          " WHERE n.id = up.id AND n.owner = ? AND up.depth < ?)"
                          " SELECT id FROM up WHERE id IS NOT NULL ORDER BY depth LIMIT ?"))
     (cons 'has-children
           "SELECT 1 FROM nodes WHERE owner = ? AND parent = ? LIMIT 1")
     (cons 'count-children
           "SELECT count(*) FROM nodes WHERE owner = ? AND parent = ?")
     (cons 'children-heads
           (string-append "SELECT id, revision FROM nodes"
                          " WHERE owner = ? AND parent = ? AND state IN ('active','archived')"
                          " ORDER BY id LIMIT ?"))
     (cons 'children-heads-kind
           (string-append "SELECT id, revision FROM nodes"
                          " WHERE owner = ? AND parent = ? AND state IN ('active','archived')"
                          " AND kind = ? ORDER BY id LIMIT ?"))
     (cons 'snapshot-exists
           (string-append "SELECT r.revision FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ? AND r.revision = ?"
                          " AND n.state <> 'purged'"))
     (cons 'snapshot-of
           (string-append "SELECT " snapshot-small ", r.body"
                          " FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ? AND r.revision = ?"
                          " AND n.state <> 'purged'"))
     (cons 'snapshots-page
           (string-append "SELECT " snapshot-small
                          " FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ? AND n.state <> 'purged'"
                          " ORDER BY r.revision DESC LIMIT ?"))
     (cons 'snapshots-page-before
           (string-append "SELECT " snapshot-small
                          " FROM revisions r JOIN nodes n ON n.id = r.node"
                          " WHERE n.owner = ? AND r.node = ? AND r.revision < ?"
                          " AND n.state <> 'purged'"
                          " ORDER BY r.revision DESC LIMIT ?"))
     (cons 'rows-changed "SELECT changes()")
     (cons 'insert-node
           (string-append "INSERT INTO nodes(id, owner, author, kind, title,"
                          " content_type, props, revision, created, updated, parent)"
                          " VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)"))
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
                          " WHERE owner = ? AND id = ? AND revision = ?"
                          " AND state IN ('active','archived')"))
     (cons 'set-node-state
           (string-append "UPDATE nodes SET state = ?, revision = ?, updated = ?"
                          " WHERE owner = ? AND id = ? AND revision = ?"
                          " AND state <> 'purged'"))
     (cons 'move-node
           (string-append "UPDATE nodes SET parent = ?, revision = ?, updated = ?"
                          " WHERE owner = ? AND id = ? AND revision = ?"
                          " AND state IN ('active','archived')"))
     (cons 'purge-snapshots
           (string-append "DELETE FROM revisions AS r WHERE r.node = ? AND EXISTS"
                          " (SELECT 1 FROM nodes n WHERE n.id = r.node AND n.owner = ?)"))
     (cons 'purge-node
           (string-append "UPDATE nodes SET title = '', props = '{}',"
                          " content_type = 'application/octet-stream', state = 'purged',"
                          " parent = NULL, revision = ?, updated = ?"
                          " WHERE owner = ? AND id = ? AND revision = ? AND state = 'trashed'"))
     (cons 'link-of
           "SELECT created FROM links WHERE owner = ? AND source = ? AND type = ? AND target = ?")
     ;; A plain INSERT and a plain DELETE (never OR IGNORE): each must change
     ;; exactly one row, and the procedure checks it (traps.md).
     (cons 'insert-link
           "INSERT INTO links(owner, source, type, target, created) VALUES (?, ?, ?, ?, ?)")
     (cons 'delete-link
           "DELETE FROM links WHERE owner = ? AND source = ? AND type = ? AND target = ?")
     ;; The four pages. Each is links l CROSS JOIN nodes n, so SQLite drives
     ;; from links; the node is the other end, small columns only, then the
     ;; link's type and created. An "in" statement names links_target; an
     ;; "out" statement never does. A typed statement compares the id alone.
     (cons 'links-out
           (string-append "SELECT " node-small ", l.type, l.created"
                          " FROM links l CROSS JOIN nodes n"
                          " WHERE l.owner = ? AND l.source = ? AND (l.type, l.target) > (?, ?)"
                          " AND n.id = l.target AND n.owner = l.owner AND n.state <> 'purged'"
                          " ORDER BY l.type, l.target LIMIT ?"))
     (cons 'links-out-typed
           (string-append "SELECT " node-small ", l.type, l.created"
                          " FROM links l CROSS JOIN nodes n"
                          " WHERE l.owner = ? AND l.source = ? AND l.type = ? AND l.target > ?"
                          " AND n.id = l.target AND n.owner = l.owner AND n.state <> 'purged'"
                          " ORDER BY l.target LIMIT ?"))
     (cons 'links-in
           (string-append "SELECT " node-small ", l.type, l.created"
                          " FROM links l INDEXED BY links_target CROSS JOIN nodes n"
                          " WHERE l.owner = ? AND l.target = ? AND (l.type, l.source) > (?, ?)"
                          " AND n.id = l.source AND n.owner = l.owner AND n.state <> 'purged'"
                          " ORDER BY l.type, l.source LIMIT ?"))
     (cons 'links-in-typed
           (string-append "SELECT " node-small ", l.type, l.created"
                          " FROM links l INDEXED BY links_target CROSS JOIN nodes n"
                          " WHERE l.owner = ? AND l.target = ? AND l.type = ? AND l.source > ?"
                          " AND n.id = l.source AND n.owner = l.owner AND n.state <> 'purged'"
                          " ORDER BY l.source LIMIT ?"))
     (cons 'purge-links-source
           "DELETE FROM links WHERE owner = ? AND source = ?")
     (cons 'purge-links-target
           "DELETE FROM links INDEXED BY links_target WHERE owner = ? AND target = ?")
     (cons 'written-node
           (string-append "SELECT " node-small " FROM nodes n WHERE n.owner = ? AND n.id = ?"))))

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

  ;; node-head : Tx Bytevector Bytevector
  ;;              -> (U (List Natural String String (U Bytevector #f)) #f)
  ;; owner id -> (revision kind state parent), from `nodes` alone. The
  ;; write's check. A purged row is not found.
  (define (node-head tx owner id)
    (let ((r (tx-query-row tx (statement 'node-head) owner id)))
      (and r (list (vector-ref r 0) (vector-ref r 1) (vector-ref r 2)
                   (col (vector-ref r 3))))))

  ;; node-of-owner : Tx Bytevector Bytevector -> (U Node #f)
  ;; owner id -> the node with its body, read from the node's NEWEST
  ;; snapshot (a change of state bumps the revision and writes none). A
  ;; purged row is not found.
  (define (node-of-owner tx owner id)
    (row->node (tx-query-row tx (statement 'node-of-owner) owner id) #t))

  ;; nodes-page : Tx Bytevector String (U 'any #f Bytevector) (U Bytevector #f)
  ;;               Natural -> (Listof Node)
  ;; owner state parent after n -> up to n nodes in STATE with id > after, by
  ;; id rising, body #f. PARENT is 'any (whatever the parent: the flat list),
  ;; #f (the top level only: parent IS NULL) or an id (that node's children).
  ;; Never touches `revisions`. STATE "purged" finds nothing: no answer shows
  ;; a purged row.
  (define (nodes-page tx owner state parent after n)
    (map (lambda (r) (row->node r #f))
         (cond ((eq? parent 'any)
                (if after
                    (tx-query tx (statement 'nodes-page-after) owner state after n)
                    (tx-query tx (statement 'nodes-page) owner state n)))
               ((not parent)
                (if after
                    (tx-query tx (statement 'nodes-page-top-after) owner state after n)
                    (tx-query tx (statement 'nodes-page-top) owner state n)))
               (else
                (if after
                    (tx-query tx (statement 'nodes-page-of-after) owner state parent after n)
                    (tx-query tx (statement 'nodes-page-of) owner state parent n))))))

  ;; ancestors : Tx Bytevector Bytevector Natural -> (Listof Bytevector)
  ;; owner id n -> the ids above the node: its parent, its parent's parent,
  ;; and so on, nearest first, at most N. '() for a root and for an id that
  ;; is not a node of that owner. The statement stops after N rows itself,
  ;; even on a loop made by hand in the table.
  (define (ancestors tx owner id n)
    (map (lambda (r) (vector-ref r 0))
         (tx-query tx (statement 'ancestors) owner id owner n n)))

  ;; has-children? : Tx Bytevector Bytevector -> Boolean
  ;; owner id -> whether any row of that owner has the id as its parent. A
  ;; purged row never has a parent, so the index alone answers.
  (define (has-children? tx owner id)
    (and (tx-query-row tx (statement 'has-children) owner id) #t))

  ;; count-children : Tx Bytevector Bytevector -> Natural
  ;; owner id -> how many rows of that owner have the id as their parent.
  (define (count-children tx owner id)
    (vector-ref (tx-query-row tx (statement 'count-children) owner id) 0))

  ;; children-heads : Tx Bytevector Bytevector (U 'any String) Natural
  ;;                  -> (Listof (Pair Bytevector Natural))
  ;; owner parent kind n -> the (id . revision) of up to N children of PARENT
  ;; whose state is active or archived and, when KIND is a String, whose kind
  ;; is that; in id order.
  (define (children-heads tx owner parent kind n)
    (map (lambda (r) (cons (vector-ref r 0) (vector-ref r 1)))
         (if (string? kind)
             (tx-query tx (statement 'children-heads-kind) owner parent kind n)
             (tx-query tx (statement 'children-heads) owner parent n))))

  ;; snapshot-exists? : Tx Bytevector Bytevector Natural -> Boolean
  ;; owner id revision -> whether the node is that owner's, not purged, and
  ;; has the snapshot. An index lookup: it selects the snapshot's key alone, never
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

  ;; link-of : Tx Bytevector Bytevector String Bytevector -> (U Natural #f)
  ;; owner source type target -> the link's `created`, or #f when there is no
  ;; such link of that owner. By the primary key.
  (define (link-of tx owner source type target)
    (let ((r (tx-query-row tx (statement 'link-of) owner source type target)))
      (and r (vector-ref r 0))))

  ;; zero-id : Bytevector     sixteen zero bytes: below every id
  (define zero-id (make-bytevector 16 0))

  ;; links-page : Tx Bytevector Bytevector (U 'out 'in) (U String #f)
  ;;              (U (Pair String Bytevector) #f) Natural
  ;;              -> (Listof (List String Natural Node))
  ;; owner node direction type cursor n -> up to n links of NODE, 'out (NODE
  ;; is the source) or 'in (NODE is the target), each as (type created Node),
  ;; the Node the OTHER end as it now is, body #f, never a purged one. Ordered
  ;; by type, then the other end's id; with TYPE, the one type, by id. CURSOR
  ;; is (type . id) of the last item seen: the page starts after it. With none
  ;; the page starts from "" and sixteen zero bytes, or from the zero bytes
  ;; alone when typed. A typed page compares the id alone: the cursor's type
  ;; is the caller's to hold equal to TYPE.
  (define (links-page tx owner node direction type cursor n)
    (let* ((cur-type (if cursor (car cursor) ""))
           (cur-id (if cursor (cdr cursor) zero-id))
           (rows
            (case direction
              ((out)
               (if type
                   (tx-query tx (statement 'links-out-typed) owner node type cur-id n)
                   (tx-query tx (statement 'links-out) owner node cur-type cur-id n)))
              ((in)
               (if type
                   (tx-query tx (statement 'links-in-typed) owner node type cur-id n)
                   (tx-query tx (statement 'links-in) owner node cur-type cur-id n)))
              (else (assertion-violation 'links-page "direction is out or in" direction)))))
      (map (lambda (r) (list (vector-ref r 12) (vector-ref r 13) (row->node r #f)))
           rows)))

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
  ;;                String (U Bytevector #f) Natural -> Node
  ;; id owner kind title body content-type props parent now. Revision 1, author the
  ;; owner: the node's row, then its snapshot (the foreign key's order), then
  ;; a change row with op "create". The Node is built from the arguments; the
  ;; body is not read back.
  (define (insert-node! tx id owner kind title body content-type props parent now)
    (tx-execute! tx (statement 'insert-node)
                 id owner owner kind title content-type props now now (or parent sql-null))
    (insert-snapshot! tx id 1 owner title body content-type props now)
    (insert-change! tx owner id 1 "create" now)
    (make-node id owner owner kind title body content-type props 1 now now "active" parent))

  ;; stored-node : Tx Bytevector Bytevector (U String #f) -> Node
  ;; The node's row as it now is, with BODY.
  (define (stored-node tx owner id body)
    (node-with-body
     (row->node (tx-query-row tx (statement 'written-node) owner id) #f)
     body))

  ;; refuse-write : Symbol Bytevector Natural -> (does not return)
  ;; An assertion violation whose irritants are the id and the expected
  ;; revision, nothing else.
  (define (refuse-write who id expected)
    (assertion-violation who "the node is not at the expected revision, or its state forbids it"
                         id expected))

  ;; write-node! : Tx Bytevector Bytevector Natural String String String
  ;;               String String Natural -> Node
  ;; id owner expected title body content-type props op now. Moves the node
  ;; from revision EXPECTED to EXPECTED + 1 with updated = now (kind, state
  ;; and created untouched), only WHERE owner, id and revision match and the
  ;; state is active or archived, and checks that exactly one row changed:
  ;; else an assertion violation whose irritants are the id and EXPECTED
  ;; only. Then the snapshot, then a change row with OP. The Node is the
  ;; row as it now is, the state the stored one, with the body given.
  (define (write-node! tx id owner expected title body content-type props op now)
    (tx-execute! tx (statement 'write-node)
                 title content-type props (+ expected 1) now owner id expected)
    (unless (= (changes tx) 1) (refuse-write 'write-node! id expected))
    (insert-snapshot! tx id (+ expected 1) owner title body content-type props now)
    (insert-change! tx owner id (+ expected 1) op now)
    (stored-node tx owner id body))

  ;; set-node-state! : Tx Bytevector Bytevector Natural String String Natural
  ;;                   -> Node
  ;; id owner expected state op now. Sets the node's state, moves it from
  ;; revision EXPECTED to EXPECTED + 1 with updated = now, only WHERE owner,
  ;; id and revision match and the row is not purged; then a change row with
  ;; OP at the new revision. Writes NO snapshot. Raises as write-node! does
  ;; when no row changed. It does not judge whether the move is allowed: a
  ;; pure table elsewhere does. The Node is the row as it now is, body #f.
  (define (set-node-state! tx id owner expected state op now)
    (tx-execute! tx (statement 'set-node-state)
                 state (+ expected 1) now owner id expected)
    (unless (= (changes tx) 1) (refuse-write 'set-node-state! id expected))
    (insert-change! tx owner id (+ expected 1) op now)
    (stored-node tx owner id #f))

  ;; move-node! : Tx Bytevector Bytevector Natural (U Bytevector #f) Natural
  ;;              -> Node
  ;; id owner expected new-parent now. Sets the node's parent (#f: the top
  ;; level), moves it from revision EXPECTED to EXPECTED + 1 with updated =
  ;; now, only WHERE owner, id and revision match and the state is active or
  ;; archived; then a change row, op "move", at the new revision. Writes NO
  ;; snapshot. Raises as write-node! does when no row changed. It does not
  ;; judge the move: a pure function elsewhere does. The Node is the row as
  ;; it now is, body #f.
  (define (move-node! tx id owner expected new-parent now)
    (tx-execute! tx (statement 'move-node)
                 (or new-parent sql-null) (+ expected 1) now owner id expected)
    (unless (= (changes tx) 1) (refuse-write 'move-node! id expected))
    (insert-change! tx owner id (+ expected 1) "move" now)
    (stored-node tx owner id #f))

  ;; refuse-link : Symbol Bytevector Bytevector -> (does not return)
  ;; An assertion violation (the convention of refuse-write for a case that
  ;; cannot happen) whose irritants are the two ids, nothing else.
  (define (refuse-link who source target)
    (assertion-violation who "the link did not change exactly one row" source target))

  ;; insert-link! : Tx Bytevector Bytevector String Bytevector Natural Natural
  ;;                -> Void
  ;; owner source type target revision now. A plain INSERT of the link, which
  ;; must make exactly one row (a second of the same key raises: SQLite's
  ;; constraint, and else this check); then a change row, op "link", on the
  ;; SOURCE at REVISION, the revision the job read. No node row is touched.
  (define (insert-link! tx owner source type target revision now)
    (tx-execute! tx (statement 'insert-link) owner source type target now)
    (unless (= (changes tx) 1) (refuse-link 'insert-link! source target))
    (insert-change! tx owner source revision "link" now))

  ;; delete-link! : Tx Bytevector Bytevector String Bytevector Natural Natural
  ;;                -> Void
  ;; As insert-link!, a plain DELETE by the whole key which must remove
  ;; exactly one row (an absent link raises and writes no change row), then a
  ;; change row, op "unlink".
  (define (delete-link! tx owner source type target revision now)
    (tx-execute! tx (statement 'delete-link) owner source type target)
    (unless (= (changes tx) 1) (refuse-link 'delete-link! source target))
    (insert-change! tx owner source revision "unlink" now))

  ;; purge-node! : Tx Bytevector Bytevector Natural Natural -> Void
  ;; id owner expected now. Deletes the node's snapshots, empties the row
  ;; (title '', props '{}', content type application/octet-stream, parent
  ;; NULL, state purged, revision + 1, updated = now) only WHERE owner, id and revision
  ;; match and the state is trashed, and raises as write-node! does when no
  ;; row changed: the job then rolls back, and the snapshots return. Then a
  ;; change row, op "purge", at the new revision. Between the check and that
  ;; row it deletes every link of the node, both ways (by source, then by
  ;; target through links_target), after the check: before it, `changes()`
  ;; would count the deletes and not the UPDATE. No change rows for them: the
  ;; purge's own row is the tombstone.
  (define (purge-node! tx id owner expected now)
    (tx-execute! tx (statement 'purge-snapshots) id owner)
    (tx-execute! tx (statement 'purge-node)
                 (+ expected 1) now owner id expected)
    (unless (= (changes tx) 1) (refuse-write 'purge-node! id expected))
    (tx-execute! tx (statement 'purge-links-source) owner id)
    (tx-execute! tx (statement 'purge-links-target) owner id)
    (insert-change! tx owner id (+ expected 1) "purge" now))
)
