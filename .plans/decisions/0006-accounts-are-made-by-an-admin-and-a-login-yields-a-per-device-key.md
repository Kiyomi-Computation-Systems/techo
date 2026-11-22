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
