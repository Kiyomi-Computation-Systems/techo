# Slice 2b: the database doorway

Date: 2026-11-23
Status: decisions accepted (owner, 2026-11-23). Revised twice, each time on an
adversarial review (the last section). Built, and reviewed a third time.

Read with [global-constraints.md](global-constraints.md), [progress.md](progress.md),
ADR-0008 with its three amendments, and
[the circuit brief](briefs/circuit-worker.md) §9 and §10.

## Summary

- A handler reaches SQLite through one doorway: `db-write` and `db-read`.
- Behind it are two of circuit's workers: one write thread, and a few read threads.
- **Each job is one whole transaction,** begun and ended by the doorway, never by the
  job. A job gets a small handle, not the connection.
- **Each transaction is run by a table and a pure step function,** verified the way
  `migrate` was: static checks, every row, every small world, a replay on real
  SQLite, real threads.
- `techo serve` opens the doorway after its check and closes it after the server
  stops: readers first, the writer last.
- No route uses the doorway yet. The first table arrives with slice 3.

## What changed since this was sketched

- circuit's worker is on its `main` (b7e6f95, its W2). Techo's pin moves there, on its
  own commit (ADR-0011). All ten suites pass on it (run 2026-11-23).
- Its names: `make-worker`, `worker-call`, `worker-stop!`, `make-test-worker`,
  `&worker-full`, `&worker-stopped`, `wrap-busy`.

## Decisions for the owner

Each has a recommendation. The rest of this plan assumes the recommendations.
D1 to D4 are the four ADR-0008's first amendment left open.

**All eleven are accepted as recommended** (owner, 2026-11-23). On D6 the owner asked
that it be documented well: what that means is under D6 and in "Records and docs".

### D1. How many read threads

**Recommended:** a setting, `TECHO_DB_READERS`, a whole number from 1 to 16, default 2.
There is always exactly one write thread.

- Two, so one slow read does not queue every other read behind it.
- A setting, because the right number depends on the machine's cores, which the
  binary cannot know (ADR-0009).

Against: a constant 2, until something needs otherwise. One less row in the config.

### D2. How the doorway tells a read from a write

**Recommended:** the handler says so, by which procedure it calls: `db-write` or
`db-read`. A read job gets a read-only connection, so a write sent the wrong way
raises `readonly` (probed) and the request fails loudly.

Against: one procedure that looks at the request's method. A `POST` that only reads
(a search with a body) would then take the write thread.

### D3. No TLA+ specification

**Recommended:** none. The threads, the lock and the queue are circuit's, and verified
there. What Techo adds runs on one thread per connection, and the suite explores
it on the real step function, as it did for `migrate`.

### D4. Password hashing

**Recommended:** slice 3 decides, when the hash exists. A third worker with no
connection can carry it, and nothing in this slice is in its way.

### D5. `synchronous` stays `full`

**Recommended:** `full`, as `open-techo-db` sets today.

- Measured (2026-11-23, 200 commits, a host that was not quiet): `full` has a median
  of 1.1 ms and a worst of 5.9 ms; `normal` 0.015 ms and 0.17 ms.
- `normal` in WAL can lose the last commits at a power cut. T5 says no caller is told
  a write succeeded unless it committed, and a commit that a power cut takes back
  breaks that.
- The stall `full` risks now lands on the write thread alone. Reads and `/health` go
  on (T3).

Against: `normal`, 70 times faster per write. Worth it only if single-row write
throughput ever matters more than the last second of notes.

### D6. A `migrate` beside a running server

Today nothing stops it (probed again: with a server's two connections open and idle,
another process's `BEGIN IMMEDIATE`, version change and `COMMIT` all succeed).

**Recommended:** the server notices, inside every transaction. After its `BEGIN`, a
job's first statement reads `user_version`. If it is not this binary's latest, the
job never runs: the caller gets a 503 and the server logs why.

- It is sound: a write transaction holds the lock, and a read transaction holds one
  snapshot, so the version cannot change under a job that passed the check.
- It costs 3 microseconds a job (measured).
- The server then answers 503 to every database request until it is restarted, when
  its start check refuses with "this binary is older". It logs the reason once, from
  the loop's thread, not once a request. `/health` still answers 200, since it
  touches no database. Slice 9's container check must ask more than `/health`.
- **What it does not see:** a file replaced under the server, as a restore does. The
  server keeps writing to the old file. "Stop the server before a restore" stays a
  rule.

Against:

- **Keep `migrate` out instead.** A `migrate` that first sets
  `locking_mode = EXCLUSIVE` is refused as busy while any other connection is open
  (probed). But that changes slice 2's verified table and its replay, and a `sqlite3`
  shell left open would block every migration too. It can be added later, on top.
- **Leave it as a rule** ("stop the server first"). Then an old server writes into a
  new schema.
- **Exit on the first "moved",** so whatever supervises Techo restarts it into the
  start check's refusal. Cleaner than 503s for ever, but it needs a way to stop the
  server from inside a request, which is not probed. It can follow.

**Documented well** (owner, 2026-11-23). D6 detects; it does not prevent. So the
person running Techo must be told, in each of these places:

- **`docs/running.md`, a section "Upgrading":** the order (stop the server, back up,
  `techo migrate`, start the new server); what happens if `migrate` runs beside a
  live server (it succeeds, and the old server answers 503 to every database request
  from then on); how to tell (the one log line, quoted; 503s while `/health` says
  200); and the cure (restart, onto the new binary).
- **The log line itself** names the cause and the cure, with both versions: the one
  the file has and the one this server expects. One line, on standard output:

  ```
  database moved: the file is at version 3 and this server expects 2; a newer techo migrate ran beside it; database requests get 503 until the newer techo serves
  ```

  Its sibling, for a thread that closed its connection (W20, R16):

  ```
  database unavailable: a connection was closed after a failed rollback; database requests can get 503 until techo is restarted
  ```
- **`techo migrate`'s help text** says to stop the server first.
- **ADR-0013** records the choice, what it does not see (a file replaced under the
  server) and the two alternatives left for later.
- **`global-constraints.md`:** every job checks the version first; "stop the server
  before migrating" stays the rule for people, and the check is what holds when it is
  broken.
- **The ledger,** for slice 9: `/health` stays 200 through this, so the container's
  check must ask more.

### D7. A read's deadline does not interrupt it yet

A request that waits too long gets a 504 from `wrap-timeout`, and a job that had not
begun then never runs (circuit's S10). A job that had begun runs to its end.

**Recommended:** leave it so until slice 7, which brings the first query that can run
long (search: 141 ms at large size in the spike). Every read before then is an indexed
lookup under a page cap.

- Interrupting needs `interrupt-database!` from the loop's thread, a lock so it cannot
  land on the next job, and a model of its own. Probed: an interrupted read leaves its
  transaction open, an interrupted write does not, and an interrupt sent to an idle
  connection does nothing.
- The read table already has the row an interrupt needs (a job that raises with its
  transaction still open).

Against: build it now, with nothing slow to stop.

### D8. The numbers

**Recommended**, each a constant until something needs a setting:

| What | Value | Why |
|---|---|---|
| Write queue's cap | 64 | circuit's own example |
| Read queue's cap | 64 | its own queue, so a flood of reads cannot refuse a write |
| `Retry-After` on a 503 | 5 seconds | |
| A request's timeout | 10 seconds | above the busy timeout, so a write that lost the lock is told 503, not 504 |
| A connection's busy timeout | 5 seconds | as today |
| The server's drain | 10 seconds | chez-http-server's default, `CHEZ_HTTP_DRAIN_TIMEOUT` |

**A stop can take the drain and then the running write** (probed: a 2 s drain and a
6 s write exited at 6.1 s). Docker's default grace before it kills is 10 seconds, the
same as the drain. A kill is safe (T4), but it leaves the `-wal` for the next start to
recover and the exit is not 0. Slice 9's container sets a longer grace, 30 seconds.

### D9. Database time per request

ADR-0008's point 5 says database time is logged per request. No request is logged
yet, and no route uses the database.

**Recommended:** it arrives with the first database route and its request log, in
slice 3. The doorway's procedures do not change when it does.

### D10. The writer's tear-down only closes

ADR-0008 says the write worker's tear-down "checkpoints and closes".

**Recommended:** it closes, and nothing more. Closing the last read-write connection
checkpoints and removes the `-wal` and `-shm` files (probed). An explicit
`wal_checkpoint(TRUNCATE)` adds nothing then, and waits the whole busy timeout, five
seconds, when another process is reading (probed).

The stop order matters more than was written down: a read-only connection that closes
last leaves the `-wal` behind (probed). Readers first, the writer last.

When another process has the file open, a `sqlite3` shell or a backup, the `-wal`
stays until that process closes. That is safe.

### D11. A job gets a handle, not the connection

The review reproduced this: a job that prepares a statement, steps it once and drops
it leaves it open on the connection. The doorway's `ROLLBACK` says ok, yet every later
read on that thread sees the old snapshot for the rest of the server's run. On the
writer, every later `COMMIT` is refused. `in-transaction?` shows neither.

**Recommended:** a job never sees the connection. It gets a handle with three
procedures, `tx-execute!`, `tx-query` and `tx-query-row`, built on chez-sqlite3's
calls that finish their statement on every way out.

- A job then cannot leave a statement open, close the connection, or keep it.
- **On every way out of a call, a raise too, the handle looks at
  `in-transaction?`.** If the transaction has ended, the handle is dead: it refuses
  every later call. So a job cannot go on to write a second, separate half.
  - The raise path matters most. `INSERT OR ROLLBACK` on a conflict ends the
    transaction and raises in one call. A job that catches that raise and writes on
    would commit its second half alone (reproduced by the second review).
- **Before a call, the handle refuses SQL that begins with a word a migration may not
  use** (slice 2's list: `BEGIN`, `COMMIT`, `END`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`,
  `ATTACH`, `DETACH`, `VACUUM`, `PRAGMA`). Reproduced: through a bare `execute!` a job
  can set `query_only`, `locking_mode` or `user_version`, each of which outlives the
  transaction and breaks every later job. The check after the call stays as the
  second guard.
- **The handle is dead once its job ends,** by any way out.
- A later slice that needs more of chez-sqlite3 adds a procedure to the handle.

Against:

- **Hand over the connection, with a rule** that a job uses only the finishing calls.
  One slip is a stale read for ever, and no test would show it.
- **Ask chez-sqlite3 for a count of unfinished statements,** and check it after each
  job. It needs an issue and a release there. It can be added behind the handle
  later, as a second guard.

## The model

The shape is slice 2's: a pure step function answers one command; the shell carries
it out with one call and feeds back what happened.

### Machine 1: a write job

One call of `db-write`, on the write thread. The connection sits in a box that belongs
to that thread. The box is empty only after row W20.

Events are what the shell saw. After a SQLite call: `ok`, `busy`, `failed-open` (it
raised, and a transaction is open) or `failed-closed`. After the job: `returned-open`,
`returned-closed`, `raised-open`, `raised-closed`. After the version read: `same` or
`moved`.

| Row | State | Event | Next | Command |
|---|---|---|---|---|
| W1 | start | present | beginning | `BEGIN IMMEDIATE` |
| W2 | start | absent | ended | refuse: unavailable |
| W3 | beginning | ok | versioning | read `user_version` |
| W4 | beginning | busy | ended | refuse: busy |
| W5 | beginning | failed-closed | ended | raise it |
| W6 | beginning | failed-open | rolling back | `ROLLBACK`, carrying it |
| W7 | versioning | same | running | run the job |
| W8 | versioning | moved | rolling back | `ROLLBACK`, carrying "moved" |
| W9 | versioning | busy or failed-open | rolling back | `ROLLBACK`, carrying it |
| W10 | versioning | failed-closed | ended | raise it |
| W11 | running | returned-open | committing | `COMMIT` |
| W12 | running | returned-closed | ended | raise: the job ended its transaction |
| W13 | running | raised-open | rolling back | `ROLLBACK`, carrying the job's raise |
| W14 | running | raised-closed | ended | raise the job's raise |
| W15 | committing | ok | ended | answer the job's values |
| W16 | committing | busy or failed-open | rolling back | `ROLLBACK`, carrying it |
| W17 | committing | failed-closed | ended | raise it |
| W18 | rolling back | ok or failed-closed | ended | what was carried |
| W19 | rolling back | busy or failed-open | closing | close the connection |
| W20 | closing | ok or failed | ended | what was carried; the box is empty |

A close has two events only: `ok`, and `failed` for every way it can raise.

- **Only W15 answers.** Every other end raises or refuses.
- **A refusal is a "no", and there are three:** busy at `BEGIN IMMEDIATE` (W4), moved
  (W8) and unavailable (W2). The app answers each with a 503. Everything else is a
  raise, the job's or SQLite's own, and becomes a 500.
- **Busy anywhere else is a raise.** In WAL, busy at `COMMIT` means a statement of
  the connection's own is unfinished (chez-sqlite3's trap, reproduced). It is a bug
  and would come back on every job, so it must not look like load.
- **A raise from `COMMIT` is a "maybe"** (W16, W17). A commit that fails may still
  have reached the disk, as slice 2's model has it. T5 holds: the caller is not told
  it succeeded.
- **W14 is real:** SQLite itself rolls back a write transaction when a write is
  interrupted or the disk is full (probed with an interrupt). It is also where the
  handle's own check lands (D11).
- **W19 should never fire.** A `ROLLBACK` that fails and leaves a transaction open
  would break T1 for the next job. So the connection is closed, which drops the
  transaction (slice 2's clause), and the thread refuses every later job as
  unavailable until the server is restarted. No reopening: that would open a file
  read-write with no read-only look first (ADR-0012), for a case that should not
  exist.
- **If that close fails,** chez-sqlite3 may keep the connection open, holding the
  write lock. The box is emptied all the same, and only a restart helps. The first
  "unavailable" a handler meets is logged once, as "moved" is.
- **W6 never fires in the model.** `BEGIN IMMEDIATE` fails with a transaction open
  only when one was left open, which T1 rules out. The row is driven at layer 2 and
  listed as defensive, as slice 2's R14 is.
- **A bug in the loop itself** (a pair with no row, a version that is not a number)
  raises inside `run-job!`. It rolls back under a guard and raises again, so the
  writer is not left idle holding the lock.

### Machine 2: a read job

One call of `db-read`, on a read thread, with that thread's read-only connection. The
same shape with a plain `BEGIN` and no commit: a read job always ends by `ROLLBACK`.

| Row | State | Event | Next | Command |
|---|---|---|---|---|
| R1 | start | present | beginning | `BEGIN` |
| R2 | start | absent | ended | refuse: unavailable |
| R3 | beginning | ok | versioning | read `user_version` |
| R4 | beginning | busy or failed-closed | ended | raise it |
| R5 | beginning | failed-open | ending | `ROLLBACK`, carrying it |
| R6 | versioning | same | running | run the job |
| R7 | versioning | moved | ending | `ROLLBACK`, carrying "moved" |
| R8 | versioning | busy or failed-open | ending | `ROLLBACK`, carrying it |
| R9 | versioning | failed-closed | ended | raise it |
| R10 | running | returned-open | ending | `ROLLBACK`, carrying the values |
| R11 | running | returned-closed | ended | raise: the job ended its transaction |
| R12 | running | raised-open | ending | `ROLLBACK`, carrying the job's raise |
| R13 | running | raised-closed | ended | raise the job's raise |
| R14 | ending | ok or failed-closed | ended | what was carried |
| R15 | ending | busy or failed-open | closing | close the connection |
| R16 | closing | ok or failed | ended | what was carried; the box is empty |

- **The version read is the transaction's first read,** so it and every later read in
  the job see one snapshot (reproduced by the review; a clause holds it).
- **R12 is the row an interrupted read takes** (D7).
- A read thread with an empty box refuses its jobs while the other read threads go
  on. circuit gives a job to any idle thread, so some reads are then 503s.

### Machine 3: `serve`, from start to exit

The brief's "doorway's shutdown" machine, with the start in front of it.

| Row | State | Event | Next | Command |
|---|---|---|---|---|
| S2 | checking | serve | opening writer | make the write worker |
| S3 | checking | refused | ended | exit 1 with its line |
| S4 | opening writer | ok | opening readers | make the read worker |
| S5 | opening writer | raised | ended | exit 1 with its line |
| S6 | opening readers | ok | serving | run the server |
| S7 | opening readers | raised | stopping writer | stop the write worker, carrying exit 1 |
| S8 | serving | returned | stopping readers | stop the read worker |
| S9 | serving | refused its settings | stopping readers | stop the read worker, carrying exit 2 |
| S10 | serving | raised | stopping readers | stop the read worker, carrying exit 1 |
| S11 | stopping readers | ok | stopping writer | stop the write worker |
| S12 | stopping readers | raised | stopping writer | stop the write worker, carrying exit 1 |
| S13 | stopping writer | ok | ended | exit with what was carried, else 0 |
| S14 | stopping writer | raised | ended | exit 1 |

- **`serve-start` answers the first state and the command "check the file"** (slice
  2's check), as slice 2's `run-start` does. There is no row for it.
- **The shell never calls `exit` before the table says "exit".** In Chez, `exit` ends
  the process at once with its threads running (reproduced), which would kill a
  write and leave the `-wal`. Every raise becomes an event.
- **The first thing carried wins.** A bad port (exit 2) followed by a reader's
  tear-down that raises still exits 2, and both lines are printed.
- **A thread's set-up** opens its connection, reads the file's four facts in one
  statement, and raises unless the file is current and in WAL. That closes the gap
  between the check and the open. The check stays in front, because it opens only
  read-only and a file that will be refused must not be opened any other way
  (ADR-0012). The verdict is built from slice 2's `classify` and `facts-wal?`, so the
  two cannot drift.
- **A thread's tear-down** closes the connection if its box holds one.
- **The writer is made first.** A read-only connection needs the `-shm` file, which
  the writer's open makes (probed: without it, a read-only open in a directory it
  cannot write fails).
- **A signal before the server is listening kills the process.** The server takes
  over the signals only when it starts. Connections are dropped, which is safe.

### The properties

T1 to T5 are the brief's. The rest are new here.

| # | Property | Held by |
|---|---|---|
| T1 | At most one write transaction is open, and none while the write worker is idle. In the model: a write job is past `beginning` only while it holds the write lock, and no transaction is open at `ended`, unless that thread's close failed (W20). | layer 3; layer 5 |
| T2 | A read called after a write was answered sees that write. | layer 3, on circuit's S14, with a ghost: the writes answered when each read job left `start`; layers 4 and 5 |
| T3 | A read completes while the writer is stalled. | layer 5 alone. In the model a reader never depends on the writer, so the model cannot fail it. |
| T4 | An abandoned write is committed whole or not at all. | layer 3; layer 5 with `kill -9` |
| T5 | No caller is told a write succeeded unless it committed, and a write whose caller got no answer is committed whole or not at all. | layer 3: an answer only at W15, after `COMMIT` said ok |
| T6 | No job runs against a version that is not this binary's. | layer 3, with a `migrate` that may commit between any two steps; layer 5 |
| T7 | What a read job sees is a prefix of the committed writes, the same prefix for the whole job. | layer 4. In the model a job is one command, so the model cannot fail it. |
| T8 | `serve` never exits with a worker it made still running, stops readers before the writer, and exits 0 only if nothing raised. | layer 3 over machine 3 |
| T9 | No transaction is open on a read thread at `ended`, unless that thread's close failed (R16). | layer 3 |
| T10 | A thread whose box is empty runs no statement again. | layer 3 |

### What the model assumes

Of SQLite, each a clause tested on a real file in `test-doorway.sps`:

1. `BEGIN IMMEDIATE` holds the write lock until the transaction ends. Another's is
   told busy, and has no transaction open afterwards.
2. A commit is whole; a rollback leaves nothing.
3. A `COMMIT` refused by a deferred foreign key leaves the transaction open, and the
   `ROLLBACK` after it leaves nothing. (That a failed `COMMIT` never takes effect is
   not assumed: the model lets W17 go either way.)
4. A close drops an open transaction (slice 2's clause 7, on a worker's connection).
5. Inside `BEGIN`, a connection reads one snapshot from its first read on, and a read
   of `user_version` counts as that first read.
6. A read never waits for a write transaction.
7. A write on a read-only connection raises `readonly`.
8. After an interrupt, `in-transaction?` tells the truth: closed after an interrupted
   write, open after an interrupted read, inside a write transaction too.
9. Closing the last read-write connection removes the `-wal`, when no other process
   has the file open.
10. **Through the handle, no statement outlives its call:** after a job whose query
    raised midway, and one that escaped, the next read on that connection sees a new
    commit, and the next write commits. The same two tests on a bare prepared
    statement show the fault, so the clause is seen to fail.

Of circuit's worker, each a property it holds by its own suite, each read against its
source by the review, and each exercised at layer 5 here:

- on one thread, jobs run in call order (its S5);
- an answer is posted only after its job returned (S14);
- a job whose caller left before it began never runs (S10);
- once `worker-stop!` returns, no job runs and every thread is joined (S7);
- a set-up's raise leaves `make-worker`, and a tear-down's leaves `worker-stop!`,
  each after every thread is joined;
- a thread's state, the box, is handed unchanged to each job and to the tear-down.

By review alone:

- **A job never calls `exit`.** It would stop the whole worker (circuit's Q9): every
  later call is a 503 while `/health` says 200.
- **A job's raise reaches the log,** irritants and all, through `wrap-catch`. ADR-0006
  binds every job: no secret in a condition.

### Verification, in layers

1. **Static checks on the three tables,** with `(techo machine)`: no double row, every
   gap on a "can't happen" list with its reason, every state reachable, `ended`
   reachable from every state.
2. **Every row driven,** and every "can't happen" pair seen to raise.
3. **Every small world explored,** with slice 2's explorer. A world holds:
   - the file: its committed writes in order, and its version;
   - the write lock's holder;
   - the write thread, running up to three jobs in order, each of one or two writes;
   - **one** read thread, running up to two jobs. Read threads share nothing, so a
     second adds worlds and no property reads them;
   - another process, which may take and free the lock, or commit a version change;
   - at each command, every outcome SQLite can give, including a failure that leaves
     the transaction open, and a failed `COMMIT` that took effect.

   It is split into named configurations, each with a floor on its world count, as
   slice 2's was. The whole must finish well inside the suite's 300 seconds: the
   builder reports the count and the time, and cuts a configuration before it cuts a
   property. Machine 3 is explored by itself: it has no file.
4. **The model's traces replayed on real SQLite,** through `job-perform!`, the same
   procedure the workers call: one thread, a connection per actor, each outcome made
   to happen or, where SQLite cannot be made to give it, injected and counted.
5. **Real threads and a real server.** A test server (a child process) with a table of
   its own and routes that write, read and stall:
   - T2: 500 writes, each followed by a read on a new connection;
   - T3: a read and `/health` answer while a write job is held open;
   - the write queue full, on a doorway made with a cap of 1: 503 with `Retry-After`;
     a caller that timed out before its job began: the write is absent afterwards;
   - `SIGTERM` while idle, and with a write held open past the drain: exit 0, the
     held write committed, a write queued behind it absent, and no `-wal` left
     (looked for before any connection is opened again: a read-only open makes one);
   - `kill -9` during a write of two rows: both or neither after a restart;
   - `techo migrate` with a longer list beside the running server: the next read and
     the next write are 503, nothing was written under the new version, and the
     reason is logged once;
   - a bad `CHEZ_HTTP_PORT`, which the server refuses after the workers exist: exit 2
     and no `-wal`;
   - the real `techo serve`: `SIGTERM` gives exit 0 and no `-wal`. A file that moves
     between the check and the open cannot be staged from outside, so the set-up's
     refusal is tested on the doorway directly.
6. **A generated diagram** of each table, in `.plans/machines/doorway.md`, held to the
   tables by a test (`make machines` writes both files).

### Mutants each layer must kill

- **Layer 1:** a row removed; a row doubled; a "can't happen" pair given a row.
- **Layer 2:** each row's next state and command swapped for a neighbour's.
- **Layer 3:**
  - W15 answers before `COMMIT` (T5);
  - W13 ends without a `ROLLBACK` (T1; not T4, see "As built");
  - R10 ends without a `ROLLBACK` (T9);
  - W8 runs the job anyway (T6);
  - the version read moved before `BEGIN` (T6);
  - `BEGIN IMMEDIATE` made a plain `BEGIN` in the write table (T1 as restated: the
    job is past `beginning` without the lock);
  - W19 ends without closing (T1 for the next job);
  - W2 begins a transaction on an empty box (T10);
  - S7 ends without stopping the writer; S8 and S11 swapped (T8).
- **Layer 4:** the model's snapshot taken at `BEGIN` and not at the first read; the
  model's busy made a success.
- **Layer 5:** `db-read` sent to the write worker (T3); the tear-down order swapped
  (the `-wal` remains); a write job that commits half and raises (the half is seen);
  `techo.sps` leaving at the server's refusal without stopping the workers (the
  `-wal` remains).
- **Equivalent, and so not a mutant:** a read job that ends by `COMMIT`; a read table
  that begins with `BEGIN IMMEDIATE`, which takes no lock on a read-only connection
  (reproduced).

## What is built

### 1. `(techo transaction)`: the three tables. Pure.

```scheme
;; write-rows, read-rows, serve-rows : (Listof Row)
;; write-start, read-start : Natural -> State        ; this binary's latest version
;; serve-start : State
;; job-event-kind : Command RawOutcome -> EventKind
;; serve-event-kind : Command RawOutcome -> EventKind
;; write-step, read-step, serve-step : State Event -> (values State Command)
;; write-cant-happen, read-cant-happen, serve-cant-happen
;;   : (Listof (List StateKind EventKind String))
;; set-up-verdict : DbFacts (Listof Migration) -> (U 'serve (List 'refuse Symbol String))
;; doorway-document : -> String                       ; for make machines
```

- **`write-start`, `read-start` and `serve-start` answer `(values State Command)`,** as
  slice 2's `run-start` does. A job's first command is `(look)`.
- **`job-carry : Carry Command RawOutcome -> Carry`,** pure, keeps what the ending
  needs: the job's values, the first object raised, and the version read. The shell
  and the replay both use it, so neither has a copy of that logic.
- **`forbidden-statement? : String -> Boolean`** is exported from `(techo
  migrations)`, from the list it already has. The handle uses it. The list is not
  written twice.
- **Commands of a job:** `(look)`, `(begin-immediate)`, `(begin)`,
  `(read-version . latest)`, `(run-job)`, `(commit)`, `(rollback)`, `(close)`,
  `(end . Ending)`.
- **An Ending** is `(answer)`, `(raise-carried)`, `(raise-ended)` or
  `(refuse . kind)`, where kind is `busy`, `moved` or `unavailable`. The step
  function carries no value of a job's. The shell holds the job's values and the
  first object raised, and the table says only which to hand back.
- **A RawOutcome** is `(status value open?)`, where `open?` is `in-transaction?`, and
  `#f` when that call itself raises:
  - `(look)`: `(present #f #f)` or `(absent #f #f)`;
  - `(begin-immediate)`, `(begin)`, `(commit)`, `(rollback)`: `(ok #t open?)`,
    `(busy obj open?)` or `(failed obj open?)`, with `obj` the object raised, not a
    string;
  - `(read-version . latest)`: `(ok v open?)`, `v` the whole number read;
  - `(run-job)`: `(returned (v ...) open?)` or `(raised obj open?)`;
  - `(close)`: `(ok #t #f)` or `(failed obj #f)`. It empties the box either way.
- **An Event** is `(cons kind raw)`, the kind from `job-event-kind`. It also sorts:
  - `ok` with no transaction after the version read as `failed-closed`;
  - `ok` with a transaction still open after `COMMIT` or `ROLLBACK` as `failed-open`;
  - a version that is not a whole number as an assertion violation.
- **At `(end . Ending)`:** `(answer)` hands back the carried values;
  `(raise-carried)` raises the carried object; `(raise-ended)` raises a new
  `&db-transaction-ended`; `(refuse . kind)` raises `&db-unavailable` with the kind,
  and for `moved` the version expected and the one found.
- **`serve`'s RawOutcomes:** `(check)` gives `(ok verdict #f)`; the opens and stops
  give `(ok #t #f)` or `(raised obj #f)`; `(serve)` gives `(returned #t #f)`,
  `(refused obj #f)` or `(raised obj #f)`. The shell answers `refused` when
  `http-server-config-error?` holds, so the pure library imports nothing of the
  server's. The line printed for it stays today's: variable names, never values.
- **Commands of `serve`:** `(check)`, `(open-writer)`, `(open-readers)`, `(serve)`,
  `(stop-readers)`, `(stop-writer)`, `(end . status)`.

### 2. `(techo doorway)`: the shell.

```scheme
;; A Tx is the handle a job gets (D11).
;; tx-execute!  : Tx String Any ... -> Void
;; tx-query     : Tx String Any ... -> (Listof (Vectorof Any))
;; tx-query-row : Tx String Any ... -> (U (Vectorof Any) #f)

;; make-doorway : String Natural (Listof Migration) [Natural Natural] -> Doorway
;;   path, read threads; optionally the write and read caps (64 each). No thread yet.
;; doorway-open-writer!, doorway-open-readers! : Doorway -> Void
;;   Each makes its worker. Raises &db-refused, with the line, when a set-up
;;   refuses the file.
;; doorway-stop-readers!, doorway-stop-writer! : Doorway -> Void
;; make-test-doorway : String (Listof Migration) [Natural] -> Doorway
;;   on circuit's doubles; optionally the busy timeout in ms
;; doorway-set-up : String Symbol (Listof Migration) [Natural] -> (Boxof (U Database #f))
;; doorway-tear-down : (Boxof (U Database #f)) -> Void        ; both for the clauses too
;; db-write : Doorway (Tx -> Any) -> Any      ; in a handler; one write transaction
;; db-read  : Doorway (Tx -> Any) -> Any      ; in a handler; one read transaction
;; &db-unavailable, db-unavailable?, db-unavailable-reason   ; busy, moved, unavailable
;; db-unavailable-expected, db-unavailable-found             ; the versions, for moved
;; &db-transaction-ended, db-transaction-ended?
;; db-retry-after : Natural                                  ; 5, seconds
;; &db-refused, db-refused?, db-refused-line
;; wrap-db : (String -> Void) -> Middleware
;;   &db-unavailable -> 503 with Retry-After; logs the first "moved" and the first
;;   "unavailable", each once

;; For the replay and the clauses, not for handlers:
;; make-job-shell : (Boxof (U Database #f)) -> JobShell
;; job-perform! : JobShell Command (Tx -> Any) -> RawOutcome   ; one call per command
;; run-job! : (State Event -> (values State Command)) State JobShell (Tx -> Any)
;;            [(Command RawOutcome -> Void)] -> Any            ; the loop; an observer
```

- **`job-perform!` is the one place a job's command meets SQLite.** The workers call
  it through `run-job!`, and layer 4 calls it directly, one command at a time, since
  it interleaves three actors. So the replay tests the real `job-perform!` and the
  real `job-carry`; `run-job!`'s own loop is held by `test-doorway.sps`.
  - On `(run-job)` it makes a new handle on the box's connection and runs the job
    under a `guard`, inside a `dynamic-wind` whose way out kills the handle.
  - On `(end . _)` it is an assertion violation: the loop ends there.
  - A step the replay injects does not call it, as in slice 2.
- **A JobShell is made per job,** inside the worker's job, from the thread's box.
- **The observer** is called as `(observer command raw)` after each command but the
  end.
- **`db-write` and `db-read` wait,** so a test calls them inside circuit's test host.
- **A job** is `(lambda (tx) ...)`. It returns plain values, as many as it likes. It
  never waits, never exits, and never keeps `tx`: the handle is dead once the job
  ends.
- **`wrap-db` is built as circuit's `wrap-busy` is,** with `call/cc` around
  `with-exception-handler`, passing everything else on by `raise-continuable`. A
  `guard` would swallow a deadline or a closed client. Its log line is one
  `put-string`, on the loop's thread: lines written from several threads run together
  (reproduced by the review).
- `open-techo-db` stays the one place a connection's settings live (ADR-0012).
  `(techo db)` does not change.

### 3. `TECHO_DB_READERS` (D1)

One row in `(techo config)`'s table, and a line in `docs/running.md`.

### 4. `serve` runs machine 3

`techo.sps` runs `serve-step` in a loop. The app is wrapped as circuit's design says,
with `wrap-db` innermost, beside `wrap-busy`:

```scheme
(wrap (make-app doorway) (wrap-db log) (wrap-busy 5) wrap-catch (wrap-timeout 10000))
```

`make-app` takes the doorway and no route uses it yet.

### 5. Records and docs

- **ADR-0013:** the doorway is two workers; a job is one transaction run by a table,
  through a handle; D1 to D11 as decided. It amends ADR-0008 by name: point 1 (the
  connection leaves the loop's thread), point 2 (two procedures, not one), point 5
  (database time waits for slice 3), and the "checkpoints and closes" of its second
  amendment. It settles the first amendment's open list.
- ADR-0011: the pin's move. ADR-0012: "stop the server first" becomes what D6 decides.
- **D6's documentation, as listed under D6:** the "Upgrading" section, the log line,
  `migrate`'s help text, the constraint and the ledger's note. A test holds the log
  line's wording and the help text.
- `global-constraints.md`, `docs/running.md` (the setting, the stop and how long it
  can take, what a 503 means), `CHANGELOG.md`, the ledger.
- The ledger notes for slice 9: a stop grace of 30 seconds, and a container check
  that asks more than `/health`.

## Rules this slice makes

- **A handler reaches SQLite only through `db-write` and `db-read`.**
- **A job is one transaction, and the doorway owns it.** A job never runs `BEGIN`,
  `COMMIT`, `ROLLBACK` or a savepoint. The handle stops a job that does.
- **A job sees a handle, never the connection.**
- **A request that writes and then reads its own change does both in one write job.**
- **A job never waits, never exits, and puts no secret in a condition.**
- **A job is handed plain data, taken from the request before the call, never a
  parameter.** A job can see a handler's `parameterize` on circuit's double every
  time, and on the real worker about once in 9,000 calls (circuit's finding, on its
  Workers page), so a test on the double would pass on a value the server almost
  never sees.
- **Readers stop before the writer.**
- **A write with no answer is a "maybe"** (ADR-0008, amended), and so is a 500 from a
  write. A 503 is a "no".
- **A stop waits for the write that is running,** however long the server's drain
  was. Whatever supervises Techo must allow for it before it kills the process; a
  kill is safe (T4).
- **Stop the server before a restore.**

## Suites, each test watched failing first

| Suite | Layers | What it holds |
|---|---|---|
| `test-transaction.sps` | 1, 2, 6 | The three tables' static checks; every row; both `event-kind`s over every raw outcome; `set-up-verdict` over every class of file; the diagram against its file. |
| `test-transaction-model.sps` | 3 | The explorer over the job worlds and over machine 3; each configuration's floor; the rows that fired; each layer 3 mutant. |
| `test-doorway.sps` | the clauses | The ten SQLite clauses. The handle: each procedure; a forbidden first word refused before it runs; the check after a call that returned and after one that raised (`INSERT OR ROLLBACK`, caught by the job: nothing of the job is committed); dead after its job ended, by a return, a raise and an escape. `run-job!`: each of the four endings, with the two raises not swapped and a refusal not a plain raise; a bug in the loop rolls back. `db-write` and `db-read` on the doubles: an answer, several values, a raise, each refusal. The set-up's refusal on a file not current and one not in WAL. The set-up and tear-down called directly: a tear-down on an empty box, and a job on one (unavailable). `wrap-db`: a 503 with `Retry-After`, a deadline passed through, "moved" logged once with both versions. |
| `test-transaction-replay.sps` | 4 | The model's traces through `job-perform!` on real SQLite, and the layer 4 mutants. |
| `test-doorway-threads.sps` | 5 | The real workers and the child server: the list under layer 5. |
| `test-integration.sps`, more rows | 5 | The real `techo serve`: `SIGTERM`, exit 0, no `-wal`; a bad port, exit 2, no `-wal`. `TECHO_DB_READERS` refused when it is not 1 to 16. |
| `test-config.sps`, more rows | | The new variable. |

## Work, and who does it

| # | Task | Model | Files |
|---|---|---|---|
| 0 | The pin's move, on its own commit | the lead | `Makefile`, `vendor/circuit` |
| 1 | `(techo transaction)`, layers 1, 2 and 6 | Sonnet | `src/techo/transaction.sls`, `src/techo/migrations.sls` (one export), `tests/test-transaction.sps`, `scripts/render-machines.sps`, the Makefile's `machines` target, `.plans/machines/doorway.md` |
| 2 | The model, layer 3 and its mutants | Opus | `tests/transaction-model.sls`, `tests/test-transaction-model.sps` |
| 3 | `(techo doorway)`, the clauses, the config row | Sonnet | `src/techo/doorway.sls`, `src/techo/config.sls`, `tests/test-doorway.sps`, `tests/test-config.sps` |
| 4 | Layer 4, the replay | Opus | `tests/transaction-replay-support.sls`, `tests/test-transaction-replay.sps` |
| 5 | `serve`'s loop, the app's wrap, `migrate`'s help line, layer 5 | Sonnet | `techo.sps`, `src/techo/app.sls`, `src/techo/cli.sls`, `tests/test-app.sps`, `tests/test-cli.sps`, `tests/doorway-child.sps`, `tests/test-doorway-threads.sps`, `tests/test-integration.sps` |
| 6 | The records and docs | the lead | `.plans/` but `machines/`, `docs/`, `CHANGELOG.md` |
| 7 | Read-only adversarial review of the whole slice | Opus | none |

- **Order:** 0; then 1; then 2 and 3 side by side; then 4 and 5 side by side; then 7.
  Task 6 runs beside them.
- **Task 4 needs both 2 and 3:** the model's traces, and `job-perform!`. Both
  interfaces are fixed above, so it is not held up by a question. The model's trace
  is a list of steps, each with who moved, the command, the raw outcome and the row,
  as slice 2's `step-` accessors give.
- **Task 4 writes its own replay support.** Slice 2's imports the migrate model.
- **A trace step** has `step-who` (`writer`, `reader` or `other`), `step-job` (the
  job's place on its thread), `step-command`, `step-raw` and `step-row` (the row's
  name, such as `W11`).
- **Task 5 first makes `test-cli.sps` match the start of each usage line.** Today it
  looks for "serve" anywhere in a line, and "stop the server first" would satisfy it
  with the serve line gone.
- **Tasks 2 and 4 are on Opus:** a wrong assumption in the model makes every check
  pass for nothing.
- Agents do not commit.

## As built, where it differs from the above

- **`(techo serve)` is a library of its own.** `serve-loop` runs machine 3, and both
  `techo.sps` and the layer 5 test server call it, so the test's stop order is the
  program's.
- **`run-job!` takes the start state, not the start's two values.** Its first command
  is always `(look)`.
- **`run-job!`'s net also catches a way out by a continuation,** not only a raise.
- **The handle refuses a dead call in two ways:** an assertion violation after its job
  ended, `&db-transaction-ended` after SQLite ended the transaction.
- **The refusal of a forbidden first word names the statement,** not the word.
- **`wrap-app` takes an optional timeout,** which only the test server passes.
- **`(techo transaction)` exports the rows' names,** `write-row-names` and its
  siblings, for the model's traces. It does not export what a mutated copy of a table
  needs to be stepped, so the model's suite carries copies of three small procedures,
  and two tests hold the copies to the real steppers at every step of an exploration.
- **Serve's event for a refused setting is `refused-settings`.**

What the build found:

- **The mutant "W13 ends without a `ROLLBACK`" is killed by T1 alone.** With T1
  unchecked it survives: the next job's `BEGIN IMMEDIATE` fails with the transaction
  open, and W6 rolls the leftovers back. So W6 is not only defensive: it is what
  cleans up after a broken row.
- **"The version read moved before `BEGIN`" is stopped by `job-event-kind`,** which
  sorts an ok version read with no transaction as a failure. The model needs that
  sorting mutated too before T6 can fail.
- **Three properties cannot fail by themselves in the model:** T1's "at most one write
  transaction" (it is SQLite's, clause 1); T2 without T5 failing first; T6 for a write
  job. Each is seen to fail only under a model mutant or with another property
  unchecked, and the suite says so.
- **N1, added by the model's builder:** with no failure injected, every job answers.
  Without it a table that refuses every job passes every safety property.
- **Two cases cannot be staged on real SQLite:** a close that raises, and a handle
  call that returns after the transaction has ended. The second is unreachable
  through the handle.
- **The model's world counts:** nine configurations, 265 to 325,355 worlds, about 12
  seconds in all.
- **The replay:** 921 traces and 17,876 steps on real SQLite, 94% of them real and
  the rest injected, each injection with its reason. It found no difference between
  the model and SQLite on any path the real tables take.
- **Two differences off those paths are pinned as expected failures:** the model
  commits every write of a job run with no transaction, where the handle commits the
  first and refuses the rest; and the model fails a close of an empty box, where the
  shell answers ok. No real table reaches either. The model is the one to change.
- **Nine rows are reached only by injection:** W9, W10, W19 failed-open, W20 failed,
  R4 failed-closed, R8, R9, R15 failed-open, R16 failed. SQLite cannot be made to
  fail a plain `BEGIN`, a version read, a `ROLLBACK` of an open transaction or a
  close.
- **Taken on trust:** that SQLite is busy nowhere but at `BEGIN IMMEDIATE`. The model
  never offers it elsewhere, so the replay cannot test it.
- **The model's "busy made a success" mutant survives every shortest trace.** Random
  walks kill it. The suite keeps both.
- **Task 3 wrote the library before its tests.** Its tests' teeth were shown by
  mutants afterwards, 22 by the builder and four by the lead.

## Not in this slice

- Any table or route that uses the doorway: slice 3.
- A read's interrupt at its deadline (D7): slice 7.
- Database time in the request log (D9): slice 3.
- Off-loop password hashing (D4): slice 3.
- Keeping `migrate` out by a lock, and exiting on "moved" (D6's alternatives).
- A count of unfinished statements from chez-sqlite3 (D11's alternative).
- `techo backup`: slice 9.

## Probed, 2026-11-23

Each by a program under `build/probe-2b-sqlite/`, and three of them run again by the
lead.

- `with-transaction` in chez-sqlite3 begins immediately, rolls back on a raise or an
  escape, and rolls back a failed `COMMIT`. This plan does not use it: the table does
  the same, and can be explored.
- A read-only connection: a `SELECT` works; a write raises `readonly`; `BEGIN
  IMMEDIATE` succeeds, so a `BEGIN` refuses nothing. With no `-wal` and `-shm` it
  creates them, and fails in a directory it cannot write.
- A reader inside `BEGIN` counts 1, 1 after another's commit, then 2 after it ends.
  Without `BEGIN`: 2, then 3.
- A reader's `SELECT` returns in microseconds while a write transaction is open, and
  sees only what was committed.
- At close: readers then the writer leaves only the database file. The writer first,
  then the readers, leaves the `-wal` and `-shm`.
- A `TRUNCATE` checkpoint with a reader inside a transaction waits the busy timeout
  and answers busy.
- An interrupt lands about 80 microseconds after the call. A read's transaction stays
  open; a write's is rolled back by SQLite; an idle connection's next statement is
  untouched.
- With a server's connections open and idle, another process's version change
  commits. `locking_mode = EXCLUSIVE` on that process is refused as busy; so is a
  change of journal mode.
- `PRAGMA user_version` costs 3.2 to 3.5 microseconds.
- One commit: `full` 1.1 ms median, 5.9 ms worst; `normal` 0.015 ms and 0.17 ms.

And by programs under `build/probe-2b-worker/`, a test server on the real workers,
three of them run again by the lead:

- The wrap order of circuit's design works end to end. 500 writes, each followed by a
  read, on new connections and on one kept alive: the read always saw the write.
- With a write held open for 3 s: a read answered in 1 ms with the old count,
  `/health` in under 1 ms, and a second write waited and then succeeded.
- A write cap of 1, the thread busy and one job queued: each further write got an
  empty 503 with `retry-after: 5` at once.
- A request that timed out got an empty 504. Its job, if begun, still committed. A
  job still queued then never ran.
- `SIGTERM` and `SIGINT` both make `run-server` return, and the code after it runs.
  Idle, the stops take about 15 ms and the exit is 0.
- **The stop can outlast the drain.** With a 2 s drain and a write held for 6 s, the
  server closed the connections at 2.9 s, the readers stopped at once, and the
  writer's stop waited for the write, which committed at 6.1 s. A write queued behind
  it never ran. Exit 0.
- A set-up's raise leaves `make-worker` as it was raised, after the other threads'
  tear-downs. A tear-down's raise leaves `worker-stop!` after every tear-down ran.
- circuit's doubles carry a real connection each, two on one file, and a read job
  after a write job in one handler sees the write. A double runs its tear-down.
- A job that raises with its transaction open and no rollback leaves it open for the
  next job on that thread, whose `COMMIT` would commit the leftovers. This is what
  rows W13 and R12 are for.
- A real worker under circuit's test host needs `test-host-advance!` once per wait.
  The double does not.

## The reviews

### The first, of the draft

An adversarial read on Opus, with probes of its own under `build/review-2b-plan/`.
The lead ran both again. Two blockers, twelve should-fixes, twelve notes.

| Finding | What changed |
|---|---|
| **Blocker.** A statement a job leaves open survives the `ROLLBACK`: stale reads for the rest of the run, and every later `COMMIT` refused (reproduced) | D11, the handle; clause 10 |
| **Blocker.** Layer 4 had no shell procedure to drive, so the replay would have tested a copy. Slice 2's first review found the same | `job-perform!` and `run-job!` fixed in the plan; task 4 follows 2 and 3 |
| A connection a job closed counted as present, and every later job failed | The handle: a job cannot close it |
| "A failed `COMMIT` commits nothing" contradicted slice 2's model | Clause 3 narrowed; W16 and W17 are a "maybe" |
| T3 could not fail in the model | Layer 5 alone holds it, with a mutant that routes a read to the writer |
| The plain-`BEGIN` mutant survived T1: SQLite refuses the second writer itself (reproduced) | T1 restated on the lock |
| No property covered a read transaction left open | T9, and its mutant |
| The layer 3 world was about a thousand times too big | One read thread; named configurations with floors |
| `make-doorway` hid two steps of machine 3 | Two open procedures; `&db-refused` exported |
| "Reopen" was three calls in one command, and opened read-write with no read-only look | No reopening: the connection is closed and the thread refuses (W19, W20, T10) |
| A tear-down on an empty box would raise | It closes only what the box holds; a test |
| The numbers left out the drain and the supervisor's grace | D8 |
| Busy at `COMMIT` was answered as load | A raise |
| ADR-0008's points 2 and 5 change too | Named for ADR-0013 |
| Notes: lines logged from two threads run together; a job that exits; a restore under the server; exit on "moved"; the `-wal` with another process; which carried exit wins; a signal before listening; the Makefile's `machines`; how `wrap-db` is built; secrets in a job's raise; `set-up-verdict` | Each taken in where it applies |

### The second, of the revision

A second adversarial read on Opus, after the decisions, aimed at what the first
revision added. Its probes are under `build/review-2b-plan-2/`; the lead ran the main
one again. One blocker, ten should-fixes, eleven notes.

| Finding | What changed |
|---|---|
| **Blocker.** The handle checked the transaction only when a call returned. `INSERT OR ROLLBACK` ends it and raises at once; a job that catches the raise then commits its second half alone (reproduced) | D11: the check is on every way out |
| Through `tx-execute!` a job could set `query_only`, `locking_mode` or `user_version`, each breaking every later job (reproduced) | D11: forbidden first words, refused before the call |
| A raise inside the loop left the transaction open | `run-job!` rolls back and raises again |
| A close's failures had no event | `failed`, for all of them |
| T1 and T9 as restated were broken by W6 and by a failed close | W6 never fires in the model; the two properties except a failed close |
| The log line had no versions to print | They ride on `&db-unavailable` |
| The shell's interface still left three tasks guessing | The RawOutcomes, the Event, the endings, `job-carry`, the trace step, all fixed above |
| Machine 3 could not tell a refused setting from a raise, and had a row with no event | The shell sorts it; `serve-start` gives the first command |
| Tests that could not be staged: an empty box, a full queue of 64, a busy that waits 5 s | The set-up and tear-down exported; optional caps and busy timeout |
| New behaviour with no test | Rows in `test-doorway.sps` |
| The new help line would have weakened a usage test | Task 5 fixes the test first |
| Notes: the world count is in budget (about 65,000 worlds for three writes and two reads, by a count of its own); T2's ghost; T7 has teeth only at layer 4; a line logged from a worker thread; `exit` with threads running; the wrap order is right | Each taken in where it applies |

### The third, of the build

A read-only adversarial read on Opus of the whole slice, with 29 mutants of its own
and the real `serve` driven by hand. Its probes are under `build/review-slice-2b/`;
the lead ran its two main ones again. No blocker, six should-fixes, fourteen notes.

| Finding | What changed |
|---|---|
| `EXPLAIN PRAGMA query_only = 1` got past the handle, and the flag stuck: SQLite applies it while preparing the statement (reproduced) | `EXPLAIN` joins the forbidden first words, for jobs and for migrations |
| The write thread accepted a file it may not write: SQLite's read-write open falls back to read-only without a word (reproduced) | The writer's set-up writes the version the file has, in a transaction it rolls back, and refuses on `readonly` or busy |
| No test held the real read threads to read-only: the doubles had their own copy of the set-up | One set-up procedure for both |
| No test held `TECHO_DB_READERS` to any effect | Layer 5 counts the server's threads with 1 reader and with 3 |
| `docs/running.md` said a port in use exits 255; it is 1 now | The doc, and an integration row |
| The ledger was not updated | Done at the close-out |
| A test that could not fail: the rows' names compared with themselves | The names are written out |
| Notes taken in: a second signal during the writer's stop kills; the docs describe what no request can show yet; a job changes no schema (a temporary trigger stays on the connection); a signature comment; a world count | Each where it applies |

Recorded, not fixed:

- **Nothing stops two `serve` processes on one file.** Both run. Whether that is
  allowed is the owner's to say.
- **`serve-loop` has no net of its own.** A raise from the check or from the step
  function would leave with threads running. Neither can happen without a bug.
- **A 503 is a "no" per job, not per request.** A handler that makes two write jobs
  could commit the first and be refused the second. Slice 3 needs the rule "one
  write job a request".
- **A reader told busy gets a 500, not a 503.** It can happen for a moment after
  another program crashed while writing. No data is at risk.
- **Only the missing-file test tells the check in front from the set-up behind it.**
  Every other refusal gives the same line either way, so "a refused file is opened
  only read-only" has one test with teeth.
- **The integration suite took 206 s under heavy load,** against a 300 s limit. It
  takes 45 s on a quiet machine.
- **The test server logs two lines from its write thread,** against the rule. It is
  the test's own, and a line could run into another once in a long while.

Not taken, from the first: timing D5 again under the benchmark trap's rules. The decision does not
turn on the number, and the plan says the host was not quiet.

## Done when

- `scripts/guix-env make test` passes, with the new suites.
- `make check-pins` and CI pass.
- The closing review's findings are fixed or recorded.
- The ledger has the close-out.
