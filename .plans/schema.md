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

## The tables to come

| Table | Slice | State |
|---|---|---|
| `nodes` | 4 | core decided; lifecycle open |
| `revisions` | 4 | decided |
| `changes` | 4, read in 8 | decided |
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

### nodes (slice 4; ADR-0003, ADR-0004)

```sql
CREATE TABLE nodes (
  id           BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  owner        BLOB    NOT NULL REFERENCES accounts(id),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  kind         TEXT    NOT NULL CHECK (kind IN ('project','journal','note','task','contact')),
  title        TEXT    NOT NULL,
  body         TEXT    NOT NULL,
  content_type TEXT    NOT NULL,
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  parent       BLOB    REFERENCES nodes(id),
  state        TEXT    NOT NULL,           -- the lifecycle
  revision     INTEGER NOT NULL,
  created      INTEGER NOT NULL,
  updated      INTEGER NOT NULL
) STRICT;
CREATE INDEX nodes_owner_parent ON nodes(owner, parent, id);
```

- **Decided:** one table for all five kinds; one parent or none; the revision is the
  ETag.
- **Open (slice 4):** the lifecycle's states and which can be undone. Whether a purged
  node keeps a row.
- **Open (slice 5):** how a move is kept from making a loop.
- **Open (slice 6):** each kind's props.

### revisions (slice 4; ADR-0004)

```sql
CREATE TABLE revisions (
  node     BLOB    NOT NULL REFERENCES nodes(id),
  revision INTEGER NOT NULL,
  title    TEXT    NOT NULL,
  body     TEXT    NOT NULL,
  props    TEXT    NOT NULL CHECK (json_valid(props)),
  tags     TEXT    NOT NULL CHECK (json_valid(tags)),
  parent   BLOB,
  created  INTEGER NOT NULL,
  PRIMARY KEY (node, revision)
) STRICT, WITHOUT ROWID;
```

- **Decided:** a full snapshot for every write, append-only.
- **Known cost:** the spike measured about 4.7 KB for each snapshot of a 2 KB note.
- **Open:** whether a snapshot holds the parent, so a restore can undo a move.

### changes (slice 4 writes it, slice 8 reads it; ADR-0004)

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
- **Open:** the list of `op` values, which follows the node lifecycle.

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

- **Sketched from the spike:** an external-content FTS5 table over title and body,
  kept in step by three triggers. A migration that creates a trigger is a single
  statement, so it fits ADR-0012's rule.
- **Known cost:** a ranked search for a word in nearly every note took 13 ms at medium
  size and 141 ms at large.
- **Open:** whether tags are searched there too.
