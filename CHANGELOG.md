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
- `make machines` writes the migrate state machines' diagrams from their
  tables.
