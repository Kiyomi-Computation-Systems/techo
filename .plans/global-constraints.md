# Global constraints

These rules bind every task brief. Each cites the decision record in
[decisions/](decisions/) it comes from, or `AGENTS.md`. If a rule here and its record
disagree, the record wins and this file gets fixed.

## Platform and stack

- **Linux only.** CI runs on Linux; no macOS runner (ADR-0001, `AGENTS.md`). The
  Makefile's everyday targets also run on macOS, for development, tested by hand
  (ADR-0001, amended 2026-11-24).
- **Chez Scheme 10.4.1 or later, threaded** (ADR-0001).
- **The stack is fixed:** circuit, chez-sqlite3, chez-curl, threading, SRFI-64,
  chez-sodium, unique-id. A new dependency needs a decision record (ADR-0001).
- **Akku 1.2.0** manages what the Akku index holds (ADR-0001).
- **The owner's libraries outside the index are git submodules under `vendor/`,** each
  pinned at a commit. Techo's `Akku.manifest` names the index dependencies each one
  needs, and `make check-pins` holds them together (ADR-0011).
- **chez-http-server 0.12.0 comes from the submodule `vendor/chez-http-server`,** ahead
  of Akku's 0.11.0, until the index has it. The manifest keeps `^0.11.0` (ADR-0011,
  amended 2026-11-23).
- **On a Guix host, every build and test runs through `scripts/guix-env`** (ADR-0001,
  `AGENTS.md`).

## Code

- **Functional core, imperative shell.** Validation, state machines and revision logic
  are pure. Handlers, SQLite, the clock and entropy are the shell (`AGENTS.md`).
- **Libraries are R6RS `.sls`,** each holding its own code. No exported variable is
  assigned (`AGENTS.md`).
- **Every exported procedure has a Typed Racket style signature comment**
  (`AGENTS.md`).
- **Behaviour with states is a transition table** and a pure step function, never
  scattered conditionals (ADR-0007).

## The API

- **REST with JSON.** A command is a `POST` to a sub-resource (ADR-0002).
- **Every refusal uses the one error format:** RFC 9457 problem details with a `code`
  member (ADR-0002, amended 2026-11-24). A handler refuses through `(techo errors)`.
- **Every list is paged, with a server-side cap:** `limit` (50, at most 100) and
  `after` (ADR-0002, amended; ADR-0008).
- **A time in the API is whole milliseconds since 1970, UTC** (ADR-0002, amended).
- **Routes live under `/v1`,** but `/health` (ADR-0002, amended).
- **Every write to a node carries `If-Match`,** or `If-None-Match: *` to make it.
  Stale answers 412, neither 428 (ADR-0004, amended 2026-11-25). The one
  exception: a bulk move's children, moved on the node's `If-Match` (ADR-0004,
  amended 2026-11-26). A link is no write to a node and takes no precondition
  (ADR-0004, amended 2026-11-26, links).
- **`If-Match` is one revision in quotes.** `*`, a list and a weak tag are refused
  (ADR-0004, amended).
- **A node's id is a UUID of version 7** (ADR-0004, amended).
- **A request's JSON is checked in time linear in its size** (slice 4's plan
  review).
- **No body is read before the key is known to be good.** A write with a body
  checks the key in a read job first, and again in its own job (ADR-0006, amended
  2026-11-25). Login has no key: its body is capped at 16 KiB.
- **A write's time is read after its body has arrived** (ADR-0006, amended).

## Data

- **Every change to a node bumps its revision,** and a change of content appends
  a snapshot, in one transaction. A change of state appends none (ADR-0004,
  amended 2026-11-25).
- **A link made or removed changes no node's row.** It writes one change row
  on its source, at the source's present revision (ADR-0004, amended
  2026-11-26, links).
- **Both ends of a link are live nodes of its owner,** and only the code keeps
  it so. A purge removes the node's links, both ways (ADR-0003, amended
  2026-11-26, links).
- **A link's answer is `link-command`'s.** The job reads whether the link is
  there first; no `INSERT OR IGNORE` (ADR-0007, amended 2026-11-26; traps.md).
- **A statement that reads or deletes links by target names `links_target`;**
  one by source never does; a typed page compares the id alone. A test holds
  each plan (traps.md).
- **History is append-only,** but for a purge, which removes a node's. A restore
  is a new revision (ADR-0004, amended).
- **A node's content is its newest snapshot's** (ADR-0004, amended).
- **A purged node's row stays, and no query that answers a client reads it.**
  Its id is never used again (ADR-0004, amended).
- **Stale is answered before the state, and the state before the kind,** by one
  pure function (ADR-0007, amended 2026-11-25). Then the new parent, then the
  children (ADR-0007, amended 2026-11-26).
- **The nodes of an account are a forest,** and only the code keeps it so: the
  foreign key on `parent` takes a loop and a purged row (ADR-0003, amended
  2026-11-26).
- **A recursive statement is written `FROM <cte> CROSS JOIN nodes`,** has its
  own cap, and has its plan held by a test (traps.md).
- **A move answers no body and writes no snapshot** (ADR-0004, amended
  2026-11-26).
- **No row's parent is a purged row** (ADR-0003, amended 2026-11-26).
- **Every change gets the owner's next sequence number,** in the same transaction
  (ADR-0004).
- **The server never interprets or merges a body** (ADR-0005).
- **Every query is scoped to the owner.** No handler reads another account's rows
  (ADR-0003). The one exception is `node-in-use?`, which reads an id alone
  (ADR-0003, amended 2026-11-25), as `key-by-hash` is the one for keys. A test
  holds it over `node-store-statements`: every statement there names the owner,
  but that one, the inserts and `SELECT changes()`.
- **The node store's SQL is in `node-store-statements`,** and nowhere else: a
  test reads the source for a statement written in place (slice 4's closing
  review).
- **A list never selects a body.** A test holds it on the statements' text and
  plans: the answers cannot show it (slice 4's closing review).
- **A node's kind never changes** (ADR-0003, amended).
- **A body is kept once, in its snapshot.** A node's row holds none (ADR-0004,
  amended).
- **A state change answers no body and reads none** (ADR-0002, amended
  2026-11-25).
- **A node's integer key never leaves the database** (ADR-0004, amended).
- **A large column is its table's last** (ADR-0004, amended; traps.md).
- **No raise in a node's job carries a title or a body:** a job's raise is logged
  whole (ADR-0013).
- **The five kinds are fixed,** and props are validated per kind before any write
  (ADR-0003).

## The database

- **One doorway.** A handler reaches SQLite only through `db-write` and `db-read`
  (ADR-0008, ADR-0013).
- **A job is one transaction, and the doorway owns it.** A job never runs `BEGIN`,
  `COMMIT`, `ROLLBACK`, a savepoint or a `PRAGMA` (ADR-0013).
- **A job sees a handle, never the connection** (ADR-0013).
- **A request that writes and then reads its own change does both in one write job**
  (ADR-0013).
- **Nothing waits inside a job:** no `await`, no `sleep-ms`, no body read. Read the
  request first. A job never calls `exit` (ADR-0008, ADR-0013).
- **A job is handed plain data, never a parameter** (ADR-0013).
- **A job changes no schema,** temporary objects included: a temporary trigger stays
  on the connection for every later job (ADR-0013, probed by its closing review).
- **Every job checks the file's version first.** It is what holds when someone
  migrates beside a running server (ADR-0013).
- **A 503 from the database is a "no". A 500 or no answer to a write is a "maybe"**
  (ADR-0008, ADR-0013).
- **Readers stop before the writer** (ADR-0013).
- **WAL mode, foreign keys on, a busy timeout set** (ADR-0008, ADR-0009). A
  connection that writes limits the `-wal` to 16 MiB and has `secure_delete` on
  (ADR-0008 and ADR-0004, amended 2026-11-26). `migrate`'s
  connection alone has foreign keys off, and checks them before each commit
  (ADR-0012).
- **A connection is opened with `open-techo-db`,** where the settings live once
  (ADR-0012).
- **The version is `user_version`, and the id is `application_id`.** There is no
  bookkeeping table (ADR-0012).
- **A shipped migration is never edited.** A change is a new migration (ADR-0012).
- **Migrations only go forward,** each a list of single statements. None begins or
  ends a transaction, attaches a database, or is a `PRAGMA` (ADR-0012).
- **A table arrives with the slice that uses it,** in that slice's migration
  (ADR-0012).
- **Table conventions:** `STRICT`; ids as 16-byte blobs; times as whole milliseconds
  since 1970, UTC; JSON as text with a `json_valid` check; a `CREATE INDEX` on an owner-scoped
  table begins with the owner; foreign keys declared (ADR-0012).
- **A file that will be refused is opened only read-only** (ADR-0012).
- **`serve` starts only on a current file in WAL.** Stop the server before migrating,
  and before a restore (ADR-0012, ADR-0013).

## Login

- **Login is refused before any reading or hashing** when its email or address is
  over the limit (ADR-0006, amended 2026-11-25).
- **A wrong email and a wrong password get the same answer and do the same work**
  (ADR-0006, amended).
- **A try is forgiven only where nothing was checked** (ADR-0006, amended).
- **Only `login-read` and `login-write` reach the database without a key,** and only
  the login route calls them (ADR-0006, amended).
- **A password is normalised to NFC** before it is hashed or verified, and never
  comes from the command line (ADR-0006, amended).
- **Hashing runs on the hasher's one thread,** never the loop's (ADR-0013, amended).
- **`TECHO_BEHIND_PROXY` is a count,** and the client's address is the Nth from the
  end of `X-Forwarded-For` (ADR-0009, amended).

## Secrets

- **A password is hashed with argon2id.** It is never logged, and never put in a
  condition's message (ADR-0006). A job's raise is logged whole, so this binds every
  job (ADR-0013).
- **An API key is stored only as its hash,** and shown once (ADR-0006).
- **An API key is 32 random bytes, found by its BLAKE2b hash on a unique index.** A raw
  secret or a signature is compared with `constant-time-bytevector=?`, never
  `bytevector=?` (ADR-0006, amended 2026-11-23).
- **Login is rate-limited before any hashing** (ADR-0006).
- **A key is hashed on the loop's thread, and only its hash enters a job** (ADR-0006,
  amended 2026-11-24).
- **A route reaches the database only through `db-read-as`, `db-write-as` and
  `db-write-with-body-as`,** which check the key in the request's own job. Only `techo.sps` names `db-read` and
  `db-write` (ADR-0006, amended).
- **A refusal leaves a job as `&refusal`,** which holds a code and an account id and
  nothing of the request (ADR-0006, amended).
- **A handler performs the command the key table's step names.** It decides no answer
  on its own (ADR-0007; ADR-0006, amended).
- **A read never writes `last_used`** (ADR-0006, amended).
- **No key makes a key,** and a key regenerates only itself (ADR-0006, amended).
- **The request log holds no query string, header or body** (ADR-0009, amended
  2026-11-24).

## Operations

- **All configuration comes from the environment** (ADR-0009).
- **`TECHO_DB_PATH` is absolute and names a file,** with no trailing slash: SQLite and
  Chez must agree on whether it exists (ADR-0012).
- **The server logs to standard output** (ADR-0009). A line is one write, from the
  loop's thread: lines from two threads run together (ADR-0013's plan, probed).
- **One binary is the server and the CLI** (ADR-0009).

## Tests

- **Test first, and watch each test fail** (`AGENTS.md`).
- **A state machine's table is checked exhaustively,** and its handlers by model-based
  tests against real SQLite (ADR-0007).
- **Integration tests drive the running server with chez-curl** (ADR-0001).
- SRFI-64's traps are in `AGENTS.md`, "Testing & mutation discipline". They bind.

## Process

- **A slice is one pull request,** squash-merged, with a close-out in
  [progress.md](progress.md).
- **A decision changes by a new or amended record,** never by an edit here alone.
- **Agents do not commit or push** unless the owner asks.
