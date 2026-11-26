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

## The tables to come

| Table | Slice | State |
|---|---|---|
| `links` | 5 | sketched |
| `tags`, or a column | 7 | open |
| `nodes_fts` | 7 | sketched, from the spike |
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

### nodes (shipped in migration 3, `state` in 4; ADR-0003, ADR-0004 amended)

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
               CHECK (state IN ('active','archived','trashed','purged'))
) STRICT;
CREATE INDEX nodes_owner ON nodes(owner, id);
```

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
- **To come, each by `ADD COLUMN`:** `parent` (5), tags (7, or a
  table). The table has no large column: at worst a title of 4,000 bytes puts later
  columns on one more page, not a walk of many.
- **Open (slice 5):** how a move is kept from making a loop.
- **Open (slice 6):** each kind's props.

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
- **Open (slice 5):** whether a snapshot holds the parent, so a restore can undo a
  move. **Open (slice 7):** how it holds tags.

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
  `create`, `update`, `restore`, `archive`, `unarchive`, `trash`, `untrash` and
  `purge`; the code's list is the truth. A `purge` row is the node's tombstone,
  and its last row.

### links (slice 5; ADR-0003)

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

- **Open:** the link types, and whether they are fixed. Whether a link change bumps
  either node's revision.

### tags (slice 7)

- **Open:** a `node_tags(owner, tag, node)` table, or a JSON column on `nodes`. A
  table makes "every node with this tag" an index read. A snapshot holds the tags as
  JSON either way.

### nodes_fts (slice 7)

- **Sketched from the spike, changed by slice 4:** an external-content FTS5 table
  over a view of each node's title and its newest snapshot's body, pointing at
  `nodes.num`, kept in step by one trigger on `revisions`
  (`build/probe-4/fts.sps`; not measured at size). A migration that creates a trigger is a single
  statement, so it fits ADR-0012's rule.
- **Known cost:** a ranked search for a word in nearly every note took 13 ms at medium
  size and 141 ms at large.
- **Open:** whether tags are searched there too.
