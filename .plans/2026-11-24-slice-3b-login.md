# Slice 3b: users, login and the rate limit

Date: 2026-11-24
Status: built, and reviewed twice: the plan (the first review section) and the build
(the last section). The owner accepted its decisions on 2026-11-24 (D11 to D14 of
[slice 3's plan](2026-11-24-slice-3-accounts.md), NFC, the timed-out request's
account) and said to build it on chez-sodium's notice, stopping only for a verb
mismatch or a hard decision. The smaller choices below are this plan's.
Records: ADR-0006 (accounts and keys), ADR-0007 (machines), ADR-0009 (settings),
ADR-0013 (the doorway). Read [global-constraints.md](global-constraints.md) first.

## What this slice is for

After 3a a real server has no accounts. This slice makes them usable:

- `techo user add` makes an account, and `techo user password` resets a password.
- `POST /v1/login` turns an email and a password into an API key.
- Login is rate-limited, and its hashing runs off the loop's thread.

No migration: 3a's tables already hold everything.

## What the probes found (2026-11-24)

Programs are under `build/probe-3b-sodium` and `build/probe-3b-techo`.

**chez-sodium at d53e83c (its M3)**

- `password-hash : String [Limits] -> String`, `password-verify : String String ->
  Boolean` (the hash first), `password-needs-rehash? : String [Limits] -> Boolean`.
  The default limits, `'interactive`, take 64 MiB and about 50 ms.
- A hash is 97 ASCII characters and starts `$argon2id$`.
- `password-verify` answers `#f` in microseconds for a string that is not a hash. So
  the stand-in for an unknown email must be a real hash.
- **Short memory:** `password-verify` answers `#f`, the right password too.
  `password-hash` raises `&sodium-failed` (`sodium-failed?`). This holds under
  `ulimit -v`. Under a container's memory limit the kernel kills the process instead
  (chez-sodium's session, not probed here).
- A password over 65,536 UTF-8 bytes, or one that is no string, is an
  `assertion-violation`, not a chez-sodium condition.
- No condition's message or irritants hold the password or the hash.
- Passwords are hashed as their UTF-8 bytes. `string-normalize-nfc` is in `(rnrs)`.
- Two threads hash in parallel. A hash holds its thread's interrupts.
- `(make-password-limits 1 8)` is the smallest and takes under a millisecond.

**Techo and circuit**

- A second worker is `(make-worker set-up cap threads [tear-down])` and
  `(worker-call w (lambda (state) ...))`. `cap` counts waiting jobs. A full queue
  raises `&worker-full` in the caller; a raise in a job is raised again in the caller.
- `req-remote-address` is a bare address: `"127.0.0.1"`, `"::1"`,
  `"::ffff:127.0.0.1"` for IPv4 on a dual-stack listener, and `#f` in the test host.
- `req-header-values req "x-forwarded-for"` gives each field whole, in order, not
  split on commas.
- `(wrap-json-body cap)` then `req-json?` and `req-json`. An object is an alist that
  **keeps a name given twice**. Invalid JSON is a plain 400; over the cap is a 413. A
  missing or wrong `Content-Type` leaves `req-json?` false.
- `problem-res` keeps a `retry-after` header. There is no code for 429 yet.
- The commands are a table in `(techo cli)`; a setting is a row in `(techo config)`.
- The server's start and stop is machine 3, `serve-rows` in `(techo transaction)`,
  performed by `(techo serve)`.
- A command can write beside a running server with `doorway-set-up`, `run-job!` with
  `write-step`, and `doorway-tear-down`. This was read, not run.
- A timed-out request logs no account because the id is known only inside the job,
  and the job's answer is dropped at the deadline.

## The owner's decisions

| | Decision |
|---|---|
| D11 | Passwords are hashed on a worker of their own: one thread, a queue of 8 |
| D12 | 5 tries an email and 20 an address in 15 minutes, in memory |
| D13 | `TECHO_BEHIND_PROXY=N`, a count of proxies, well documented |
| D14 | One `serve` for each file: documented, not enforced |
| | A password is normalised to NFC before it is hashed or verified |
| | A request that times out is to log its account |
| | After a false verify, a throwaway hash tells short memory from a wrong password |

## The design

### L1. Login is a table

`POST /v1/login` is run by a table in `(techo login)`, as ADR-0007 asks. The handler
performs each command and feeds the outcome back. It decides no answer itself.

| State | Command | Outcomes |
|---|---|---|
| `limiting` | count the try | `allowed`, `limited` (seconds), `full` |
| `reading` | read the account by email | `found` (id, hash), `missing` |
| `verifying` | verify on the worker | `matched`, `unmatched`, `busy` |
| `doubting` | hash a throwaway on the worker | `hashed`, `failed`, `busy` |
| `rehashing` | hash the password again on the worker | `rehashed` (hash), `failed`, `busy` |
| `writing` | make the key in one write job | `made` (key), `stale`, `full` |
| `ended` | answer | |

How it goes:

1. **`limiting`.** `limited` and `full` end with a 429 and `Retry-After`. Nothing is
   hashed or read (ADR-0006, item 7).
2. **`reading`.** `missing` goes on to `verifying` with the stand-in hash, so both
   cases cost the same.
3. **`verifying`.**
   - `busy` (the queue is full) ends with a 503 and `Retry-After`, and the try is
     forgiven: nothing was checked.
   - `unmatched` goes to `doubting`.
   - `matched` with a found account goes to `rehashing` when the hash is not at the
     current limits, else to `writing`.
   - `matched` on the stand-in is treated as `unmatched`. It cannot happen: the
     stand-in is the hash of 32 random bytes.
4. **`doubting`.**
   - `hashed` ends with a 401: memory was fine, so the password was wrong.
   - `failed` (`&sodium-failed`) ends with a 503 and `Retry-After`, and the try is
     forgiven: memory is short, so nothing was really checked.
   - `busy` ends with a 401 and the try **stays counted**. The verify did run. If a
     full queue forgave it, filling the queue would buy unlimited guesses.
5. **`rehashing`.** `failed` and `busy` go on to `writing` with no new hash. A failed
   rehash never fails a login.
6. **`writing`.** One write job: read the account again, and only if its hash is still
   the one verified, count its active keys, store the new hash when there is one, and
   insert the key. The insert is D5's `create` row, stepped and performed as 3a's
   handlers do (ADR-0006, item 11).
   - `made` ends with a 201 and clears the email's count.
   - `stale` ends with a 401. `techo user password` ran in between, so the password
     that was verified is no longer the password.
   - `full` ends with a 409 `too_many_keys`, and clears the email's count: the
     account already has 100 active keys (slice 3's plan). Nothing is written.

A raise that is none of these (the database busy, a deadline, a hung-up client) goes
on to the stack as it does for every route. The try stays counted.

**Events are named by the shell from what the effect did,** as machine 3's are. The
table's diagram is `.plans/machines/login.md`, rendered by `make machines`. The table
passes `machine-problems`, and every row is driven by a test.

### L2. The request and the answers

```
POST /v1/login
Content-Type: application/json

{"email": "a@example.com", "password": "…", "name": "laptop"}
```

- `name` is the new key's name: 3a's rule, 1 to 64 characters.
- **201:** the key's fields and `"key": "techo_…"`, the same body as a regenerate,
  with `cache-control: no-store`.
- **415 `unsupported_media_type`:** the `Content-Type` is missing or is not
  `application/json` (slice 3's D7).
- **400 `invalid_json`:** the body does not parse. circuit answers a plain 400 here,
  which `wrap-errors` would call `invalid_request`, so the route makes this answer
  itself.
- **413 `payload_too_large`:** over 16 KiB, slice 3's cap for a JSON body.
- **400 `invalid_request`:** an empty body, not an object, a name given twice, a name
  that is none of the three, a missing one, a value that is no string, an email that
  `normalise-email` refuses or that is over 254 characters, a bad key name, or a
  password over 1,024 bytes after NFC.
- None of the above is counted as a try.
- **409 `too_many_keys`:** the password was right, and the account has 100 active
  keys. Revoke one first.
- **401 `invalid_credentials`:** wrong email or wrong password. One answer for both.
- **429 `rate_limited`** with `Retry-After`.
- **503 `unavailable`** with `Retry-After: 5`: the hashing queue is full, or memory is
  short.
- **A password is not checked against the 8-character minimum at login.** That rule
  is for setting one. A short password is simply wrong.
- The password is normalised to NFC, then verified.

### L3. The rate limit

`(techo limiter)`: pure decisions, and one mutable table the loop's thread owns.

- **A count is a window:** its start and how many tries. It opens at the first try
  and lasts 15 minutes. At the limit, a try is refused until the window ends, and
  `Retry-After` is the seconds left, rounded up.
- **A try is counted against both keys or neither.** The address is checked first,
  then the email. If either refuses, neither count grows. When both refuse,
  `Retry-After` is the larger of the two.
- **The check and the count are one call,** on the loop's thread, with no wait inside
  it. So two requests cannot both pass on the last free try.
- **Forgiving** a try takes one from each count, with three rules:
  - never below zero;
  - only in the window the try was counted in: the try carries each window's start,
    and a window that has since been cleared or reopened is left alone;
  - so forgiving after a clear does nothing.
- **Clearing** removes the email's window.
- **The email's key** is the normalised email.
- **The address's key** (`(techo address)`, pure). An address is parsed to its bits
  first, so every spelling of one address has one key:
  - IPv4 is four decimal numbers, 0 to 255, with dots. No octal, no `127.1`. Its key
    is `v4:` and the dotted form.
  - IPv6 is parsed in full: `::`, upper or lower case, a dotted IPv4 tail. A zone id
    (`%…`) is dropped.
  - An IPv6 address in `::ffff:0:0/96`, however it is written, is its IPv4 address.
  - Any other IPv6 address's key is `v6:` and its first 64 bits as 16 hex digits.
  - No address, or text that is neither, is the one key `unknown`.
  - The prefixes keep an IPv4 key and an IPv6 key from ever being the same text.
- **At most 10,000 windows.** When a try would add one past that, expired windows are
  swept. If it is still full the try is refused, `Retry-After: 60`, and one line is
  logged, once until the table has room again.
- The time is the app's injected duration clock (`real-time` in the program), which
  never goes backwards. Not the wall clock. No test sleeps.

### L4. The client's address

`client-address : Natural (Listof String) (U String #f) -> (U String #f)`, pure, in
`(techo address)`.

- `0` proxies: the peer's address.
- `N` proxies: every `X-Forwarded-For` field is split on commas and trimmed, the
  fields joined in order into one list, and the answer is the Nth from the end.
- Empty entries are dropped (RFC 9110).
- **An entry may carry a port or brackets,** as some proxies write them:
  `1.2.3.4:5678`, `[2001:db8::1]`, `[2001:db8::1]:443`. They are stripped. The entry
  is the trusted proxy's own, so this gives a client nothing to forge.
- A list shorter than N, or an entry that is still not an address (`unknown`, a
  name), gives the peer's address. Behind a proxy that is the proxy's, so every such
  client shares one count. The docs say so.
- The `Forwarded` header is not read.
- **The request log's `address` stays the peer's.** Behind a proxy it is the
  proxy's. Whether it should be the client's is a question for the owner.
- `TECHO_BEHIND_PROXY` is a row in `(techo config)`: unset or `0` to `8`, digits
  only. Anything else refuses to start, exit 2, naming the variable and not its
  value.

### L5. The hashing worker

`(techo hasher)`: the shell around one circuit worker, one thread, a queue of 8.

- It is given two procedures, `hash` and `verify`, so tests pass fast fakes.
- **Starting it makes the stand-in:** the hash of 32 random bytes as hex. If that
  hash raises, the server does not start. A machine that cannot hash once cannot
  serve a login.
- It is also given `failed?`, the predicate for "memory is short"
  (`sodium-failed?` in the program), so it imports nothing of chez-sodium's.
- `hasher-verify`, `hasher-hash` and `hasher-doubt` each run one job and answer a
  symbol the login table reads. They catch `&worker-full` (`busy`) and what `failed?`
  accepts (`failed`), by the doorway's own catch pattern. Anything else goes on.
- A deadline during a job: a queued job never runs; a running one finishes, holding
  the password for one hash at most.
- **A job closes over the password.** It has to. It is safe because no chez-sodium
  condition shows a secret, and Techo's log lines never print a job's closure.
- **Machine 3 starts and stops it.** Two new states, `opening-hasher` after
  `opening-writer` and `stopping-hasher` before `stopping-writer`:

  ```
  checking → opening-writer → opening-hasher → opening-readers → serving
           → stopping-readers → stopping-hasher → stopping-writer → ended
  ```

  - Four rows are new, and four change where they go: a raise in `opening-readers`
    must now stop the hasher, and `stopping-readers` goes to `stopping-hasher`.
  - A raise in `opening-hasher` stops the writer and ends with status 1.
  - `serve-loop` takes the hasher's open and stop as two more arguments, both
    thunks, so the table's tests need no chez-sodium. **Its four-argument form
    stays,** with a hasher that does nothing, so `tests/doorway-child.sps` and
    `techo.sps` keep working until they are wired.
  - Machine 3's pins all change with it: `tests/test-transaction.sps`,
    `tests/transaction-model.sls`, `tests/test-transaction-model.sps` and the
    rendered `.plans/machines/doorway.md`. The replay suites do not touch machine 3.

### L6. Passwords

`(techo passwords)`.

- `prepare-password : Any -> (U String Symbol)`: NFC, then the length rules. For
  setting a password: 8 characters or more, 1,024 bytes or fewer. For login: only the
  upper bound (`prepare-login-password`).
- `sodium-hash`, `sodium-verify`, `sodium-needs-rehash?`: chez-sodium's verbs at
  `'interactive`. The only place the limits are named, so hash and needs-rehash agree.
- `memory-short? : Any -> Boolean`: `sodium-failed?`.
- Three tests use the real verbs at `'interactive`. Every other test uses fakes or
  `(make-password-limits 1 8)`.

### L7. Login reaches the database by two named procedures

ADR-0006's item 9 says a route reaches the database only through `db-read-as` and
`db-write-as`, which check a key. Login has no key. So `(techo auth)` gains two more,
and nothing else:

- `login-read : Runner Clock Req String -> (U (Pair Bytevector String) #f)`: the
  account's id and password hash by email, in one read job.
- `login-write : Runner Clock Req Bytevector String (U String #f) Key-fields ->
  (U Key 'stale 'full)`: the check-and-insert of L1's step 6, in one write job.
- `Key-fields` is the new key's id, its name, its 32-byte hash and the time. Plain
  data. The secret stays on the loop's thread.

The request's note:

- **`db_ms` is the two jobs' sum.**
- **The account goes into the note once the password has matched,** before the
  write. `login-write` keeps it whatever the write does: `made`, `stale`, `full`, a
  raise or a deadline.
- So a login whose password did not match shows no account, and one that matched
  always shows it.

### L8. A timed-out request logs its account

For the key routes, the job writes the account's id into a one-slot box as soon as
the key check passes, and the loop's thread reads the box when the job's answer never
comes.

- This is the one thing a job shares with the loop's thread. **The box is read and
  written under a mutex,** so the reader never sees a half-made value on any
  processor. ADR-0013 gets an amendment saying so.
- **It is read on every raise,** not the deadline alone: a hung-up client and a 500
  log the account too, when the key check had passed. `docs/running.md` says `-` on
  a 500 today, and changes.
- **It does not close the case entirely.** A job still in the queue at the deadline,
  or taken up but waiting for the write lock, has not checked the key yet. It logs
  `-`, and a job waiting for the lock can still commit afterwards. The docs say so.

### L9. The commands

```
techo user add --username NAME --email EMAIL
techo user password --email EMAIL
```

- **The password comes from standard input, never the command line,** where `ps`
  would show it.
  - A terminal (`test -t 0`): prompted twice on standard error with echo off
    (`stty -echo`, restored whatever happens), and the two must match.
  - A pipe or file: the first line.
  - One trailing `\r` is dropped. Spaces at either end are kept: they are part of
    the password.
  - An empty line or no line is refused.
  - Ctrl-C at the prompt restores the echo. The exit status is then Chez's, 255.
  - The terminal path cannot run in CI: the container has no terminal. It is tested
    by hand.
- Both check the settings, then the database, then write, in this order:
  1. `check-db`, so a missing file or one that needs `techo migrate` gets the proper
     line;
  2. the hash, before any transaction;
  3. `doorway-set-up` read-write, `run-job!` with `write-step`, and
     `doorway-tear-down` whatever happens;
  4. `&db-refused` and `&db-unavailable` (busy, moved) are one line and exit 1.
- That is **one write transaction**, and both work beside a running server.
- `(techo users)` imports `(techo doorway)` with `only`, and never names `db-read` or
  `db-write`: a test in `tests/test-app.sps` reads every source file for that.
- `user add`: the username and email by 3a's rules, the password by L6, an id from
  unique-id. A username or email already there is refused by name. It prints the
  account's id.
- `user password`: sets the hash and **revokes every key of the account**, and prints
  how many. No such email is refused.
- Exit 0 done; 1 refused or failed, one line on standard error; 2 usage or settings.
- `(techo cli)` parses them, pure. `(techo users)` is the shell, given its hashing,
  clock and ids, so tests are fast. `techo.sps` only dispatches.

### L10. Wiring

- `make-app` takes one more optional argument, a login kit: the hasher's three calls,
  `needs-rehash?`, the limiter, the proxy count, the id generator, and the log
  procedure for the limiter's "full" line. Without it there is no
  `/v1/login`, so 3a's tests stand as they are.
- `techo.sps` builds the kit for `serve`.

## Smaller choices, made unless the owner objects

- A login answers **201**, since it makes a key.
- The limit's window is fixed from the first try, not sliding.
- A full table answers 429, not 503.
- An unknown field in the login body is a 400.
- A login's log line shows the account once the password matched, and not before.
- Every raise logs the account when the key check had passed, a 500 too.
- The request log's `address` stays the peer's.
- A bare 429 keeps the code `error`; only login makes a 429, and names it itself.
- The largest proxy count is 8.
- A piped password is one line; the terminal asks twice.
- A right password on an account with 100 active keys clears the email's count.

## What must hold, and what would catch a break

| | Property | Caught by |
|---|---|---|
| Q1 | A wrong email and a wrong password get the same status, body and headers, and do the same work: one read, one verify, one throwaway hash | login table tests count the commands; a route test compares the answers |
| Q2 | Nothing is read or hashed for a refused try | fakes that count their calls |
| Q3 | The password and the hash never reach a log line or a response | the integration suite searches every output for both |
| Q4 | A login cannot make a key after `user password` reset the account | `login-write` test with the hash changed between verify and write |
| Q5 | `user password` leaves no working key | integration: the old key answers 401 |
| Q6 | A try is forgiven only where nothing was checked, or memory was short | the table: only `verifying busy` and `doubting failed` forgive. Narrow gap: memory running short between a real verify and the throwaway |
| Q10 | An account never has more than 100 active keys | `login-write` test at 99 and 100 |
| Q11 | Login's handlers follow the model over random sequences | the login model test |
| Q7 | The count is by the normalised email and the address's key | limiter and address tests |
| Q8 | With N proxies, a client cannot choose its own address by sending the header | address tests: the Nth from the end is the proxy's own entry |
| Q9 | At most one hash runs at a time in the server | a hasher test with two slow jobs |

## The work

Agents do not commit. One agent per shared file. Each brief carries
[global-constraints.md](global-constraints.md).

**Wave 1, in parallel, disjoint files**

| Task | Model | Files | What |
|---|---|---|---|
| 1 | Sonnet | new `src/techo/limiter.sls`, `src/techo/address.sls`, `tests/test-limiter.sps`, `tests/test-address.sps` | L3 and L4's pure parts |
| 2 | Sonnet | new `src/techo/passwords.sls`, `tests/test-passwords.sps`; `src/techo/store.sls`, `tests/test-store.sps` | L6; `account-by-username`, `set-password-hash!` (only when the old hash matches), `revoke-all-keys!` |
| 3 | Sonnet | `src/techo/errors.sls`, `tests/test-errors.sps`; `src/techo/config.sls`, `tests/test-config.sps`; `src/techo/cli.sls`, `tests/test-cli.sps` | the codes `invalid_credentials`, `rate_limited`, `too_many_keys` (`unavailable` is there); `status->code` unchanged; `TECHO_BEHIND_PROXY`; the two commands' parsing |
| 4 | Opus | `src/techo/transaction.sls`, `src/techo/serve.sls`, new `src/techo/hasher.sls`, `tests/test-hasher.sps`, `tests/test-transaction.sps`, `tests/transaction-model.sls`, `tests/test-transaction-model.sps`, `.plans/machines/doorway.md` | L5 |

**Wave 2, in parallel, after wave 1 is verified**

| Task | Model | Files | What |
|---|---|---|---|
| 5 | Opus | new `src/techo/login.sls`, `tests/test-login.sps`; `src/techo/auth.sls`, `src/techo/routes.sls`, `src/techo/app.sls`, `src/techo/log.sls`, their tests, `tests/http-support.sls`, `scripts/render-machines.sps`, `.plans/machines/login.md` | L1, L2, L7, L8, L10's `make-app` |
| 6 | Opus | new `src/techo/users.sls`, `tests/test-users.sps` | L9's shell |

Before wave 2 the parent adds `login` to the Makefile's `machines` rule. After it,
the parent wires `techo.sps` and `tests/doorway-child.sps`: the kit and the hasher
for `serve`, and the two commands.

**Wave 3**

| Task | Model | Files | What |
|---|---|---|---|
| 7 | Sonnet | `tests/test-integration.sps`, `docs/api.md`, `docs/running.md`, `README.org`, `CHANGELOG.md` | the real program end to end; the docs, D13 at length |
| 8 | Opus | new `tests/login-model.sls`, `tests/test-login-model.sps` | random sequences of logins, resets and passing time against a model, through the real handlers with a fast hasher (the constraints' model-based test) |

Tasks 7 and 8 run in parallel.

Then a read-only adversarial review on Opus, and the records: ADR-0006, ADR-0009 and
ADR-0013's amendments, the constraints, the ledger, the traps.

## Not in this slice

- Changing a password over the API, or any password reset by mail.
- A lock that outlives a restart, or one shared by two servers.
- Limits on any route but login.
- An admin role.

## The review of this plan (Opus, 2026-11-24)

Read-only. Its scratch programs are in `build/review-3b-plan`. All of it is folded in
above.

**Blockers**

- **The 100-key cap was missing.** Slice 3's plan promised it for 3b, with
  `too_many_keys`. Without it anyone with the password could grow the table without
  end. Now L1's `full`.
- **Login's body errors would have had the wrong codes.** circuit's plain 400 for bad
  JSON becomes `invalid_request` in `wrap-errors`, and a wrong `Content-Type` is a
  415 by slice 3's D7, not a 400. Now L2.

**Should-fix, all taken**

- The address key was loose: `::ffff:7f00:1` and `::1` would have shared a key.
- An entry with a port, as some proxies write, would have put every client on one
  count: a third way to refuse everyone, beyond the two the owner accepted.
- The box for a timed-out request's account had no ordering across threads, and does
  not cover a job still waiting for the lock.
- Machine 3 changes eight rows and three test files, not "two states".
- Files no task owned: the Makefile's `machines` rule, the rendered diagrams.
- The commands need `check-db` first, and a trailing `\r` dropped.
- Login's write must step D5's `create`; `db_ms` is a sum; the note keeps the account.
- The limiter's forgiving needed its three rules, and the duration clock.
- The hasher must not need task 2's library in the same wave.
- ADR-0007: the login table needs `machine-problems` and a model test. Task 8.

**Found sound:** `make-worker` as the plan uses it; counting cannot race; the Nth from
the end for one proxy and two; the four paths' work for Q1; one stand-in made at
start; hash and revoke in one write for `user password`.

**Notes kept**

- Q1 holds for hashes made at today's limits. A stored hash that is unreadable, or
  made at other limits, answers in a different time. Only a hand-edited row or a
  future change of limits makes one.
- A good login clears tries counted while it was in flight.
- A 401 from login carries `WWW-Authenticate: Bearer`, the same on both paths.

## As built, where it differs from the above

- **`verifying`'s `matched` is three events:** `matched` (to `writing`),
  `matched-outdated` (to `rehashing`) and `matched-stand-in` (to `doubting`). A row's
  next state is fixed, so the shell's sorter, `login-event-kind`, names which, as
  machine 3's does. Whether a hash is outdated is asked only after a match on a
  stored hash, so the two wrong paths do the same work.
- **`(techo wiring)` builds what the program runs:** the hasher over chez-sodium's
  verbs, login's kit, the app with the duration clock, the id source and the `user`
  commands' kit. `techo.sps` calls it. It came from the closing review: a wrong
  argument in `techo.sps` passed every suite.
- **`parse-login-body` is in `(techo login)`,** which so loads chez-sodium through
  `(techo passwords)`. `make machines` needs libsodium.
- **`read-password` refuses when it cannot turn the echo off** (`'no-echo`), and
  prompts only once the echo is off.
- **The commands look at the name, the email and the database before asking for the
  password.**
- **U+007F to U+009F are refused** in a username, an email and a key's name, as the
  other control characters are.
- **`tests/doorway-child.sps` keeps `serve-loop`'s four-argument form.** It tests the
  doorway, and needs no hasher.
- **Tasks 1 to 8 as planned; task 9 was the closing review's fixes.** Suites: 31.

## The closing review (Opus, 2026-11-25)

Read-only, with a real server and mutants in a private copy. Its scratch is in
`build/review-3b`.

**No blocker.** It could not tell an existing email from a missing one (status, body,
headers, and 60 timings each: 106.3 ms both), get a sixth guess (13 spellings of one
email, floods to fill the hashing queue), pass 100 active keys with logins fired
together, keep a key alive across `user password`, wedge the server with bad bodies,
or find a password, a hash or a key in any output.

**Fixed**

- **The password was echoed when `stty` was missing,** and the command went on.
- **The docs said 20 *wrong* tries lock everyone out** behind a proxy counted too
  low. Good logins count toward the address too.
- **Nothing held the 64 MiB limits:** `'moderate` passed every suite.
- **The program's wiring was held by almost nothing.** Eighteen mutants in
  `techo.sps` survived, the worst a "memory is short" test that says yes to
  everything: a deadline during the throwaway hash would then forgive a try whose
  verify had run. Now `(techo wiring)` and its suite.
- **After `user password`, devices still sending the old password use up the
  email's tries.** The docs say so.
- Survivors in the route, the address key and the body's cap, each now with a test.

**Recorded, not fixed**

- A forgive that lands on a window cleared and opened again in the same millisecond
  takes one from the new window. A clear follows a real hash, about 50 ms, so the
  program cannot reach it.
- The `limiter full=1` line can come again after a try is counted on windows already
  there, though the table never had room.
- `program-app` given the wall clock survives: it behaves the same unless the clock
  jumps.
- The hasher's stop left out survives: the process is ending anyway.
- The kit's log left silent survives: the program's table of 10,000 is not filled by
  any test. The route's own test holds the line with a small table.
- The mutex on the account's cell cannot be shown to matter by a test.
- Nothing but a search holds that only the login route calls `login-read` and
  `login-write`.
- Invalid UTF-8 on standard input becomes U+FFFD, silently.
- Not run: a real short-memory server (`ulimit -v`), an IPv6 listener, a slow body
  near the deadline, the terminal path of the password prompt.
- An older integration test, "clause 11, -shm deleted", fails now and then under
  load. It is not this slice's.
