

## Amendment, 2026-11-24: the request log

Status: accepted (owner, 2026-11-24, as slice 3's D10, offered and not objected to)

- **One line a request,** on standard output, when its answer ends: the method, the
  path, the status, how the answer ended, the time taken, the time the database took,
  the account, and the peer's address.
- **Never in it:** a query string, a header or a body. So never a key.
- It is one write, from the loop's thread (ADR-0013).

## Amendment, 2026-11-25: the proxy count, and one server a file

Status: accepted (owner, 2026-11-24, as slice 3's D13 and D14: "make it a count of
proxies, well documented")

- **`TECHO_BEHIND_PROXY=N` says how many proxies stand in front.** The client's
  address for the login limit is then the Nth from the end of `X-Forwarded-For`.
  Unset or `0`, it is the peer's. Anything but 0 to 8 refuses to start, exit 2.
- An entry may carry a port or brackets. One that is still no address, or a list
  shorter than N, gives the peer's address.
- Too low a number puts every client on the proxy's count. Too high, or a port that
  can be reached past the proxy, lets a client write its own address.
- **Run one `techo serve` for each database file.** The database is safe with two,
  but each keeps its own login counts. Nothing enforces it.
- The request log's `address` is still the peer's. Whether it should be the client's
  is open.
