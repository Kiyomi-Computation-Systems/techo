# Global constraints

These rules bind every task brief. Each cites the decision record in
[decisions/](decisions/) it comes from, or `AGENTS.md`. If a rule here and its record
disagree, the record wins and this file gets fixed.

## Platform and stack

- **Linux only.** CI runs on Linux; no macOS runner (ADR-0001, `AGENTS.md`).
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
- **Every refusal uses the one error format** (ADR-0002).
- **Every list is paged, with a server-side cap** (ADR-0002, ADR-0008).
- **Every write to a node carries `If-Match`.** Stale answers 412, missing 428
  (ADR-0004).

## Data

- **Every change to a node bumps its revision and appends a snapshot,** in one
  transaction (ADR-0004).
- **History is append-only.** A restore is a new revision (ADR-0004).
- **Every change gets the owner's next sequence number,** in the same transaction
  (ADR-0004).
- **The server never interprets or merges a body** (ADR-0005).
- **Every query is scoped to the owner.** No handler reads another account's rows
  (ADR-0003).
- **The five kinds are fixed,** and props are validated per kind before any write
  (ADR-0003).

## The database

- **One doorway.** A handler reaches SQLite only through it (ADR-0008).
- **Nothing waits inside the doorway's closure:** no `await`, no `sleep-ms`, no body
  read. Read the request first (ADR-0008).
- **WAL mode, foreign keys on, a busy timeout set** (ADR-0008, ADR-0009).

## Secrets

- **A password is hashed with argon2id.** It is never logged, and never put in a
  condition's message (ADR-0006).
- **An API key is stored only as its hash,** and shown once (ADR-0006).
- **An API key is 32 random bytes, found by its BLAKE2b hash on a unique index.** A raw
  secret or a signature is compared with `constant-time-bytevector=?`, never
  `bytevector=?` (ADR-0006, amended 2026-11-23).
- **Login is rate-limited before any hashing** (ADR-0006).

## Operations

- **All configuration comes from the environment** (ADR-0009).
- **The server logs to standard output** (ADR-0009).
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
