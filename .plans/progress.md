# Progress ledger

Where Techo stands. Read it with [global-constraints.md](global-constraints.md) before
starting slice work. When a slice merges, update **Now** and **Next**, and add a
close-out under **Close-outs**, newest first.

## Now

- **The outline is merged**, squashed from
  [PR #1](https://github.com/Kiyomi-Computation-Systems/techo/pull/1) on 2026-11-22
  (4b06708). It is [outline.md](outline.md).
- **Thirteen decisions are recorded**, ADR-0001 to ADR-0013, in [decisions/](decisions/),
  with the rules they make in [global-constraints.md](global-constraints.md).
- **Slice 1 is merged**, squashed from
  [PR #2](https://github.com/Kiyomi-Computation-Systems/techo/pull/2) on 2026-11-22
  (980b424): the build, the pins, `techo serve` with `/health`, five suites, CI and
  [the loop-stall report](research/2026-11-22-loop-stall.md).
- **`await-outside` is on the path** (2026-11-23): circuit is pinned at 442dd85, and
  chez-http-server 0.12.0 comes from a submodule until the index has it (ADR-0011,
  amended 2026-11-23).
- **Slice 2 is merged**, squashed from
  [PR #6](https://github.com/Kiyomi-Computation-Systems/techo/pull/6) on 2026-11-23:
  `techo migrate`, `serve`'s database check, and the migrate state machine verified in six layers
  ([the plan](2026-11-23-slice-2-migrations.md), ADR-0012). No table yet:
  [schema.md](schema.md) sketches them.
- **Slice 2b, the doorway, is merged**, squashed from
  [PR #7](https://github.com/Kiyomi-Computation-Systems/techo/pull/7) on 2026-11-24:
  one write thread and `TECHO_DB_READERS` read threads on circuit's worker, each job
  one transaction run by a table, through a handle
  ([the plan](2026-11-23-slice-2b-doorway.md), ADR-0013). No route uses it yet.
- **The pins moved** in
  [PR #8](https://github.com/Kiyomi-Computation-Systems/techo/pull/8) on 2026-11-24,
  rebased so each is its own commit: circuit to a39346c, its worker's docs; and
  chez-sodium (3a14085) and unique-id (e0ed128) joined, with libsodium.
- **Slice 3a is merged**, squashed from
  [PR #9](https://github.com/Kiyomi-Computation-Systems/techo/pull/9) on 2026-11-24: the `accounts`
  and `api_keys` tables, the key check, four routes under `/v1`, RFC 9457 errors and
  the request log ([the plan](2026-11-24-slice-3-accounts.md); ADR-0002 and ADR-0006,
  amended). No account can be made until 3b, so a real server answers 401.
- **chez-sodium (v0.1.0, 981ba2e, since 2026-11-25) and unique-id (v0.1.0) are pinned submodules,** and
  circuit's pin is at a39346c (ADR-0011, amended 2026-11-24). The move to M3 was
  [PR #11](https://github.com/Kiyomi-Computation-Systems/techo/pull/11), rebased on
  2026-11-25.
- **Slice 3b is merged**, squashed from
  [PR #12](https://github.com/Kiyomi-Computation-Systems/techo/pull/12) on 2026-11-25:
  `techo user add`, `techo user password`, `POST /v1/login`, the login limit,
  `TECHO_BEHIND_PROXY` and the hashing worker
  ([the plan](2026-11-24-slice-3b-login.md); ADR-0006, ADR-0009 and ADR-0013,
  amended 2026-11-25). A real server can now be used: make an account, log in, use
  the key.
- **Slice 4 is merged** (#15, `f195ea2`): migration 3, seven routes
  under `/v1/nodes`, the versioned write as a table, and the key checked before a
  write's body is read ([the plan](2026-11-25-slice-4-nodes.md); ADR-0002,
  ADR-0003, ADR-0004 and ADR-0006, amended 2026-11-25). A person can now store
  notes and read their history.
- **Slice 4b is merged** (#18, `77398a8`): migration 4, the
  lifecycle as a table, five routes to archive, trash and purge a node
  ([the plan](2026-11-25-slice-4b-node-lifecycle.md); ADR-0002, ADR-0004,
  ADR-0007 and ADR-0008, amended 2026-11-25 and 26). A person can now put a note
  away, and delete it for good.
- **Slice 5a is merged** (#19, `93bb42a`): migration 5, folders,
  a move and a bulk move of children, the list by parent
  ([the plan](2026-11-26-slice-5a-tree.md); ADR-0002, ADR-0003, ADR-0004 and
  ADR-0007, amended 2026-11-26). A person can now keep notes in Projects and
  Journals.
- **ADR-0006's amendment is accepted** (owner, 2026-11-23): a key is looked up by its
  BLAKE2b hash.
- **T5 is restated** (owner, 2026-11-23; ADR-0008's second amendment), since circuit's
  worker refuses queued jobs at a stop.

## Next

**Slice 6: kinds and props; task transitions.**
[Planned](2026-11-27-slice-6-kinds-and-props.md), built and reviewed on
`slice-6-kinds-and-props`: the owner decided P1 to P14 on 2026-11-27, and
three tightenings after the build's review. Not merged.

**Slice 5b is merged** (#20, `25ad3b2`): migration 6, three
link routes ([the plan](2026-11-26-slice-5b-links.md); ADR-0002, ADR-0003,
ADR-0004 and ADR-0007, amended 2026-11-26). A person can now link one note to
another and read a note's backlinks.

**For slice 8, the change feed:** read
[issue #21](https://github.com/Kiyomi-Computation-Systems/techo/issues/21)
before planning it. The Emacs client asks for a cursor contract: read the
latest cursor (an empty account too), paged replay after a saved cursor, a
feed row for every kind of change with purges and links, and a distinct
error for an expired cursor. Its acceptance cases are in the issue.

**Kept ready, from slice 5b (2026-11-27):**

- **A cap on a node's links,** or a purge in steps. Nothing caps them (K7): a
  purge of 3 million holds every account's writes 6 s, and past 10 s answers
  504 though it lands.

**Kept ready, from slice 5a (owner, 2026-11-26):**

- **"Inherit on read":** a node counts as trashed when any folder above it is.
  Today trash touches one node (T6), and a client hides what is inside a
  trashed folder itself. If clients struggle, this is the way out: no
  migration, under 1 ms a page at depth 5. It needs its own cap on the walk,
  and past that cap it would be wrong, since a tree's depth has no bound.
- **A bulk purge of a folder and what is in it** (T7): its own slice, with
  measured limits, if emptying a folder by hand hurts.

**chez-sodium is pinned at its v0.1.0** (981ba2e, moved 2026-11-25): no export
changed since d53e83c. Its docs say to bound a password before verify: Techo's
bound, 1024 bytes, is under its 64 KiB cap, so nothing changes.

**Watch for:** the Akku index gaining chez-http-server 0.12.0 and a chez-websocket
that admits it. That ends the server's submodule (ADR-0011, amended 2026-11-23).
Nothing fails when it happens.

**Run on the owner's Mac, by hand, 2026-11-27, before slice 5b's merge:**
`make test` passed 36 of 36 suites, and twenty steps by hand against the
server matched: a link made (201) and made again (200, the first time kept);
a node's links and its backlinks, one a page with `next`; no revision changed
by a link; a self link and an `If-Match` refused (400); no new link to a
trashed node (409) while the old one is kept (200) and listed as trashed; a
link removed (204, then 404); and a purge taking the node's links with it.

**Still GNU-only, found by the macOS audit and left:** `make test` needs `timeout` or
`gtimeout`; `make help`'s awk pattern `.*?` is untested on BSD awk; `check-pins` and
`fetch` use `diff --no-dereference`. On macOS chez-sodium needs
`CHEZ_SODIUM_LIBRARY`, and chez-sqlite3 needs `CHEZ_SQLITE3_LIBRARY` set to
Homebrew's SQLite: Apple's own fails six suites.

**Run on the owner's Mac, by hand, 2026-11-25, at slice 3b's merge:** `make test`
passed 31 of 31 suites (two `/proc` tests skipped), and `techo user add` at a real
terminal hid the password, refused a short one, and made the account. The `mv -h`
branch of `scripts/mv-no-follow-flag` ran there on 2026-11-24. The same day's run
met a submodule left behind by a pull, which is why `make deps` now checks each
pin.

**And at slice 4's merge, 2026-11-25:** `make test` passed 35 of 35 suites. Against
a real server: a login, then a node made (201, `ETag: "1"`), replaced (200,
`"2"`), a stale replace refused (412), revision 1 restored (200, `"3"`), and the
node, the list and the revisions read back as the docs say.

**And for slice 4b, 2026-11-26, on its branch before the merge:** `make test`
passed 35 of 35 suites. Against a real server: a node archived (200, `"2"`, no
body), absent from the default list and present under `?state=archived`,
trashed, refused a replace (409 `wrong_state`) and a stale untrash (412),
untrashed, refused a `DELETE` while active (409), trashed again, purged (204, no
body, no `ETag`), and then a 404.

**And for slice 5a, 2026-11-26, on its branch before the merge:** `make test`
passed 35 of 35 suites. Against a real server: a Note made inside a Project,
the top level and the folder listed, a Task moved in (200, revision 2), refused
by a Journal (409 `invalid_parent`), a Project refused under its own child (409
`would_loop`), the Project trashed with the Task inside still active, its
`DELETE` refused (409 `has_children`), its children moved out in one call
(`{"moved":2,"left":0}`), and then deleted (204).

**And for slice 6, 2026-11-27, on its branch before the merge:** `make test`
passed 40 of 40 suites. Against a real server, twenty steps matched: a Note
with `at`, a Task with a deadline (read as `TODO`), a Contact stored in
Techo's own order; a false date, an unknown member, an email past ASCII and a
blank label each refused (400); a Task marked done, refused a second `done`
(409 `wrong_status`), moved to `WONTDO` with `closed` kept, refused a replace
that changed its status (409 `status_fixed`), kept its props through a replace
with none, reopened with `closed` gone; `done` refused on a Note (409
`not_a_task`); and a restore that brought back the old deadline and left the
Task `DONE`.

## Slices

| # | Slice | State | Waits on |
|---|---|---|---|
| 1 | Skeleton, health endpoint, loop-stall spike | merged (PR #2) | |
| 2 | Migrations, the CLI's `migrate`, `serve`'s check | merged (PR #6) | |
| 2b | The database doorway: write and read workers | merged (PR #7) | |
| 3a | The tables, the key check, the key routes, the error format, the request log | merged (PR #9) | |
| 3b | `techo user add`, login, the rate limit, the hashing worker | merged (PR #12) | |
| 4 | Node create, read, update; revisions; `If-Match` | merged, #15 | |
| 4b | The node lifecycle: archive, trash, purge | merged, #18 | |
| 5a | The tree and move | merged, #19 | |
| 5b | Links | merged, #20 | |
| 6 | Kinds and props; task transitions | built, on `slice-6-kinds-and-props` | |
| 7 | Tags and search | not planned | |
| 8 | The change feed | not planned | |
| 9 | Docker image and backup | not planned | |

## Sibling projects

Each has its own repository, beside this one on the owner's machine, and its own
ledger. The briefs in [briefs/](briefs/) are the snapshots handed over; **the sibling's
own `.plans/` is the truth from then on.**

| Project | Where | State on 2026-11-22 |
|---|---|---|
| chez-sodium | `../chez-sodium` | v0.1.0 (981ba2e, pinned here). Asked on 2026-11-24 whether `password-verify` can tell "could not check" from "wrong" ([brief](briefs/chez-sodium-verify-out-of-memory.md)): no, settled in its M3 plan |
| unique-id | `../unique-id` | v0.1.0 released (2026-11-23, e0ed128), pinned here since slice 3a |
| chez-http-server: `await-outside` | `../chez-http-server` | Released in v0.12.0 (bba2ba6); not on the Akku index yet |
| circuit: the worker | `../circuit` | Issue 53 done: W2, the shell (b7e6f95, pinned here); W3, the docs (a39346c, 2026-11-24) |

## Open questions

From [outline.md](outline.md) §14, each for the slice named:

| Question | Slice |
|---|---|
| What the feed says of a link: a `link` row names no target, two rows of a node can carry one revision, and a purge's row means every link of the node is gone | 8 |
| Whether a move into a Journal checks a Note's timestamp, and what of Notes moved in before | 6 |
| A kind that holds some kinds but not all, in the bulk move's filter | 6 |
| Whether a search shows what is inside a trashed folder | 7 |
| Whether the feed gives a moved node's parent: a `move` row names none | 8 |
| Whether `state` behind a large `props` costs the list and the write's check | 6 |
| How the search index forgets a purged node's words | 7 |
| What the feed says of a revision that has no snapshot, or whose node is purged | 8 |
| Search over a join of each node and its newest snapshot, measured at size | 7 |
| Whether `VACUUM INTO` keeps a search index true (it did in a small probe) | 9 |
| A Contact's first fields, exactly | 6 |
| The container's stop grace (30 s) and a check that asks more than `/health` | 9 |

## Close-outs

### Slice 6: kinds and props; task transitions (PR #22, 2026-11-27)

- **Built:** four pure libraries, `(techo when)`, `(techo contact)`,
  `(techo tasks)` and `(techo props)`; `props-of` in the store; three routes,
  `done`, `wontdo`, `reopen`; four codes. No migration. Four new suites: 40.
  The model sends props from a corpus of 115 and runs about 37,000 requests
  in 38 s.
- **Answered:** fixed members per kind, add-only for good; a 4 KiB cap; a
  When in three forms that the server never compares; a Task's status moved
  only by a command, each a revision; a Contact as a strict subset of
  JSContact; old Tasks read as `TODO` (P1 to P14).
- **Moved on:** nothing. Kept ready: a rebuild of `nodes` with props last, if
  the cap is ever raised past about 8 KiB (a page of 51 costs 6.7 ms at 4 KiB
  and grows in line with it).
- **What the reviews caught that the builders could not:**
  - the plan's: props were judged inside the job, on the writer; "the store
    needs nothing new" was false; a transition through `node-command` would
    have raised; the canonical form was not pinned; `wrong_status` meant two
    things;
  - the build's: no bug, in 270 raced pairs and 121 mutants. Three rules too
    loose, which P3 would have frozen: any character past ASCII in an email
    address, U+2028 and U+2029 in every string, and a string of only spaces.
    All three tightened on the owner's word. Ten false or thin sentences in
    the guide.
- **Run on the owner's Mac, by hand, before the merge:** see "Run on the owner's
  Mac" above.
- **Learned:** with an add-only rule, the review that matters most is of what
  is accepted, not of what is refused. A loose rule cannot be fixed later.

### Slice 5b: links (merged 2026-11-27, #20)

- **Built:** migration 6 (`links`, `links_target`); a new pure `(techo links)`
  with `link-command`; two events more in the lifecycle's table; nine
  statements and four procedures in the store, and the purge's two deletes;
  three routes. One new suite: 36. The model runs about 34,800 requests in
  33 s (it was 24,400 in 22 s).
- **Answered:** three fixed types; directed, one per source, type and target;
  no bump, no `If-Match`, a change row on the source; no new link at a trashed
  end, a kept one still 200; a purge takes the node's links and is not blocked
  by them (K1 to K8).
- **Moved on:** what the feed says of a link, to slice 8. A cap on a node's
  links, kept ready.
- **What the reviews caught that the builders could not:**
  - the plan's: my store split was an import cycle; a change row with no bump
    broke seven of the model's laws; `INSERT OR IGNORE` read a null as "already
    there"; a typed page with the cursor's row value left its index (39 ms a
    page); the two events would have made `node-command` raise; a page figure
    of mine was of 6 rows, not 51;
  - the build's: no bug, in 100 rounds of races and 42 mutants. Two test gaps
    (a 204's headers, the time read once), three false or thin sentences in
    the guide, and K7's price at size: seconds for every account, and a 504
    that lands.
- **CI's first run failed one test:** a plan line that reads differently in
  CI's SQLite 3.45.1 than in the container's 3.53.1. The test now drops the
  one word that differs.
- **Run on the owner's Mac, by hand, before the merge:** see "Run on the owner's
  Mac" above.

### Slice 5a: the tree and move (merged 2026-11-26, #19)

- **Built:** migration 5 (`nodes.parent`, `nodes_parent`); `may-hold?`,
  `parent-verdict` and two more events in `(techo nodes)`; `ancestors`,
  `children-heads`, `move-node!`; two routes, `move` and `move-children`; the
  list's `?parent=`; three codes. No new suite: 35, with the pure suite at
  4,383 tests, the route suite at about 570, and the model at about 24,400
  requests a run in 22 s.
- **Answered:** only a Project or a Journal has children; a parent is set at
  the make or by a move; a move writes no snapshot; a loop is refused and a
  parent may have 63 ancestors; trash touches one node; a purge waits for the
  node to be empty; a bulk move, and no bulk purge yet (T1 to T10).
- **Moved on:** links, to 5b.
- **What the reviews caught that the builders could not:**
  - the plan's: the walk up was fast in my probe by luck, and 375 ms written
    the plain way; a bulk move could answer "moved 0" with movable children
    left; it had no place in the tables; migration 5 broke four test files no
    task owned; the model's laws were false for a bulk move;
  - the build's: the bulk move's rule was said twice with nothing holding the
    copies equal; the guide's folder section was wrong in six places. No bug,
    and none of its 29 mutants survived.
- **Two holes in the decisions, documented and left:** a folder inside a
  trashed one still takes new nodes; a tree's depth has no bound, and a folder
  64 levels down holds nothing.
- **What I got wrong:** the walk's probe; "the depth cap bounds it" of inherit
  on read; a brief that said every 400 logs no account.
- **The agents:** the plan's review (Opus, 285k tokens, 19 min); task 1, the
  store (Sonnet, 163k, 30 min); 2, the pure rules (Opus, 245k, 16 min); 3, the
  routes (Opus, 355k, 43 min); 4a, the model (Opus, 534k, 71 min); 4b,
  integration (Sonnet, 148k, 55 min); the build's review (Opus, 299k, 24 min);
  its fixes (Sonnet, 104k, 10 min).
- **Run on the owner's Mac, by hand, before the merge:** see "Run on the owner's
  Mac" above.

### Slice 4b: the node lifecycle (merged 2026-11-26, #18)

- **Built:** migration 4 (`nodes.state`); the lifecycle's table and
  `node-command` in `(techo nodes)`; `set-node-state!` and `purge-node!`; five
  routes; `wrong_state`; `journal_size_limit` and `secure_delete` set by
  `open-techo-db`. No new suite: 35, with the route suite at 378 tests and the
  model at about 16,400 requests a run.
- **Answered:** the states are active, archived and trashed; archive and trash
  can be undone and a purge cannot; a state change bumps the revision and writes
  no snapshot, so a node's body is its newest snapshot's; a purge empties the
  row and keeps it, so the id is never used again (L1 to L11).
- **Moved on:** children of a trashed node, to slice 5.
- **What the reviews caught that the builders could not:**
  - the plan's: my purge figure came from `:memory:` (1 ms; the file's is 390 ms
    and a 211 MB `-wal`); the records forbade the slice until amended; no
    interface gave a state change its 404 or 412; `node-head` would have found a
    purged row; three of slice 4's invariants were false under L4;
  - the build's: nothing set `secure_delete`, on which "gone for good" rested;
    the docs still said every write is kept. No bug, and none of its 30 mutants
    survived.
- **What I got wrong:** the `:memory:` measurement, the second of its kind after
  slice 4's body cap. It is a trap now.
- **Changed from slice 4:** the model no longer asks `(techo nodes)` what to
  expect. It states the rules itself.
- **Left as they are:** a purge past the deadline answers 504 and finishes;
  purged text can stay in the `-wal` until the next write; a list of a rare
  state reads the account's rows.
- **The agents:** the plan's review (Opus, 249k tokens, 16 min); task 1, the
  store (Sonnet, 151k, 11 min); 2, the table (Opus, 192k, 14 min); 3, the routes
  (Opus, 278k, 31 min); 4a, the model (Opus, 349k, 48 min); 4b, integration
  (Sonnet, 99k, 23 min); the build's review (Opus, 324k, 43 min).
- **Run on the owner's Mac, by hand, before the merge:** see "Run on the owner's
  Mac" above.

### Slice 4: nodes, revisions and `If-Match` (merged 2026-11-25, #15)

- **Built:** `(techo nodes)`, `(techo node-store)`, `(techo node-routes)`,
  `(techo requests)`; `db-write-with-body-as` in `(techo auth)`; migration 3;
  seven routes; the write machine; four new suites, 35 in all, one a model test of
  300 random sequences by two accounts.
- **Answered:** an id must be version 7; a node is made by `PUT` with
  `If-None-Match: *`; the ETag is the revision; a body is kept once, in its
  snapshot; a node has an integer key beside its id; the key is checked before a
  body is read (D1 to D12).
- **Moved on:** the lifecycle, to 4b.
- **What the reviews caught that the builders could not:**
  - the plan's: a column behind a large body costs a walk of its pages; login's
    member check, copied, would have held the loop a minute a request;
  - the build's: my figure for the loop's cost was 13 times too low, because I
    measured a request shaped like a note and not a hostile one; a list that read
    every body passed every test, since no answer showed it.
- **What to keep:**
  - Measure a cost with the worst input, not the usual one, before putting it to
    the owner.
  - A probe that stores 0 hides what a real value costs.
  - What an answer cannot show needs a check on the statement itself.
  - A brief that says "at least one row" or "101 is a 400" from memory is wrong
    as often as right: three builders corrected mine against the records.
- **Agents:** the plan's review (Opus, 289k tokens, 20 min); tasks 1 (Sonnet,
  121k, 13 min), 2 (Opus, 238k, 26 min), 3 (Opus, 286k, 30 min), 4 (Sonnet, 92k,
  12 min), 5a (Opus, 330k, 34 min), 5b (Sonnet, 130k, 19 min); the build's review
  (Opus, 362k, 28 min); task 9, its fixes (Opus, 262k, 31 min); task 10, the key
  before the body (Opus, 360k, 43 min).
- **Run on the owner's Mac, by hand, after the merge:** see "Run on the owner's
  Mac" above.

### The clause 11 flake (2026-11-25)

- **What it was:** three integration tests failed once in a while, and once in CI.
  The helper that writes rows until it is killed opened its report with
  `(file-options no-fail append)`, which empties the file at every open. A kill
  between the open and the write left no number.
- **The fix:** `no-truncate`. A new test holds that the report has a line for every
  batch, and failed every time before the fix.
- **How it was found:** the integration suite now prints what a failing test
  expected and saw, and six copies pinned to two cores showed it.
- **What to keep:** a flake was recorded twice as "not this slice's" and left. It
  then failed a CI run. A flake gets its own task when it is first seen.

### Slice 3b: users and login (merged 2026-11-25, PR #12)

- **Built:** `(techo login)`, `(techo limiter)`, `(techo address)`,
  `(techo passwords)`, `(techo hasher)`, `(techo users)`, `(techo wiring)`;
  `POST /v1/login`; `techo user add` and `techo user password`;
  `TECHO_BEHIND_PROXY`; machine 3 with the hasher; eight new suites, 31 in all, one a
  model test of 300 random sequences. No migration.
- **Answered:** hashing has its own worker; the limit's numbers; the proxy setting is
  a count; one `serve` a file; NFC; what a timed-out request logs (ADR-0006,
  ADR-0009, ADR-0013, amended).
- **Two reviews.** The plan's found the 100-key cap missing and login's body errors
  wrong. The build's found no hole, and that the program's wiring was still untested.
- **What went well:** the owner said "go on its notice", and the notice carried the
  verbs' behaviour; probes checked it and corrected one claim; each hand-back met
  mutants of the parent's own (about thirty); the model test caught every one of its
  24 mutants.
- **What did not:**
  - **the wiring gap came back.** 3a's close-out named it, and 3b's plan still left
    `techo.sps` to the parent with no test. Eighteen mutants survived there. A
    slice's plan must give the program's own wiring a task and a suite;
  - one full run on the pin's branch failed and its output was not kept;
  - a probe's line numbers were wrong throughout, though its facts held;
  - two builders were briefed to plant mutants in `src/` while sharing the checkout.
    They were told in time to use a copy. Nothing went wrong.
- **Recorded, not fixed:** see the plan's closing review.
- **Answered after the build** (owner, 2026-11-25): the request log's `address` is
  the client's behind proxies, by the same count as the login limit.

### Slice 3a: keys (merged 2026-11-24, PR #9)

- **Built:** migration 2; `(techo errors)`, `(techo keys)`, `(techo accounts)`,
  `(techo store)`, `(techo auth)`, `(techo routes)`, `(techo log)`; `GET /v1/account`,
  `GET /v1/keys`, and revoke and regenerate; `docs/api.md`; eight new suites, 23 in
  all. With it, the carry-overs: `make submodules`, the Makefile on macOS, `make
  clean` on a read-only directory, `make check-makefile`.
- **Answered:** an id is a UUID; a request is one job, so a 503 is a "no" for all of
  it; the error format, paging and times (ADR-0002, amended).
- **Three reviews, two of the plan and one of the build.** Each found what the last
  could not: the key table could not pass its own library's checks; a 409 that could
  never be reached; and, in the build, that nothing tested the program's random bytes.
- **What went well:** probes first; mutants planted on every hand-back (about twenty,
  and five more by the closing review); the reviewer shipping migration 2 in a
  scratch copy to find the suites it would break before any builder met them.
- **What did not:**
  - an agent's test of `make clean` deleted the real `build/` under two running
    probes (`traps.md`: a variable does nothing to a path the recipe spells out);
  - two builders wrote code before its tests (the store, and the integration tests
    of behaviour already built), and showed teeth by mutants afterwards;
  - the plan's checks never reached `techo.sps`'s own wiring, so three program-level
    mutants survived until the closing review.
- **Recorded, not fixed:** see the plan's third review. The fixture's migrations now
  follow the shipped list, and the replay is pinned to the first migration, so the
  next shipped migration should break neither.

### Slice 2b: the doorway (PR #7, 2026-11-24)

- **Built:** `(techo transaction)`, `(techo doorway)` and `(techo serve)`;
  `TECHO_DB_READERS`; `serve` opening and stopping the workers by a table; six new
  suites, fifteen in all; ADR-0013; the "Upgrading" section of `docs/running.md`.
- **Decided on the way:** D1 to D11 of the plan, all as recommended. A job gets a
  handle, never the connection. Every job checks the file's version first. A
  connection is never reopened. The writer's tear-down only closes.
- **Verified:** every `make` check on the final tree. Nine model configurations, up
  to 325,355 worlds each, with T1, T2, T4 to T6 and T8 to T10 holding. 921 traces and
  17,876 steps replayed on real SQLite, 94% of them real. Real threads and a real
  server: 1,000 writes each read back, a read during a held write, a full queue,
  `SIGTERM` idle and mid-write, `kill -9` mid-write, a `migrate` beside the server.
- **Not verified:** CI, until the pull request runs it. A signal in the 70 ms
  between the workers opening and the server listening. Nine table rows on real
  SQLite: they are reached only by injection, since SQLite cannot be made to fail a
  plain `BEGIN`, a version read, a `ROLLBACK` or a close. That SQLite is busy nowhere
  but at `BEGIN IMMEDIATE`.
- **Left for later:**
  - What the third review recorded and did not fix (the plan's last section).
  - Two places where the model is wrong off the real tables' paths, pinned as
    expected failures in the replay suite. The model is the one to change.
  - Keeping `migrate` out by a lock, and exiting on "moved" (ADR-0013).
  - A count of unfinished statements from chez-sqlite3, as a second guard.
  - Slice 2's "nothing stops `migrate` beside a running server" is now detected, not
    prevented.
- **Found on the way** (each in [traps.md](traps.md)):
  - A statement a job leaves open outlives its transaction.
  - SQLite can end a transaction and raise in the same call.
  - A `PRAGMA` run inside a transaction can outlive it, and `EXPLAIN` does not stop
    one.
  - A read-only connection that closes last leaves the `-wal`.
  - `exit` does not wait for threads.
  - Lines written from two threads run together.
- **What each review caught:** the first, that a dropped statement survives the
  rollback, which made the handle. The second, that the handle's check missed a call
  that raises after SQLite ended the transaction. The third, `EXPLAIN PRAGMA`, and a
  write thread on a file it may not write. Each was in a part the review before it
  had caused to be written.

### Slice 2: migrations (PR #6, 2026-11-23)

- **Merged:** `techo migrate`; `serve`'s database check; `(techo machine)`,
  `(techo migrations)` and `(techo db)`; the explorer and the file's model; ten suites;
  `make machines`; ADR-0012 and [schema.md](schema.md).
- **Decided on the way:** the doorway is slice 2b; tables arrive with their slices; ids
  are blobs; migrations are Scheme data, forward only; the version is `user_version`;
  a file that will be refused is opened only read-only; a hot rollback journal is
  named, not recovered.
- **Verified:** every `make` check on the final tree, and CI green on its first run.
  2.96 million model worlds with M1 to M12 and ML1 to ML3 holding; 818 traces replayed
  on real SQLite; `kill -9` mid-migration and mid-write in WAL.
- **Not verified:** Ctrl-C on a real terminal; a kill during the WAL conversion; a disk
  filling at `COMMIT`; 8 of the 14 list shapes in the suite (all 14 passed once by
  hand).
- **Left for later:**
  - Nothing stops `migrate` beside a running server. Slice 2b can close it.
  - Ctrl-C during a migration exits 255 and prints nothing.
  - A `COMMIT` inside a migration is stopped by the check on the shipped list, not at
    run time.
  - The binary's output on a run that made progress and then failed has no test.
  - Layer 3 has no property tying a result's kind to the file. Layers 2 and 4 hold it.
  - unique-id v0.1.0 is released and not pinned: slice 4 takes it.
- **Found on the way** (each in [traps.md](traps.md)):
  - Chez's `equal-hash` reads only the start of a value.
  - `pkill -f` kills the shell that runs it.
- **What the verification caught that the reviews did not:** the exploration found
  R26b's hole, which two plan reviews had read past. The closing review then found
  the trailing-slash bug, which no layer could: the model assumed Chez and SQLite
  agree on what a missing file is, and no clause said so.

### Slice 1: the skeleton (PR #2, 2026-11-22)

- **Merged:** the Makefile and Guix container, the pins (Akku.lock and three
  submodules), `techo serve` with `GET /health`, `techo version` and `help`, five
  suites with 75 tests, Linux CI, the loop-stall spike and its report.
- **Decided on the way:** slice 2 waits for `await-outside`; writes and reads on
  separate threads; the worker modelled and verified; `techo user add` in slice 3; a
  pin is a full commit SHA (ADR-0011, amended).
- **Filed:** circuit 51 (merged there as 5cf5946) and 53; chez-http-server 262.
- **Verified:** every `make` check on the final tree, and CI green on its first run,
  which is also the fresh clone.
- **Not verified:** a commit's worst time on a quiet disk. The spike's disk numbers
  were taken on a busy host.
- **Left for later:**
  - `check-pins` compares version ranges, not resolved versions.
  - `techo help x` exits 0 while `techo version x` exits 2.
  - Copied comments name test scripts Techo does not have.
  - The 25 ms worst write in memory is unexplained (the report says how to find out).
- **Found on the way** (each in [traps.md](traps.md)):
  - A step that clears shared build output breaks a second run beside it, and `$$` is
    the same in every container.
  - A shallow checkout has no tags.
  - A benchmark that syncs measures whatever else is writing to the disk.
- **What the review caught that the builders and the lead did not:** the CI blocker,
  and that the lead's own fix for the race was broken. Both came from the read-only
  review at the end, on code that every local check passed.

### The outline (PR #1, 2026-11-22)

- **Merged:** [outline.md](outline.md) and three briefs, for chez-sodium, a UUID
  library (now unique-id), and chez-http-server's `await-outside`.
- **Decided in discussion:** what ADR-0001 to ADR-0010 now record.
- **Filed:** chez-http-server issue 260.
- **Not verified:** nothing was run. The proposal was read against chez-http-server's
  source; libsodium's signatures in the chez-sodium brief were from memory.
- **Found on the way:**
  - Akku's `uuid` package has versions 1 to 5 only, and its name is taken.
  - A worker thread's blocking C call still stalls the loop unless the call is
    `__collect_safe`. chez-sqlite3's are.
