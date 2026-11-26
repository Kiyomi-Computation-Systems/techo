# Slice 4b: the node lifecycle

Date: 2026-11-25
Status: the owner accepted L1 to L10 on 2026-11-25 ("i approve L1 - 10"), each as
recommended. Reviewed (the review section, at the end): where it and the text
above it disagree, the review wins. L11, which the review raised, is decided: A ("L11 got with A", 2026-11-26). The
two choices of mine (no body in a state change's answer; 412 before 409) are
accepted too ("your choices are fine"). The records are amended. Not built.
Records: ADR-0002 (the API), ADR-0004 (revisions), ADR-0007 (machines), ADR-0012
(migrations), ADR-0013 (the doorway). Read
[global-constraints.md](global-constraints.md) first, and
[slice 4's plan](2026-11-25-slice-4-nodes.md): this slice builds on its libraries.

## What this slice is for

After slice 4 a note can be made and changed, and never put away. This slice
lets a person:

- archive a node, and bring it back;
- trash a node, and bring it back;
- purge a trashed node, for good, with its history.

Every one is checked with `If-Match`, bumps the revision, and gets the owner's
next sequence number.

## What the probes found (2026-11-25)

The program is `build/probe-4b/p.sps`, on real SQLite through chez-sqlite3.

| Question | Answer |
|---|---|
| Can a node's body be "its newest snapshot's" when the node's revision is ahead? | Yes. The join's subquery `max(revision)` is a search of the primary key's index. 100 lookups: 1 ms |
| Can `state` arrive by `ADD COLUMN`, `NOT NULL`, with a default and a `CHECK`? | Yes. A bad state is refused by the table |
| Does deleting a node's row work while it has snapshots? | No: the foreign key refuses. A purge deletes the snapshots first, whatever the row's fate |
| A purge that deletes 3 MiB of snapshots and empties the row, in one transaction | about 1 ms |
| Does the list, filtered by state, still use `nodes_owner`? | Yes. No new index |

**Why L4 exists.** Slice 4 reads a node's body by joining the node to the
snapshot at the node's own revision. A state change that bumped the revision and
wrote no snapshot would leave the node with no body.

## Decisions (the owner's, 2026-11-25)

| # | Question | Decided |
|---|---|---|
| L1 | The states | `active`, `archived`, `trashed`. A purged node is gone to every client |
| L2 | What can be undone | archive and unarchive; trash and untrash, which always lands on `active`. A purge cannot |
| L3 | The routes | `POST /v1/nodes/{id}/archive`, `/unarchive`, `/trash`, `/untrash`; `DELETE /v1/nodes/{id}` purges. All need `If-Match` |
| L4 | A state change and the revision | It bumps the revision and writes **no snapshot**. A node's body is its newest snapshot's |
| L5 | Writes by state | Archived: as an active node. Trashed: a replace or a revision's restore is a 409. A `GET` works in all three and shows `state` |
| L6 | The list | Active only, unless `?state=archived` or `?state=trashed` |
| L7 | What a purge leaves | The node's row, emptied, so its id is never used again by anyone. A read is a 404, a create a 412 |
| L8 | When a purge is allowed | Only from `trashed`. Nothing purges by itself |
| L9 | The new code | `wrong_state` (409): the node's state does not allow the event |
| L10 | The feed's ops | `archive`, `unarchive`, `trash`, `untrash`, `purge`. The purge's row is the tombstone |

**What L4 costs.** A node's revisions list has gaps: 1, 2, 4 when revision 3 was
an archive. The feed shows every number. Restoring revision 3 is a 404, as any
revision with no snapshot.

**What L2 costs.** A node archived, then trashed, comes back active.

## The design

### The lifecycle is a table

In `(techo nodes)`, beside the write's table, read by the same `(techo machine)`.

| State | archive | unarchive | trash | untrash | purge | write |
|---|---|---|---|---|---|---|
| `active` | → `archived` | 409 | → `trashed` | 409 | 409 | allowed |
| `archived` | 409 | → `active` | → `trashed` | 409 | 409 | allowed |
| `trashed` | 409 | 409 | 409 | → `active` | → `purged` | 409 |
| `purged` | cannot happen: a purged node is found as `none` |

- `write` is a replace or a revision's restore. It changes no state.
- `purged` is the table's one end.
- `lifecycle-step : State Event -> (Values State Command)`, pure. Commands:
  `set-state`, `purge`, `allow`, `refuse-409`.
- `make machines` writes `.plans/machines/lifecycle.md` from it.

### How the two tables meet

A request is answered by the first of these that applies:

1. The id, the precondition's shape and the query: 400, 428. No job.
2. The key: 401.
3. What the write's table finds: `none` is a 404, `differ` a 412.
4. On `match` only, the lifecycle's table: 409 `wrong_state`, or the change.

- **A stale request is a 412 before a 409.** A client that is behind reads the
  node again, and sees its state then.
- **A purged node and another account's node are both `none`.**
- A create (`If-None-Match: *`) on a purged id finds `differ`: 412, as any id in
  use.
- `If-None-Match` on any of the five new routes is a 400, as on a restore.
- A slice 4 write to a trashed node: its job reads `state` with the revision and
  the kind, in the one lookup it makes today. `kind_fixed` and `wrong_state`
  can both be true; `wrong_state` is answered first.

### The answers

| Route | Answer |
|---|---|
| The four `POST`s | 200, the node **without its body**, the new `ETag` |
| `DELETE` | 204, no body, no `ETag` |
| Any node, a list's item | gains `"state"` |

- **No body in a state change's answer.** The client sent none and has it
  already, and the job would read up to 1 MiB to echo it. Accepted by the owner.
- None of the five reads a request body or its `Content-Type`. They go through
  `db-write-as`: there is no body to hold back until the key is good.
- `state` in a request's JSON is a 400, as any member the route does not know.
- `?state=` takes one of the three names. Anything else is a 400. A page's
  `after` works as today.
- A trashed node's revisions can still be listed and read.

### What a purge does, in one job

1. Deletes the node's snapshots.
2. Empties the row: `title` to `''`, `props` to `'{}'`, `state` to `'purged'`,
   the revision bumped, `updated` to now. `kind`, `content_type`, `author`,
   `owner`, `created` and `num` stay: the table's checks need the first two, and
   none can be read.
3. Appends the change row, op `purge`, at the new revision.

Slice 7's search index will have to drop the node here. Noted for its plan.

### Migration 4, "a node's state"

```sql
ALTER TABLE nodes ADD COLUMN state TEXT NOT NULL DEFAULT 'active'
  CHECK (state IN ('active','archived','trashed','purged'));
```

- One statement. Every node there is becomes `active`.
- **A `CHECK`, though `changes.op` has none:** the four states are ADR-0007's,
  as the five kinds are ADR-0003's. A fifth state would mean rebuilding the
  table.
- `shipped-objects` stays 14.

### `(techo node-store)`

- `node-of-owner` joins the newest snapshot, and leaves out `purged`.
- `node-head` answers the state too.
- `nodes-page` and `nodes-page-after` take a state.
- The revisions' queries leave out a purged node (it has no snapshots; the
  node's own check answers the 404).
- `node-in-use?` does not change: a purged row is in use.
- New: `set-node-state!` and `purge-node!`. Both name the owner and the expected
  revision, as `write-node!` does, and raise with the id and the revision only.
- Every statement stays in `node-store-statements`.

## What must hold, and what would catch a break

| # | What holds | A mutant that must be caught |
|---|---|---|
| G1 | The lifecycle's table is whole: every state and event has a row or a "cannot happen", every state is reached, `purged` is the one end | a row removed |
| G2 | A node's body, title and content type are its newest snapshot's, in every state but purged | the join back at `r.revision = n.revision` |
| G3 | A state change bumps the revision by one, appends one change row with its op, and writes no snapshot | a snapshot written; the revision left |
| G4 | A write to a trashed node changes nothing: no snapshot, no change row, no revision | the check after the write |
| G5 | Stale is a 412 whatever the state, before any 409 | the lifecycle's step run first |
| G6 | After a purge: no snapshot of the node is left, the title is empty, a read and the revisions list are 404, a create is 412 for both accounts | the row deleted; the snapshots left |
| G7 | Another account's node answers 404 to all five routes, and is not changed | a statement without the owner |
| G8 | The list shows a node under exactly one state, and under `active` by default | no filter |
| G9 | `created`, `kind` and `author` never change through a state change | `created` set |
| G10 | Slice 4's H1 to H19 still hold with states in play | (the model's own) |

## How it is checked

- **The table:** `machine-problems`, and every cell stepped, in `test-nodes.sps`.
- **The store:** `test-node-store.sps`, against real SQLite, with the statement
  tests slice 4's review added (owner named; no list selects a body).
- **The routes:** `test-node-routes.sps`.
- **The model:** `nodes-model.sls` gains the state and the five events. The
  generator aims writes at trashed nodes, state changes at stale revisions, and
  account B at A's ids. The suite reports which cells were reached.
- **Integration:** the five routes against the running server.
- **Migrations:** a file at version 3 with nodes in it migrates, and each node is
  active with its body.

## The work

1. **Migration 4 and the store** (Sonnet): `migrations.sls`,
   `tests/shipped-migrations.scm`, the migration suites, `node-store.sls`,
   `test-node-store.sps`.
2. **The lifecycle's table** (Opus): `nodes.sls`, `test-nodes.sps`,
   `wrong_state` in `errors.sls` and its suite, `lifecycle.md` with the
   `Makefile`'s `machines` loop and `scripts/render-machines.sps`. Beside task 1:
   no shared file.
3. **The routes** (Opus): `node-routes.sls`, `test-node-routes.sps`. After 1
   and 2.
4. **The model** (Opus) and **the integration tests** (Sonnet), side by side.
   After 3.
5. **The records** (me): ADR-0004 (a state change writes no snapshot; the body is
   the newest snapshot's), ADR-0007 (the lifecycle's table), ADR-0002 (`DELETE`
   for a purge; the list's `state`), the constraints, the schema, the API docs,
   the changelog, the ledger.
6. **A read-only adversarial review of the build** (Opus), then its fixes.

Before any of it: **a read-only review of this plan** (Opus).

## Not in this slice

- What trashing a parent does to its children: there is no parent until slice 5.
- Purging by age.
- Search leaving out trashed nodes (slice 7).
- The feed's route (slice 8). This slice only writes its rows.

## The review of this plan (Opus, 2026-11-25)

Read-only, with probes under `build/review-4b/`. Four blockers and one wrong
figure. I reran the purge probe and read the three source claims I spot-checked.

### The wrong figure: a purge is not 1 ms

My probe ran in `:memory:`. On a real file in WAL, as the server runs
(`build/review-4b/purge-wal.sps 200`, rerun by me):

| Purging | Writer held | `-wal` afterwards |
|---|---|---|
| 200 snapshots of 1 MiB | 390 ms (delete 151, commit 239) | 211 MB |
| The same with `secure_delete` off | about 45 ms | 0.4 MB |

- This SQLite is built with `SECURE_DELETE`: every freed page is zeroed, through
  the WAL. It is what makes "gone for good" true in the file.
- About 2 ms a MiB of history. Nothing caps a node's history, so about 4.5 GiB of
  it would pass the 10 s deadline.
- SQLite does not shrink the `-wal`, and `open-techo-db` sets no
  `journal_size_limit`.
- **This is L11, for the owner.**

### Blockers, and what they change

1. **The records forbid L4 and the purge.** The constraints say every change
   "appends a snapshot" and "history is append-only"; ADR-0004 says the body is
   the snapshot "at its revision". **So the records are amended first,** in the
   plan's own commit, before task 1: ADR-0004, ADR-0007, and those constraint
   lines.
2. **No interface gave a state change its 404 or 412.** `write-event` knows two
   routes, and a handler may decide no answer itself. **So:** one pure function in
   `(techo nodes)`,
   `node-command : Found State Event -> Command`, checked over every cell. D5's
   table and `write.md` do not change. The order "stale, then state, then kind"
   lives in it, not in a handler.
3. **`node-head` must leave out a purged row,** or a write finds it, the
   lifecycle's "cannot happen" cell raises, and the answer is a 500. **So:**
   `node-head` has `AND state <> 'purged'`, and `write-node!`'s `UPDATE` has
   `AND state IN ('active','archived')` behind it. `node-head` answers
   `(revision kind state)`, all three fixed here.
4. **G10 cannot hold as written.** Slice 4's H2, H3 and H15 are false under L4.
   Restated:
   - H2': title, content type, props and body equal the newest snapshot's.
   - H3': a node's snapshot numbers rise within 1 to N, none ever changes, and
     none is left after a purge.
   - H15': `updated` is the newest change row's time.
   - H18': each node is listed once, within its state.

### Answers the plan lacked, now given

| Case | Answer |
|---|---|
| A restore on a trashed node, at the right revision, of a revision with no snapshot | 409 `wrong_state`: the state comes before the 404 |
| The `state` in a replace's or a restore's answer | the stored state, never a fixed `active` |
| The lifecycle's refusal | its own command, `refuse-wrong-state`: `refuse-409` is `kind_fixed` today |
| A malformed key with a bad id | 401 first, as `(techo auth)` does today. The plan's order was wrong |
| A state change sent again after its answer was lost | 412. Read the node. Documented as a "maybe" |
| A `DELETE` sent again after its answer was lost | 404 means it is done. Documented |
| A `DELETE` or a `POST` with a body | not read; the connection closes after the answer |
| A create on a purged id | 412, and a read is 404: make a new id. Documented |
| `?state=purged` | 400 |

### Decided between the tasks

- **A state is a symbol in `(techo nodes)` and a string in the store.** The
  routes convert. A test holds the names equal to migration 4's `CHECK`.
- **`(techo nodes)` parses `?state=`** and maps an event to its op.
- `set-node-state! : Tx Id Id Natural String String Natural -> Boolean` (owner,
  id, expected revision, state, op, now) and `purge-node!` with the same but the
  state. Each answers whether it changed a row.
- The purge's `DELETE` is `DELETE FROM revisions AS r WHERE r.node = ? AND EXISTS
  (SELECT 1 FROM nodes n WHERE n.id = r.node AND n.owner = ?)`: the owner test
  reads for that shape.
- **A purge sets `content_type` to `application/octet-stream`.** It is the
  client's text, and the check needs a value, not theirs.

### The work, as reviewed

This replaces "The work" above.

0. **The records that bind the build** (me, in the plan's commit).
1. **Migration 4 and the store** (Sonnet). Also `tests/test-migrations.sps`'
   "versions 1, 2 and 3". It may leave `node-routes.sls` and the route, model,
   app and integration suites red: the brief names them.
2. **The lifecycle's table and `node-command`** (Opus), with `wrong_state`.
   Beside task 1.
3. **The routes** (Opus). Also `tests/test-app.sps`, which holds that a `DELETE`
   on a node is a 405.
4. **The model** (Opus), with H2', H3', H15', H18', and **the integration
   tests** (Sonnet).
5. **The rest of the records** (me), `README.org`'s "full history" and
   `docs/api.md`'s "history is never rewritten" among them.
6. **A read-only adversarial review of the build** (Opus), then its fixes.

### What must hold, added and sharpened

- G2 includes props. G4's mutant is "`write-node!` without its state term": the
  one named cannot be seen. G7 aims B at A's id at A's own revision. G8's
  fixture holds a purged node.
- G11: a state change leaves title, content type, props and body as they were.
- G12: a replace or a restore keeps the state.
- G13: a refused request changes nothing, `last_used` included.
- G14: no answer ever shows a purged row.
- G15: `wrong_state` is never answered as `kind_fixed`.
- G16: no change row for a node follows its `purge` row.

### Noted, not taken

- **A list of a rare state reads the account's rows:** 10 ms on a reader for 10
  trashed among 100,000. An index `(owner, state, id)` when it hurts.
- **Slice 7:** the search view must join the newest snapshot, and a purge must
  take the node out of the index before it empties the row.
- **A purge leaves** `created`, `updated`, the earlier change rows, backups, and
  the `-wal` until it is checkpointed. The docs say so.

## L11. A purge's cost (for the owner)

| | Choice | Cost |
|---|---|---|
| A | **Accept it, and set `journal_size_limit`** so the `-wal` shrinks back | a purge of a node with 200 MiB of history holds the writer about 0.4 s; other writes wait |
| B | Purge in pieces, over several jobs | a new state, `purging`, and a node half gone if the server stops |
| C | Turn `secure_delete` off | fast, and the purged text stays in the file's free pages |

**Recommended: A.** A node's history reaches 200 MiB only after 200 writes of
the largest body there is. `journal_size_limit` is one line in `open-techo-db`,
probed before it is built.

**Decided: A** (owner, 2026-11-26). Probed (`build/probe-4b/jsl.sps`): with the
limit set, the `-wal` was 211 MB after the purge and at the limit after the next
checkpoint and write. The limit is 16 MiB, a few of the largest writes. Task 1
owns it: `open-techo-db` in `db.sls`, with a test in `test-db.sps` that the
setting is read back on a connection that writes.
