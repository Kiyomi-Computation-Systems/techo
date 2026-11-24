# 0013: The doorway is two workers, and a job is one transaction run by a table

Date: 2026-11-23
Status: accepted (owner, 2026-11-23, answering the slice 2b plan's D1 to D11)
Plan: [the slice 2b plan](../2026-11-23-slice-2b-doorway.md)

## Context

- ADR-0008's first amendment put writes and reads on separate threads and left four
  questions open. Its third made that work slice 2b, waiting for circuit's worker.
- circuit's worker is merged (its ADR-0013; b7e6f95). It runs a job on a thread that
  owns a state, and wakes the handler with the answer.
- Probes for the plan found three things no earlier record had:
  - A statement a job leaves open outlives the transaction. Reads on that thread are
    then stale for the rest of the run, and no later write commits.
  - SQLite can end a transaction and raise in the same call (`INSERT OR ROLLBACK`).
  - A `PRAGMA` run inside a job can change the connection for every later job.
- A `migrate` from another process succeeds while a server holds the file open.

## Decision

1. **Two workers.** One write thread with a read-write connection, and
   `TECHO_DB_READERS` read threads (1 to 16, default 2), each with a read-only
   connection. Each has its own queue, capped at 64.
2. **Two procedures.** A handler calls `db-write` or `db-read`. Nothing else reaches
   SQLite.
3. **A job is one transaction, and the doorway owns it.** The doorway begins it
   (`BEGIN IMMEDIATE` for a write, `BEGIN` for a read), and ends it. A write job that
   returns is committed; one that raises is rolled back. A read job is always rolled
   back.
4. **Each transaction is run by a transition table and a pure step function**
   (ADR-0007), in `(techo transaction)`. `serve`'s start and stop is a third table.
   They are verified in the six layers ADR-0012 used.
5. **A job gets a handle, never the connection.** The handle has `tx-execute!`,
   `tx-query` and `tx-query-row`. It:
   - refuses SQL that begins with a word a migration may not use (ADR-0012), before
     running it;
   - looks at the transaction on every way out of a call, a raise too, and is dead if
     it has ended;
   - is dead once its job ends.
6. **Every job reads `user_version` first, inside its transaction.** If it is not
   this binary's, the job does not run, the caller gets a 503, and the server logs
   the reason once. Until it is restarted the server answers every database request
   so.
7. **Refusals and raises.** Busy at `BEGIN IMMEDIATE`, a moved version and a closed
   connection are refusals: a 503, which is a "no". Anything else is a raise: a 500.
   A 500 from a write is a "maybe", as a missing answer is (ADR-0008, amended).
8. **A connection is never reopened.** If a `ROLLBACK` fails with the transaction
   still open, the connection is closed and that thread refuses its jobs until a
   restart.
9. **The order.** The check (ADR-0012), then the write worker, then the read worker,
   then the server. At a stop: the server, the read worker, the write worker. Each
   thread's set-up reads the file's facts again and refuses a file that is not
   current and in WAL. The write thread's also refuses a file it may not write:
   SQLite's read-write open falls back to read-only without a word (probed).
10. **The writer's tear-down only closes.** Closing the last read-write connection
    checkpoints and removes the `-wal`.
11. **`synchronous` stays `full`.**
12. **The numbers,** each a constant: a request's timeout 10 s; the busy timeout 5 s;
    `Retry-After` 5 s; the queue caps 64.
13. **No TLA+ specification.** The threads and the queue are circuit's, verified
    there.
14. **Left to their slices:** off-loop password hashing and database time in the
    request log (slice 3); interrupting a read at its deadline (slice 7).

## What this changes in ADR-0008

- **Point 1,** one connection on the loop's thread: replaced by 1 above.
- **Point 2,** one procedure: now two (2 above).
- **Point 5,** database time logged per request: waits for slice 3, which has the
  first database route and the first request log.
- **The second amendment's "checkpoints and closes":** closes (10 above).
- **The first amendment's open list** is settled by 1, 2, 13 and 14.

## Consequences

- **Item 6 detects; it does not prevent.** "Stop the server before migrating" stays
  the rule for people. If it is broken, no job of the old server runs against the
  new schema, but the old server is then useless until replaced. `/health` answers
  200 throughout, so slice 9's container check must ask more.
- **Item 6 does not see a file replaced under the server,** as a restore does. Stop
  the server before a restore.
- **Two alternatives are left for later:** keeping `migrate` out with
  `locking_mode = EXCLUSIVE` (probed: it is refused while another connection is
  open, but it changes ADR-0012's verified table), and exiting on the first "moved".
- **A stop waits for the write that is running,** past the server's drain. Slice 9's
  container needs a stop grace above Docker's default 10 s; the plan says 30.
- **A job that needs more of chez-sqlite3** than the handle's three procedures adds
  one to the handle, in its own slice.
- **A second guard is possible:** a count of unfinished statements from chez-sqlite3,
  checked after each job. It would be an issue there.
- **Held by review alone:** a job never calls `exit`, never waits, puts no secret in
  a condition (ADR-0006), and is handed plain data, never a parameter: circuit's
  double shows a handler's `parameterize` to a job every time, and the real worker
  almost never does (circuit's `docs/workers.md`).
