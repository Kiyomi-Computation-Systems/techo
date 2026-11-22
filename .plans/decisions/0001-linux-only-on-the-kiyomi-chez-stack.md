# 0001: Techo runs on Linux, on the Kiyomi Chez stack

Date: 2026-11-22
Status: accepted (owner: `AGENTS.md`, and the planning discussion of 2026-11-22)
Plan: [the outline](../outline.md) §11

## Context

- Techo is deployed as a Docker container on the owner's Linux server.
- The owner's libraries cover HTTP, SQLite, an HTTP client and threading macros, and
  each already pins its toolchain in a Guix container.
- circuit sets the floor: Chez Scheme 10.4.1, threaded, and libuv 1.48.

## Decision

1. **Linux only.** CI runs on Linux. No macOS runner is ever set up.
2. **Chez Scheme 10.4.1 or later, threaded.** The code stays close to R6RS where that
   is free.
3. **The stack:**
   - circuit, on chez-http-server, for HTTP;
   - chez-sqlite3 for the database;
   - chez-curl for the integration tests, and later for an object store;
   - threading for its macros;
   - SRFI-64, from chez-srfi, for the suites;
   - chez-sodium for hashing and random bytes;
   - unique-id for ids.
4. **Akku 1.2.0 manages what the Akku index holds.** On 2026-11-22 it holds threading,
   chez-srfi, chez-http-server and what that brings, and jsonparse. It does not hold
   circuit, chez-sqlite3, chez-curl, chez-sodium or unique-id.
5. **Builds and tests run in a pinned Guix container with no network**, through
   `scripts/guix-env`, as the siblings' do.

## Consequences

- How the five libraries outside the index are fetched and pinned is ADR-0011.
- chez-sodium and unique-id are new. Techo's auth slice waits on the first, its node
  slice on the second.
