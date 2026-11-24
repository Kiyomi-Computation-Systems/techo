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
