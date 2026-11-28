# Slice 7b: search

Date: 2026-11-27
Status: the owner decided Q1 to Q7 on 2026-11-27 (below). Not planned further,
not reviewed, not built. It follows [7a](2026-11-27-slice-7a-tags.md).
Records: ADR-0004 (the index points at `nodes.num`), ADR-0005 (search indexes
the raw text), ADR-0008 and the
[loop-stall report](research/2026-11-22-loop-stall.md), ADR-0012.

## Decisions (the owner's, 2026-11-27)

| # | Decided |
|---|---|
| Q1 | Search covers the title, the body, the tags and a Contact's props. |
| Q2 | Techo's own small query syntax: every word required, `"a phrase"`, `prefix*`. SQLite's own syntax is never passed through. |
| Q3 | SQLite's default tokenizer (`unicode61`), named in one place. A command `techo search rebuild`, with no options, run with the server stopped. No setting. The choice may be revisited by a migration. |
| Q4 | Results come newest made first: the index's own order, paged by cursor. Ranking by relevance may be added later as an option. |
| Q5 | Filters: state (active unless asked; trashed only when asked), kind, tag, parent. |
| Q6 | Each result has an excerpt. Cap how much of a body an excerpt reads. |
| Q7 | The index forgets a purged node's words. Held by a test. |

**Why no tokenizer setting (Q3):** the tokenizer is part of the index's table,
so a setting needs a rebuild and a check at start; search would differ from
one server to the next; and the query translator, the guide and every suite
would be doubled. The rebuild command is needed anyway, to repair an index,
and makes a later change one migration.

## What the probe found (2026-11-27)

`build/probe-7/search.sps`: 200,000 notes, half English of 300 words and half
Japanese of about 190 with no spaces, the body in the snapshot as the schema
has it, an external-content FTS5 table over a view, kept by one trigger on
`revisions`. Synthetic text, and the file in the operating system's cache.
A page of 51; each pair is `unicode61` / trigram.

| Measure | `unicode61` | trigram |
|---|---|---|
| Index, for 391 MiB of snapshots | 316 MiB | 878 MiB |
| Fill, 200,000 notes | 50 s | 135 s |
| A replace of a 2 KB body | median under 1 ms, worst 31 | median 1, worst 48 |
| A replace with a 1 MiB body | 74 to 122 ms | 84 to 252 ms |
| A word in every English note, by relevance | 85 ms | 257 ms |
| The same, newest changed first | 19 ms | 102 ms |
| The same, newest made first | under 1 ms | under 1 ms |
| A prefix of 3 letters, newest made first | 17 ms | 3 ms |
| 51 excerpts from 2 KB bodies | 1 ms | 2 ms |
| 51 excerpts from 100 KiB bodies | 11 ms | 33 ms |
| A rare Japanese word of 3 characters | 4 found of 131 | 131 |
| A Japanese word of 2 characters | almost none | none |
| A scan by `LIKE` for 2 characters | 27 ms at 20,000 notes; over 110 at 200,000 | the same |

- **Neither tokenizer searches Japanese well.** `unicode61` finds a word only
  where it stands alone between spaces or punctuation. Trigram finds nothing
  under three characters. A tokenizer of character pairs would need C code in
  chez-sqlite3: kept ready, with a brief to that repository when wanted.
- **Trigram with `detail=none`** refuses any phrase: unusable.
- **The index stayed whole** through every replace (`integrity-check`).
- **Not measured:** a replace of 1 MiB with no index, for a baseline; 51
  excerpts from bodies of 1 MiB (by the row above, 110 to 340 ms); a cold
  disk; the tags and props columns of Q1.
- **To confirm in the plan's probe:** that `日本*` finds a run of text that
  begins with 日本, before the guide says so.
