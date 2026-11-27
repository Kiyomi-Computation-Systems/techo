# Slice 5b: links

Date: 2026-11-26
Status: the owner decided K1 to K8 on 2026-11-26 (below). Reviewed (the review
section, at the end): where it and the text above disagree, the review wins.
The records are amended. Built, and the build reviewed (the last section).
Records: ADR-0002 (the API), ADR-0003 (nodes), ADR-0004 (revisions), ADR-0005
(the server never reads a body), ADR-0007 (machines), ADR-0012 (migrations),
ADR-0013 (the doorway). Read [global-constraints.md](global-constraints.md)
first, then the plans of slices [4](2026-11-25-slice-4-nodes.md),
[4b](2026-11-25-slice-4b-node-lifecycle.md) and
[5a](2026-11-26-slice-5a-tree.md): this slice builds on all three.

## What this slice is for

After 5a a node lives in one folder. This slice lets a node point at any other:

- say "this node mentions, is related to, or blocks that one";
- list what a node points at;
- list what points at a node (its backlinks);
- take a link away.

The server never reads a body (ADR-0005), so it finds no links itself. A client
makes each one.

## What the probes found (2026-11-26)

`build/probe-5b/p.sps`, `p2.sps` and `p3.sps`, on a real file opened by
`open-techo-db`, in WAL, `secure_delete` on: 121,112 nodes of one account,
726,656 links, one hub with 121,116 backlinks.

| Question | Answer |
|---|---|
| A page of 51 links with the other node's columns, either direction | about 0.5 ms, from the start or the middle (the review's; mine read 6 rows and fewer columns) |
| Make a link, a commit each | about 1 ms |
| Tell "made" from "already there" | `INSERT OR IGNORE`, then `changes()` is 1 or 0 |
| A link to an id that is no node | the foreign key raises: the job must look first |
| Count the hub's backlinks | 5 ms |
| A purge's delete of every link of the hub, both ways | 213 ms of work, 196 ms to commit, a `-wal` of 64 MB |
| A backlink page of only `active` sources, when 121,110 trashed ones sort first | 99 ms |

**Two traps, both seen** (`p2.sps`, `p3.sps`):

- **A delete by target ignores `links_target`.** `DELETE FROM links WHERE
  owner = ? AND target = ?` searched the primary key by owner alone: 28 ms for
  a node with five backlinks. With `INDEXED BY links_target`, under 0.1 ms.
  `ANALYZE` also mends it, but nothing runs `ANALYZE`.
- **Backlinks of one type, joined to `nodes`, pick the primary key too**
  (`owner = ? AND source > ?`): 28 ms a page, 0.05 ms with the index named. The
  same statement without the join picks the right index.

So: every statement that reads or deletes by target names `links_target`, and
a test holds each plan.

## Decisions (the owner's, 2026-11-26)

| # | Question | Decided |
|---|---|---|
| K1 | Link types | A fixed list on the server: `related`, `mentions`, `blocks`. The code's list is the truth; a new type is a release, not a migration |
| K2 | Shape | Directed, stored once, read from either end. One link per source, type and target. No node links to itself |
| K3 | Routes | `PUT` and `DELETE /v1/nodes/{id}/links/{type}/{target}`, no request body. `GET /v1/nodes/{id}/links?direction=out\|in&type=`, paged. An item carries the other node |
| K4 | Revision | A link bumps neither node's revision, needs no `If-Match`, writes no snapshot |
| K5 | The feed | Each link made or removed writes a change row on the source, `link` or `unlink`. It names no target; slice 8 decides what the feed says |
| K6 | States | No link is made to or from a trashed node (409 `wrong_state`). Removing one is always allowed. Trash and archive leave links alone; the list shows them with the other node's state |
| K7 | Purge | A purge deletes the node's links, both ways, in its own transaction. Links do not block a purge. No cap on a node's links |
| K8 | Missing ends | A source or a target that is missing, purged or another account's is a 404. Removing a link that is not there is a 404 |

**K4's reason.** A link is there or it is not: two devices cannot conflict over
one. A bump would make an offline edit of a body meet a 412 because a link was
made elsewhere, and a purge of the hub would bump 121,116 nodes. **Its cost:**
a restore of an old revision brings back no old links, and a node's `ETag` says
nothing of its links.

**K6's reason for no filter.** The list could hide links to trashed nodes, but
the worst page then costs 99 ms. The client hides what it wants, as with what
is inside a trashed folder (5a's T6).

**K7's cost.** A purge of a node with 121,116 links holds the writer 0.4 s and
grows the `-wal` to 64 MB, which the next commit after a checkpoint cuts to
16 MiB. The same kind of cost as a purge of a large history (4b's L11).

## The design

### Routes

| Route | Does | Answer |
|---|---|---|
| `PUT /v1/nodes/{id}/links/{type}/{target}` | makes the link from `{id}` to `{target}` | 201 and the link when made; 200 and the link when it was there |
| `DELETE /v1/nodes/{id}/links/{type}/{target}` | removes it | 204 |
| `GET /v1/nodes/{id}/links` | a page of the node's links | 200, a page |

- **A link in an answer** is `{"source": id, "type": name, "target": id,
  "created": ms}`. `created` is when it was first made: a second `PUT` changes
  nothing and writes no change row.
- **The list's query:** `direction` is `out` (the default) or `in`; `type` is
  one of the three, or absent for all; `limit` and `after` as every list.
- **A page's item** is `{"type": name, "created": ms, "node": N}`, where N is
  the node at the other end, without its body, as the nodes list gives one. A
  page is ordered by type, then by the other node's id. `next` is
  `<type>:<id>`, and `after` takes it back.
- The list's node may be in any state but purged: a trashed node's links can
  be read.
- No request body is read on any of the three. No `ETag` is answered.
- Each handler is one call of `db-write-as` or `db-read-as`.

### The checks, in order

Before the job, on the loop's thread:

1. the key's shape: 401;
2. the path's ids, the type, the query: 400. A type not in the list is a 400.
   A source that is its own target is a 400;
3. `If-Match` or `If-None-Match` on any of the three: 400. A link takes no
   precondition, and a client that sent one would think it guarded.

In the job, after the key (401):

| # | Fact | `PUT` | `DELETE` |
|---|---|---|---|
| 1 | the source is no node of the account, or purged | 404 | 404 |
| 2 | the target is no node of the account, or purged | 404 | (not read) |
| 3 | the source is trashed | 409 `wrong_state` | goes on |
| 4 | the target is trashed | 409 `wrong_state` | (not read) |
| 5 | the link is there | 200, nothing written | removed: 204 |
| 6 | the link is not there | made: 201 | 404 |

- A missing node and another account's get one answer, byte for byte, at
  either end.
- A `DELETE` does not read the target: a link's ends are always live nodes of
  the account (below), so "no such link" covers a bad target.

### The tables

- The lifecycle's table gains two events: `link`, allowed for `active` and
  `archived` and refused for `trashed`; and `unlink`, allowed in all three.
- `link-command`, pure, answers from the two ends' states and the event, by
  `lifecycle-step` on each end, the source first:
  `link-command : (U Symbol #f) (U Symbol #f) Symbol -> Command`, the source's
  state (`#f` for none), the target's (`#f` for none; not asked for `unlink`),
  the event. Commands: `link`, `unlink`, `refuse-404`, `refuse-wrong-state`.
- Whether the link was there is the store's answer, not the table's: the
  insert and the delete each say whether a row changed.

### Pure, in a new `(techo links)`

- `link-types : (Listof String)`, the three.
- `parse-link-type : String -> (U String 'invalid)`.
- `parse-direction : (U String #f) -> (U 'out 'in 'invalid)`.
- `parse-link-cursor : String -> (U (Pair String Bytevector) 'invalid)` and
  `link-cursor : String Bytevector -> String`.
- `link-command`, above.
- `(techo nodes)` gains only the two events, their ops (`link`, `unlink`) and
  the generated `lifecycle.md`.

### Migration 6, "links"

```sql
CREATE TABLE links (
  owner   BLOB    NOT NULL REFERENCES accounts(id),
  source  BLOB    NOT NULL REFERENCES nodes(id),
  target  BLOB    NOT NULL REFERENCES nodes(id),
  type    TEXT    NOT NULL,
  created INTEGER NOT NULL,
  PRIMARY KEY (owner, source, type, target)
) STRICT, WITHOUT ROWID;
CREATE INDEX links_target ON links(owner, target, type, source);
```

- Two statements. `type` has no `CHECK`, as `changes.op` has none: SQLite
  cannot change one.
- A node's row is never deleted, so the foreign keys never fire on a node's
  side. They refuse a link to an id that is no row; they do not hold the
  owner, the state or K2. Only the code does.

### A new `(techo link-store)`

All its SQL in `link-store-statements`, held by the tests that hold
`node-store-statements`: every statement names the owner; none is written in
place.

- `insert-link! : Tx Bytevector Bytevector String Bytevector Natural ->
  Boolean`: owner, source, type, target, now. `#t` when a row was made. Then,
  and only then, a change row `link` on the source at its present revision.
- `delete-link! : Tx Bytevector Bytevector String Bytevector Natural ->
  Boolean`: the same, with a change row `unlink`.
- `link-of : Tx Bytevector Bytevector String Bytevector -> (U Link #f)`.
- `links-page : Tx Bytevector Bytevector Symbol (U String #f) (U (Pair String
  Bytevector) #f) Natural -> (Listof (List String Natural Node))`: owner, node,
  direction, type or `#f`, cursor, n. Four statements (two directions, typed
  or not), each joined to `nodes` for the other end, no body selected.
- `delete-links-of! : Tx Bytevector Bytevector -> Natural`: owner, node; both
  directions. No change rows: the purge's own row is the tombstone.
- `purge-node!` in `(techo node-store)` calls `delete-links-of!` itself, so no
  caller can purge and leave links.
- Every statement by target is written `INDEXED BY links_target`, and a test
  holds its plan. A test holds the plan of every page statement.

## What must hold, and what would catch a break

| # | What holds | A mutant that must be caught |
|---|---|---|
| Q1 | Both ends of every link are nodes of the link's owner, and neither is purged | the owner left out of the target's lookup |
| Q2 | No link has one node at both ends; every type is in the list | the self check left out |
| Q3 | At most one link per source, type and target; a second `PUT` answers 200 and writes nothing | a change row on the second `PUT` |
| Q4 | A link made or removed changes no node's row: no revision, no `updated`, no snapshot | the source bumped |
| Q5 | Each link made or removed appends one change row, `link` or `unlink`, on the source at its present revision | the row on the target |
| Q6 | No link is made when either end is trashed; one is removed whatever the states | only the source's state read |
| Q7 | A refused request changes nothing | the insert before the check |
| Q8 | After a purge the node has no link either way, and no other node's row changed | only outgoing links deleted |
| Q9 | Trash, archive, a move, a replace and a restore leave every link as it was | links deleted at a trash |
| Q10 | Each list shows every link of the node in that direction once, across its pages, with the other node as it is now; `type` narrows it | `in` answering `out` |
| Q11 | Another account's node at either end, and a missing one, get the same answer, byte for byte | a 409 for one |
| Q12 | No statement by target, and no page, reads more of `links` than it answers | `INDEXED BY` left out |
| Q13 | The invariants of slices 4, 4b and 5a still hold | (the model's own) |

## How it is checked

- **The pure parts:** `link-command` over every pair of states and both
  events; the parsers over what they take and refuse; the lifecycle's table,
  exhaustively, with its two new columns.
- **The store:** against a real file. Each statement's plan is held.
- **The routes:** each row of the checks' table, each order between two rows.
- **The model:** it keeps a set of links beside its nodes. Its generator makes
  and removes links, aims them at trashed, purged and other accounts' nodes,
  at the node itself, and purges linked nodes. After every request it checks
  Q1, Q2 and Q8 on the whole database.
- **Integration:** the three routes against the running server.
- **Migrations:** a version 5 file with nodes migrates, and has no links.

## The work

0. **The records that bind the build** (me, in this plan's commit, once the
   plan is reviewed): ADR-0002, ADR-0003, ADR-0004, ADR-0007, the constraints,
   the two traps.
1. **Migration 6 and the stores** (Sonnet): `migrations.sls`, a new
   `link-store.sls` and `test-link-store.sps`, `purge-node!` in
   `node-store.sls` and its tests, and the files a migration touches:
   `tests/shipped-migrations.scm`, `shipped-objects` in `test-db.sps` and
   `test-integration.sps`, `test-migrations.sps`' wording.
2. **The pure parts** (Opus): a new `links.sls` and `test-links.sps`; the two
   events in `nodes.sls`, `test-nodes.sps`, `lifecycle.md`. Beside task 1.
3. **The routes** (Opus): a new `link-routes.sls` and `test-link-routes.sps`,
   its line in `app.sls`, `test-app.sps`. After 1 and 2.
4. **The model** (Opus) and **the integration tests** (Sonnet), side by side.
5. **The rest of the records** (me): the API guide, `README.org`, the
   changelog, the schema, `running.md`'s disk section, the ledger.
6. **A read-only adversarial review of the build** (Opus), then its fixes.

Before any of it: **a read-only review of this plan** (Opus).

## Not in this slice

- What the feed says of a link (slice 8).
- A link's own data: a note on it, an order among a node's links.
- Finding links in a body: the server reads none (ADR-0005).
- A count of a node's links in the node's answer.
- A filter of the list by the other node's state or kind.
- Bulk making or removing.

## The review of this plan (Opus, 2026-11-26)

Read-only, with probes under `build/review-5b/`. Six blockers. I reran the
probes for 1, 3 and 4 and read the lines cited for 2, 5 and 6.

### Blockers, and what they change

1. **The store split was an import cycle.** `link-store` needs `node-store`'s
   `insert-change!` and its Node reader; `purge-node!` would need
   `link-store`. Chez refuses it (`build/review-5b/cycle/`, rerun). And a
   separate routes library would need `node->json`, `page-answer` and `refuse`,
   all inside `node-routes`. **So: no new store or routes library.** The link
   SQL joins `node-store-statements`, the store's procedures join
   `(techo node-store)`, the three handlers join `(techo node-routes)`. Only
   the pure `(techo links)` is new. Every test that holds the statements then
   holds the new ones, and the import tests in `test-app.sps` stand.
2. **Q13 cannot hold as written:** a change row with no bump breaks the
   model's laws. Restated:
   - **G3':** a node's rows other than `link` and `unlink` run 1..n. A `link`
     or `unlink` row carries the revision of the newest other row before it,
     and keeps the state.
   - **H15'':** `updated` is the time of the newest row that is neither.
   - **H1':** an accepted link or unlink changes no node row and no snapshot,
     makes or removes that one link row, and adds one change row: the asker,
     the next seq, the source, the source's revision, the op, now.
   - **H4'':** a 200 `PUT`, a 404 `DELETE` and every refusal change nothing
     but the asking key's `last_used`.
   - **G7':** no request changes another account's links.
   - **G6':** a purge removes every link of the node both ways, writes only
     its own change row, and changes no other row of `nodes`.
   - **H14':** no link answer carries an `ETag`.
   - The model's `reset!` deletes links before nodes: the foreign key refuses
     the other order.
3. **The handler decided the answer from the store's boolean, and
   `INSERT OR IGNORE` hides a real error.** A null in a `NOT NULL` column
   answered "already there" (`build/review-5b/ignore.sps`, rerun). **So:** the
   job reads `link-of` first, `link-command` takes whether the link is there
   as a fact, and its commands name every answer: `link`, `keep`, `unlink`,
   `refuse-404`, `refuse-wrong-state`. `insert-link!` is a plain `INSERT` and
   `delete-link!` a plain `DELETE`; each raises, with ids only, unless one row
   changed.
4. **A typed page must compare the id alone.** With `l.type = ?` and the
   cursor's row value both in, the range leaves the search: 39 ms a page from
   the middle of 181,667 backlinks, against 0.47 ms (`plans.out`). **So:** a
   typed statement is `l.type = ? AND <other end> > ?`; an `after` whose type
   is not `?type=` is a 400; and each plan test holds the `SEARCH` line whole.
5. **`link` and `unlink` must not join `lifecycle-events`:** `node-command`
   takes every member for a state change and would raise. They go in a new
   `link-events`, appended to `table-events`; `event-op` takes them by name;
   `node-command` answers "cannot happen" for both, and a test holds that.
6. **Files no task owned,** now owned (the work, below). `shipped-objects`
   becomes 17: a `WITHOUT ROWID` table's key has no row of its own.

### The interface, pinned

**`(techo links)`**, pure; imports `(rnrs)` and `(techo nodes)`.

- `link-types : (Listof String)`. A page sorts by the type's name: `blocks`,
  `mentions`, `related`.
- `parse-link-type : Any -> (U String 'invalid)`. Exact case.
- `parse-type-param : Any -> (U String #f 'invalid)`. `#f` for not given.
- `parse-direction : Any -> (U 'out 'in 'invalid)`. `#f` is `out`.
- `parse-link-cursor : Any -> (U (Pair String Bytevector) 'invalid)`: split at
  the first colon; a type of the list; a version 7 id; refused past 45
  characters before it is read.
- `link-cursor : String Bytevector -> String`.
- `link-command : (U Symbol #f) (U Symbol #f) Symbol Boolean -> Symbol`: the
  source's state, the target's (`#f` for none; not looked at for `unlink`),
  the event, whether the link is there. The first that applies:

| # | Fact | Command |
|---|---|---|
| 1 | no source | `refuse-404` |
| 2 | `link`, and no target | `refuse-404` |
| 3 | the link is there | `keep` for `link`, `unlink` for `unlink` |
| 4 | `unlink`, and it is not there | `refuse-404` |
| 5 | `lifecycle-step` refuses `link` for the source, or for the target | `refuse-wrong-state` |
| 6 | otherwise | `link` |

  Both 404s come before any 409. It raises for any other event or state.

**`(techo nodes)`:** six rows more (`link` allowed for `active` and `archived`,
refused for `trashed`; `unlink` allowed in all three); two "cannot happen"
cells for `purged`; `link-events`; `table-events` and `event-op` widened.
`lifecycle-events` stays the five, and `node-command` is unchanged.

**`(techo node-store)`:**

- `link-of : Tx Bytevector Bytevector String Bytevector -> (U Natural #f)`:
  owner, source, type, target; the link's `created`.
- `insert-link! : Tx Bytevector Bytevector String Bytevector Natural Natural
  -> Void`: owner, source, type, target, the source's revision as the job
  read it, now. The row, then a change row `link` at that revision.
- `delete-link!`: the same arguments, with `unlink`.
- `links-page : Tx Bytevector Bytevector (U 'out 'in) (U String #f) (U (Pair
  String Bytevector) #f) Natural -> (Listof (List String Natural Node))`.
  Four statements. No cursor starts from `""` and sixteen zero bytes, or from
  the zero bytes alone when typed. The node's columns come first.
- `purge-node!` keeps its signature. Its order: the snapshots; the row's
  `UPDATE` and its `changes()` check; the links by source; the links by
  target; the change row. The deletes come after the check: before it, their
  count would be read for the `UPDATE`'s.

**The four page statements, and the plan line a test holds for each,** on a
fresh file with no `sqlite_stat1`:

| Statement | Where | Its first plan line |
|---|---|---|
| out | `l.source = ? AND (l.type, l.target) > (?, ?) ... ORDER BY l.type, l.target` | `SEARCH l USING PRIMARY KEY (owner=? AND source=? AND (type,target)>(?,?))` |
| out, typed | `l.source = ? AND l.type = ? AND l.target > ? ... ORDER BY l.target` | `SEARCH l USING PRIMARY KEY (owner=? AND source=? AND type=? AND target>?)` |
| in | `links l INDEXED BY links_target ... l.target = ? AND (l.type, l.source) > (?, ?) ... ORDER BY l.type, l.source` | `SEARCH l USING INDEX links_target (owner=? AND target=? AND (type,source)>(?,?))` |
| in, typed | the same, `l.type = ? AND l.source > ? ... ORDER BY l.source` | `SEARCH l USING INDEX links_target (owner=? AND target=? AND type=? AND source>?)` |

- Each is `FROM links l ... CROSS JOIN nodes n WHERE l.owner = ? ... AND n.id =
  <other end> AND n.owner = l.owner AND n.state <> 'purged'`. Its second line
  is `SEARCH n USING INDEX nodes_owner (owner=? AND id=?)`, and no line is a
  temp b-tree.
- **An out statement never names `links_target`:** it then sorts in a temp
  b-tree.

**`(techo node-routes)`:** `(route "/v1/nodes/:id/links" (GET ...))` and
`(route "/v1/nodes/:id/links/:type/:target" (PUT ...) (DELETE ...))`. `link`
is 201 and `keep` 200, each with the link, `keep` with the stored `created`;
`unlink` is 204. The `GET`'s job reads `node-head` first.

### Answers the plan lacked, now given

| Case | Answer |
|---|---|
| `GET` of a node that is missing, purged or another account's | 404, not an empty page |
| `GET` of a trashed or an archived node | 200, its links |
| A body on any of the three | not read: no 400, 413 or 415. The server answers, then closes the connection (read in chez-http-server, not run) |
| `HEAD` on one link; `GET` or `POST` on one link | 405. No route reads one link |
| `direction`, `type`, `after` or `limit` twice, or empty | 400 |
| Another case: `OUT`, `Related` | 400 |
| `after` with a type not `?type=`, a type not in the list, no colon, a v4 id, or text after the id | 400 |
| `after` naming a link that is not there | the page after that place |
| A v4 id at either end | 400 |
| Source and target the same sixteen bytes, on a `PUT` or a `DELETE` | 400 |
| `If-Match` or `If-None-Match` on the `PUT` or the `DELETE` | 400 |
| The same on the `GET` | ignored, as every `GET` does. **This changes the text above** |
| `PUT`, the source trashed and the target missing | 404 |
| **`PUT` again after an end was trashed, the link there** | 200 `keep`: nothing is made, and a retry must not read as a refusal. **This reorders the checks' table above** (the link's being there now comes before the states) |
| `DELETE`, the target purged, missing or another account's | 404; the target is not read |
| `DELETE`, either end trashed, the link there | 204 |
| An other end that is trashed or archived, in a page | listed, with its state |
| A 201's or a 200's headers | no `ETag`, no `Location` |
| A 200 `PUT` | no link row, no change row. The key's `last_used` may move |

### Holes in the decisions, left as decided and to be documented

- **K5:** two change rows of a node can carry one revision. Slice 8's feed must
  not key on node and revision.
- **K5 with K7:** a purge of X removes Y's link to X and writes no row on Y.
  A feed's reader takes a purge to mean "every link of this node is gone".
- **K1:** a type once shipped cannot be dropped by a release alone: its links
  could no longer be named in a path or a cursor.
- **K8:** a `DELETE` retried after a lost 204 answers 404. The guide says that
  means "done".
- **K6 with T6:** a node inside a trashed folder can be linked, as it can be
  written.

### What the plan said that was wrong

- **"A page of 51 outgoing links, 0.04 ms":** that page held 6 links. A full
  page with a Node's columns is about 0.5 ms either way.
- **"`INSERT OR IGNORE`, then `changes()`"** tells made from there only when
  nothing else is wrong (blocker 3).
- **Q3's "writes nothing":** a 200 `PUT` is a write job, so `last_used` can
  move.
- **"The foreign keys never fire":** true of the server; the model's reset
  made them fire.

### Measured by the review

- Migration 6 through `migrate!` on a version 5 file made by the present code,
  with nodes in every state: applied, nothing to do the second time, no
  foreign key violation, 17 objects.
- **The foreign keys hold little:** they took a link to a purged row, a self
  link, the type `Related`, and another account as the owner.
- A purge's deletes for 181,667 backlinks: 386 ms and 199 ms to commit, a
  `-wal` of 70 MB; the next small commit cut it to 16 MiB.
- Both index traps show on a fresh file of five nodes, so a plan test in a
  suite can fail.
- All four statements paged at limits 1, 7, 50 and 100 over 17,305 outgoing
  and 11,015 incoming links: each list whole and in order.

### The work, as reviewed

This replaces "The work" above.

0. **The records that bind the build** (me, in this plan's commit).
1. **Migration 6 and the store** (Sonnet): `migrations.sls`; the link
   statements and procedures and `purge-node!` in `node-store.sls`;
   `test-node-store.sps` (the statement lists too, and a stale purge of a node
   with one link); `tests/shipped-migrations.scm`; `test-db.sps`
   (`shipped-objects` 17, a migration 6 test); `test-integration.sps`'
   `shipped-objects` and `shipped-tables`; `test-migrations.sps` (six
   migrations, "migration 6 is two statements").
2. **The pure parts** (Opus): a new `links.sls` and `test-links.sps`;
   `nodes.sls` as blocker 5 says, `lifecycle-document`'s prose, `lifecycle.md`;
   `test-nodes.sps` (its events, counts, `event-op`, the document's lines,
   `request-events` with the two as "cannot happen"). Beside task 1.
3. **The routes** (Opus): the three handlers in `node-routes.sls`;
   `test-node-routes.sps` (links in its `tables`; a purge of a node linked both
   ways); `test-app.sps` where it lists routes. After 1 and 2.
4. **The model** (Opus): `nodes-model.sls` and `test-nodes-model.sps`, with
   the laws of blocker 2, `reset!`, and floors for `link-command`'s cells.
   Beside it, **the integration tests** (Sonnet): `test-integration.sps`, its
   counts of rows too.
5. **The rest of the records** (me).
6. **A read-only adversarial review of the build** (Opus), then its fixes.

### What must hold, added

- Q14: a page item's node is the nodes list's item for that node, byte for
  byte.
- Q15: `created` is the first `PUT`'s time in every answer (tested with a
  later clock).
- Q16: a 200 `PUT` and every refusal change nothing but `last_used`.
- Q17: a purge writes one change row however many links it removes, and bumps
  no other node.
- Q18: G3' and H15''.
- Q19: `node-command` answers "cannot happen" for `link` and `unlink`, and
  `lifecycle-events` is the five.
- Q20: each page statement's plan is its two lines, with no temp b-tree.
- Q21: an `after` of another type is a 400; paging to the end shows each link
  once, in order, at limits 1 and 100.

**Mutants the first table would have let live:** the typed row value kept; the
purge's deletes before its `changes()` check; `links_target` named on an out
statement; `ORDER BY` dropped; the cursor's type ignored on a typed page; the
target's state asked of an `unlink`; `created` overwritten by a second `PUT`.

### Handed on

- **Slice 8:** the three K5 notes above; a `link` row names no target.
- **Not measured:** where a purge of a node's links meets the 10 s deadline
  (the review guesses 3 to 4 million links).

## The review of the build (Opus, 2026-11-27)

Read-only, with probes and 42 mutants of its own under
`build/review-5b-build/`. **No bug found: no 500, no leak between accounts, no
wrong write, no broken invariant.** It raced real requests in 100 rounds (a
`PUT` against a purge and a trash of either end; five `PUT`s of one link at
once; a `PUT` against a `DELETE`; a `DELETE` against a purge): never two 201s,
no link with a purged end, one change row a link made or removed. A missing
id, another account's and a purged one gave the same 114 bytes and the same
time. Migration 6 ran on a file made by the code before it. The guide's
examples, run, matched field for field.

**Measured, through the server**

| Request | Time |
|---|---|
| A page of 100 of a hub's 121,000 backlinks: start, middle, end; typed or not | 0 to 5 ms |
| A `PUT` or a `DELETE` on the hub | 0 to 3 ms |
| A purge of a node with 110,000 links | 0.2 s; reads beside it 2 to 6 ms |
| A purge of 1,000,000 links | 2.6 s, a `-wal` of 361 MB |
| A purge of 3,000,000 links | 6 s; every write waited 6 s. On a busy machine: a 504 at 10 s, and the purge landed |

No link statement scans.

**What it found, and what was done**

| Finding | Done |
|---|---|
| No test held a link's 204 headers: one with a JSON `Content-Type` passed | a test holds them |
| No test held that a link's time is read once | a test with a clock that steps |
| "No longer purged" was held by text alone on three of the four page statements | the hand-made row's test covers all four |
| A test's name said it planned `insert-link` | renamed |
| K1's "a type once shipped stays" was held by nothing | a test with the shipped types written out |
| The guide: "send the `PUT` to learn whether it is there"; a kept link's 200 with a trashed end not said; `related` reads as two-way | corrected |
| The disk note priced a purge at 180,000 links only | the figures to 3 million, and the 504 |

Of its 42 mutants, 35 were caught. Five that lived are equivalent. Two were
not, and are the first two rows above.

**Holes in the decisions, left as decided and documented**

- **K7, no cap.** A purge of a node with millions of links holds every
  account's writes for seconds, and past 10 s answers 504 though it lands.
  Building 3 million links takes about an hour of requests. A cap on a node's
  links, or a purge in steps, would close it.
- **K1.** Were a type ever dropped, a page ending on one of its links would be
  a 500, and the link could not be removed. The test above holds the rule.
- **K2.** `related` is directed like the rest: a client lists both ways.
- **A link left at a purged node could not be seen through the API** but by a
  `DELETE` of it. Three checks of the tables in the model, and the store's and
  routes' tests, are what hold the purge's deletes.

**Left as they are**

- A dropped `ORDER BY` and `INSERT OR IGNORE` are held by the statements'
  text: no answer shows either.
- A `DELETE` that read its target would answer the same.

**Handed on, added**

- **Slice 8:** as the plan's review said. And a 503 from the queue under five
  `PUT`s at once is a "no", as everywhere.
- **Later:** a cap on a node's links, with K7's numbers.

