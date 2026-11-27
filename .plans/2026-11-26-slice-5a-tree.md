# Slice 5a: the tree and move

Date: 2026-11-26
Status: the owner decided T1 to T10 on 2026-11-26 (below). Reviewed (the review
section, at the end): where it and the text above disagree, the review wins. The
records are amended. Built, and the build reviewed (the last section).
Records: ADR-0002 (the API), ADR-0003 (nodes), ADR-0004 (revisions), ADR-0007
(machines), ADR-0012 (migrations), ADR-0013 (the doorway). Read
[global-constraints.md](global-constraints.md) first, then
[slice 4's plan](2026-11-25-slice-4-nodes.md) and
[slice 4b's](2026-11-25-slice-4b-node-lifecycle.md): this slice builds on both.

## What this slice is for

After 4b a person has a flat pile of notes. This slice gives them folders:

- make a node inside a Project or a Journal;
- move a node to another parent, or to the top level;
- move all of a node's children at once;
- list a node's children, or the top level.

Links are slice 5b.

## What the probes found (2026-11-26)

`build/probe-5/p.sps` and `links.sps`, on a real file opened by `open-techo-db`,
in WAL: 121,112 nodes, a chain 10,000 deep and a tree of 111,111 (fan-out 10).

| Question | Answer |
|---|---|
| `ADD COLUMN parent BLOB REFERENCES nodes(id)` with rows there, foreign keys on | works |
| Walk up from a node to its root | 0 ms at depth 100, 1 ms at 1,000, 5 ms at 10,000 |
| The same walk stopped at 64 steps, from depth 10,000 | 0 ms |
| A page of children, or of roots, by `nodes_parent(owner, parent, id)` | one index search; 1,000 pages in 8 ms |
| All descendants of 111,111 nodes | 58 ms |
| Trash a subtree in one transaction, a change row each | 1,111: 6 ms. 11,111: 36 ms. 111,111: about 400 ms |
| A page of 51 with "no trashed ancestor" as a filter, depth 5 | under 1 ms |
| Deleting a node that is a parent | refused by the foreign key |

**Two traps, both seen:**

- **A recursive query can be driven from the wrong table.** Written
  `FROM nodes n JOIN down ON n.parent = down.id`, all descendants of 11,111
  nodes took 57 s: SQLite read every node of the owner at each step. Written
  `FROM down CROSS JOIN nodes n WHERE n.parent = down.id`, 5 ms. The walk up
  was right as first written. Every recursive statement gets its plan tested.
- **A delete can ignore the index made for it** (5b's): `DELETE FROM links WHERE
  owner = ? AND target = ?` searched the primary key by owner alone.

## Decisions (the owner's, 2026-11-26)

| # | Question | Decided |
|---|---|---|
| T1 | One slice or two | Two: 5a the tree and move, 5b links |
| T2 | What can hold what | Only a Project or a Journal has children. A Project holds any kind, Projects too. A Journal holds only Notes. A Note holds nothing: a Contact joins a Note by a link (5b) |
| T3 | How a parent is set | `parent` is optional when a node is made. After that only a move changes it. A replace may not carry it |
| T4 | A move and history | It bumps the revision and writes no snapshot. A restore never undoes a move |
| T5 | Loops and depth | A move under itself or a descendant is refused. A new parent may be at most 64 levels deep |
| T6 | Trashing or archiving a parent | It touches that node only. Children keep their own state. **To be documented well, with "inherit on read" kept as the way out** |
| T7 | Purging a parent | Refused while it has children. **A bulk move of children is in this slice. A bulk purge is not, yet** |
| T8 | Parents and state | Nothing is made in or moved into a trashed node. A trashed node cannot be moved. Archived is fine both ways |
| T9 | Listing children | `GET /v1/nodes?parent={id}`, `?parent=null` for the top level, beside `?state=` |
| T10 | New codes | `invalid_parent`, `would_loop`, `has_children`, all 409 |

**T6's way out, kept for later.** "A node is in the trash if it or any ancestor
is" can be computed when a list is read: under 1 ms a page at depth 5, and the
depth cap bounds it. It needs no migration and changes no stored row. Every
list, slice 7's search and slice 8's feed would carry the check. A cascade was
not chosen: it cannot be undone (an untrash cannot tell which children were
trashed before), and it costs the writer 400 ms on a large tree.

**T4's reason.** A column added to `revisions` now lands behind the body, which
costs a walk of the body's pages to read (traps.md). And a state change already
works this way.

## The design

### Routes

| Route | Does | Answer |
|---|---|---|
| `PUT /v1/nodes/{id}` with `If-None-Match: *` | as today; the JSON may carry `"parent"` | 201, the node |
| `POST /v1/nodes/{id}/move` with `If-Match` | body `{"parent": id or null}` | 200, the node without its body, the new `ETag` |
| `POST /v1/nodes/{id}/move-children` with `If-Match` | body `{"parent": id or null}`; moves up to 1,000 of the node's children | 200, `{"moved": N, "left": M}` |
| `GET /v1/nodes?parent=` | the children of a node, or `null` for the top level | a page |

- Every node in an answer gains `"parent"`, an id or `null`, after `"state"`.
- A move's body is one JSON object with the one member, at most 16 KiB, read
  only after the key is good (`db-write-with-body-as`).
- `parent` in a replace's JSON is a 400, as any member a replace does not know.
- A move to the parent a node already has is a move: a new revision.
- `?parent=` of a node that is missing, purged or another account's is a 404.
  With no `?parent=` the list is flat, as today.

### What can hold what, and the checks on a new parent

Pure, in `(techo nodes)`:

- `may-hold? : String String -> Boolean`, a parent's kind and a child's.
- `depth-cap` is 64.
- `parent-verdict`, from plain facts the job read. The first that applies:

| # | Fact | Verdict | Answer |
|---|---|---|---|
| 1 | the new parent is `null` | `ok` | |
| 2 | no such node of this account, or purged | `missing` | 409 `invalid_parent` |
| 3 | it is trashed | `trashed` | 409 `invalid_parent` |
| 4 | its kind may not hold the node's | `wrong-kind` | 409 `invalid_parent` |
| 5 | it is the node, or the node is among its ancestors | `loop` | 409 `would_loop` |
| 6 | it has more than 63 ancestors | `too-deep` | 409 `invalid_parent` |
| 7 | otherwise | `ok` | |

- **A missing parent and another account's get one answer,** so a parent's id
  tells nothing.
- The job reads the new parent's head and its ancestors, at most 65 ids: enough
  to tell "more than 64" from "64". One walk serves the loop and the depth.
- **The cap is on the new parent, not on what is moved under it.** A subtree
  moved under a deep parent can reach past 64. Nothing can then be made or moved
  under its deep nodes. Every walk stays bounded, which is the point.

### How the tables meet

The lifecycle's table gains an event, `move`: allowed for `active` and
`archived`, refused for `trashed`. `node-command` gains the facts it needs:

1. Before the job: the id, the precondition, the body's shape. 400, 428, 413.
2. The key: 401.
3. Found: `none` is 404, `differ` is 412. A create on an id in use is 412.
4. The node's state: 409 `wrong_state`.
5. The new parent's verdict: 409 `invalid_parent` or `would_loop`.
6. A purge of a node with children: 409 `has_children`.

- A create with a parent: 412 before the parent's verdict.
- A purge sets the purged row's `parent` to null, so no row's parent is ever a
  purged row, and a purged child never blocks its old parent's purge.
- "Children" in rule 6 are rows that are not purged, trashed ones too.

### The bulk move

`POST /v1/nodes/{id}/move-children` moves the node's direct children to another
parent.

- `If-Match` is the **node's** revision. Its revision does not change: a node's
  children are no part of it.
- The node may be in any state but purged: emptying a trashed Project is what
  this is for.
- The new parent is checked as a move's, with the node as the one to keep out of
  its ancestors: the new parent may not be the node or under it.
- Up to 1,000 children, in id order. Each that moves is bumped, with a change
  row `move`, and no snapshot.
- **A child stays where it is** when it is trashed (T8), or its kind may not go
  in the new parent. `left` counts the children still there afterwards.
- A client calls it until `moved` is 0. `left` above 0 then means children that
  must be dealt with one by one.
- **The children are moved without their own `If-Match`.** It is the one write
  that is. A move loses no content.

### Migration 5, "a node's parent"

```sql
ALTER TABLE nodes ADD COLUMN parent BLOB REFERENCES nodes(id)
  CHECK (parent IS NULL OR length(parent) = 16);
CREATE INDEX nodes_parent ON nodes(owner, parent, id);
```

- Two statements. Every node there is has no parent.
- `shipped-objects` becomes 15.
- `parent` sits behind `props` and `state`. Slice 6 decides whether props may
  grow large (traps.md).

### `(techo node-store)`

- The Node record gains `parent` (`node-parent : Node -> (U Bytevector #f)`).
- `node-head` answers `(revision kind state parent)`.
- `ancestors : Tx Bytevector Bytevector Natural -> (Listof Bytevector)`: owner,
  id, n; the ids above the node, nearest first, at most n.
- `has-children? : Tx Bytevector Bytevector -> Boolean`.
- `children-heads : Tx Bytevector Bytevector Natural -> (Listof (List Bytevector
  Natural String String))`: owner, parent, n; id, revision, kind, state of up to
  n children that are not purged, in id order.
- `count-children : Tx Bytevector Bytevector -> Natural`.
- `nodes-page` takes a parent filter: `'any`, `#f` for the top level, or an id.
- `insert-node!` takes the parent.
- `move-node! : Tx Bytevector Bytevector Natural (U Bytevector #f) Natural ->
  Node`: id, owner, expected revision, the new parent, now. As
  `set-node-state!`: no snapshot, one change row, raises when no row changed.
- `purge-node!` also sets `parent` to null.
- Every statement in `node-store-statements`. Each recursive one has its plan
  held by a test.

## What must hold, and what would catch a break

| # | What holds | A mutant that must be caught |
|---|---|---|
| P1 | The nodes of an account are a forest: from every node a walk up ends at a root | the loop check left out |
| P2 | Every edge obeys `may-hold?`: the parent is a Project, or a Journal holding a Note | the kind not checked on a move |
| P3 | A parent is a node of the same account and is not purged | the owner left out of the parent's lookup |
| P4 | A move bumps the revision by one, appends one change row `move`, writes no snapshot, and changes nothing else of the node | a snapshot written |
| P5 | A refused move changes nothing | the check after the write |
| P6 | Stale is 412 before any 409; the state before the parent | the parent checked first |
| P7 | Nothing is made in or moved into a trashed node; a trashed node is not moved | the parent's state not read |
| P8 | A purged row has no parent and no children | `parent` left at a purge |
| P9 | A purge of a node with children changes nothing | `has-children?` counting only active ones |
| P10 | No walk reads more than 65 rows | the cap left out of the statement |
| P11 | The bulk move moves only direct children, at most 1,000, each as P4; `moved` and `left` are true counts | a grandchild moved |
| P12 | Another account's node as the parent, and a missing one, get the same answer, byte for byte | a 404 for one |
| P13 | The list by parent shows each child once, in its state, and the flat list is as it was | the parent filter ignored |
| P14 | Slice 4's and 4b's invariants still hold | (the model's own) |

## How it is checked

- **The pure parts:** `may-hold?` over all 25 pairs; `parent-verdict` over every
  combination of its facts; `node-command`'s grid, extended.
- **The store:** against a real file, with trees built for it. The plan of each
  recursive statement is held, and a walk on a chain of 1,000 reads 65 rows.
- **The routes,** and **the model:** the model holds the forest. Its generator
  aims moves at descendants, at trashed and other accounts' parents, at the
  depth cap, and bulk moves at mixed children. After every request it checks P1,
  P2, P3 and P8 on the whole database.
- **Integration:** the routes against the running server.
- **Migrations:** a version 4 file with nodes migrates, and each node is at the
  top level.

## The work

0. **The records that bind the build** (me, in this plan's commit, once the
   plan is reviewed): ADR-0002, ADR-0003, ADR-0004, ADR-0007, the constraints.
1. **Migration 5 and the store** (Sonnet).
2. **The pure parts** (Opus): `may-hold?`, `parent-verdict`, the lifecycle's
   `move`, `node-command`, the bodies' and the query's parsing, the three codes.
   Beside task 1.
3. **The routes** (Opus). After 1 and 2.
4. **The model** (Opus) and **the integration tests** (Sonnet), side by side.
5. **The rest of the records** (me): the API guide with T6 said plainly, the
   changelog, the schema, the ledger.
6. **A read-only adversarial review of the build** (Opus), then its fixes.

Before any of it: **a read-only review of this plan** (Opus).

## Not in this slice

- Links (5b).
- A bulk purge of a subtree (T7): it cannot be undone and holds the writer
  without bound. Its own slice, with measured limits, if clients need it.
- "Inherit on read" for trashed parents (T6).
- A Journal entry's timestamp (slice 6).
- An order among siblings: the server keeps none (ADR-0003).

## The review of this plan (Opus, 2026-11-26)

Read-only, with probes under `build/review-5a/` and a model of the plan's rules
(`forest.py`). Five blockers. I reran the walk's probe; the rest I read.

### Blockers, and what they change

1. **The walk up is fast only when written one way.** With the cap in, a walk
   written `FROM up JOIN nodes n ON n.id = up.id WHERE n.owner = ?` took 375 ms
   at any depth on the probe's tree: each step read every node of the owner
   (`build/review-5a/walk.sps`, rerun). My probe's text was fast by the luck of
   one extra term. **So:** every recursive statement is written
   `FROM <cte> CROSS JOIN nodes n WHERE n.id = <cte>.id ...`, and a test holds
   each plan: the step is `SCAN up` then a `SEARCH` of `nodes` by `id`, and no
   line names `nodes_parent (owner=?)` alone. P10's mutant cannot show this:
   the cap is in and 64 ids come back either way.
2. **The bulk move could answer `moved 0` with movable children left.** It took
   the first 1,000 children by id, trashed ones too: 1,000 trashed and 5 active
   after them moved none. **So:** it selects only children that can move (state
   `active` or `archived`, a kind the new parent holds). `left` still counts
   every child afterwards.
3. **The bulk move had no place in the tables.** **So:**
   - the lifecycle's table gains two events, `move` (refused when trashed) and
     `move-children` (allowed in all three states);
   - `child-moves? : Symbol String (U String #f) -> Boolean`, pure: the child's
     state, its kind, the new parent's kind (`#f` for the top level);
   - for the bulk move the kind rule is not asked of the node. A new parent
     whose kind holds nothing is `invalid_parent`;
   - `node-command` takes the verdict and whether there are children, for every
     event (below).
4. **Migration 5 breaks tests no task owned.** Task 1 owns, by name:
   `tests/test-integration.sps`' `make-ahead!` (it writes version 5, which
   becomes current: it must write `latest + 1`) and its `shipped-objects`;
   `tests/test-db.sps`' migration 4 test and `shipped-objects`;
   `tests/test-migrations.sps`' wording; `tests/shipped-migrations.scm`.
5. **P14 cannot hold as written.** The model's laws for an accepted write expect
   the node bumped, one change row, and no other row touched. A bulk move
   leaves the node and changes up to 1,000 others. Restated:
   - H1, H4: every change row belongs to one node's bump; a bulk move appends
     one a child moved, in id order, and none for the node.
   - H14: a bulk move's answer has no `ETag`.
   - H18': each node is listed once within its state and its parent.
   - G7: nine routes refuse another account's node.
   - P5's mutant is "the refusal returned, not raised"; P10's is held by item 1's
     plan test and a 2-cycle made by hand, which the walk must leave in 64 steps.

### The interface, pinned

- A state is a symbol in `(techo nodes)` and a string in the store. A kind is a
  string. An id is a bytevector.
- `ancestors : Tx Bytevector Bytevector Natural -> (Listof Bytevector)`: owner,
  id, n. The ids above the node, nearest first, at most n. `'()` for a root or a
  node not found. Called with `depth-cap`.
- **A parent may have at most 63 ancestors** (`depth-cap` is 64): it is too deep
  exactly when `ancestors` answers 64 ids. Tested at 63 and 64. This is the one
  statement of the depth.
- `parent-verdict : (U Bytevector #f) (U (List String Symbol) #f) (Listof
  Bytevector) Bytevector (U String #f) -> Verdict`: the new parent; its kind and
  state as found, `#f` for none; its ancestors; the id to keep out; the kind
  going in, `#f` for a bulk move.
- **The verdict's order, changed:** `ok` for null; `missing`; `trashed`; `loop`;
  `wrong-kind`; `too-deep`. The loop now comes before the kind, so a node moved
  under itself is `would_loop` whatever its kind.
- `node-command : Found (U Symbol #f) Symbol Verdict Boolean -> (values Command
  (U Symbol #f))`. The verdict is `ok` for an event with no parent; the boolean
  is whether the node has children, `#f` for every event but a purge. New
  commands: `move`, `move-children`, `refuse-invalid-parent`,
  `refuse-would-loop`, `refuse-has-children`. A create takes the verdict too.
- `children-heads` answers the id and revision of only the children that are
  `active` or `archived`, and takes the kind the new parent holds: `'any`, or one
  kind, which today is `"note"`. Two statements, both in the list. *(Corrected
  at the build: first written as a list of kinds.)*
- `has-children?` and `count-children` have no `state` term: a purged row has
  no parent, so the index alone answers.
- `move-node!`'s `UPDATE` has `AND state IN ('active','archived')`.
- The top level in the store is `parent IS ?`: `parent = ?` with a null finds
  nothing.
- The list's parser answers what `nodes-page` takes: `'any`, `#f`, or an id.

### Answers the plan lacked, now given

| Case | Answer |
|---|---|
| The order of a move's checks | as the `PUT`'s: the key's shape 401, the id 400, the precondition 428 or 400, the key 401, then 415, 413, `invalid_json`, the body's shape 400, then the job. The plan's list read the body before the key |
| No JSON `Content-Type` on a move | 415 |
| `If-None-Match` on a move or a bulk move | 400 |
| `{}`, `{"parent": 5}`, a v4 id, a member twice, another member | 400. `{}` parses as `'()`, and JSON null as the symbol `null`: a `null?` test would take `{}` for the top level |
| `"parent": null` on a create | the top level, as no `parent` |
| A loop more than 64 above the new parent | `invalid_parent` (too deep), not `would_loop`. Documented |
| A move to the parent it has, when that parent is too deep | `invalid_parent` |
| A bulk move whose new parent is under a child that stays | `would_loop`, though none would form. Documented |
| A bulk move's answer | no `ETag` |
| The order of a bulk move's change rows | by child id |
| `?parent=` | exactly `null`, or a v7 id. Empty, another case, twice: 400. A Note as the parent: 200 and an empty page. A trashed parent lists its children |
| `?parent=X` and state | active children by default. `left` and `has_children` count every state: the guide tells a client to ask the other two states as well |

### What the plan said that was wrong

- **"The depth cap bounds it", of T6's way out.** Depth is not bounded: two
  subtree moves made a node 128 deep in the model, and more moves go further.
  Each walk is bounded, because each has its own cap. "Inherit on read" would
  need its own cap too, and item 1's shape.
- **The bulk move's `If-Match` guards nothing it changes.** A retry after a lost
  answer runs again (and moves nothing more). A child moved in since the client
  looked goes along. No content is lost, but every moved child's offline edit
  then meets a 412. Kept, for the 428 and the 404 it gives; documented.

### Measured

- Migration 5 through `migrate!` on a version 4 file with nodes: applied, every
  parent null, no foreign key violation, 15 objects.
- **The foreign key holds none of the rules:** it took a purged row, a node as
  its own parent and a 2-cycle. Only the verdict keeps P1, P3 and P8.
- A bulk move of 1,000 children, a statement each, on a file of 112,010 nodes:
  the writer held 44 to 49 ms (not rerun by me).
- A write to a parent with 10,000 children costs what any does. No index on
  `parent` alone.
- The rules, modelled: 360 random runs, always a forest, no row at a purged
  row, no edge against `may-hold?`.

### The work, as reviewed

This replaces "The work" above.

0. **The records that bind the build** (me, in this plan's commit).
1. **Migration 5 and the store** (Sonnet): `migrations.sls`, `node-store.sls`,
   `test-node-store.sps`, and the files of blocker 4. It may make the minimal
   call-site changes in `node-routes.sls`.
2. **The pure parts** (Opus): `nodes.sls`, `test-nodes.sps`, `errors.sls`,
   `test-errors.sps`, `lifecycle.md` and its document's prose. Beside task 1.
3. **The routes** (Opus): `node-routes.sls`, `test-node-routes.sps`,
   `test-app.sps`. After 1 and 2.
4. **The model** (Opus) with the laws restated, and **the integration tests**
   (Sonnet). The generator purges parents whose only children are trashed.
5. **The rest of the records** (me): the API guide, `README.org`, the changelog,
   the schema, the ledger.
6. **A read-only adversarial review of the build** (Opus), then its fixes.

### What must hold, added

- P15: a replace or a restore keeps the parent.
- P16: a bulk move never changes the node's own row.
- P17: each verdict maps to its own code.
- P18: the boundary holds at 63 and 64 ancestors.

### Handed on

- **Slice 5b:** whether links block a purge, as children do.
- **Slice 6:** a Note in a Journal needs a timestamp (the outline). Whether a
  move into a Journal checks props, and what of Notes moved in before.
- **Slice 7:** a search within a subtree caps its own walk.
- **Slice 8:** a `move` row names neither parent, and history keeps none. One
  bulk move writes up to 1,000 rows.

## The review of the build (Opus, 2026-11-26)

Read-only, with probes and 29 mutants of its own under
`build/review-5a-build/`. **No broken forest, wrong write, leak or 500 found,
and no mutant survived.** It raced real requests (two nodes each moved under the
other, 40 at a time; a bulk move against a move of its target; a purge against
a create under the node): one winner each, and the forest whole. A missing id,
another account's and a purged one gave the same bytes on every new path, and
the same time. Migration 5 ran on a file made by the code before it.

**Measured, through the server, on 141,213 nodes**

| Request | Time |
|---|---|
| A move under 1, 63, 64 and 9,999 ancestors | 1 to 2 ms (5 cold) |
| A bulk move of 1,000 | 47 to 51 ms |
| A bulk move, 5 movable behind 20,000 trashed | 6 ms |
| A purge refused for 20,000 children | 0 ms |
| `?parent=` of 50,100 children: active | 1 to 2 ms |
| The same, a state held by few | 5 to 7 ms |

No statement scans `nodes`.

**What it found, and what was done**

| Finding | Done |
|---|---|
| Which children a bulk move takes is said twice, in `child-moves?` and in `children-heads`' SQL, and no test tied them | a store test holds them equal over every state, kind and parent |
| The owner in `ancestors`' step was held only by the statement's text | a test with one account's node under another's |
| A bulk move's handler had no arm for a state's refusal: a later row in the table would be a 500 | each handler raises every refusal its events can get |
| No route test moved an archived node's children, nor met a parent both trashed and a loop | added |
| No test held that a page of children needs no sort | added |
| The guide: "parent's parent" for any folder above; `left` while `moved` is 1,000; how to deal with what is left; a loop past 64 levels; nothing can be made 64 levels down; a retry of either move | corrected |

**Two holes in the decisions, left as decided and documented**

- **T8 looks at the folder named, not at those above it.** A folder that is
  active but sits inside a trashed one takes new nodes. It follows from T6:
  trash touches one node. "Inherit on read" would close it.
- **T5's cap is on the new parent only, so depth has no bound.** One subtree
  move left a node 125 deep. A folder 64 levels down can hold nothing, and its
  refusal reads as any other `invalid_parent`. "Inherit on read" would need a
  cap of its own, and past that cap it would be wrong, not slow.

**Left as they are**

- The 404 of `?parent=` is decided where the list is read, as the revisions
  list's is: it is a read's "no such node", not a command.
- `child-moves?` is called by no handler. It is the rule in one place, and the
  test above holds the SQL to it.

**Handed on, added**

- **Slice 6:** a kind that holds some kinds but not all would need more than
  `child-kind-filter`'s one kind. Notes moved into a Journal before slice 6
  have no timestamp.
- **Slice 7:** nodes inside a trashed folder show in a search as active.
- **Slice 8:** a `move` row names no parent, so a client reads each moved node:
  up to 1,000 a bulk move. Neither parent's revision shows that its children
  changed. The feed could give the parent as it is when read.

