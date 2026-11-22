# 0011: The owner's libraries outside the Akku index are git submodules, pinned at a commit

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, answering the slice 1 plan's first question)
Plan: [the slice 1 plan](../2026-11-22-slice-1-skeleton.md) §3.2

## Context

- circuit, chez-sqlite3, chez-curl, chez-sodium and unique-id are not in the Akku
  index (checked on 2026-11-22). Their own dependencies are.
- The owner: Akku's publishing pipeline is slow, and circuit will not be released
  until Techo has proved it out.
- circuit takes chez-http-server, chez-websocket, hashing and jsonparse from the
  index. Akku resolves a package's dependencies only for packages it knows.

## Decision

1. **Each of the five is a git submodule under `vendor/`,** pinned at a commit. A
   release tag is used where the library has one that Techo can build on. circuit may
   be pinned at an unreleased commit.
2. **Techo's `Akku.manifest` names the index dependencies those libraries need,**
   since Akku cannot read them from a submodule.
3. **`make check-pins` holds the two together.** It fails unless Techo's manifest
   admits everything each submodule's own manifest, at its pinned commit, names.
4. **Moving a pin is its own commit,** with the reason, and a line in `CHANGELOG.md`
   if behaviour changes.
5. **This is for now.** When a library is published to the index, it moves to
   `Akku.manifest` and its submodule goes, by an amendment here.

## Consequences

- A fresh clone needs `git submodule update --init --recursive`, on the host, before
  `make deps`. `AGENTS.md` already says so.
- Techo is circuit's proving ground: what Techo finds wanting in circuit becomes an
  issue there, and Techo's pin moves when it is fixed.
- chez-sodium and unique-id join as submodules when slices 3 and 4 need them.
