# Changelog

Each release's changes. Dates are UTC.

## Unreleased

### Added

- The build: a Makefile whose `make help` lists every target, a pinned Guix
  container reached through `scripts/guix-env`, and CI on Linux.
- Dependencies: threading and circuit's own from the Akku index, pinned by
  `Akku.lock`; circuit, chez-sqlite3 and chez-curl as git submodules under
  `vendor/`. chez-http-server 0.12.0 is a submodule too, until the index
  has it.
- `techo serve`, answering `GET /health`. A setting it refuses is named on
  standard error, with exit status 2.
- `techo version` and `techo help`.
- `techo migrate`: makes the database file, or brings it to this version's
  schema. It refuses a file from a newer Techo or from another program, and
  leaves it unchanged. The first migration only marks the file as Techo's.
- `techo serve` checks the database before it listens. It refuses, with exit
  status 1, a file that is missing, behind, newer, not Techo's, or not in WAL
  mode.
- `make machines` writes the state machines' diagrams from their tables.
- The second migration: the `accounts` and `api_keys` tables.
- The first API routes, under `/v1`, each needing an API key in
  `Authorization: Bearer`: `GET /v1/account`, `GET /v1/keys`, and
  `POST /v1/keys/{id}/revoke` and `/regenerate`. See `docs/api.md`.
- Every error is RFC 9457 problem details with a `code` member.
- A request log: one line a request on standard output.
- `techo user add --username NAME --email EMAIL` makes an account, and
  `techo user password --email EMAIL` sets a new password and revokes the
  account's keys. The password is read from standard input, never an option.
  Both work while the server runs.
- `POST /v1/login`: an email and a password make a new API key (201, shown once).
  A wrong email and a wrong password get the same answer. An account may hold 100
  active keys; the next login is a 409. New codes: `invalid_credentials`,
  `too_many_keys`, `rate_limited`.
- Login is rate limited: 5 tries for one email and 20 for one address in 15
  minutes, kept in memory, with `Retry-After`.
- `TECHO_BEHIND_PROXY`: how many proxies add to `X-Forwarded-For`, so the limit
  counts the client and not the proxy. Default `0`. `docs/running.md` explains
  how to count.
- Passwords are hashed with Argon2 (64 MiB, one at a time) on a thread of their
  own; a full queue answers 503.
- Notes. `PUT /v1/nodes/{id}` makes a node, with `If-None-Match: *`, or replaces
  its content, with `If-Match`. `GET /v1/nodes/{id}` reads one and `GET /v1/nodes`
  lists them. A node's id is a version 7 UUID the client makes.
- Every write is checked against the node's revision, which is its `ETag`: a
  stale write is a 412 and a write with no precondition a 428. New codes:
  `precondition_failed`, `precondition_required`, `kind_fixed`.
- Every write is kept, until the node is deleted. `GET /v1/nodes/{id}/revisions` lists a node's history,
  `.../revisions/{n}` reads one, and `POST .../revisions/{n}/restore` makes a new
  revision from an old one.
- A node's body may be 1 MiB, its title 1,000 characters, a request 2 MiB. A
  write's body is read only after its key has been checked.
- The third migration: the `nodes`, `revisions` and `changes` tables. Run
  `techo migrate` with the server stopped.
- A node can be put away: `POST /v1/nodes/{id}/archive`, `/unarchive`, `/trash`
  and `/untrash`, and `DELETE /v1/nodes/{id}`, which removes a trashed node and
  its history for good. All need `If-Match`. A wrong move is a `409`
  `wrong_state`.
- Every node shows its `state`. `GET /v1/nodes` lists active nodes, or another
  state with `?state=`.
- A trashed node cannot be written.
- The fourth migration: a node's `state`. Run `techo migrate` with the server
  stopped.
- The write-ahead log file shrinks back to 16 MiB after a large write. It can
  grow by the size of a deleted node's history meanwhile.
- A deleted node's text is overwritten with zeros in the database file.
- Folders: a Project holds any node and a Journal holds Notes. Give `parent`
  when making a node, or move it with `POST /v1/nodes/{id}/move`.
  `POST /v1/nodes/{id}/move-children` moves a folder's children to another,
  1,000 a call.
- Trashing or archiving a folder changes that node only, not what is in it.
- `GET /v1/nodes?parent=` lists a folder, or the top level with `null`. Every
  node shows its `parent`.
- A node that holds others cannot be deleted (`409` `has_children`).
- Three codes: `invalid_parent`, `would_loop` and `has_children`.
- The fifth migration: a node's `parent`. Run `techo migrate` with the server
  stopped.

### Changed

- The request log's `address` is the client's address behind proxies, when
  `TECHO_BEHIND_PROXY` finds one in `X-Forwarded-For`. It was always whoever
  connected.
- The request log's `account` now shows on a 500 or 504 when the key had been
  checked. A login's line shows it only when the password matched.
- The 404 for an unknown route was `{"error":"not_found"}`. It is now in the
  error format.
- Dependencies: chez-sodium and unique-id as git submodules. Techo now needs
  libsodium, 1.0.18 or later, on the machine.
- `make submodules` checks out each submodule at its pin, for a fresh clone.
- `make deps` stops when a submodule's files are not at its pin, as after a
  `git pull` that moved one, and says to run `make submodules`.
- `make check-makefile` holds the Makefile's own promises: `submodules`, the
  hint `deps` gives, the rename `deps` uses, and `clean`.
- The Makefile runs on macOS for development: `deps` no longer needs GNU's
  `mv -T` or `ln -sT`. Tested by hand there, not in CI. `make test` needs
  `timeout` or Homebrew's `gtimeout`, and chez-sodium needs
  `CHEZ_SODIUM_LIBRARY` set to libsodium's path.
- `make clean` removes a read-only directory under `build/`.
- The database doorway: one thread writes and `TECHO_DB_READERS` threads read
  (default 2), so a slow write will not hold up a read or `/health`. No
  route uses the database yet.
- `techo serve` refuses a database file it may not write, and exits 1 on a
  port in use (it was 255).
- `techo serve` closes the database when it stops, readers first.
- A server whose database was migrated under it answers 503 to database
  requests and says why once. `docs/running.md` has an "Upgrading" section.

### Changed

- circuit moves to b7e6f95, which adds its worker.
