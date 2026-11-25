# Slice 4: nodes, revisions and `If-Match`

Date: 2026-11-25
Status: the owner accepted D1 to D10 on 2026-11-25, each as recommended, with the
body's cap at 1 MiB "for now". The plan is reviewed (the review section, near the
end), and what the review changed is there: where it and the text above it
disagree, the review wins. D11, which the review raised, is decided too, and its
tables replace D9's. Not built.
Records: ADR-0002 (the API), ADR-0003 (nodes), ADR-0004 (revisions), ADR-0005
(bodies), ADR-0007 (machines), ADR-0012 (migrations), ADR-0013 (the doorway). Read
[global-constraints.md](global-constraints.md) first.

## What this slice is for

After 3b a person can log in, and there is nothing to store. This slice stores
notes:

- make a node, read it, list nodes, replace its content;
- every write checked against the node's revision, with `If-Match`;
- every write kept as a snapshot, which can be listed, read and restored;
- every write given the owner's next sequence number, for slice 8's feed.

## What the probes found (2026-11-25)

The program is `build/probe-4/p.sps`.

**JSON, through circuit's reader (jsonparse)**

| Body, characters | JSON bytes | Parse ms | Encode ms |
|---|---|---|---|
| 2,000 | 2,086 | under 1 | under 1 |
| 65,536 | 67,653 | under 1 | 1 |
| 262,144 | 270,542 | 1 | 1 |
| 1,048,576 | 1,082,093 | 9 | 7 |
| 2,097,152 | 2,164,167 | 20 | 14 |

- Both run on the loop's thread, where they hold up every other request.
- `"\u0000"` is read as a string holding U+0000.
- A lone surrogate (`"\ud800"`) and invalid UTF-8 are refused as invalid JSON. A
  surrogate pair is read as one character.
- An object keeps a name given twice (known since 3b).

**SQLite, through chez-sqlite3**

- Text with U+0000 goes in and comes back whole, but `length()` answers 1 for
  `a`, U+0000, `c`: SQLite's text functions stop at it. FTS5 (slice 7) would too.
- One 1 MiB text value takes about 31 ms to insert and 32 ms to read, in memory,
  with no disk. A node write stores the body twice (the node and its snapshot). This
  is on the writer's thread, not the loop's. The time is probably the binding's
  copying, not SQLite's; not looked into.

**Read, not run**

- circuit's router has `PUT`, `PATCH` and `DELETE`. Neither circuit nor
  chez-http-server knows `ETag` or `If-Match`: Techo reads and writes them as plain
  headers.
- chez-http-server has no body cap by default (`CHEZ_HTTP_MAX_BODY_BYTES` unset).
  `wrap-json-body`'s cap is the only one.
- unique-id (pinned, v0.1.0): `string->uuid` answers `#f` for what is no id,
  `uuid-version`, `uuid->bytevector`.
- The spike's node write (update, snapshot, sequence number, change row) had a
  median under 10 ms at medium size; its tail is the disk's fsync.

## Decisions for the owner

### D1. This slice has no lifecycle, no parent and no tags

The ledger gives slice 4 the question "the node lifecycle's states, and which
transitions can be undone". The outline gives slice 4 only create, read, update and
revisions.

**Recommended:** leave the lifecycle out, and make it slice 4b with its own plan:
archive, trash, purge, the tombstone, and what a write to a trashed node gets.

- Every node in this slice is active. The `state` column arrives with 4b, as
  `ALTER TABLE ... ADD COLUMN state TEXT NOT NULL DEFAULT 'active'`.
- `parent` arrives with slice 5 and `tags` with slice 7, the same way. A table
  arrives with the slice that uses it (ADR-0012); this holds a column to the same
  rule. So "does a snapshot hold the parent" moves to slice 5.
- **Cost:** three later migrations add columns. SQLite adds a column without
  rewriting the table.

### D2. A node's id must be a UUID of version 7

Open since the outline.

**Recommended:** refuse anything else with 400. No check of the id's timestamp
against the server's clock.

- **Why:** v7 ids arrive in rising order, so the primary key's index grows at one
  end, and a list paged by id comes out roughly in the order nodes were made.
- **Cost:** a client must make v7 ids. It is about 20 lines in any language.
- A client with a wrong clock makes ids that sort early or late. Nothing breaks.

### D3. The routes

| Route | What it does | Needs |
|---|---|---|
| `PUT /v1/nodes/{id}` with `If-None-Match: *` | makes the node, at revision 1 (201) | |
| `PUT /v1/nodes/{id}` with `If-Match: "N"` | replaces its content, at revision N+1 (200) | |
| `GET /v1/nodes/{id}` | the node, with `ETag` | |
| `GET /v1/nodes?limit=&after=` | the account's nodes, by id, without bodies | |
| `GET /v1/nodes/{id}/revisions?limit=&after=` | its snapshots, newest first, without bodies | |
| `GET /v1/nodes/{id}/revisions/{n}` | one snapshot, whole | |
| `POST /v1/nodes/{id}/revisions/{n}/restore` with `If-Match: "N"` | a new revision copied from snapshot n (200) | |

- **Create is a `PUT` to the id the client chose,** with HTTP's own header for
  "only if it is not there yet". A retry after a lost answer gets 412; the client
  then reads the node and finds its own. The other shape, `POST /v1/nodes` with the
  id in the body, needs a rule of Techo's own for the retry.
- **A write with neither header is 428.** With `If-Match` on a node that is not
  there, 404.
- **Replace is the whole content** (title, body, content type, props). No `PATCH`
  in this slice: every write stores a whole snapshot anyway, and a client that has
  a conflict to resolve already holds the whole node. `PATCH` can be added later
  and break nothing.
- **Every accepted write is a new revision,** the same content too. The server
  compares nothing.
- **A restore copies** title, body, content type and props. Restoring the newest
  snapshot is allowed, and is one more revision.
- **Left out:** `GET` with `If-None-Match` answering 304. The feed (slice 8) is how
  a client learns what changed.

### D4. The ETag is the revision in quotes, and `If-Match` is exactly one of them

- A node's answers carry `ETag: "7"`.
- **Changed after the owner's yes:** the draft said a 412 carries it too. It does
  not. A refusal leaves a job as `&refusal`, which holds a code and an account and
  nothing else (ADR-0006), and the client reads the node next anyway.
- `If-Match` is accepted only as one `"N"`. `*`, a list, a weak tag (`W/"7"`), or
  the header given twice is a 400. `If-Match: *` would mean "overwrite whatever is
  there", which is what ADR-0004 exists to stop.
- `If-None-Match` on a `PUT` is accepted only as `*`.
- Both headers on one request is a 400.

### D5. The versioned write is a table

ADR-0007, and the outline's §6 names it. The job finds the node and says what it
found; a pure function names the event; the step names the command; the handler
performs it.

| Found | create | replace | replace, other kind | restore | restore, no such snapshot |
|---|---|---|---|---|---|
| no node | insert, 201 | 404 | 404 | 404 | 404 |
| node at the revision given | cannot happen | write, 200 | 409 | copy, 200 | 404 |
| node at another revision | 412 | 412 | 412 | 412 | 412 |

- A create finds a node "at another revision" whenever there is one: it gave none.
- A stale write is 412 before anything else about it is looked at.
- "Insert", "write" and "copy" each do the same three things in the one job: the
  node's row, a snapshot, a change row with the owner's next number.
- Verified as the others are: the table checked exhaustively, a diagram made from
  it, and a model test of random sequences against real SQLite, with two accounts.

### D6. Limits on what a node holds

| Thing | Limit |
|---|---|
| The request's JSON | 2 MiB (413 over it) |
| `body` | 1,048,576 bytes of UTF-8 |
| `title` | 1,000 characters; may be empty |
| `content_type` | 1 to 255 printable ASCII characters with one `/`; required; never interpreted |
| U+0000 in `title` or `body` | refused, 400 |

- **Why 1 MiB:** it is a 500-page book as plain text, and one person's whole org
  file fits. Parsing it holds the loop about 10 ms, inside the spike's rule for v1
  (5 to 50 ms).
- **The cost to know:** the body is read and parsed before the key is checked,
  because the key is checked in the request's own job (ADR-0006) and nothing waits
  inside a job. So anyone who can send a well-shaped key can make the loop parse
  2 MiB, about 20 ms a request. The other choice is a lower cap: 256 KiB of JSON
  parses in 1 ms.
- **Why refuse U+0000:** SQLite's text functions and search stop at it, so a body
  holding one would be stored whole and searched in part.
- **Accepted at 1 MiB for now** (owner, 2026-11-25). It is a constant, not a
  setting. Larger bodies want the key checked before the body is read, which is two
  jobs a write and a change to ADR-0006: not this slice.
- A name given twice in the JSON is a 400, as login's is. A member the route does
  not know is a 400.

### D7. Kind is set at create and never changes; props must be `{}` until slice 6

- `kind` is one of the five, required at create.
- On a replace `kind` may be left out. Given and different, it is 409 `kind_fixed`.
- `props` may be left out, and must be an empty object when given. Slice 6 decides
  each kind's props; anything accepted before then would be data slice 6 never
  checked.

### D8. Another account's node is a missing node

- Every read and write is scoped to the owner (ADR-0003), so another account's id
  answers 404, as a missing one does.
- **One leak, accepted:** ids are unique across accounts, so a create with an id
  another account holds is 412, and the read after it is 404. Someone who already
  knows an id learns it is in use. An id has 74 random bits; it is not guessed.
- The other choice, a key of owner and id together, makes every later table carry
  the owner in its foreign key, and gets in the way of sharing later.

### D9. The tables (migration 3)

```sql
CREATE TABLE nodes (
  id           BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  owner        BLOB    NOT NULL REFERENCES accounts(id),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  kind         TEXT    NOT NULL CHECK (kind IN ('project','journal','note','task','contact')),
  title        TEXT    NOT NULL CHECK (length(title) <= 1000),
  body         TEXT    NOT NULL,
  content_type TEXT    NOT NULL CHECK (length(content_type) BETWEEN 1 AND 255),
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  created      INTEGER NOT NULL,
  updated      INTEGER NOT NULL
) STRICT;
CREATE INDEX nodes_owner ON nodes(owner, id);

CREATE TABLE revisions (
  node         BLOB    NOT NULL REFERENCES nodes(id),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  title        TEXT    NOT NULL,
  body         TEXT    NOT NULL,
  content_type TEXT    NOT NULL,
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  created      INTEGER NOT NULL,
  PRIMARY KEY (node, revision)
) STRICT;

CREATE TABLE changes (
  owner    BLOB    NOT NULL REFERENCES accounts(id),
  seq      INTEGER NOT NULL,
  node     BLOB    NOT NULL,
  revision INTEGER NOT NULL,
  op       TEXT    NOT NULL,
  created  INTEGER NOT NULL,
  PRIMARY KEY (owner, seq)
) STRICT, WITHOUT ROWID;
```

Against [schema.md](schema.md)'s sketch:

- **A snapshot holds the content type,** which the sketch forgot: a restored body
  with the wrong type is a different note. It holds the author too, for sharing
  later.
- **No `parent`, `state` or `tags`** (D1).
- **`op` has no `CHECK`.** Its values here are `create`, `update` and `restore`;
  4b and slice 5 add more, and SQLite cannot change a `CHECK` without rebuilding
  the table. The code's table is the list, and a test holds it.
- **`revisions` is a plain table,** not `WITHOUT ROWID` as drafted and as sketched.
  Probed on 20,000 snapshots (`build/probe-4/rowid.sps`):

  | Body | Table | Bytes a snapshot | Insert | Read one | List 10 |
  |---|---|---|---|---|---|
  | 2,000 | `WITHOUT ROWID` | 4,670 | 95 us | 76 us | 39 us |
  | 2,000 | plain | 4,135 | 87 us | 70 us | 37 us |
  | 20,000 | `WITHOUT ROWID` | 21,054 | 821 us | 628 us | 86 us |
  | 20,000 | plain | 20,519 | 777 us | 600 us | 38 us |

  At 200 characters the two are the same. `changes` keeps `WITHOUT ROWID`: its
  rows are small.

### D10. New error codes

| Code | Status | When |
|---|---|---|
| `precondition_required` | 428 | a write with neither header |
| `precondition_failed` | 412 | a stale `If-Match`, or a create on an id in use |
| `kind_fixed` | 409 | a replace that names another kind |

`invalid_request`, `not_found`, `payload_too_large` and `unsupported_media_type`
are used as they are.

### Smaller choices, made unless the owner objects

- A create answers 201 with the node, `ETag` and `Location`. A replace and a
  restore answer 200 with the node and `ETag`.
- A node in JSON: `id`, `kind`, `title`, `body`, `content_type`, `props`,
  `revision`, `created`, `updated`. In a list, the same without `body`.
- A snapshot in JSON: `revision`, `title`, `body`, `content_type`, `props`,
  `created`. In a list, without `body`.
- The revisions list is newest first, and its `after` is the last revision number
  seen.
- The order of checks: the key's shape (401), the id and the query (400), the
  preconditions' shape (428, 400), the body (415, 413, 400), then the job: the key
  (401), then D5's table.
- The owner's next sequence number is `coalesce(max(seq), 0) + 1` in the write's
  own job. One
  writer, so no two jobs get the same.
- `updated` is the time of the newest revision. `created` never changes.

## The design

### Libraries

| Library | Holds | Kind |
|---|---|---|
| `(techo nodes)` | ids, the two headers, the ETag, the body's parsing and limits, D5's table and its step | pure |
| `(techo node-store)` | the SQL, and the records a row becomes | shell |
| `(techo node-routes)` | the seven routes | shell |
| `(techo migrations)` | migration 3 | data |
| `(techo errors)` | three codes | data |
| `(techo app)`, `(techo wiring)` | the routes joined to the program | shell |

`(techo auth)` is used as it is:
every route is one `db-read-as` or `db-write-as`.

### `(techo nodes)`, pure

```scheme
;; node-kinds : (Listof String)          the five, lower case
;; body-cap : Natural                    1048576, in UTF-8 bytes
;; request-cap : Natural                 2097152, for wrap-json-body
;; title-cap : Natural                   1000, in characters

;; parse-node-id : Any -> (U Bytevector 'invalid)
;; 16 bytes for a string that is a UUID of version 7, RFC variant.

;; parse-revision : Any -> (U Natural 'invalid)
;; A path's or a query's revision: decimal digits, no sign, no leading zero,
;; 1 to 2^53.

;; etag : Natural -> String              7 -> "\"7\""

;; Precondition = (U 'create Natural)
;; precondition : (Listof String) (Listof String) -> (U Precondition 'missing 'invalid)
;; From every If-Match field and every If-None-Match field (D4).

;; Content : kind (U String #f), title, body, content-type, props (the text "{}")
;; parse-content : Any -> (U Content 'invalid 'too-large)
;; From req-json's value. 'too-large only for a body over body-cap.

;; Found = (U 'none 'match 'differ)
;; found : (U Natural #f) Precondition -> Found
;; The stored revision, or #f for no node, against what the request gave.

;; write-event : Symbol Precondition Found ... -> EventKind
;; write-step : Found EventKind -> (values Found CommandKind)
;; write-rows, write-cant-happen, write-document: as (techo keys) has them.
```

- Events: `create`, `replace`, `replace-other-kind`, `restore`, `restore-unknown`.
- Commands: `insert`, `write`, `copy`, `refuse-404`, `refuse-409`, `refuse-412`.
- The table is built on `(techo machine)`, as the key table is, and
  `make machines` writes `.plans/machines/write.md` from it.

### `(techo node-store)`, the SQL

```scheme
;; Node : id owner author kind title body content-type props revision created updated
;; Snapshot : node revision author title body content-type props created

;; node-in-use? : Tx Bytevector -> Boolean
;; Whether any account holds this id (D8). It reads no column but the id.

;; node-of-owner : Tx Bytevector Bytevector -> (U Node #f)
;; nodes-page : Tx Bytevector (U Bytevector #f) Natural -> (Listof Node)     body ""
;; snapshot-of : Tx Bytevector Bytevector Natural -> (U Snapshot #f)        owner node n
;; snapshots-page : Tx Bytevector Bytevector (U Natural #f) Natural -> (Listof Snapshot)

;; insert-node! : Tx Bytevector Bytevector String String String String String Natural -> Node
;;   id owner kind title body content-type props now
;; write-node! : Tx Bytevector Bytevector Natural String String String String String Natural -> Node
;;   id owner expected title body content-type props op now
;; The node's row at EXPECTED + 1, its snapshot, and the change row, OP its
;; op. It raises when the row was not at EXPECTED.
```

- Every query but `node-in-use?` has the owner in its `WHERE`. A snapshot is
  reached through its node's owner, by a join: `revisions` has no owner column.
- `write-node!` updates `WHERE owner = ? AND id = ? AND revision = ?` and checks
  one row changed. The table has already said the revision matches; this holds it
  again where the write happens.
- A list never selects `body`.

### `(techo node-routes)`

```scheme
;; node-routes : Runner Runner (-> Natural) Clock -> (Listof Route)
```

- The order of checks is the smaller choices' list. `wrap-json-body` is applied
  inside the handler, after the cheap checks, as login's handler does.
- A write's work, in the job: read the node (or `node-in-use?` for a create), name
  the event, step the table, perform the command. A refusal is raised as a
  `&refusal`, so the job rolls back, the key's `last_used` with it.
- Restore's work reads the snapshot in the same job, and names `restore-unknown`
  when it is not there.
- `Location` on a 201 is the request's path.

## What must hold, and what would catch a break

| # | What holds | A mutant that must be caught |
|---|---|---|
| H1 | An accepted write raises the revision by exactly one | `+ 2`; no bump |
| H2 | A node's row equals its newest snapshot, in every content column | snapshot written before the update; a column left out |
| H3 | Snapshots 1 to N exist for a node at N, and none ever changes | restore edits the old row; snapshot skipped on create |
| H4 | An owner's change numbers are 1 to M with no gap, one for each accepted write | number taken across owners; no row on restore |
| H5 | A refused write changes nothing: no row, no number, no `last_used` | 412 answered after the insert; refusal returned, not raised |
| H6 | No route shows or changes another account's node or snapshot | owner dropped from one `WHERE`; snapshot read without the join |
| H7 | Each line of D5's table | each cell swapped for a neighbour |
| H8 | Each limit of D6, at the limit and one past it | `<` for `<=`; bytes counted as characters |
| H9 | `If-Match` only as one `"N"` (D4) | `*` accepted; `W/"7"` read as 7; two fields joined |
| H10 | An id of another version is refused | version not checked |
| H11 | Kind never changes | replace writes the request's kind |
| H12 | A list holds no body | `body` selected in a page |

H1 to H6 are the model test's. Its model is pure: a map from id to owner and a
list of contents, and a count for each owner. After each step the suite reads
the three tables whole and compares.

## How it is checked

| Suite | What |
|---|---|
| `test-nodes.sps` | parsing, limits, headers, the table checked exhaustively (H7 to H10) |
| `test-node-store.sps` | the SQL against real SQLite, two accounts (H2, H3, H4, H6, H12) |
| `test-node-routes.sps` | each route through circuit's test host: statuses, headers, JSON, the order of checks |
| `test-nodes-model.sps` | random sequences by two accounts, against the model (H1 to H6, H11) |
| `test-migrations*.sps` | migration 3, and `tests/shipped-migrations.scm` gains it |
| `test-wiring.sps` | the program's app answers a node route |
| `test-integration.sps` | the running server through chez-curl: create, read, a stale write, restore, a second account |

## The work

Each builder plants its mutants in a private copy of `src/`, first on the
library path, never in the shared tree. No builder commits.

1. **Migration 3 and `(techo node-store)`**, with `test-node-store.sps` and the
   migration suites (Sonnet).
2. **`(techo nodes)`**, with `test-nodes.sps`, the diagram, and the three error
   codes in `(techo errors)` with its suite (Opus). Beside task 1: no shared file.
3. **`(techo node-routes)`** and `test-node-routes.sps` (Opus). After 1 and 2.
4. **The model test** (Opus). After 3.
5. **The program:** `(techo app)`, `(techo wiring)`, `techo.sps`, `test-wiring.sps`,
   `test-app.sps`, and the integration tests (Sonnet). After 3, beside 4.
6. **The records** (me): `docs/api.md`, the README's status, the CHANGELOG,
   `schema.md`, the amendments to ADR-0003 (D7, D8) and ADR-0004 (D2, D3, D4, D9),
   the constraints, the ledger with 4b as its own row.
7. **A read-only adversarial review of the build** (Opus), then its fixes.

## The review of this plan (Opus, 2026-11-25)

Read-only, with probes under `build/review-4/`. Four blockers, each checked again
by me before it was folded in: the column probe rerun, the rest read in the source.

**Blockers**

1. **A column after a large body costs a walk of the body's pages.** With 100 rows
   of 1 MiB, a list reading `revision` and `created` took 17 ms with the body
   before them and under 1 ms with it last (`build/review-4/overflow3.sps`, rerun).
   The write's own check reads `revision`. D9's probe missed it: it stored
   `created` as 0, which SQLite keeps in the row's header. **This is D11, for the
   owner.**
2. **Login's member check is quadratic.** `repeated?` in `(techo login)` compares
   every name with every later one: 40,000 members took 2.8 s in the reviewer's
   probe, and 2 MiB holds about 190,000. Copied to the node body it would stop the
   loop for about a minute a request, before the key is checked. So:
   `parse-content` looks for an unknown member first, which bounds the list at the
   five known names, and H13 holds a time at the cap.
3. **Tasks 1 and 2 shared an undecided type.** The store now takes plain
   arguments, not a `Content`.
4. **Migration 3 breaks two suites no task owned:** `shipped-objects` is 8 in
   `tests/test-db.sps` and `tests/test-integration.sps`, with the table list
   beside it. Task 1 owns both edits.

**Answers the plan lacked, now given**

| Case | Answer |
|---|---|
| JSON that does not parse | 400 `invalid_json`, as login's |
| A body over `body-cap` | 413 `payload_too_large` |
| A create with no `kind`, or any member of the wrong type | 400, before the job, so before a 412 |
| Required members | `title`, `body`, `content_type`; `kind` too on a create. `body` and `title` may be `""` |
| A member the route does not know, `id` and `revision` among them | 400. A client sends content, not a node it read |
| `If-None-Match` on a restore | 400 |
| `If-Match` or `If-None-Match` on a `GET` | ignored |
| A restore's body and `Content-Type` | not read |
| The revisions list of a node that is missing or another account's | 404 |
| The revisions list's `next` | a number, or null. ADR-0002's amendment says "the last id seen"; task 6 amends it |
| A space in `content_type` | allowed: the characters are U+0020 to U+007E |
| `Location` | made from the id as Techo writes it, lower case, not from the request's path |

**The request's cap comes before the body's for escaped text.** A client that
escapes every non-ASCII character writes 1 MiB of Japanese as about 2 MiB of JSON
and gets a 413. `docs/api.md` says: send UTF-8 as it is, and the limit a client
can count on is 2 MiB of JSON.

**The table (D5), made buildable**

- `write-event : Symbol Precondition Found (U String #f) (U String #f) Boolean ->
  EventKind`: the route (`put` or `restore`), the precondition, what was found,
  the request's kind, the stored kind, and whether the snapshot is there.
- A create's found is `none` when `node-in-use?` is false, and `differ` when true.
- After `insert`, `write` or `copy` the next state is `differ`: the same request
  sent again is stale. After a refusal the state stays.
- Cannot happen, each with its reason: create with `match`; `replace-other-kind`
  with `none` (no stored kind); `restore` with `none` (no node, so no snapshot).
- `write-document` renders the cells, as `login-document` does: the diagram's
  edges carry no answer.

**The loop's cost for a write is about double D6's figure.** The answer echoes the
body, and encoding 1 MiB holds the loop about 7 ms after the 9 ms parse. Accepted
with the cap. The write's check reads `revision` and `kind` only, never the body,
and the answer is built from the request's content, not read back.

**Constraints**

- `node-in-use?` is the one query with no owner, as `key-by-hash` is for keys. It
  reads the id only (a covering index, by `EXPLAIN`). A test holds that it is the
  only one. Task 6 writes the exception into the constraints.
- No raise in a node job or in `parse-content` carries a title or a body: a job's
  raise is logged whole. `write-node!` raises with the id and the expected
  revision only.
- A job's work closes over the id, the precondition, the five content values and
  the time. Never the request or the parsed JSON.
- `changes.node` has no foreign key, as sketched: a tombstone outlives its node.

**Smaller points taken**

- The next number is `coalesce(max(seq), 0) + 1`: `max` of no rows is null.
- `revisions.revision` gets `CHECK (revision >= 1)`.
- The revisions list checks the node first, then reads snapshots alone.
- `docs/api.md` tells a client to build `If-Match` from the JSON's `revision`: a
  proxy that compresses may turn `"7"` into `W/"7"` (not verified).
- The request's deadline (10 s) covers the upload. Documented.

**Not taken**

- A `CHECK` on the body's size in the table: the cap is "for now", and a `CHECK`
  cannot be changed.
- `VACUUM` renumbering rowids, which matters to slice 7's search index: noted for
  slice 7, not verified.

## D11. Where the body lives

Found by the review, after D1 to D10 were accepted. D1 adds `state`, `parent` and
`tags` later with `ADD COLUMN`, which always puts a column last, so behind the
body.

| | Choice | Cost |
|---|---|---|
| A | **The body is kept only in `revisions`.** A node's body is its newest snapshot's | reading a node is two lookups; slice 7's search index is built over a join |
| B | The body stays in `nodes`, as its last column today | each later column lands behind it: about 0.17 ms a row for a 1 MiB body, nothing for a body that fits a page |
| C | Ship `state`, `parent` and `tags` now, unused | undoes D1; decides three slices' columns today |

**Recommended: A.**

- One copy of each body, not two: about half the file, and half of a large
  write's 62 ms.
- `nodes` has no large column, so a list, the write's check and every later
  `ADD COLUMN` cost nothing extra.
- "A node equals its newest snapshot" (H2) is then true of the body by
  construction.
- In `revisions` the body is the last column.

**Decided (owner, 2026-11-25): A, and `nodes` gets an integer key beside the
UUID.**

- Probed for slice 7 (`build/probe-4/fts.sps`, SQLite 3.53.1): an FTS5 index over
  a view of each node and its newest snapshot finds the current text only, gives
  snippets, and passes FTS5's integrity check. Its one trigger is on `revisions`,
  after an insert: a trigger on `nodes` cannot see a new node's body, because the
  foreign key puts the node's row first.
- **Why the integer key:** a search index points at a row by its number. SQLite's
  documentation says `VACUUM` may renumber the rows of a table with no integer
  primary key, and the backup is `VACUUM INTO`. It did not happen in the probe.
  A primary key cannot be changed after migration 3, so it is settled now.
- `num` never leaves the database: no route shows it, and every lookup is by `id`.
- Not measured: search at the spike's sizes with the join. Slice 7's plan measures
  it. A contentless index (no snippets, no join) stays possible.

**The tables, final. These replace D9's.**

```sql
CREATE TABLE nodes (
  num          INTEGER PRIMARY KEY,
  id           BLOB    NOT NULL UNIQUE CHECK (length(id) = 16),
  owner        BLOB    NOT NULL REFERENCES accounts(id),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  kind         TEXT    NOT NULL CHECK (kind IN ('project','journal','note','task','contact')),
  title        TEXT    NOT NULL CHECK (length(title) <= 1000),
  content_type TEXT    NOT NULL CHECK (length(content_type) BETWEEN 1 AND 255),
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  created      INTEGER NOT NULL,
  updated      INTEGER NOT NULL
) STRICT;
CREATE INDEX nodes_owner ON nodes(owner, id);

CREATE TABLE revisions (
  node         BLOB    NOT NULL REFERENCES nodes(id),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  title        TEXT    NOT NULL,
  content_type TEXT    NOT NULL,
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  created      INTEGER NOT NULL,
  body         TEXT    NOT NULL,
  PRIMARY KEY (node, revision)
) STRICT;
```

`changes` is as in D9.

- A write inserts the node's row, or updates it, and then the snapshot: the
  foreign key needs that order.
- A node's body is read by `(node, revision)` from `revisions`, in the same job.
  `node-of-owner` answers the node with its body; the write's check reads
  `revision` and `kind` from `nodes` alone.
- `shipped-objects` becomes 15, not 14: `nodes`' unique index on `id` is one more
  object than a blob primary key's, and `revisions` has its key's index. Task 1
  counts them from `sqlite_schema` and does not trust this number.
- H2 is now: a node's title, content type and props equal its newest snapshot's,
  and a snapshot at the node's revision exists.
- H20: a node's `num` is in no answer and no log line.

## The work, as reviewed

This replaces "The work" above.

1. **Migration 3 and `(techo node-store)`** (Sonnet): `test-node-store.sps`, the
   migration suites, `tests/shipped-migrations.scm`, and the shipped constants in
   `tests/test-db.sps` and `tests/test-integration.sps`. The store's verbs take
   plain arguments: `kind title body content-type props`.
2. **`(techo nodes)`** (Opus): `test-nodes.sps`; the three codes in
   `(techo errors)` and its suite; `write.md`, with the `Makefile`'s `machines`
   loop and `scripts/render-machines.sps`. Beside task 1.
3. **`(techo node-routes)`** and `test-node-routes.sps` (Opus). After 1 and 2. It
   owns `routes.sls` for one move: `query-one`, `take` and the JSON type check go
   to a small library both route libraries import.
4. **The program** (Sonnet): `(techo app)`, `(techo wiring)`, `techo.sps`,
   `test-app.sps` with an import check on `(techo node-store)`, `test-wiring.sps`.
   After 3.
5. **The model test** (Opus), driving `make-app` as the key model does, and
   **the integration tests** (Sonnet). After 4, side by side: no shared file.
6. **The records** (me), with ADR-0002's amendment for the revisions list's
   `after`, and the `node-in-use?` exception in the constraints.
7. **A read-only adversarial review of the build** (Opus), then its fixes.

**What must hold, added and sharpened**

| # | What holds | A mutant that must be caught |
|---|---|---|
| H13 | Parsing a request at the cap, whatever its members, takes under 100 ms | the repeat check before the unknown-member check |
| H14 | `ETag` equals the JSON's `revision` and the stored row | the old revision in the header |
| H15 | `created` never changes; `updated` is the write's time, and equals the newest snapshot's and the change row's | `created` set on a replace |
| H16 | `author` is the asking account, in the node and the snapshot | the owner of another row |
| H17 | No title or body in a log line or a logged raise | a raise with the content as an irritant |
| H18 | Paging shows every node once, and revisions strictly falling | `>=` for `>` |
| H19 | `node-in-use?` is the only query without an owner | a second one |

- H2: the generator varies title, body and content type each on its own.
- H4: a change row's node, revision, op and time are compared, not only its number.
- H5: the model holds each key's `last_used` and a clock that crosses a day, so a
  refusal that was returned and not raised shows.
- H6: the generator aims account B at account A's id at A's own revision, and the
  suite reports which cells of D5 were reached.
- H8: the request's cap is tested in `test-node-routes.sps`.
- H10: the RFC variant too.
- H11: `kind` sent left out, the same and different.

## Not in this slice

- The lifecycle: archive, trash, purge, tombstones (4b).
- Parents, moves and links (5). Props and task transitions (6). Tags and search
  (7). Reading the change feed (8).
- `PATCH`, and `GET` with `If-None-Match`.
