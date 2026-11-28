# Slice 7a: tags

Date: 2026-11-27
Status: the owner decided G1 to G8 on 2026-11-27 (below). Reviewed (the review
section, at the end): where it and the text above disagree, the review wins.
Not built.
Records: ADR-0002 (the API), ADR-0003 (nodes), ADR-0004 (revisions), ADR-0007
(machines), ADR-0012 (migrations), ADR-0013 (the doorway). Read
[global-constraints.md](global-constraints.md) first, then the plans of slices
[4](2026-11-25-slice-4-nodes.md), [5a](2026-11-26-slice-5a-tree.md) and
[6](2026-11-27-slice-6-kinds-and-props.md): this slice builds on all three.
Slice 7 is split (S1): this is tags, and
[7b](2026-11-27-slice-7b-search.md) is search.

## What this slice is for

A person can put short labels on any node, and then:

- list the nodes that carry a tag, or several;
- list the account's tags, with how many nodes carry each;
- rename a tag everywhere, or take it off everything.

## What the probes found (2026-11-27)

`build/probe-7/tags.sps` and `fold.sps`, on a real file opened by
`open-techo-db`: one account, 200,000 nodes, 610,000 to 750,000 tag rows in a
`node_tags(owner, tag, node)` table with an index on `node`. The file was in
the operating system's cache throughout.

| Question | Answer |
|---|---|
| A page of 51 nodes by tag | 0.2 ms (6.7 ms when every node has 4 KiB of props) |
| One node's tags | 0.01 ms |
| A page of 51 tags with counts | 3 to 4 ms |
| Every tag with its count, 501 tags | 32 to 40 ms: the list must be paged |
| A rename step of 100 nodes: the writer held | median 3 ms, worst 17 (13 and 35 with 4 KiB props) |
| A step of 1,000 | median 34 ms, worst 38 (72 and 77 with 4 KiB props) |
| A whole rename of 100,000 nodes, 1,000 a step | 0.9 s of database time, in 100 steps |
| A rename onto a tag half the nodes already have | the same, and no duplicate |

- **A step's cost follows how scattered the nodes are,** not how many carry
  the tag.
- **Not measured:** a cold disk; other accounts writing at once; a step that
  also reads each node's tags back.
- **Chez's `string-normalize-nfkc` and `string-downcase`** fold `Work` and
  full-width `ＷＯＲＫ` to `work`, half-width `ﾒﾓ` to `メモ`, `E` with a combining
  accent to `é`, and leave `日本` alone. `STRASSE` and `Straße` stay two tags,
  as do hiragana and katakana.

## Decisions (the owner's, 2026-11-27)

| # | Decided |
|---|---|
| S1 | Slice 7 is two: 7a tags, 7b search. |
| G1 | A tag is part of a node's content: a `tags` list in the `PUT`, replaced whole, under `If-Match`. A change bumps the revision, the snapshot holds the tags, and a restore brings them back. |
| G2 | A replace with no `tags` keeps the stored tags. `[]` clears them. |
| G3 | The server normalises a tag and stores and answers that form (below). |
| G4 | A `node_tags` table, and the list as JSON in each snapshot. |
| G5 | At most 50 tags a node. |
| G6 | `GET /v1/nodes?tag=x`, repeated for "all of these"; `GET /v1/tags`, the account's tags with counts, paged. |
| G7 | No inherited tags. The client works them out from the tree. |
| G8 | Rename a tag and remove a tag, as step commands of at most 500 nodes, with no snapshot. Approved on the measurements above. If it proves too slow in use, tags as their own records is a slice of its own. |

**G3, the rule, in order:**

1. Normalise (NFKC).
2. Lowercase.
3. Trim white space from both ends.
4. Each run of white space inside becomes one `-`. Hyphens sent are left.
5. The result is 1 to 64 characters, with no control character and no
   zero-width character: else a 400. Neither is stripped.

- `Work Space`, ` work  space ` and `work-space` are one tag: `work-space`.
- `["Work", "work"]` in one request is one tag, not an error.
- The limit of 64 is on the stored form.

## The design

### Routes

| Route | Does |
|---|---|
| `PUT /v1/nodes/{id}` | takes `tags`, a list of strings; left out, a create has none and a replace keeps them |
| every answer that holds a node | has `tags`, sorted |
| `GET /v1/nodes?tag=a&tag=b` | the nodes that carry every tag named, at most 10; with `state`, `parent` and paging as now |
| `GET /v1/tags?limit=&cursor=` | `{"items":[{"tag","count"}],"next"}`, in the tags' order; the cursor is the last tag |
| `POST /v1/tags/rename` | body `{"from","to"}`: renames on at most 500 nodes, answers `{"renamed":n,"left":m}` |
| `POST /v1/tags/remove` | body `{"tag"}`: removes from at most 500 nodes, answers `{"removed":n,"left":m}` |

- **The two commands name the tag in the body,** not the path: a tag may hold
  `/`, `%` and any script, and the router's decoding of a path is untested for
  those. For the review: probe how a `?tag=` of percent-encoded UTF-8 arrives.
- **A tag given to a filter or a command is normalised as a stored one is,**
  so `?tag=Work` finds `work`. One that fails the rule is a 400.
- **A command is safe to repeat.** A tag no node carries answers
  `{"renamed":0,"left":0}`, not a 404. The client calls until `left` is 0.
- **A rename onto a tag that exists is a merge.** `from` equal to `to`, once
  normalised, is a 400.
- **Each node a command touches** gets its revision bumped, `updated` set and
  one change row, op `tags`. No snapshot, as a move writes none. Its price,
  to be documented: a restore of a revision from before brings the old tag
  back to that node, and a device with an unsent edit to it gets a 412.
- **A command touches a node in any state.** A tag left on trashed nodes
  would never let `left` reach 0.
- **A count is of every node that carries the tag,** trashed ones too.
- **No `If-Match` on a command:** it names no one node. Sent, it is a 400.

### The stored form

- A node's tags are a set, stored and answered sorted by code point.
- More than 50 entries as sent is a 400, counted before they are folded.
- In a snapshot: a JSON array of the stored forms, `[]` for none.

### Pure, in a new `(techo tags)`

```scheme
;; tag-cap : Natural                         50
;; tag-length-cap : Natural                  64
;; tag-step-cap : Natural                    500
;; tag-filter-cap : Natural                  10
;; normalise-tag : String -> (U String 'invalid)
;; request-tags : Any -> (U (Listof String) 'absent 'invalid)
;;   A parsed `tags` member: the stored forms, sorted, no two the same.
;; tags->json : (Listof String) -> String
;; json->tags : String -> (Listof String)
```

- The character rules (control, blank, zero-width) are the Contact's. They
  move from `(techo contact)` to a small shared library, and both use it.
- **No table:** a tag has no states. For the review: whether the two commands
  belong in the lifecycle's table, as the bulk move's did.

### Migration 7, "tags"

```sql
CREATE TABLE node_tags (
  owner BLOB NOT NULL REFERENCES accounts(id),
  tag   TEXT NOT NULL,
  node  BLOB NOT NULL REFERENCES nodes(id),
  PRIMARY KEY (owner, tag, node)
) STRICT, WITHOUT ROWID;
CREATE INDEX node_tags_node ON node_tags(node);
ALTER TABLE revisions ADD COLUMN tags TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags));
```

- A snapshot made before this has no tags: restoring it clears them.
- `tags` lands behind `body` in `revisions`. It is read only with the body.
- `node_tags` is the one truth for a node's present tags. A node's row holds
  none. For the review: measure a list page that gathers each node's tags.

### The store

- A write of content replaces the node's rows in `node_tags` when `tags` was
  sent, and writes the stored tags into the snapshot either way.
- A task command and a restore write a snapshot: the first with the present
  tags, the second with the old snapshot's, which then replace the rows.
- A purge deletes the node's rows.
- A step: pick the first 500 nodes by id that carry the tag; insert the new
  tag where it is not there (rename only); bump each node; write each change
  row; delete the old rows; count what is left. One transaction.
- Every statement that reads or deletes by `node` has its plan held by a test.

## What must hold, and what would catch a break

| # | Law | Catches |
|---|---|---|
| L1 | `normalise-tag` of a stored tag is that tag | a tag read back and sent again changing |
| L2 | A node's tags, read, are sorted, with no two the same and none over 64 | a fold that is skipped on one path |
| L3 | `node_tags` and the newest snapshot agree after every content write | the two written apart |
| L4 | A replace with no `tags` changes no row of `node_tags` | G2 |
| L5 | After commands repeated until `left` is 0, no node carries `from`, every one that did carries `to`, and each was bumped once per step that touched it | a step that skips or repeats a node |
| L6 | A command changes no node of another account | a missing `owner` |
| L7 | A purged node has no row in `node_tags` | a purge that forgets |
| L8 | A tag's count is the number of nodes the filter finds across every state | counts and filter drifting |

## How it is checked

- `tests/test-tags.sps`: the rule, with a fixed corpus of what Chez's Unicode
  tables decide (as the URIs are pinned), and L1 over generated strings.
- The store's and the routes' suites; the model gains tags, the filter and
  the two commands, and holds L2 to L8.
- A mutant of my own per hand-back, and a read-only review of the build.

## The work

| # | Task | Files |
|---|---|---|
| 1 | `(techo tags)`, the shared character rules, their suites | `src/techo/tags.sls`, a new shared library, `contact.sls`, tests |
| 2 | Migration 7 and the store | `migrations.sls`, `node-store.sls`, tests |
| 3 | The routes and the guide | `nodes.sls`, `node-routes.sls`, `docs/api.md`, tests |
| 4 | The model and the integration test | `tests/nodes-model.sls`, tests |

Tasks 1 and 2 share no file and can run together. 3 needs both, 4 needs 3.

## Not in this slice

- Search over tags: 7b.
- Tags as their own records, with ids (G8's fallback).
- Tags in the change feed beyond the `tags` row: slice 8, with issue #21.
- Folding `ß` with `ss`, or hiragana with katakana.

## The review of this plan (Opus, 2026-11-27)

Read-only. Its probes are in `build/review-7a/` (22 scripts). Timings are on
files opened by `open-techo-db`, in the operating system's cache, on SQLite
3.53.1. Chez 10.4.1's tables are Unicode 16.0. I reproduced blockers 1 to 5
myself (`build/verify-7a/v.sps`).

### Blockers, and what they change

1. **G3 as written breaks L1.** Lowercasing after NFKC leaves forms that are
   not normalised: `W` and U+030A gives `w` and U+030A, and a second pass
   gives `ẘ`. Of 12.03M generated strings, 0.05% to 0.2% failed.
   **So the rule is NFKC, `string-downcase`, NFKC, trim, collapse, check.**
   That gave no failure in the 12.03M, in each of the 1,111,909 scalar
   values, and in 1.57M targeted pairs and triples. No example of the
   owner's changes.
2. **A create that sends `tags` is a 400 today, in two places:**
   `request-props` (`props.sls:213`) takes an object of at most 6 members,
   and `parse-content` refuses the member. Task 1 owns both.
3. **A hostile request stalls the loop's thread.** One 2 MiB tag of U+FDFA,
   which grows 18 times under NFKC, took 2.5 s to fold (7.5 s in my run).
   **So a sent tag over `tag-raw-cap`, 256 code points, is refused before it
   is normalised.** The worst request is then 50 of 256: 15 to 20 ms.
4. **The index must begin with the owner** (a global rule):
   `CREATE INDEX node_tags_node ON node_tags(owner, node)`. It covers a
   node's tags in order.
5. **`GET /v1/tags` pages by `limit` and `after`,** as ADR-0002 has every
   list, not by `cursor`.
6. **The filter as sketched is 100 times slower in its bad cases.** A page of
   51, 200,000 nodes with 4 KiB props: a tag on 95% of nodes with a second
   on 51 took 259 ms; a good page is 6.7 ms. **So:**
   - every other tag is joined before `nodes` (259 to 69 ms);
   - the scan drives from the rarest tag, by counts capped at 1,000 (0.04 ms
     each): 5.6 ms;
   - with a `parent` given, it drives from `nodes_parent` (194 to 0.69 ms);
   - one statement per number of tags, each named literally, with the
     zero-id cursor `links-page` uses; every plan held by a test.
   - **What stays slow:** every tag on 1,000 or more nodes and none in
     common, 121 ms; a state none of the tag's nodes is in, 78 ms (today's
     list costs 144 ms for a state no node is in, on the same file).
7. **"Every answer that holds a node" missed the links list and the snapshot
   answers.** The Node record gains `tags`, filled on every path that makes
   one. A whole snapshot's answer shows `tags`; the revisions list does not.
8. **The model breaks at once:** `reset!` deletes `nodes` with `node_tags`
   rows left; `feed-state` knows no op `tags`; `db-now` reads neither the
   table nor the column; three laws assume one node per write.
9. **The records contradict the plan.** Three rules of
   `global-constraints.md` need an amendment before any brief: a change of
   content appends a snapshot; every write to a node carries `If-Match`; a
   large column is its table's last (`revisions.tags` lands behind `body`,
   measured at 0.015 ms extra when read with it).
10. **The two commands belong in the lifecycle's table,** as the bulk move
    did: a `retag` event, allowed in active, archived and trashed, and
    "cannot happen" when purged. It is in its own `tag-events` list, and
    `node-command` does not answer it. A test holds the store's
    `state IN (...)` equal to `retag-states`, derived from the table.
11. **Files no task owned:** `props.sls`, `requests.sls` (`query-one` refuses
    a repeated `tag`), `test-db.sps` and `test-integration.sps`
    (`shipped-objects` 17 to 19, `shipped-tables`), `shipped-migrations.scm`,
    `test-migrations.sps`. Owners are in the work, below.

### The interface, pinned

**`(techo chars)`,** new, pure, each rule a written list:

```scheme
;; allowed-char? : Char Boolean -> Boolean     moved from Contact, unchanged
;; blank-char? : Char -> Boolean               moved from Contact, unchanged, never widened
;; zero-width-char? : Char -> Boolean          U+200B to U+200D, U+2060, U+FEFF (hole H3)
;; space-char? : Char -> Boolean               what a tag trims and collapses (hole H2)
```

**`(techo tags)`,** pure:

```scheme
;; tag-cap 50   tag-length-cap 64   tag-raw-cap 256   tag-step-cap 500   tag-filter-cap 10
;; normalise-tag : Any -> (U String 'invalid)
;;   'invalid for what is no string, and for one over tag-raw-cap before any
;;   character is read. Then NFKC, downcase, NFKC, trim, collapse, check.
;;   Never raises.
;; request-tags : Alist Boolean -> (U (Listof String) 'absent 'invalid)
;;   The request's object, and whether it is a create. No member: '() on a
;;   create, 'absent on a replace. A vector of at most tag-cap entries,
;;   counted before any is read: the stored forms, sorted, distinct.
;; filter-tags : (Listof String) -> (U (Listof String) 'invalid)
;; tags->json : (Listof String) -> String
;; json->tags : String -> (Listof String)
;; parse-rename-body : Any -> (U (Pair String String) 'invalid)
;; parse-remove-body : Any -> (U String 'invalid)
```

**`(techo node-store)`,** which does not import `(techo tags)`:

```scheme
;; node-tags : Node -> (Listof String)
;; snapshot-tags : Snapshot -> (U String #f)        #f from snapshots-page
;; tags-of : Tx Bytevector Bytevector -> (Listof String)        owner, id
;; insert-node! : Tx Bytevector Bytevector String String String String String (U Bytevector #f) (Listof String) Natural -> Node
;; write-node! : Tx Bytevector Bytevector Natural String String String String (U (Listof String) 'keep) String Natural -> Node
;; nodes-page : Tx Bytevector String (U 'any #f Bytevector) (Listof String) (U Bytevector #f) Natural -> (Listof Node)
;; tag-count-capped : Tx Bytevector String Natural -> Natural
;; tags-page : Tx Bytevector (U String #f) Natural -> (Listof (Pair String Natural))
;; rename-tag! : Tx Bytevector String String Natural Natural -> (Pair Natural Natural)     owner, from, to, cap, now: (touched . left)
;; remove-tag! : Tx Bytevector String Natural Natural -> (Pair Natural Natural)
```

- **The snapshot's `tags` is read from the rows in the same statement,**
  `json_group_array` over the node's tags in order, after the rows are
  written. So L3 holds by construction. Its text is byte for byte
  `json->string`'s.
- **A step's statements, in order:** the cap-th node by `OFFSET`; for a
  rename, `INSERT ... SELECT ... WHERE NOT EXISTS` (no `OR IGNORE`:
  traps.md); the `UPDATE` of `nodes`, with the owner and the live states,
  checked against the count picked; one `INSERT INTO changes` numbering by
  `row_number()` from the owner's next `seq`; the `DELETE`; the count left.
  Every statement names the owner.
- **Nothing is named `step!` or `changes`:** `(chez-sqlite3)` exports both.
- **`(techo nodes)`:** `parse-content` hands `tags` on as it does props; a
  create may have 7 members. `tag-events`, `retag-states`, three rows.
- **`(techo requests)`:** `query-all : Req String -> (Listof String)`.
- **`(techo node-routes)`:** `"tags"` after `"props"` in a node and in a
  whole snapshot. The tag routes live here. A command answers 200 with no
  `ETag`. No raise carries a tag.

### The order of answers

Before any route: a malformed `%` or raw UTF-8 in the target is a 400 with no
body, and a target over 8,192 bytes a 414.

- **`PUT /v1/nodes/{id}`:** as slice 6, with `request-tags`' 400 after
  `request-props`' and before any 413. Tags add nothing in the job.
- **`GET /v1/nodes?tag=`:** 401; `limit`, `after`, `state`, `parent`, then
  `tag` (over 10 as sent, or one refused, an empty one too), 400; in the job
  401, then 404 for a `parent` that is no node of the account.
- **`GET /v1/tags`:** 401; `limit` 400; `after` 400; in the job 401.
- **The two commands:** 401; any `If-Match` or `If-None-Match` 400 (never
  428); the key 401; 415; a body over 16 KiB 413; `invalid_json` 400; the
  body 400; in the job 401, then the step. Never 404, never 412.

### Answers the plan lacked, now given

| Case | Answer |
|---|---|
| `?tag=a+b` | `a b`, so `a-b`: a `+` is a space in a query. `?tag=c++` finds `c`. Send `%2B` |
| `?tag=%E6%97%A5%E6%9C%AC`, `%2F`, `%26` | `日本`, `/`, `&` |
| `?tag=%FF`, or a cut-off sequence | U+FFFD, a valid tag: 200 |
| `?tag=` | 400 |
| `?tag=Work&tag=work` | two as sent, toward the 10; one tag |
| `tags: null`, `[""]`, `["   "]`, a number in the list | 400 |
| 51 entries that fold to one | 400 |
| 4 of U+FDFA | 72 characters once folded: 400 |
| `㈱`, `Ⓐ` | `(株)`, `a` |
| U+2010 and U+2212 against `-` | distinct tags |
| A restore | the rows become the snapshot's tags as stored, never folded again |
| A restore of the newest snapshot after a rename | brings `from` back |
| Two steps of one rename at once | one after the other on the one writer; no node touched twice (inferred from ADR-0013) |
| A client adds `from` back between steps | `left` can rise; each step still takes min(500, left) |
| A step on a tag only another account has | `{"renamed":0,"left":0}` |

### What the plan said that was wrong

- **"A page of 51 tags with counts: 3 to 4 ms."** It is 21 to 22 ms when the
  page holds a tag on 190,000 nodes: the cost is the sum of the page's counts.
- **"The character rules are the Contact's."** Its zero-width list is five
  code points. Other invisible characters pass (H3).
- **"Tasks 1 and 2 share no file."** True, but task 2 alone leaves the build
  broken: the callers of `insert-node!` and `write-node!` must change with it.
- **The probe's step** used `INSERT OR IGNORE` and an `UPDATE` with no owner.
  Both are forbidden. The right statements cost the same.
- **G3's step 5 never fires for tab or a line break** if "white space" means
  Unicode's whole set: they become `-` first (H2).

### Measured by the review

200,000 nodes, 660,000 tag rows; "4 KiB" is every node with 4 KiB of props.

| What | Result |
|---|---|
| Fold, one 2 MiB tag of U+FDFA; 50 tags sharing 2 MiB | 2,527 ms; 135 to 1,055 ms |
| Fold, worst under the raw cap | 15 to 20 ms |
| A page of 51 with each node's tags by `tags-of` | 0.52 ms more (6.7 ms a page at 4 KiB before it) |
| Filter, one tag on 10% of nodes | 0.37 ms; 6.7 ms at 4 KiB |
| Filter's bad cases, as redesigned, 4 KiB | 5.6 to 6.9 ms; 121 ms when every tag is on 1,000 or more and none match |
| A count of a tag on 190,000; capped at 1,000 | 5.4 ms; 0.04 ms |
| A step of 500, 4 KiB: statements, count left, commit (median, worst) | 8.2 (68), 3.1 (8.0), 10.8 (29) ms |
| A whole rename of 190,000, 4 KiB | 380 steps, 9.9 s of database time |
| Change rows for a step: one statement against 500 calls | 3.3 against 9.5 ms |
| Migration 7 on a version-6 file | applied; 17 to 19 objects; old snapshots read `[]` |

### Holes in the decisions, left as decided and to be documented

- **H1.** G3's order, fixed by blocker 1.
- **H2. G3 names no set of white space.** Open, for the owner: whether a tab
  or a line break in a tag is a 400 or becomes `-`.
- **H3. G3's "zero-width" leaves other invisible characters:** a
  left-to-right mark, a soft hyphen, a direction override each make a second
  tag that looks the same. Open, for the owner.
- **H4. G3 takes unassigned code points.** A later Chez that gives one a case
  mapping breaks L1 for tags already stored (inferred, not run).
- **H5. G1 with G8:** a step changes content with no snapshot and no
  `If-Match`. Three recorded rules are amended for it.
- **H6. G5 with G6:** a tags page costs the sum of its counts. Fifty tags on
  all of 200,000 nodes is about 0.5 s a page (scaled, not run).
- **H7. G8's price:** a rename of 190,000 nodes is 380 calls, 190,000 change
  rows, and a 412 for every device with an unsent edit to one of them.
- **H8. G6 puts tags in a query:** a `+` is a space and bad UTF-8 becomes
  U+FFFD. A client must encode a tag.

### The work, as reviewed

This replaces the table above.

| # | Task | Files | Model |
|---|---|---|---|
| 0 | The records: ADR-0002, 0003, 0004, 0007, the constraints, three traps | `.plans/` | mine |
| 1 | Pure | `chars.sls`, `contact.sls`, `tags.sls`, `nodes.sls`, `props.sls`, their suites, `lifecycle.md` | Opus |
| 2 | Migration 7 and the store, with the callers' arity so the suite stays green | `migrations.sls`, `shipped-migrations.scm`, `node-store.sls`, their suites, the object counts, call sites in `node-routes.sls` and its suite | Opus |
| 3 | The routes and the guide | `node-routes.sls`, `requests.sls`, `docs/api.md`, their suites, `test-app.sps` | Opus |
| 4 | The model, then the integration test | `nodes-model.sls`, `test-nodes-model.sps`, `test-integration.sps` | Opus, then Sonnet |
| 5 | The rest of the records, and a read-only review of the build | | mine; Opus |

1 and 2 run together. 3 follows both, 4 follows 3.

### What must hold, added and corrected

- **L1** is of the rule with its second NFKC. A tag restored from a snapshot
  is taken as stored.
- **L2** adds: at most 50, each a fixed point of L1, on every answer and row.
- **L3, restated:** after a content write the new snapshot's tags are the
  rows. Between a step and the node's next content write they differ by
  exactly the steps since.
- **L5, restated:** a step touches min(500, carriers); each is bumped once,
  with one row of op `tags` at its new revision, numbered in id order from
  the owner's next `seq`; no snapshot; no other node changes; `left` is the
  count after.
- **L8** is held as the sum of the filter over the three states.
- **L9.** A `node_tags` row's owner is its node's.
- **L10.** A request refused for its tags makes no write job.
- **L11.** A restore sets the rows to the snapshot's tags; one from before
  migration 7 clears them.
- **L12.** No raise carries a tag.
- **L13.** A step touches every live state, and the store's list of states
  equals `retag-states`.
- **L14.** Every plan of the filter and the tags list is held by a test.
- **The model:** `reset!` deletes `node_tags` first; `db-now` reads the table
  and the column; `feed-state` keeps the state for `tags`; tags are a corpus
  written by hand; one seed has over 500 carriers of a tag, so `left` is
  above 0.

## Decided after the review (owner, 2026-11-27)

- **H2:** a tab or a line break in a tag is a 400. `space-char?` is U+0020,
  U+00A0, U+1680, U+2000 to U+200A, U+202F, U+205F and U+3000; after NFKC
  only U+0020 and U+1680 can be left. U+2028 and U+2029 are refused, as in a
  Contact.
- **H3:** an invisible character is a 400. `invisible-char?` replaces
  `zero-width-char?` in `(techo chars)`, and is Unicode 16's
  Default_Ignorable_Code_Point, written out: U+00AD, U+034F, U+061C, U+115F,
  U+1160, U+17B4, U+17B5, U+180B to U+180F, U+200B to U+200F, U+202A to
  U+202E, U+2060 to U+206F, U+3164, U+FE00 to U+FE0F, U+FEFF, U+FFA0, U+FFF0
  to U+FFF8, U+1BCA0 to U+1BCA3, U+1D173 to U+1D17A, U+E0000 to U+E0FFF.
  **Its price:** an emoji typed with its variation selector (`❤️`, U+2764 and
  U+FE0F) or joined by U+200D is refused. A client strips U+FE0F first. A
  refusal can be lifted later; an acceptance cannot be taken back.
- **H5:** the three rules are amended (ADR-0004; the constraints).
- **H6:** a tag's count stops at 1,000. `tags-page` answers
  `min(count, 1000)` for each tag, and L8 is held against that.
