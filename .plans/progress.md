# Progress ledger

Where Techo stands. Read it with [global-constraints.md](global-constraints.md) before
starting slice work. When a slice merges, update **Now** and **Next**, and add a
close-out under **Close-outs**, newest first.

## Now

- **The outline is merged**, squashed from
  [PR #1](https://github.com/Kiyomi-Computation-Systems/techo/pull/1) on 2026-11-22
  (4b06708). It is [outline.md](outline.md).
- **Eleven decisions are recorded**, ADR-0001 to ADR-0011, in [decisions/](decisions/),
  with the rules they make in [global-constraints.md](global-constraints.md).
- **Slice 1 is planned and approved**, in
  [2026-11-22-slice-1-skeleton.md](2026-11-22-slice-1-skeleton.md). The owner answered
  its four questions on 2026-11-22 (its §6); the first is ADR-0011. No code exists
  yet.

## Next

Slice 1: the skeleton and the loop-stall spike. It is ready to start.

## Slices

| # | Slice | State | Waits on |
|---|---|---|---|
| 1 | Skeleton, health endpoint, loop-stall spike | approved | |
| 2 | Schema, migrations, admin CLI | not planned | slice 1 |
| 3 | Accounts, login, API keys | not planned | chez-sodium M3 |
| 4 | Node create, read, update; revisions; `If-Match` | not planned | unique-id |
| 5 | The tree and move; links | not planned | |
| 6 | Kinds and props; task transitions | not planned | |
| 7 | Tags and search | not planned | |
| 8 | The change feed | not planned | |
| 9 | Docker image and backup | not planned | |

## Sibling projects

Each has its own repository, beside this one on the owner's machine, and its own
ledger. The briefs in [briefs/](briefs/) are the snapshots handed over; **the sibling's
own `.plans/` is the truth from then on.**

| Project | Where | State on 2026-11-22 |
|---|---|---|
| chez-sodium | `../chez-sodium` | Repository made; its brief under adversarial review |
| unique-id | `../unique-id` | Repository made, holding the brief |
| chez-http-server: `await-outside` | `../chez-http-server`, branch `feat/await-outside` | Issue 260 accepted as its decision 0039; work under way |

## Open questions

From [outline.md](outline.md) §14, each for the slice named:

| Question | Slice |
|---|---|
| Does the server refuse an id that is not version 7? | 4 |
| Are ids stored as 16-byte blobs or as text? | 2 |
| The node lifecycle's states, and which transitions can be undone | 4 |
| A Contact's first fields, exactly | 6 |
| The login rate limit's numbers | 3 |

## Close-outs

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
