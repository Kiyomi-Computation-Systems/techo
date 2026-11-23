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

Status: proposed; awaits the owner. It came from the adversarial review of
chez-sodium's brief, passed on by that project's session.

**Context.** The decision says a key is stored as a hash and that every request checks
one. It does not say how.

**Proposed.**

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
