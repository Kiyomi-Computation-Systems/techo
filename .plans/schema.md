# The schema, sketched

The v1 tables, seen whole before any is built. **Nothing here is frozen.** A table
arrives in a migration with the slice that uses it (ADR-0012), and that migration is
the truth from then on. Each table says what is decided and what is open.

Every table follows ADR-0012's conventions: `STRICT`; ids as 16-byte blobs; times as
whole milliseconds since 1970, UTC; JSON as text with a `json_valid` check; a
`CREATE INDEX` on an owner-scoped table begins with the owner; foreign keys declared.

## What the file holds today

| Version | Migration | What it does |
|---|---|---|
| 1 | techo's database | Sets `application_id` to `0x74656368`. No table. |
| 2 | accounts and api keys | Creates `accounts`, `api_keys` and the index `api_keys_account`. |
| 3 | nodes, revisions and changes | Creates `nodes`, `revisions`, `changes` and the index `nodes_owner`. |
| 4 | a node's state | Adds `nodes.state`. Every node there is becomes `active`. |
| 5 | a node's parent | Adds `nodes.parent` and the index `nodes_parent`. Every node there is has none. |
| 6 | links | Creates `links` and the index `links_target`. |
| 7 | tags | Creates `node_tags` and the index `node_tags_node`. Adds `revisions.tags`. Every snapshot there is has `[]`. |

## The tables to come

| Table | Slice | State |
|---|---|---|
| `nodes_fts` | 7b | sketched, from the spike; the tokenizer decided (`unicode61`) |
| attachments | not in v1 | shape fixed (ADR-0010) |

### accounts (shipped in migration 2; ADR-0006)

```sql
CREATE TABLE accounts (
  id            BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  username      TEXT    NOT NULL UNIQUE CHECK (username GLOB '[a-z0-9]*' AND username NOT GLOB '*[^a-z0-9_-]*' AND length(username) <= 32),
  email         TEXT    NOT NULL UNIQUE CHECK (email NOT GLOB '*[A-Z]*'),
  password_hash TEXT    NOT NULL,          -- argon2id's own string
  created       INTEGER NOT NULL
) STRICT;
```

- **Decided:** the id is a UUIDv7 blob, one rule for every id.
- **Decided:** email is stored in lowercase, by ASCII's letters alone, and the
  table's `CHECK` holds it there. It uses `GLOB`, whose range is ASCII on every
  build. `lower()` folds more on a build with ICU, and would then refuse what the
  code hands it.
- **Decided:** the table also holds a username's shape, and a key's name's length.

### api_keys (shipped in migration 2; ADR-0006, amended)

```sql
CREATE TABLE api_keys (
  id        BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  account   BLOB    NOT NULL REFERENCES accounts(id),
  name      TEXT    NOT NULL CHECK (length(name) BETWEEN 1 AND 64),  -- the device
  key_hash  BLOB    NOT NULL UNIQUE CHECK (length(key_hash) = 32),  -- BLAKE2b
  created   INTEGER NOT NULL,
  last_used INTEGER,
  revoked   INTEGER
) STRICT;
CREATE INDEX api_keys_account ON api_keys(account, id);
```

- **Decided:** a key is found by `WHERE key_hash = ?` on the unique index.
- **Decided:** `revoked` is a time, and null means active.
- **Decided:** `last_used` is set only by a request that writes, at most once a day.
- **Open:** the login rate limit's counters. Slice 3b: in memory.

### nodes (shipped in migration 3, `state` in 4, `parent` in 5; ADR-0003, ADR-0004 amended)

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
  updated      INTEGER NOT NULL,
  state        TEXT    NOT NULL DEFAULT 'active'      -- migration 4, by ADD COLUMN
               CHECK (state IN ('active','archived','trashed','purged')),
  parent       BLOB    REFERENCES nodes(id)           -- migration 5, by ADD COLUMN
               CHECK (parent IS NULL OR length(parent) = 16)
) STRICT;
CREATE INDEX nodes_owner ON nodes(owner, id);
CREATE INDEX nodes_parent ON nodes(owner, parent, id);   -- migration 5
```

- **Decided:** `parent` is null at the top level. A purged row's is null, so no
  row points at a purged one.
- **The foreign key keeps none of the tree's rules.** It takes a loop, a purged
  row and another account's node. The code's checks keep the forest
  (ADR-0003, amended 2026-11-26).
- **Not built:** an index on `parent` alone. Nothing deletes a node's row, and
  an update of a parent does not look at its children.
- **`state` and `parent` sit behind `props`.** Slice 6 decides whether props may
  grow large (traps.md).

- **Decided:** no body here. A node's body is its newest snapshot's. A change of
  state bumps `revision` and writes no snapshot, so the two numbers can differ.
- **Decided:** a purged node keeps its row, emptied: title `''`, props `'{}'`,
  content type `application/octet-stream`, no snapshots. Its id and `num` are
  never used again. No query that answers a client reads it.
- **Decided:** `state` has a `CHECK`, as `kind` has. A fifth state would mean
  rebuilding the table.
- **Not built:** an index `(owner, state, id)`. A list of a rare state reads the
  account's rows: 10 ms for 10 trashed among 100,000.
- **Decided:** `num` is for a search index to point at, and never leaves the
  database. Every lookup is by `id`.
- **Tags came as a table,** `node_tags` (slice 7a, below), not a column. The table has no large column: at worst a title of 4,000 bytes puts later
  columns on one more page, not a walk of many.
- **Decided (slice 6):** each kind's props, checked before any write and stored in
  one canonical form of at most 4,096 bytes (ADR-0003, amended 2026-11-27). The
  column's only check is still `json_valid`: the code's rules are the truth. A
  Task's default status is not stored, so a Task from before reads as `TODO`.
- **Kept ready:** past about 8 KiB of props, rebuild the table with `props` last,
  or move it out.

### revisions (shipped in migration 3; ADR-0004 amended)

```sql
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

- **Decided:** a full snapshot for every write of content, and the only copy of
  a body. Append-only, but for a purge, which deletes a node's. The body is the last column: one before others costs a walk of its
  pages to read them.
- **Decided:** a plain table. `WITHOUT ROWID` took 4,670 bytes a snapshot of a
  2,000-character body against 4,135, and was slower to read.
- **Decided (slice 5a):** a snapshot holds no parent. A move writes none, and a
  restore does not undo a move.
- **Decided (slice 7a):** `tags`, a JSON array of the stored forms, added by
  migration 7 behind `body` (`'[]'` for a snapshot from before). It is written
  from the node's rows in `node_tags` in the same statement, and a rename of
  a tag writes no snapshot: so a node's newest snapshot may hold an older
  name. `op` `tags` in `changes` marks each such change.

### changes (shipped in migration 3; slice 8 reads it; ADR-0004)

```sql
CREATE TABLE changes (
  owner    BLOB    NOT NULL REFERENCES accounts(id),
  seq      INTEGER NOT NULL,
  node     BLOB    NOT NULL,               -- no foreign key: a tombstone outlives its node
  revision INTEGER NOT NULL,
  op       TEXT    NOT NULL,
  created  INTEGER NOT NULL,
  PRIMARY KEY (owner, seq)
) STRICT, WITHOUT ROWID;
```

- **Decided:** each owner has its own sequence, and a change gets the next number in
  the write's own transaction.
- **Decided:** `op` has no `CHECK`: SQLite cannot change one. Today's values are
  `create`, `update`, `restore`, `archive`, `unarchive`, `trash`, `untrash`,
  `purge`, `move`, `link`, `unlink`, `done`, `wontdo`, `reopen` and `tags`; the code's list is
  the truth, but for `tags`, which the store writes itself and `event-op` does
  not name. A `link` or
  `unlink` row is on the link's source, at the source's present revision: two rows
  of a node can carry one revision. A `purge` row is the node's tombstone,
  and its last row.

### links (migration 6, slice 5b; ADR-0003)

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

- **Decided:** three types, `related`, `mentions`, `blocks`. `type` has no `CHECK`:
  the code's list is the truth.
- **Decided:** a link bumps neither node's revision (ADR-0004, amended).
- **Decided:** both ends are live nodes of the owner, and only the code keeps it so.
  The foreign keys take a purged row, a self link and another account's owner.
  A purge deletes the node's links, both ways.
- **Decided:** a read or delete by target names `links_target`; one by source never
  does (traps.md).

### node_tags (migration 7, slice 7a; ADR-0003)

```sql
CREATE TABLE node_tags (
  owner BLOB NOT NULL REFERENCES accounts(id),
  tag   TEXT NOT NULL CHECK (length(tag) BETWEEN 1 AND 64),
  node  BLOB NOT NULL REFERENCES nodes(id),
  PRIMARY KEY (owner, tag, node)
) STRICT, WITHOUT ROWID;
CREATE INDEX node_tags_node ON node_tags(owner, node);
```

- **Decided:** a node's present tags are its rows here, and nowhere else. A
  tag is in its stored form (ADR-0003, amended): the code folds it, the table
  checks only its length.
- **Decided:** the index begins with the owner. In a table with no rowid it
  holds the tag too, so a node's tags are read from it in order.
- **Not held by the file:** that a row's owner is its node's. The code keeps
  them equal, and the model checks it after every request.
- **A purge deletes the node's rows.** A rename or a removal of a tag changes
  at most 500 nodes' rows in one transaction.
- **Measured, 200,000 nodes and 660,000 rows, 4 KiB props:** a page of 51
  nodes with their tags 7.3 ms (6.7 before); a filter of up to 10 tags 0.9 to
  9 ms, driven from the rarest; 78 to 133 ms when every tag is on 1,000 or more
  nodes and none in common (the count's cap hides which is rarer); 19 to 43 ms
  for a rare tag under a parent of 20,000 children (it drives from
  `nodes_parent`); 203 to 269 ms, the worst found, for a tag on 185,000 nodes
  asked in a state none of them is in. Each holds a reader, never the writer.
- **Measured, the same file:** one step of a rename, 500 nodes, holds the
  writer 18 to 48 ms with its commit. During a rename of 185,000 nodes
  another account's write takes a median 19 ms, 35 ms at worst (2.4 ms alone).

### nodes_fts (slice 7b)

- **Sketched from the spike, changed by slice 4:** an external-content FTS5 table
  over a view of each node's title and its newest snapshot's body, pointing at
  `nodes.num`, kept in step by one trigger on `revisions`
  (`build/probe-4/fts.sps`; not measured at size). A migration that creates a trigger is a single
  statement, so it fits ADR-0012's rule.
- **Known cost:** a ranked search for a word in nearly every note took 13 ms at medium
  size and 141 ms at large.
- **Open:** whether tags are searched there too.
