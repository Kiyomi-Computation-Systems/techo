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
- **Slice 2b, the doorway, waits for circuit's worker**, the third item of
  [circuit issue 53](https://github.com/Kiyomi-Computation-Systems/circuit/issues/53)
  ([the brief](briefs/circuit-worker.md)). Its design is merged there
  ([circuit PR 55](https://github.com/Kiyomi-Computation-Systems/circuit/pull/55),
  06f1894, with its ADR-0013). circuit builds it in three slices, and Techo needs the
  second, which has `make-worker` and `worker-call` (ADR-0008, amended 2026-11-23).
- **`techo user add` moved to slice 3** (owner, 2026-11-22).
- **ADR-0006's amendment is accepted** (owner, 2026-11-23): a key is looked up by its
  BLAKE2b hash.
- **T5 is restated** (owner, 2026-11-23; ADR-0008's second amendment), since circuit's
  worker refuses queued jobs at a stop.

## Next

Plan slice 2b against circuit's merged worker design, once
circuit's shell slice, W2, lands. The plan starts from ADR-0008's amendments, the
brief's §9 and §10, and the slice 2 plan's "For slice 2b".

**Watch for:** the Akku index gaining chez-http-server 0.12.0 and a chez-websocket
that admits it. That ends the server's submodule (ADR-0011, amended 2026-11-23).
Nothing fails when it happens.

## Slices

| # | Slice | State | Waits on |
|---|---|---|---|
| 1 | Skeleton, health endpoint, loop-stall spike | merged (PR #2) | |
| 2 | Migrations, the CLI's `migrate`, `serve`'s check | merged (PR #6) | |
| 2b | The database doorway: write and read workers | not planned | circuit issue 53's worker, W2 |
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
| circuit: the worker | `../circuit` | Issue 53: items 1 and 2 merged (442dd85); the worker's design is merged (06f1894); W1, the machine, is next, then W2, the shell |

## Open questions

From [outline.md](outline.md) §14, each for the slice named:

| Question | Slice |
|---|---|
| Does the server refuse an id that is not version 7? | 4 |
| The node lifecycle's states, and which transitions can be undone | 4 |
| A Contact's first fields, exactly | 6 |
| The login rate limit's numbers | 3 |
| Is an account's id a UUID or an integer? ([schema.md](schema.md)) | 3 |

## Close-outs

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
