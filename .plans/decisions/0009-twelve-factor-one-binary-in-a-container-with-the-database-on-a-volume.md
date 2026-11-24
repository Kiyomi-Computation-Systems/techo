

## Amendment, 2026-11-24: the request log

Status: accepted (owner, 2026-11-24, as slice 3's D10, offered and not objected to)

- **One line a request,** on standard output, when its answer ends: the method, the
  path, the status, how the answer ended, the time taken, the time the database took,
  the account, and the peer's address.
- **Never in it:** a query string, a header or a body. So never a key.
- It is one write, from the loop's thread (ADR-0013).
