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
  `POST /v1/keys/{id}/revoke` and `/regenerate`. No account can be made yet, so
  on a real server they all answer 401 until login arrives. See `docs/api.md`.
- Every error is RFC 9457 problem details with a `code` member.
- A request log: one line a request on standard output.

### Changed

- The 404 for an unknown route was `{"error":"not_found"}`. It is now in the
  error format.
- Dependencies: chez-sodium and unique-id as git submodules. Techo now needs
  libsodium, 1.0.18 or later, on the machine.
- `make submodules` checks out each submodule at its pin, for a fresh clone.
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
