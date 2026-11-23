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

- A fresh clone needs `git submodule update --init`, on the host, before
  `make deps`. `AGENTS.md` already says so.
- Techo is circuit's proving ground: what Techo finds wanting in circuit becomes an
  issue there, and Techo's pin moves when it is fixed.
- chez-sodium and unique-id join as submodules when slices 3 and 4 need them.

## Amendment, 2026-11-22: a pin is written as a full commit SHA

Status: accepted as a correction (slice 1's adversarial review, reproduced)

- CI's checkout of a submodule is shallow and brings no tags, so a pin written as a tag
  does not resolve there. `SUBMODULE_PINS` names the tag's commit in full, with the tag
  in a comment beside it.
- A fresh clone needs `git submodule update --init`, without `--recursive`: nothing in
  Techo reads a submodule's own `vendor/`.
- `make check-pins` reads all three submodules' manifests. One with no `depends` form,
  only `depends/dev`, asks nothing of Techo's.

## Amendment, 2026-11-23: chez-http-server 0.12.0 comes from a submodule until the index has it

Status: accepted (owner, 2026-11-22: "we need to take the exception"). It follows
circuit's ADR-0012, item 7.

- **Why:** Techo's database work needs `await-outside`, which chez-http-server 0.12.0
  adds. The index's newest is 0.11.0, and chez-websocket 0.6.0 admits only 0.11.
- **The server is a fourth submodule,** `vendor/chez-http-server`, pinned at
  `bba2ba6` (v0.12.0). The library path takes the server's `src/` from it.
- **`Akku.manifest` and `Akku.lock` keep `chez-http-server ^0.11.0`,** as circuit's
  manifest does. That entry brings chez-libuv, chez-httparse, chez-uri and
  byte-machine at the versions 0.12.0's own lock names. The 0.11.0 tree is still
  fetched, and nothing reads it.
- **The manifest now names the server's four depends too,** since the server is a
  submodule and `make check-pins` reads every submodule's manifest. The lock holds the
  same ten projects as before, in another order.
- **Two checks hold it.** `make deps` fails unless the submodule's manifest says
  0.12.0. The stack suite fails unless `(http-server)` exports `await-outside` and
  `(circuit http-server)` hands on the same procedure.
- **circuit's pin moves to `442dd85`,** which re-exports `await-outside` and the
  config-error predicates. `techo.sps` no longer imports from the server.
- **What ends it:** the index having chez-http-server 0.12.0 and a chez-websocket whose
  range admits it. Then circuit's ranges move, Techo's pin and manifest follow, and the
  submodule, `SERVER_DIR` and `SERVER_VERSION` go, on one commit. Nothing turns CI red
  when that day comes: the ledger holds the reminder.
