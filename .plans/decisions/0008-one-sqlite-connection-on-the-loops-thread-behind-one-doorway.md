# 0008: One SQLite connection on the loop's thread, behind one doorway

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §9

## Context

- chez-http-server runs one libuv loop on one thread. Each request is a coroutine on
  it. A blocking call holds up every request.
- A chez-sqlite3 call blocks, and a connection belongs to the thread that opened it.
- On 2026-11-22 a handler could not be woken from another thread, so a database worker
  thread could not be built. The proposal to add that is chez-http-server issue 260,
  accepted there as its decision 0039 and under way on its branch
  `feat/await-outside`.
- A handler that does not wait in the middle of a transaction cannot be interleaved
  with another request.

## Decision

1. **v1 opens one connection on the loop's thread** and calls it synchronously.
2. **One doorway.** A handler passes a closure to one procedure and gets a value back.
   No handler touches the connection any other way.
3. **Nothing waits inside that closure.** A request's body is read and parsed first.
4. **Every query is bounded** by a page cap (ADR-0002).
5. **Database time is logged per request.**
6. **The admin CLI and backup are separate processes** with connections of their own.
   WAL and a busy timeout let them run beside the server.
7. **A password hash blocks the loop** for its length in v1 (ADR-0006).

## Consequences

- A slow query stalls everyone. Slice 1's spike measures how slow the real ones are.
- When `await-outside` is released, the doorway can hand its closure to a worker
  thread, and hashing can leave the loop. No handler changes. That is a new decision,
  taken on the spike's numbers.

## Amendment, 2026-11-22: slice 2 waits for `await-outside`

Status: accepted (owner, 2026-11-22, on the spike's numbers)

- **What the spike found**, at medium size
  ([the loop-stall report](../research/2026-11-22-loop-stall.md)):
  - SQLite's own work on a write has a median of 0.3 ms and a worst of 25 ms, measured
    in memory.
  - Its largest cost of its own is processor time, not the disk: a ranked search for a
    word in nearly every note takes 13 ms, and 141 ms at large size.
  - A commit also waits on the disk's `fsync`. One commit held the loop for 31 seconds,
    while the host was unpacking a download and the benchmark's own 950 MB copy was
    still being written out. No number from a quiet disk exists yet. Techo cannot bound
    this wait.
- **Decided.** Slice 2 does not start until chez-http-server's `await-outside` has
  landed. Point 1 above, the connection on the loop's thread, is not built.
- **What a worker thread does not fix.** One connection on one worker still queues
  every database request behind a stalled commit or a slow search. Only requests that
  never touch the database are freed.
- **Decided (owner, 2026-11-22): writes and reads run on separate threads.** One write
  thread with a read-write connection, and one or more read threads, each with a
  read-only connection. A WAL reader does not wait for the writer. The arrangement, and
  what it asks of circuit, is in
  [the circuit brief](../briefs/circuit-worker.md) §9.
- **Decided (owner, 2026-11-22): the design is modelled as state machines and
  verified**, not only tested: that brief's §10 lists the machines, the layers and the
  properties. Techo's share is the write transaction, the shutdown order and
  properties T1 to T5.
- **Still to decide, in slice 2's plan and a new record:**
  - how many read threads, and whether it is a setting;
  - how the doorway tells a read from a write;
  - whether a TLA+ specification is written, or the exhaustive exploration in the
    suite is enough;
  - whether password hashing goes to a worker too.

  Points 2 to 6 are to be read again against that design, not assumed.

## Amendment, 2026-11-23: T5 restated, and what a missing answer means

Status: accepted (owner, 2026-11-23)

- **T5 now reads:** no caller is told a write succeeded unless it committed, and a
  write whose caller got no answer is committed whole or not at all.
- **Why.** circuit's `worker-stop!` refuses the jobs not yet begun (circuit's ADR-0013,
  the owner's answer there). Techo stops its workers after the server, so a write still
  queued then is neither committed nor is its caller told. The first wording asked for
  one or the other.
- **A write with no answer is a "maybe".** That covers a 504 and a connection closed at
  shutdown: the write may have committed. A client retries it safely, because a node's
  id is made by the client and an update carries `If-Match`.
- **The stop order is unchanged:** `run-server` returns, then the read worker stops,
  then the write worker, whose tear-down checkpoints and closes.


## Amendment, 2026-11-23: the doorway is slice 2b

Status: accepted (owner, 2026-11-23, answering the slice 2 plan's D1)

- **Slice 2 is the schema's machinery, migrations and `techo migrate`.** It needs no
  worker thread: the CLI has its own connection (point 6), and `serve` checks the
  schema before the loop starts, on a connection it opens and closes.
- **The doorway, the workers, the shutdown order and T1 to T5 are slice 2b.** It waits
  for circuit's worker, the second slice of circuit's ADR-0013.
- **"2b" and not a renumbering,** because the records name slices 3 to 9 by number.
- **The first amendment's "slice 2 does not start until `await-outside` has landed"**
  now binds slice 2b. `await-outside` has landed.

## Amendment, 2026-11-23: the doorway is decided in ADR-0013

Status: accepted (owner, 2026-11-23, answering the slice 2b plan)

- [ADR-0013](0013-the-doorway-is-two-workers-and-a-job-is-one-transaction-run-by-a-table.md)
  replaces point 1, changes points 2 and 5, and settles the first amendment's open
  list. It says which, by name.
- **The write worker's tear-down closes and does not checkpoint by hand.** The close
  of the last read-write connection checkpoints (probed).
- Points 3, 4, 6 and 7 stand. Point 7, the password hash on the loop, is slice 3's to
  revisit.
