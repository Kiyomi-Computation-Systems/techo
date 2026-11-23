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
