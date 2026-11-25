# 0006: An admin makes accounts, and a login yields a named, per-device API key

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §7

## Context

- One self-hosted instance, with few users.
- Email verification and password reset need outgoing mail, which v1 does not have.
- argon2id is slow on purpose, and the server is one thread (ADR-0008): each hash
  stalls every request. Login is the one endpoint open to strangers.

## Decision

1. **An account has a username, an email and a password.** An admin creates it with
   the CLI. There is no signup.
2. **Login is by email and password,** and returns an API key.
3. **A user has several keys:** one per device, each named, each revocable. A key can
   be regenerated.
4. **A key is shown once and stored as a hash.**
5. **Passwords are hashed with argon2id,** through chez-sodium.
6. **Keys are hashed with a fast hash,** BLAKE2b. A key is long and random, so nothing
   slower is needed, and every request checks one.
7. **Login is rate-limited** per email and per address, **before any hashing.**

## Consequences

- A lost password is an admin's job to reset.
- The rate limit's numbers are for slice 3.
- Hashing leaves the loop's thread once chez-http-server's `await-outside` is released
  (ADR-0008).

## Amendment, 2026-11-22: a key is checked by looking it up by its hash

Status: accepted (owner, 2026-11-23). It came from the adversarial review of
chez-sodium's brief, passed on by that project's session.

**Context.** The decision says a key is stored as a hash and that every request checks
one. It does not say how.

**Decided.**

1. A key is 32 random bytes from chez-sodium's `random-bytes`, shown to the user in one
   fixed encoding.
2. To check a request, hash the presented key with `blake2b` (32 bytes
   out, no key), over that same encoding, and find the row with `WHERE key_hash = ?` on
   a unique index.
3. No `id.secret` key format, and no separate compare step.

**Why it is safe.** An index lookup is not constant time. But its timing reveals only
bits of the hash of a long random key, and BLAKE2b's preimage resistance means those
bits do not help anyone find a key. This holds only while a key has at least 128 bits
of entropy.

**Consequences.**

- Techo's v1 has no use for chez-sodium's `constant-time-bytevector=?`. It stays in that
  library as a general verb.
- If Techo ever compares a raw secret or a MAC, such as a webhook signature or a signed
  cookie, it uses `constant-time-bytevector=?`, never `bytevector=?`.
- The encoding is slice 3's to fix, once, for creation and lookup alike.

## Amendment, 2026-11-24: what slice 3 decided

Status: accepted (owner, 2026-11-24, as slice 3's D1 to D6 and D9)
Plan: [slice 3](../2026-11-24-slice-3-accounts.md)

1. **An account's id and a key's id are UUIDs, version 7,** made by the server.
2. **A key is `techo_` and 64 lowercase hex digits,** sent as
   `Authorization: Bearer …`. Its stored hash is BLAKE2b, 32 bytes, of those 70
   characters. This is "the one fixed encoding" the first amendment left to slice 3.
3. **The key is hashed on the loop's thread. Only the hash enters a database job,** so
   the key can never be in a logged raise.
4. **The key is checked inside the request's own job** (ADR-0013). One job a request:
   a 503 is a "no" for the whole request, and a revoke cannot cross a write.
5. **A key's lifecycle is three states:** none, active, revoked. The table is in
   `(techo keys)`, and its diagram in `.plans/machines/key.md`.
   - A key may revoke any key of its account. That is how a lost device is shut out.
   - A key may regenerate only itself. So a stolen key cannot take over the others.
   - Another account's key looks like no key at all: a 404.
6. **No key makes a key.** A key comes only from a login. A key that could make keys
   would let a leaked one quietly make a second, which revoking the first would not
   remove.
7. **`last_used` is the last time a key *changed* something,** to the day. A request
   that only reads does not set it.
   - Why: a read job cannot write, and a second job after a read would hold a
     finished answer behind the writer.
   - The cost: a device that only reads looks unused.
8. **The slice is split at the password verbs.** 3a is everything that needs no
   password: the tables, the key check, the key routes. 3b waits on chez-sodium's M3:
   `user add`, login, the rate limit.

9. **A route reaches the database only through `db-read-as` and `db-write-as`,**
   which check the key first. Only `techo.sps` names the doorway's `db-read` and
   `db-write`, and a test holds that.
10. **A refusal leaves a job as one condition, `&refusal`,** holding an error code and
    the account's id. Nothing of the request rides on it.
11. **A handler performs the command the key table's step names.** It decides no
    answer by a test of its own.
12. **The table's own checks hold an account's shape:** a lowercase email, by ASCII's
    letters alone, whatever the SQLite build; a username of `[a-z0-9][a-z0-9_-]*`, at
    most 32 characters; a key's name of 1 to 64 characters.

**Consequences**

- After 3a a real server has no accounts, and every key route answers 401.
- `password-verify` answers false when memory is short, as for a wrong password.
  chez-sodium was asked whether it could tell them apart
  ([the brief](../briefs/chez-sodium-verify-out-of-memory.md)); its answer was "no
  for now". 3b plans on checking for itself.

## Amendment, 2026-11-25: what slice 3b decided

Status: accepted (owner, 2026-11-24: slice 3's D11 to D14, NFC, and the timed-out
request's account; "build it on chez-sodium's notice"). Items 6 to 12 are the plan's
own choices, made under that word.
Plan: [slice 3b](../2026-11-24-slice-3b-login.md)

1. **Passwords are hashed on a worker of their own:** one thread, a queue of 8. A
   full queue is a 503 with `Retry-After`. So one hash runs at a time: 64 MiB,
   whatever the load.
2. **Login is limited to 5 tries an email and 20 an address in 15 minutes,** counted
   in memory, refused before any reading or hashing. A good login clears its email's
   count.
   - The cost: anyone who knows an email can stop new logins for it for 15 minutes.
     Keys already given keep working.
   - The cost: someone with many addresses can fill the table of 10,000 and stop
     every login for a while.
3. **A password is normalised to NFC** before it is hashed or verified.
4. **An unknown email is hashed against too,** a stand-in made when the server
   starts, so the time taken does not say which emails have accounts. A wrong email
   and a wrong password get one answer.
5. **After a false verify, a throwaway hash tells short memory from a wrong
   password:** chez-sodium answers false for both. Its own failure raised from the
   throwaway is a 503, and the try is not counted. Any other raise there, a deadline
   among them, stays counted.
6. **Login is a table** in `(techo login)`, its diagram in
   `.plans/machines/login.md`. The table names each ending's answer and what it does
   to the try's count, so the handler decides neither.
7. **A try is forgiven only where nothing was checked:** the queue was full before
   the verify, or memory was short. A full queue after the verify stays counted, or
   filling the queue would buy guesses.
8. **Login's write goes ahead only if the account's hash is still the one it
   verified.** So a login that began before `techo user password` cannot make a key
   after it.
9. **An account has at most 100 active keys.** The 101st login is a 409
   `too_many_keys`.
10. **Item 9 of the amendment above gains two procedures:** `login-read` and
    `login-write` in `(techo auth)`. They are the only way to the database without a
    key, and the login route is their only caller.
11. **`techo user add` and `techo user password` read the password from standard
    input,** never the command line. Each is one write transaction and works beside
    a running server. `user password` revokes every key of the account in the same
    transaction.
12. **A password is 8 characters or more to set, and 1,024 bytes or fewer.** A login
    does not check the lower bound: a short password is simply wrong.

**Consequences**

- The limit's counts die with the process. Two servers on one file each keep their
  own, so the docs say run one (ADR-0009, amended).
- Under a container's memory limit the kernel kills the process rather than failing
  one hash, so item 5 helps only where memory is limited another way.
- A stored hash that is unreadable, or made at other limits, answers in a different
  time than a good one. Only a hand-edited row or a later change of limits makes one.
