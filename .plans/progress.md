# Progress ledger

Where Techo stands. Read it with [global-constraints.md](global-constraints.md) before
starting slice work. When a slice merges, update **Now** and **Next**, and add a
close-out under **Close-outs**, newest first.

## Now

- **The outline is merged**, squashed from
  [PR #1](https://github.com/Kiyomi-Computation-Systems/techo/pull/1) on 2026-11-22
  (4b06708). It is [outline.md](outline.md).
- **Twelve decisions are recorded**, ADR-0001 to ADR-0012, in [decisions/](decisions/),
  with the rules they make in [global-constraints.md](global-constraints.md).
- **Slice 1 is merged**, squashed from
  [PR #2](https://github.com/Kiyomi-Computation-Systems/techo/pull/2) on 2026-11-22
  (980b424): the build, the pins, `techo serve` with `/health`, five suites, CI and
  [the loop-stall report](research/2026-11-22-loop-stall.md).
- **`await-outside` is on the path** (2026-11-23): circuit is pinned at 442dd85, and
  chez-http-server 0.12.0 comes from a submodule until the index has it (ADR-0011,
  amended 2026-11-23).
- **Slice 2 is merged**, squashed from
  [PR #6](https://github.com/Kiyomi-Computation-Systems/techo/pull/6) on 2026-11-23:
  `techo migrate`, `serve`'s database check, and the migrate state machine verified in six layers
  ([the plan](2026-11-23-slice-2-migrations.md), ADR-0012). No table yet:
  [schema.md](schema.md) sketches them.
- **Slice 2b, the doorway, is built** on branch `slice-2b-doorway`, not yet merged:
  one write thread and `TECHO_DB_READERS` read threads on circuit's worker, each job
  one transaction run by a table, through a handle
  ([the plan](2026-11-23-slice-2b-doorway.md), ADR-0013). No route uses it yet.
- **circuit is pinned at b7e6f95,** its W2, which has the worker. Its W3 (a39346c,
  2026-11-24) adds only docs and an example: the pin has not moved to it.
- **`techo user add` moved to slice 3** (owner, 2026-11-22).
- **ADR-0006's amendment is accepted** (owner, 2026-11-23): a key is looked up by its
  BLAKE2b hash.
- **T5 is restated** (owner, 2026-11-23; ADR-0008's second amendment), since circuit's
  worker refuses queued jobs at a stop.

## Next

Merge slice 2b. Then slice 3, accounts, which waits on chez-sodium M3 and brings the
first table, the first route through the doorway and the first request log.

**Watch for:** the Akku index gaining chez-http-server 0.12.0 and a chez-websocket
that admits it. That ends the server's submodule (ADR-0011, amended 2026-11-23).
Nothing fails when it happens.

## Slices

| # | Slice | State | Waits on |
|---|---|---|---|
| 1 | Skeleton, health endpoint, loop-stall spike | merged (PR #2) | |
| 2 | Migrations, the CLI's `migrate`, `serve`'s check | merged (PR #6) | |
| 2b | The database doorway: write and read workers | built, not merged | |
| 3 | Accounts, `techo user add`, login, API keys | not planned | chez-sodium M3 |
| 4 | Node create, read, update; revisions; `If-Match` | not planned | unique-id |
| 5 | The tree and move; links | not planned | |
| 6 | Kinds and props; task transitions | not planned | |
| 7 | Tags and search | not planned | |
| 8 | The change feed | not planned | |
| 9 | Docker image and backup | not planned | |

## Sibling projects

Each has its own repository, beside this one on the owner's machine, and its own
ledger. The briefs in [briefs/](briefs/) are the snapshots handed over; **the sibling's
own `.plans/` is the truth from then on.**

| Project | Where | State on 2026-11-22 |
|---|---|---|
| chez-sodium | `../chez-sodium` | Repository made; its brief under adversarial review |
| unique-id | `../unique-id` | v0.1.0 released (2026-11-23, e0ed128); not pinned here yet: slice 4 takes it |
| chez-http-server: `await-outside` | `../chez-http-server` | Released in v0.12.0 (bba2ba6); not on the Akku index yet |
| circuit: the worker | `../circuit` | Issue 53 done: W2, the shell (b7e6f95, pinned here); W3, the docs (a39346c, 2026-11-24) |

## Open questions

From [outline.md](outline.md) §14, each for the slice named:

| Question | Slice |
|---|---|
| Does the server refuse an id that is not version 7? | 4 |
| The node lifecycle's states, and which transitions can be undone | 4 |
| A Contact's first fields, exactly | 6 |
| The login rate limit's numbers | 3 |
| Is an account's id a UUID or an integer? ([schema.md](schema.md)) | 3 |
| Does password hashing go to a worker of its own? (ADR-0013) | 3 |
| One write job a request, so that a 503 is a "no" for the whole request? | 3 |
| May two `serve` processes share one file? Nothing stops them today. | 3 |
| The container's stop grace (30 s) and a check that asks more than `/health` | 9 |

## Close-outs

### Slice 2b: the doorway (built 2026-11-23, not yet merged)

- **Built:** `(techo transaction)`, `(techo doorway)` and `(techo serve)`;
  `TECHO_DB_READERS`; `serve` opening and stopping the workers by a table; six new
  suites, fifteen in all; ADR-0013; the "Upgrading" section of `docs/running.md`.
- **Decided on the way:** D1 to D11 of the plan, all as recommended. A job gets a
  handle, never the connection. Every job checks the file's version first. A
  connection is never reopened. The writer's tear-down only closes.
- **Verified:** every `make` check on the final tree. Nine model configurations, up
  to 325,355 worlds each, with T1, T2, T4 to T6 and T8 to T10 holding. 921 traces and
  17,876 steps replayed on real SQLite, 94% of them real. Real threads and a real
  server: 1,000 writes each read back, a read during a held write, a full queue,
  `SIGTERM` idle and mid-write, `kill -9` mid-write, a `migrate` beside the server.
- **Not verified:** CI, until the pull request runs it. A signal in the 70 ms
  between the workers opening and the server listening. Nine table rows on real
  SQLite: they are reached only by injection, since SQLite cannot be made to fail a
  plain `BEGIN`, a version read, a `ROLLBACK` or a close. That SQLite is busy nowhere
  but at `BEGIN IMMEDIATE`.
- **Left for later:**
  - What the third review recorded and did not fix (the plan's last section).
  - Two places where the model is wrong off the real tables' paths, pinned as
    expected failures in the replay suite. The model is the one to change.
  - Keeping `migrate` out by a lock, and exiting on "moved" (ADR-0013).
  - A count of unfinished statements from chez-sqlite3, as a second guard.
  - Slice 2's "nothing stops `migrate` beside a running server" is now detected, not
    prevented.
- **Found on the way** (each in [traps.md](traps.md)):
  - A statement a job leaves open outlives its transaction.
  - SQLite can end a transaction and raise in the same call.
  - A `PRAGMA` run inside a transaction can outlive it, and `EXPLAIN` does not stop
    one.
  - A read-only connection that closes last leaves the `-wal`.
  - `exit` does not wait for threads.
  - Lines written from two threads run together.
- **What each review caught:** the first, that a dropped statement survives the
  rollback, which made the handle. The second, that the handle's check missed a call
  that raises after SQLite ended the transaction. The third, `EXPLAIN PRAGMA`, and a
  write thread on a file it may not write. Each was in a part the review before it
  had caused to be written.

### Slice 2: migrations (PR #6, 2026-11-23)

- **Merged:** `techo migrate`; `serve`'s database check; `(techo machine)`,
  `(techo migrations)` and `(techo db)`; the explorer and the file's model; ten suites;
  `make machines`; ADR-0012 and [schema.md](schema.md).
- **Decided on the way:** the doorway is slice 2b; tables arrive with their slices; ids
  are blobs; migrations are Scheme data, forward only; the version is `user_version`;
  a file that will be refused is opened only read-only; a hot rollback journal is
  named, not recovered.
- **Verified:** every `make` check on the final tree, and CI green on its first run.
  2.96 million model worlds with M1 to M12 and ML1 to ML3 holding; 818 traces replayed
  on real SQLite; `kill -9` mid-migration and mid-write in WAL.
- **Not verified:** Ctrl-C on a real terminal; a kill during the WAL conversion; a disk
  filling at `COMMIT`; 8 of the 14 list shapes in the suite (all 14 passed once by
  hand).
- **Left for later:**
  - Nothing stops `migrate` beside a running server. Slice 2b can close it.
  - Ctrl-C during a migration exits 255 and prints nothing.
  - A `COMMIT` inside a migration is stopped by the check on the shipped list, not at
    run time.
  - The binary's output on a run that made progress and then failed has no test.
  - Layer 3 has no property tying a result's kind to the file. Layers 2 and 4 hold it.
  - unique-id v0.1.0 is released and not pinned: slice 4 takes it.
- **Found on the way** (each in [traps.md](traps.md)):
  - Chez's `equal-hash` reads only the start of a value.
  - `pkill -f` kills the shell that runs it.
- **What the verification caught that the reviews did not:** the exploration found
  R26b's hole, which two plan reviews had read past. The closing review then found
  the trailing-slash bug, which no layer could: the model assumed Chez and SQLite
  agree on what a missing file is, and no clause said so.

### Slice 1: the skeleton (PR #2, 2026-11-22)

- **Merged:** the Makefile and Guix container, the pins (Akku.lock and three
  submodules), `techo serve` with `GET /health`, `techo version` and `help`, five
  suites with 75 tests, Linux CI, the loop-stall spike and its report.
- **Decided on the way:** slice 2 waits for `await-outside`; writes and reads on
  separate threads; the worker modelled and verified; `techo user add` in slice 3; a
  pin is a full commit SHA (ADR-0011, amended).
- **Filed:** circuit 51 (merged there as 5cf5946) and 53; chez-http-server 262.
- **Verified:** every `make` check on the final tree, and CI green on its first run,
  which is also the fresh clone.
- **Not verified:** a commit's worst time on a quiet disk. The spike's disk numbers
  were taken on a busy host.
- **Left for later:**
  - `check-pins` compares version ranges, not resolved versions.
  - `techo help x` exits 0 while `techo version x` exits 2.
  - Copied comments name test scripts Techo does not have.
  - The 25 ms worst write in memory is unexplained (the report says how to find out).
- **Found on the way** (each in [traps.md](traps.md)):
  - A step that clears shared build output breaks a second run beside it, and `$$` is
    the same in every container.
  - A shallow checkout has no tags.
  - A benchmark that syncs measures whatever else is writing to the disk.
- **What the review caught that the builders and the lead did not:** the CI blocker,
  and that the lead's own fix for the race was broken. Both came from the read-only
  review at the end, on code that every local check passed.

### The outline (PR #1, 2026-11-22)

- **Merged:** [outline.md](outline.md) and three briefs, for chez-sodium, a UUID
  library (now unique-id), and chez-http-server's `await-outside`.
- **Decided in discussion:** what ADR-0001 to ADR-0010 now record.
- **Filed:** chez-http-server issue 260.
- **Not verified:** nothing was run. The proposal was read against chez-http-server's
  source; libsodium's signatures in the chez-sodium brief were from memory.
- **Found on the way:**
  - Akku's `uuid` package has versions 1 to 5 only, and its name is taken.
  - A worker thread's blocking C call still stalls the loop unless the call is
    `__collect_safe`. chez-sqlite3's are.
