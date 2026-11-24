# Slice 3: accounts, login and API keys

Date: 2026-11-24
Status: built, and reviewed three times (the last three sections). **Accepted (owner, 2026-11-24):** D1, D2, D4,
D5, D6, D8, D9 and D15. D3 and D10 were offered and not objected to. D7 is accepted as RFC 9457. D11 to D14 are 3b's and wait
for its plan.
Records: ADR-0006 (accounts and keys), ADR-0002 (the API), ADR-0007 (machines),
ADR-0013 (the doorway). Read [global-constraints.md](global-constraints.md) first.

## What this slice is for

After it, an admin can make an account, a person can log in from a device and get a
key, and every later request proves who it is with that key. It brings the first
tables, the first routes through the doorway, the one error format and the request
log.

## What the probes found (2026-11-24)

Each was read at a named line or run; the reports are in this session's record.

**chez-sodium**

- Its `main` (3a14085, M2) has `random-bytes`, `blake2b` and
  `constant-time-bytevector=?`. **It has no password verbs.** They are its M3, which
  has no plan yet.
- M3's interface is decided in its brief: `password-hash : String [Limits] -> String`,
  `password-verify : String String -> Boolean` (hash first),
  `password-needs-rehash? : String [Limits] -> Boolean`. The default limits are
  `'interactive`: 2 passes and 64 MiB, about 55 ms a hash on the brief author's machine.
- `password-verify` answers `#f` for a wrong password, an unreadable hash and "out of
  memory" alike.
- Every input is capped at 64 KiB. A password is a string, hashed as its UTF-8 bytes,
  with no normalising.
- Hash and verify are collect-safe and meant for a worker thread. The library must be
  referenced once on the main thread before any worker uses it.
- If libsodium is missing, a program that imports the verbs dies before its first line.
- Techo's container has no libsodium. One word in `manifest.scm` adds it (1.0.22).
  Ubuntu 24.04's is 1.0.18, the library's floor.
- Measured in the container: `blake2b` 3.5 µs, `random-bytes 32` 1.5 µs. Four threads
  at once gave right answers.
- It has no tag. The pin is a commit.

**circuit**

- A handler reads a header with `req-header` (first one wins) or `req-header-values`
  (all), a path part with `req-path-param`, and a JSON body through `wrap-json-body`
  (objects are alists with string keys, arrays are vectors, null is the symbol `null`).
- `wrap-json-body` answers a parse error itself: 400, `text/plain`. An oversize body is
  an empty 413. A 405 is empty. A raise is an empty 500. **None is in a JSON format.**
- `req-remote-address` gives the peer's address as a string. Nothing reads
  `X-Forwarded-For`. The test host gives `#f`.
- `req-set` and `req-ref` with a `make-req-key` carry data from a middleware inward.
- `wrap-log` exists (method, path, status, ending, ms, address) but Techo does not use
  it, and it cannot show database time or the account.
- **`db-read` and `db-write` raise "a wait on no coroutine" on a bare
  `make-test-req` call.** A route that uses the doorway is tested through the server's
  test host, with raw HTTP bytes.
- `real-time` is what `wrap-log` uses for a duration. Techo's `src/` has no clock yet.

**unique-id** v0.1.0 is released. An id is made by `(unique-id generator)`'s
`generate-v7`, from a generator that must stay on one thread. `uuid->bytevector`,
`bytevector->uuid`, `uuid->string` and `string->uuid` convert. It needs only chez-srfi.

## Decisions for the owner

### D1. Split the slice at the password verbs

chez-sodium's M3 is not built, and `user add` and login cannot work without it.

- **3a, now:** the dependencies, the tables, the error format, the request log, the
  key check, and the key routes. Its tests put an account's row in by hand.
- **3b, when M3 is on chez-sodium's `main`:** `techo user add`, `techo user password`,
  `POST /v1/login`, the rate limit and the hashing worker.

Each is its own pull request. After 3a a real server has no accounts, so every
request to a key route answers 401. That is harmless.

Other choices: one pull request that waits for M3; or do nothing until M3.
**Recommended: split.** The rest of this plan assumes it.

### D2. An account's id is a UUID, version 7, made by the server

A 16-byte blob like every other id (ADR-0012), from unique-id's `generate-v7`. Keys'
ids are the same. This brings unique-id in one slice early.

- One generator, used only on the loop's thread. An id is made before the job and
  handed to it as data.

The other choice is an integer, which makes each owner-led index entry 8 bytes
smaller. One rule for every id is worth more.

### D3. A key is `techo_` and 64 hex digits

- 32 random bytes from `random-bytes`, shown as lowercase hex after the prefix
  `techo_`: 70 characters. Chez's `number->string` writes capitals, so the
  encoder lowercases on purpose, and a test holds it (`traps.md`).
- Sent as `Authorization: Bearer techo_…`.
- Stored as `blake2b` (32 bytes) of the 70 characters' bytes (ADR-0006, amended).
- The scheme's case does not matter (`bearer` is fine). One space follows it. The
  rest must be the 70 characters exactly.
- A header that is missing, doubled, or not that shape is refused before any database
  work.
- **The hash is taken on the loop's thread, and a job is handed only the 32 bytes.**
  The key itself never enters a job, so it can never be in a logged raise.
- A test holds one fixed key and its hash, so a change to the encoding fails a test
  instead of orphaning every stored key.

Hex is longer than base64 but has one spelling and needs no decoder. The prefix lets a
secret scanner find a leaked key.

### D4. The account check runs inside the request's own job

A handler calls `db-read-as` or `db-write-as`. The job first finds the key's row by its
hash, then runs the handler's work with the account, all in one transaction.

- **One job a request.** So a 503 is a "no" for the whole request, which answers the
  ledger's open question.
- **No gap** between checking a key and acting on it: a revoke and a write cannot cross.
- **A refusal leaves a job as one condition, `&refusal`,** holding an error code and
  nothing else. `db-read-as` and `db-write-as` catch it and answer in the error
  format. A write's work so far is rolled back. It never reaches `wrap-catch`, so it
  is not logged as a failure and is never a 500.
- **Known cost:** a write route's check runs on the one writer, so a stranger sending
  well-shaped random keys to a `POST` queues jobs there. The queue's cap of 64 bounds
  it.

The other choice is a middleware that does a read job, then the handler's job: two
jobs a request, and a small gap.

### D5. A key's lifecycle has three states, one of them "no such key"

"None" is what an unknown key, or another account's key, looks like to the caller.
Regenerate is two events, by who asks: the key itself, or another key of its account.

| State | Event | Next | Command | What the caller gets |
|---|---|---|---|---|
| none | create | active | insert | the secret, once (login, 3b) |
| none | check | none | refuse-401 | 401 |
| none | revoke | none | refuse-404 | 404 |
| none | regenerate-other | none | refuse-404 | 404 |
| active | check | active | admit | the request goes on |
| active | regenerate-self | active | replace-hash | a new secret, once; the old one dies at once |
| active | regenerate-other | active | refuse-403 | 403 |
| active | revoke | revoked | set-revoked | the key, with its `revoked` time |
| revoked | check | revoked | refuse-401 | 401 |
| revoked | revoke | revoked | nothing | the key, as it is |
| revoked | regenerate-other | revoked | refuse-403 | 403 |

- **Cannot happen,** each for its reason:
  - `create` on an active or a revoked key: a create makes a new key;
  - `regenerate-self` on none or revoked: the asking key passed its check, so it is
    active.
- **There is no 409.** The first draft had "regenerating a revoked key is a 409". But
  a key regenerates only itself, and a revoked key fails its check first, so that row
  could only be reached by another key, which is a 403 whatever the state.
- **No state is an end.** `(techo machine)` today calls every state of such a table a
  dead end. It gains one meaning: terminals given as `#f` say "no end, on purpose",
  and the dead-end check is skipped. An empty list is still checked, so forgetting
  the terminals is still caught. The migrate and doorway tables are untouched.
- `revoked` is a time, and null means active. No state column.
- A revoked row stays, and a list shows it.
- **A key may revoke any key of its account,** itself included: that is how a lost
  device is shut out.
- **A key may regenerate only itself.** So a stolen key cannot take over the other
  devices.
- Regenerate keeps `created`.
- Another account's key is a 404, never a 403: its existence is not told.
- **The command names the answer.** The handlers call the table's step and perform
  its command. They decide nothing on their own.

### D6. `last_used` is set only by a request that writes

In a write job the asking key's `last_used` is set to now in the same transaction,
when it is null or more than a day old. A read never sets it.

- A write that is refused sets nothing: its transaction is rolled back.
- Regenerate is a write like any other, so the key's answer shows the new time.

- **Known cost:** a device that only reads looks unused. A person who revokes it by
  mistake logs in again.
- **Why not on reads too:** a read job cannot write, and circuit has no job that is
  not waited for. A second job after a read holds a finished answer behind the
  writer, and can turn it into a 504 when the writer is busy.

The other choices: a second job with its own short deadline (accurate, but more
moving parts and an exception to "one job a request"); or drop the column.

**The owner asked that this be documented** (2026-11-24). So:

- the API's document says, where it lists a key's fields, that `last_used` is the
  last time the key *changed* something, to the day, and that reading does not count;
- ADR-0006's amendment for this slice records it and why;
- `.plans/global-constraints.md` gets the rule "a read never writes `last_used`".

### D7. One error format, RFC 9457's, made by one outer middleware

**Decided (owner, 2026-11-24): RFC 9457 problem details,** with a `code` member.

```json
{"type": "about:blank", "title": "Forbidden", "status": 403,
 "code": "forbidden", "detail": "A key can only regenerate itself."}
```

- Sent as `application/problem+json`. That content type is how anything tells an
  answer is already in the format.
- `type` is `about:blank`, which the RFC defines as "nothing more than the status
  says". A self-hosted server has no fixed address to hang a URI for each kind of
  error on. Real ones can be added later without breaking a client that reads `code`.
- `title` is the status's own phrase, as the RFC asks when `type` is `about:blank`.
- `status` repeats the HTTP status.
- `code` is a fixed word a client can switch on. `detail` is for a person.
- **`wrap-errors` is the outermost middleware.** An answer of 400 or more whose
  content type is not the format's gets the format's body for its status: 400 is
  `invalid_request`, and 404, 405, 413, 500, 503 and 504 are as the table below. Any
  other bare status gets the code `error` and its status's own phrase.
- A handler that knows more answers in the format itself, with its own code. It
  keeps every header but `content-type` and `content-length`, so `allow` and
  `retry-after` stay. That covers circuit's own 400, 405, 413, 500, 503 and 504.
- `wrap-json-body` sits inside `wrap-catch`, on the routes that take a body. Outside
  it, an oversize body would reach the server and not be in the format.
- **Not covered:** what the server refuses before any handler runs, such as bytes that
  are not HTTP.
- ADR-0002 said slice 4 would design this. Slice 3 has the first refusals, so it is
  amended.

| Status | Code | When |
|---|---|---|
| 400 | `invalid_json`, `invalid_request` | a body that does not parse; a bad `limit`, `after` or id |
| 401 | `unauthorized` | every failed check, whatever the reason; with `WWW-Authenticate: Bearer` |
| 403 | `forbidden` | regenerating a key that is not the one asking |
| 404 | `not_found` | no such route, or no such key for this account |
| 405 | `method_not_allowed` | |
| 413 | `payload_too_large` | |
| 415 | `unsupported_media_type` | a body that is not `application/json`, on a route that takes one |
| 500 | `internal` | |
| 503 | `unavailable` | |
| 504 | `timeout` | |

3b adds `invalid_credentials` (401), `rate_limited` (429) and `too_many_keys` (409).

No 3a route can answer 413, 415 or `invalid_json`: none takes a body. Their tests use
a stand-in route that does.

The other choice was a smaller body of Techo's own, `{"error": {"code", "message"}}`.
The first draft recommended it, wrongly saying the RFC needs a URI for each error.

### D8. Routes live under `/v1`

`/health` stays where it is. Adding a prefix later would break every client.

### D9. The routes

| Route | Slice | What it does | Answers |
|---|---|---|---|
| `GET /v1/account` | 3a | who this key belongs to | 200: `id`, `username`, `email`, `created` |
| `GET /v1/keys` | 3a | the account's keys, paged, no secrets | 200: `items`, `next` |
| `POST /v1/keys/{id}/revoke` | 3a | D5's revoke | 200: the key |
| `POST /v1/keys/{id}/regenerate` | 3a | D5's regenerate | 200: the key, and `key`, the new secret |
| `POST /v1/login` | 3b | email, password and a device name in | 201: the key, and `key`, the secret |

- A key in an answer is `id`, `name`, `created`, `last_used` and `revoked`. Its hash
  is never sent.
- Revoke and regenerate take no body.
- An answer that carries a secret has `Cache-Control: no-store`.
- **There is no `POST /v1/keys`.** A key that could make keys would let a leaked key
  quietly make a second one, which revoking the first would not remove. A key comes
  from a login (ADR-0006).

Paging, the first of it: `?limit=` (default 50, cap 100) and `?after=` (the last id
seen). The answer is `{"items": [...], "next": "<id>" or null}`.

- A `limit` that is not a whole number of 1 or more is a 400. One over 100 is read
  as 100.
- An `after` that is not an id is a 400. It is only a place to start from, and is
  never looked up, so naming another account's key tells nothing.
- **The order of checks:** the header's shape (401), then the id, `limit` and `after`
  (400), then the job, where the key is checked (401) and the work done.
- The store reads one row more than the limit to know
whether there is a next. ADR-0002 is amended.

### D10. The request log is Techo's own line

circuit's `wrap-log` cannot show database time or the account, so `wrap-request-log`
replaces it:

```
request method=GET path=/v1/keys status=200 ending=written ms=4 db_ms=1 account=0193… address=203.0.113.9
```

- One line, one write, from the loop's thread, when the response ends.
- **Never in it:** a query string, a header, a body.
- It sits outside everything but `wrap-errors`, which never changes a status, so it
  logs the status the client got.
- The middleware puts a note on the request. `db-read-as` and `db-write-as` write the
  account and the time the database took into it, **on the loop's thread, from what
  the job returned.** A job never writes it: after a deadline a job can finish later
  than the line is written.
- `&refusal` carries the account's id beside the code, when the check had passed. So
  a 403 or a 404 is logged with its account. An id is not a secret.
- `db_ms` is the time from handing the job over to getting its answer, the wait in
  the queue included.
- A field with nothing to show is `-`.
- **A 504 on a write is a "maybe":** the job may still commit after the line.
- **Two clocks:** the time of day in milliseconds for a row's times, and `real-time`
  for `ms` and `db_ms`. Each is an argument, so a test gives its own.

### D11. Passwords are hashed on a worker of their own (3b)

- One thread, a queue of 8. Full is a 503 with `Retry-After`.
- `'interactive` limits. A hash that `password-needs-rehash?` flags is replaced at the
  next good login.
- So at most one hash runs at a time: 64 MiB, whatever the load.
- **An unknown email is still hashed against,** so a stranger cannot tell a missing
  account from a wrong password by the time it takes. The stand-in is the hash of
  random bytes drawn at start, and the answer is a 401 whatever the verify says.
- `user add` hashes on its own thread: it is not a server.

This answers the ledger's question on a hashing worker.

### D12. The login rate limit (3b)

- **Each email: 5 tries in 15 minutes. Each address: 20 in 15 minutes.** A good login
  clears its email's count.
- A refusal is a 429 with `Retry-After`, before any hashing or database work.
- The email is counted after it is trimmed and lowercased, so `A@x` and `a@x` share
  one count.
- The address is checked first. A try it refuses adds no count for the email.
- A body that names a field twice is a 400, so the limit and the lookup cannot read
  two different emails.
- The counts live in memory. A restart forgets them.
- IPv6 addresses are counted by their first 64 bits. An IPv4 address written the IPv6
  way (`::ffff:1.2.3.4`) is counted as the IPv4 address.
- At most 10,000 counts. Past that, every login is refused until some expire, and one
  line says so.
- **Known cost:** anyone can lock a known email out of *logging in* for 15 minutes.
  Keys already given keep working. Someone with a few hundred addresses can fill the
  table and stop every login for a while.

### D13. Behind a proxy, one flag says so (3b)

`TECHO_BEHIND_PROXY=1` makes the address the last one in the last `X-Forwarded-For`
header, when that is an address. Otherwise, and when unset, it is the peer's.

- Set it only when nothing but the proxy can reach the port.
- Behind a proxy without it, every login shares one address's count. The docs say both.

The other choice is a list of trusted proxy addresses, which is safer, but a proxy's
address in a Docker network is not fixed.

### D14. One `serve` for each file

Two would each keep their own rate-limit counts. The docs say run one. Nothing
enforces it.

### D15. A time in the API is whole milliseconds since 1970, UTC

The same number the database holds: `"created": 1795515226123`. Every later slice
inherits this, and ADR-0002 is amended.

The other choice is an RFC 3339 string, `"2026-11-24T10:13:46.123Z"`. A person can
read it, but each client must parse it, and the server needs date arithmetic it does
not have. A number compares and sorts as it is.

### Smaller choices, made unless the owner objects

- **An email** is trimmed and lowercased (ASCII letters only), at most 254 bytes, with
  one `@` and something on each side. It is unique after that, and the table refuses
  one that is not lowercase.
- **A username** is `[a-z0-9][a-z0-9_-]{0,31}`.
- **A password** is at least 8 characters and at most 1024 bytes.
- **A key's name** is 1 to 64 characters with no control character. Two keys may share
  a name. (3b: nothing in 3a takes one.)
- **An account has at most 100 active keys** (3b: login is what makes them).
- **A JSON body** is at most 16 KiB, and must say `application/json`, or it is a 415
  (3b: no 3a route takes a body).
- **`techo user add USERNAME EMAIL` reads the password from standard input,** one
  line. It does not hide typing. The docs show a pipe.
- **A missing libsodium ends every command** at start, `version` and `migrate` too,
  with the library's own message.

## Slice 3a

### The tables (migration 2)

```sql
CREATE TABLE accounts (
  id            BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  username      TEXT    NOT NULL UNIQUE CHECK (username GLOB '[a-z0-9]*' AND username NOT GLOB '*[^a-z0-9_-]*' AND length(username) <= 32),
  email         TEXT    NOT NULL UNIQUE CHECK (email NOT GLOB '*[A-Z]*'),
  password_hash TEXT    NOT NULL,
  created       INTEGER NOT NULL
) STRICT;
CREATE TABLE api_keys (
  id        BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  account   BLOB    NOT NULL REFERENCES accounts(id),
  name      TEXT    NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
  key_hash  BLOB    NOT NULL UNIQUE CHECK (length(key_hash) = 32),
  created   INTEGER NOT NULL,
  last_used INTEGER,
  revoked   INTEGER
) STRICT;
CREATE INDEX api_keys_account ON api_keys(account, id);
```

`check-migrations` passes and foreign keys hold. The three `CHECK`s on text came
from the closing review: see the last section.

### Libraries

| Library | Pure? | Holds |
|---|---|---|
| `(techo errors)` | yes | D7's codes, each one's status and message; `error-res`; `&refusal` |
| `(techo keys)` | yes | D5's table and step; the secret's shape and its hex; the header's reader, which answers `#f` for any string and never raises; paging checks |
| `(techo accounts)` | yes | email, username and password checks |
| `(techo store)` | jobs | each SQL statement, as a procedure of a `Tx`. It answers rows or `#f` and raises nothing of its own |
| `(techo auth)` | shell | hashing the key (`blake2b`); `db-read-as`, `db-write-as`, which raise and catch `&refusal` |
| `(techo routes)` | shell | the four handlers |
| `(techo log)` | shell | `wrap-request-log` and its note |
| `(techo app)` | shell | `wrap-errors`, the router, the order of the middlewares |

The shell takes as arguments its two clocks, its random bytes, its id maker, and
**the two procedures that run a job,** each a `(Tx -> Any) -> Any`. `make-app` is
given those, not the doorway: `techo.sps` makes them from `db-read` and `db-write`.
So no route can reach the doorway by another way, and a test that gives its own can
count jobs.

- `db-read-as` and `db-write-as` take a runner, the request and the work, a
  procedure of the `Tx` and the account. They answer the work's value, or the
  refusal's answer in the error format.
- A job closes over plain data only, never the request.
- The two clocks have one shape, so a swap would go unseen. A test holds that an id's
  own time is its row's `created`. A test's random bytes are a sequence, never one
constant: two keys with one hash would break the unique index.

The middlewares, as `wrap` takes them, innermost first:
`(wrap router (wrap-db log) (wrap-busy 5) wrap-catch (wrap-timeout ms)
wrap-request-log wrap-errors)`. A test pins the order. The reviewer walked it: the
log sees the 500, 503 and 504 the client gets.

**`wrap-app` keeps its meaning and its signature.** The two new middlewares go on in
a wrapper of their own, so the doorway's own suites and their child server do not
change their answers.

### What must hold, and what would catch a break

| | Property | Caught by |
|---|---|---|
| P1 | No secret is kept or logged: after a run, neither the database file, its `-wal`, nor the log holds a shown secret, as hex or as bytes. A forced 500 is part of the run: the test's own connection adds a trigger that aborts an update of `api_keys`. | integration; and a test that feeds the header's reader random strings |
| P2 | An account sees only its own keys. Another's is a 404 on every route. | the model test, whose sequences aim at the other account's ids |
| P3 | A revoked key passes no check that starts after the revoke commits, nor does a regenerated key's old secret. | the model test, which keeps using dead secrets |
| P4 | Every answer of 400 or more from the app is in the one format. | handler tests, one for each status in D7's table |
| P5 | A request makes one job, and every key route checks the key. | handler tests, counting calls to the job runners; a 401 test with no key for each route; a test that reads each library's imports, so only `techo.sps` names `db-read` and `db-write` |
| P6 | A header of the wrong shape makes no job. | handler tests, the same way |
| P7 | The real handlers agree with D5's table on every sequence tried. | the model test |

### How it is checked

1. **The table itself:** `machine-problems` on D5's table; its diagram rendered into
   `.plans/machines/key.md` and held by a test.
2. **Pure tests** of every check and of the error codes, with D3's fixed key and hash.
3. **Store tests:** each job against real SQLite through the test doorway.
4. **Handler tests** through the server's test host, with fixed clocks, bytes and ids.
5. **The model test:** random sequences of check, regenerate and revoke, over two
   accounts and several keys, live and dead, against the real handlers and SQLite,
   compared with the step function. The model keeps each key's true state; the
   caller's view is "none" for an unknown id or another account's key. A check
   belongs to a secret, not a key: an old secret is "none".
6. **Integration:** the real server and chez-curl, on a file with an account and its
   keys put in by hand.
7. **A closing review,** adversarial, with a pass for secrets and timing.

Lighter than slice 2b's six layers on purpose: no exhaustive model and no replay.
The machine has three states.

**What 3a does not check:** `create`, the one row no 3a route can reach. The tests
put keys in by hand, with the same hash procedure the check uses. 3b's login is its
first real use.

### The work

| # | Task | Who | Files |
|---|---|---|---|
| 0 | Dependencies (**done**, 2026-11-24): chez-sodium and unique-id as pinned submodules; libsodium in the container and CI | the lead | `Makefile`, `manifest.scm`, `.gitmodules`, CI |
| 1 | The pure core, the machine library's change, the diagram | Sonnet | `errors`, `keys`, `accounts`, `machine.sls`, `scripts/render-machines.sps`, the `machines` rule, their tests |
| 2 | Migration 2 and the store | Sonnet | `migrations.sls`, `store.sls`, `schema.md`, and the suites below |
| 3 | The shell: auth, routes, log, app | Opus | `auth`, `routes`, `log`, `app`, `techo.sps`, their tests, `doorway-child.sps`, and `test-integration.sps`'s 404 |
| 4 | The model test | Opus | its own suite and support |
| 5 | Integration and the docs | Sonnet | `test-integration.sps`, `docs/` |
| 6 | The closing review | Opus | reads only |

- **Task 2's suites,** each found by shipping migration 2 in a scratch copy:
  - `test-migrations.sps`, `test-db.sps`, `shipped-migrations.scm` and the version
    numbers in `test-integration.sps`;
  - `migrations-fixture.sls`: its own migrations follow the shipped list's last
    version, whatever it is;
  - `test-doorway.sps` and `test-doorway-threads.sps`, which spell version numbers out;
  - `transaction-replay-support.sls` and `test-transaction-replay.sps`: the replay is
    pinned to the first shipped migration. The model must not follow the shipped
    list, or every later migration would stall it.
- Tasks 1 and 2 run together, each running only its own suites. The lead runs
  everything when both are back.
- Task 2's store tests use 32-byte blobs written out, so they need nothing of task 1.
- The key's hash is task 3's, in `(techo auth)`, with D3's fixed key and hash.
- Task 3 follows both. It is judgement, not copying, so it is Opus's.
- Tasks 4 and 5 run together after 3.

## As built, where it differs from the above

- **`db-read-as` and `db-write-as` take a thunk, not the work.** The thunk runs only
  once the header has passed, and answers a response (the route's 400, with no job)
  or a plan: the work for the job, and the answer made from its value on the loop's
  thread. That gives D9's order of checks, and keeps a new secret out of the job.
- **The error answer is `problem-res`,** in `(techo errors)`, not `error-res`.
- **`wrap-server` is the wrapper** that puts the request log and `wrap-errors`
  outside `wrap-app`.
- **`wrap-errors` cannot tell a bad JSON body from any other 400.** A route that
  takes a body (3b's login) must answer `invalid_json` and the 415 itself.
- **A problem's title is chez-http-server's phrase** for the status: a 413 is
  "Content Too Large".
- **"More than a day" is strict:** a `last_used` exactly a day old is not set again.
- **A revoke that changes nothing is still a write,** so it sets the asking key's
  `last_used`.
- **A regenerate draws its random bytes before the key is checked,** so a refused one
  still spends 32 bytes.
- **The log's `account` is `-` on a 500 and on a 401,** even when a job ran: only a
  job's own answer or a refusal carries it.
- **Two procedures are named `key-hash`:** the store's row accessor and auth's hash
  of a secret. A library that imports both leaves one out.
- **Three of the store's guards cannot be seen through HTTP:** `revoked IS NULL` on
  revoke, and the account on revoke and on re-hash. A route reaches them only after
  it has found the key as its own, in the same transaction. The store's suite alone
  holds them.
- **The handlers never read the step's next state.** They take the state from the
  row and perform the command. The model test holds the two together.
- **The model test:** 400 sequences, 12,219 requests, each of the ten reachable rows
  hit 377 times or more.
- **Not checked:** two requests at once. The model test runs one at a time.

## Slice 3b, in outline

Planned in full when chez-sodium's M3 lands; its interface may still move.

- `(techo passwords)`: a record of `hash`, `verify` and `needs-rehash?`, so tests use
  a fast fake and three tests use the real one.
- `(techo limiter)`: D12 as a pure function of the counts, the time and a try.
- The hashing worker (D11), started and stopped by `serve`'s table, before the readers.
- `POST /v1/login`: limit, read the account, verify on the worker, then one write job
  that makes the key. The write is last, so a 503 is still a "no".
- **Login's write goes ahead only if the account's hash is still the one it
  verified.** Otherwise a login that began before `techo user password` could make a
  key after the reset revoked them all, or write a re-hash of the old password over
  the new one.
- `techo user add` and `techo user password`, each one write transaction beside a
  running server. `user password` revokes every key of the account.
- D13's flag and D14's line in the docs.
- **To decide then:** whether a password is normalised (NFC) before hashing. Changing
  it later means checking both ways.

**A question for chez-sodium, before its M3 is built** (sent to its session on
2026-11-24, as [the brief](briefs/chez-sodium-verify-out-of-memory.md). Its answer the
same day: **no,** settled in chez-sodium's M3 plan (§4.2, item 4): libsodium 1.0.18, its
floor, reports short memory as a mismatch. So plan on the
fallback below): `password-verify` answers
`#f` when the machine is out of memory, the same as for a wrong password. A server
short of memory would then tell people their passwords are wrong, and count each try
toward D12's lock. Whether that library should tell the two apart is its owner's
call. If it does not, login hashes a throwaway string after a `#f`: a raise from that
means memory is short, so the answer is a 503 and the try is not counted.

## Not in this slice

- Signup, email verification, password reset by mail (the outline, §1).
- A password change through the API.
- Deleting or disabling an account.
- Expiring keys.
- Making a key from a key (`POST /v1/keys`): see D9.

## The review of this plan (Opus, 2026-11-24)

Read-only and adversarial, with probes in `build/review-3-plan/`.

**Two blockers, both fixed above**

- **D5's table could not pass the machine library's checks** (run): a key's lifecycle
  has no end, and the library demands one. "None" was also missing its rows. Fixed
  in D5.
- **A login could outrun `techo user password`** (argued). Fixed in the 3b outline.

**Fixed above**

- A refusal raised in a job came out as a 500, with the key in the log line (run).
  Now `&refusal`, and only the hash enters a job (D3, D4).
- Migration 2 would break suites outside its task's files (read). The work table now
  names them.
- A touch of `last_used` after a read could turn a finished read into a 504 (read).
  D6 now sets it on writes only.
- `wrap-errors` would have sent two content types (read). D7 now says which headers
  stay, and where `wrap-json-body` sits.
- P5 and P6 had no layer that could see them. The job runners are now arguments.
- D2 named a procedure that only formats bits (read). Now `generate-v7`.
- Unsaid things a builder would have invented: times in the API (D15), the codes
  (D7), each route's answer (D9), `Bearer`'s case, the two clocks, the log's note.
- For 3b: the limiter's key and order, IPv4 written the IPv6 way, the last
  `X-Forwarded-For`, random bytes for D11's stand-in.

**Taken from where the reviewer disagreed**

- No `POST /v1/keys` (D9). A key regenerates only itself (D5).

**Recorded, not fixed**

- A write route's check runs on the one writer (D4's known cost).
- A regenerate that times out is a "maybe": the old secret may be dead and the new
  one never received. Until 3b there is no login to recover with.
- A key that revokes itself and retries gets a 401, not the first answer.
- A read whose snapshot began before a revoke commits still passes (P3 says so).
- Revoked rows are never removed.
- `api_keys.account` where later tables say `owner`.
- A password piped from `echo` lands in the shell's history. The docs will say so.

## The second review (Opus, 2026-11-24)

Of slice 3a only, with probes in `build/review-3-plan-2/`.

**Two blockers, both fixed above**

- **D5's 409 could never be reached** (run, then argued), and the table could not
  tell a handler which refusal to send. Regenerate is now two events, each refusal is
  its own command, and the 409 is gone.
- **Migration 2 breaks four more files than the work table named** (run, by shipping
  it in a scratch copy). The table now names them, and the replay is pinned.

**Fixed above**

- `wrap-app` stays as it is, so the doorway's suites do not change.
- What a write does to `last_used` when the key regenerates itself (D6).
- The job runners' shape, and `make-app` taking them in place of the doorway.
- A 401 test with no key for every route, and a test of who imports the doorway.
- The order of a handler's checks, and what a `limit` over the cap does (D9).
- `wrap-errors`'s answer for a status it has no code for (D7).
- The log's note is written on the loop's thread only; a refusal carries its account.
- `#f`, not an empty list, says "no end on purpose" to the machine library.

**Recorded**

- The first review said the page of keys reads from the index alone. It does not: it
  searches and orders by the index, with no sort, and then reads the rows. Harmless.
- In 3a nothing calls the id maker or `(techo accounts)`. Both are built and tested
  now, and first used by 3b.

## The third review, of the build (Opus, 2026-11-24)

Read-only and adversarial, with probes and mutants in `build/review-slice-3a/`. It
attacked the running server with raw requests, and found **no security hole, wrong
answer or way to corrupt data.** Five mutants survived every suite.

**One blocker, fixed**

- **A constant in place of the program's random bytes passed every suite** (run).
  Every regenerated key would have had one secret. Nothing tested what `techo.sps`
  hands the app. The integration suite now regenerates two keys and holds that their
  secrets differ and are not one byte repeated.

**Fixed**

- **The email `CHECK` used `lower()`,** which folds more on an SQLite built with ICU,
  and would then refuse what the code stores (run). It is now a `GLOB` on ASCII's
  capitals. The table also holds a username's shape and a key name's length, while
  migration 2 can still be changed.
- **No test held the `Bearer` scheme** (run): "Basic" was refused for its length. Both
  suites now try a scheme of the same length.
- **The program's reader could have been a write job** and nothing would have said so
  (run). An integration test now reads while another program holds the write lock.
- **Docs:** a key that revoked itself gets a 401 on its second try; the log's
  `account` is `-` on a 500; a refused request has its own line; macOS needs
  `CHEZ_SODIUM_LIBRARY`.
- **Records:** the rules the constraints cited from ADR-0006 are now in it; the
  request log is in ADR-0009; macOS for development is in ADR-0001; the `ln -sT` trap
  says what replaced it.

**Recorded, not fixed**

- **A regenerate that times out or is hung up on still commits,** and its log line
  shows no account. An operator cannot tell whose key changed.
- **Two mutants still survive:** `ORDER BY id` removed from the page of keys (SQLite
  reads the index in order anyway), and a clock in whole seconds.
- **`wrap-errors` keeps every header but two.** A later `content-encoding` or `etag`
  would ride on the replaced body.
- **The count of active keys reads revoked rows too,** and they are never removed.
  3b's cap of 100 may want an index.
- **Two emails that differ only in a non-ASCII letter's case are two accounts.**
- **The store's `revoked IS NULL` repeats a row of the table.** If the table changes,
  the model test's comparison of rows would show it.
