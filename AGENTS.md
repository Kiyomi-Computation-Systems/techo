# AGENTS.md

## Project guidelines

### Architecture & portability

* Use the functional core / imperative shell pattern
* Follow the 12 Factor Apps philosophy
* Project is built for Chez Scheme but should be mostly portable to R6RS
* **DO NOT** setup macos CI runners: linux only!
* Exported functions should have a comment with a Typed Racket style type signature

### Dependencies

* testing: srfi-64
* circuit https://github.com/Kiyomi-Computation-Systems/circuit
* chez-sqlite3 https://github.com/Kiyomi-Computation-Systems/chez-sqlite3/
* threading https://github.com/Kiyomi-Computation-Systems/threading
* chez-curl https://github.com/Kiyomi-Computation-Systems/chez-curl
  (integration tests; later an object store)
* chez-sodium https://github.com/Kiyomi-Computation-Systems/chez-sodium
  (password hashing, random bytes, fast hashing)
* unique-id https://github.com/Kiyomi-Computation-Systems/unique-id (UUID v4
  and v7)
* Use Akku 1.2.0 where possible for managing dependencies (chez-srfi, threading)
* circuit, chez-sqlite3, chez-curl, chez-sodium and unique-id are not in Akku,
  but their dependencies are
* A new dependency needs a decision record

### Sibling projects

* The dependencies above are the owner's, each checked out beside this
  repository: `../circuit`, `../chez-http-server`, `../chez-sqlite3`,
  `../chez-curl`, `../chez-sodium`, `../unique-id`, `../threading`.
* Read a sibling's source, its `.plans/decisions/` and its traps there before
  relying on its behaviour or proposing a change to it.
* Never edit a sibling from here. A change to one is an issue on its
  repository, with a brief in `/.plans/briefs`.
* A brief is the snapshot handed over. Once the sibling has taken it up, the
  sibling's own `.plans/` is the truth.

### Layout, process & libraries

* Plans live in `/.plans`, decision records in `/.plans/decisions`
* `/.plans/outline.md` is the project's outline. A slice's plan is
  `/.plans/YYYY-MM-DD-slice-N-name.md`. Spikes and their reports live in
  `/.plans/research`.
* A decision record is `NNNN-what-was-decided.md`, with Date, Status, Plan,
  then Context, Decision and Consequences. A decision changes by a new or
  amended record.
* Traps this repo has hit live in `/.plans/traps.md`, each reproduced before
  it is recorded.
* The ledger is `/.plans/progress.md`: where the project stands, the next
  slice, and a close-out for each merged slice. `/.plans/global-constraints.md`
  holds the decision records' hard rules and binds every task brief. Read both
  before starting slice work.
* Add entries to `CHANGELOG.md` for each release
* `/docs` is for user facing documentation only.
* Documentation should be very concise, focused, to the point, ELI5 style.
* `Makefile` should have a `help` command which lists all of its commands
* Libraries are R6RS `.sls`; libraries and programs contain their own code —
  no shared include bodies. R6RS forbids assigning an exported variable —
  reach mutable state through procedures.
* Before a global replace, predict how many matches it should hit, and check
  the count afterwards: the sentence that defines a marker contains the
  marker.
* Model behaviour that has states as a transition table with a pure step
  function (ADR-0007).

### Guix development container

* **On a Guix host, run every build and test through `scripts/guix-env`**,
  e.g. `scripts/guix-env make test`. Batch commands with
  `scripts/guix-env sh -c 'make a && make b'`: each call takes a second or
  more to start.
* Edit, commit and push on the host. The container has no git identity,
  agents or tokens, and no network but loopback.
* Verify it with `make check-guix`, run on the host.
* Anything that needs the network or git runs on the host: fetches, pushes,
  downloads, `make check-pins`, `make site-deps`, and
  `git submodule update --init`,
  which a fresh clone needs once before `make deps`. The container has no git.

### Testing & mutation discipline

* Use TDD / test-driven development
* A test that passes whether the code is right or wrong is worse than no test.
* A test is not finished when it passes. It is finished when you have watched
  it fail.
* Prefer a check to a comment.
* `guard` returns the body's value when nothing raises, and `0` is truthy.
  Assert *what was raised* against an expected value, with a distinct sentinel
  for the no-raise case.
* SRFI-64 turns an exception in the *actual* expression into `#f`. Never
  expect `#f` from something that can raise.
* SRFI-64 does not catch an exception in the *expected* expression, nor in a
  suite's top-level definitions: the suite dies and no test is named. Compute
  anything that can raise under a `guard`.
* SRFI-64 keeps one result per runner. Never run a test inside another test's
  actual expression: the outer verdict is reported under the inner test's name.

## Closing ritual

We run this when we're done and ready to merge the PR.

**Important**: ALWAYS ask before running this.

1. Squash merge the PR.
2. Catch up local `main`.
3. Clean up branches. Delete the merged branch locally and on the remote.
4. Reflect.
