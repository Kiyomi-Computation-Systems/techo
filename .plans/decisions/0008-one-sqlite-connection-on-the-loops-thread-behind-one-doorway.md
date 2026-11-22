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
