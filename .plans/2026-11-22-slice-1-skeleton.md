# Slice 1: the skeleton, a health endpoint, and the loop-stall spike

Date: 2026-11-22
Status: approved (owner, 2026-11-22; the answers are in §6)
Binds: [global-constraints.md](global-constraints.md)
Decisions: ADR-0001, ADR-0008, ADR-0009, ADR-0011

## 1. Goal

A repository that builds and tests in the pinned container and in CI, serves one
endpoint, and has measured how long SQLite holds the loop.

**After this slice:**

- `scripts/guix-env make test` is green, and so is CI.
- `techo serve` answers `GET /health`.
- A test starts the server and calls it with chez-curl.
- A report says how long each representative query blocks the loop, and whether
  ADR-0008 stands.

## 2. Not in this slice

- Any schema, migration or real table (slice 2). The spike makes its own throwaway
  database.
- Accounts, nodes, the error format.
- The Docker image (slice 9).
- chez-sodium and unique-id. Nothing here needs them.

## 3. Work, in order

Each step is test-first: write the check, watch it fail, then make it pass.

### 3.1 The Makefile and the container

1. `Makefile` with `help`, and `check-help`, which fails unless `help` lists exactly
   the `.PHONY` targets.
2. `channels.scm`, `manifest.scm`, `scripts/guix-env`, `guix-env-enter`,
   `guix-env-selftest`, `require-tools`, copied from circuit and adapted.
   - The manifest needs: Chez 10.4.1 threaded, libuv, SQLite, libcurl, a C compiler
     for chez-libuv's shim, `make`, and the usual shell tools.
3. `make check-guix`, run on the host.

### 3.2 Dependencies

4. `Akku.manifest` and `Akku.lock`, for what the index holds: threading, chez-srfi as
   a development dependency, and what circuit needs from the index (chez-http-server,
   chez-websocket, hashing, jsonparse).
5. circuit, chez-sqlite3 and chez-curl as git submodules under `vendor/`, each pinned
   at a commit (ADR-0011). `Akku.manifest` repeats circuit's own index dependencies.
6. `make fetch`, on the host: fetches each tree as pinned, with its checksum checked.
7. `make deps`, in the container: builds chez-libuv's shim and links SRFI-64. It never
   fetches.
8. `make check-pins`: fails unless the lock, the fetched trees and the pins agree, and
   unless Techo's manifest admits every index dependency that circuit's manifest, at
   its pinned commit, names.

### 3.3 The test runner

9. `make test` runs every `tests/test-*.sps` under a timeout. It fails if one fails or
   hangs, or if there is none.
10. A shared exit form that every suite ends with, and `make check-suites`, which
    fails on a suite without it.
11. `make check-test-fails`: plants a failing suite and a hanging one in a copy, and
    requires `make test` to fail on each, by name.

### 3.4 Configuration: the first pure library

12. `(techo config)`: a pure procedure from an environment lookup to either a
    configuration or a list of what is wrong.
    - It takes the lookup as an argument, as `serve` does, so tests pass their own.
    - Variables: `TECHO_DB_PATH`, required. The server's host and port stay
      chez-http-server's own (ADR-0009).
    - Tests: a good environment; a missing variable; an empty one; a relative path.
13. The shell prints every problem and exits non-zero before anything listens.

### 3.5 The program

14. `techo.sps`, with sub-commands dispatched by a pure parser:
    - `techo serve`
    - `techo version`
    - anything else prints usage and exits non-zero.
15. `GET /health` answers 200 and `{"status":"ok"}`.
    - It is a circuit handler, tested with `make-test-req`, with no server.
    - Any other path answers 404, as JSON.
16. `make run`.

### 3.6 The integration test

17. A suite that starts `techo serve` on a free loopback port, waits for its
    `listening` log line, calls `/health` with chez-curl, checks the answer, sends
    SIGTERM, and checks the server exits cleanly.
    - This is the pattern every later slice's integration tests follow.

### 3.7 CI

18. `.github/workflows/ci.yml`: one Linux job. It builds or restores the pinned Chez,
    fetches, and runs `make test`. Every action is pinned by commit.
19. A check that the workflow keeps that shape, if circuit's is cheap to copy.

### 3.8 The spike (§4)

20. Run it, and write its report.

### 3.9 Records

21. `CHANGELOG.md`, with an Unreleased section.
22. `README.org`: how to build, test and run.
23. `docs/`: one page, on running the server.
24. The ledger's close-out, and any trap met, reproduced first.

## 4. The spike: how long does SQLite hold the loop?

**The question.** ADR-0008 puts every query on the loop's thread. How long does each
representative query block it, on a database of realistic size?

**Where it lives.** `.plans/research/spike/`, with its report beside it. Spike code is
not `src/` code and is not reused.

**The database.** A throwaway file in WAL mode, with a nodes table, a revisions table
and an FTS5 index, shaped as [outline.md](outline.md) §3 and §4 describe. Filled at
three sizes:

| Size | Nodes | Revisions per node | Body |
|---|---|---|---|
| small | 1,000 | 5 | about 2 KB of text |
| medium | 20,000 | 10 | about 2 KB |
| large | 200,000 | 10 | about 2 KB |

**What is timed**, each many times, on each size:

| Operation | What it does |
|---|---|
| read | one node by id |
| write | update one node, bump its revision, append a snapshot, take a sequence number: one transaction |
| list | a page of 100 children of one parent |
| search | an FTS5 query for a common word and for a rare one, first page of 50 |
| feed | 500 changes after a cursor |
| checkpoint | a write that triggers a WAL checkpoint |

**What is reported**, per operation and size: the median, the 99th percentile and the
worst, in milliseconds.

**Under load.** A second measurement, through the real server: while one client runs
searches in a loop, another times `GET /health`. This is the number a user feels.

**Also check:**

- FTS5 and the JSON functions are present in the container's SQLite and in Ubuntu
  24.04's.
- What the database's size on disk is at each size, since every write keeps a
  snapshot (ADR-0004).

**What the numbers decide:**

| Worst case, medium size | Meaning |
|---|---|
| under 5 ms | ADR-0008 stands as it is. |
| 5 to 50 ms | ADR-0008 stands for v1. The worker thread is planned for when `await-outside` is released. |
| over 50 ms | Stop. Find out which operation, and bring the numbers to the owner before slice 2. |

The owner agreed these thresholds on 2026-11-22.

## 5. Done when

- [x] `make help` lists every target, and `make check-help` passes.
- [x] `make check-guix` passes on the host.
- [x] `scripts/guix-env make test` passes, from a fresh clone, after `make fetch`.
- [x] Each check has been seen to fail: a planted failing suite, a planted hang, a bad
      configuration.
- [x] `techo serve` answers `/health`, and the integration suite passes.
- [x] CI is green on the pull request.
- [x] The spike's report is written, with its verdict against §4's table.
- [x] `CHANGELOG.md`, `README.org` and the ledger are updated.

## 6. The owner's answers (2026-11-22)

| Question | Answer |
|---|---|
| How are circuit, chez-sqlite3 and chez-curl fetched? | Git submodules, for now. Akku's publishing is slow, and circuit will not be released until Techo has proved it out. Recorded as ADR-0011. |
| The health path | `/health` |
| Does the health check touch the database? | From slice 2, not in this one. |
| The spike's thresholds | 5 ms and 50 ms, as §4 has them. |

## 7. Risks

- **The container's SQLite may lack FTS5.** The spike checks first. If it does, the
  manifest needs another SQLite build before slice 7.
- **chez-curl's own tests need Node.js; a program using it does not.** Techo's
  manifest should not need Node. Confirm when writing the integration suite.
- **Starting a server inside a test is the first of its kind here.** Port choice, the
  wait for `listening`, and cleanup after a failed test all need care, or later
  suites inherit a flaky pattern.
