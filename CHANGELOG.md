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
