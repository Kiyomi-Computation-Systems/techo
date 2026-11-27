# 0004: A node has one revision counter, which is its ETag, and every write keeps a snapshot

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §4

## Context

- Several devices edit the same notes, some of them offline.
- A buggy client with a valid `If-Match` can overwrite a note with garbage. With only a
  counter, that note is then lost on every device.
- Two counters, one for content and one for placement, would spare a false conflict
  between an offline edit and a move, at the price of two ETags per node.

## Decision

1. **One integer revision per node.** Any change bumps it: content, props, tags, a
   move.
2. **It is the node's ETag.** A write must carry `If-Match`. A stale one answers 412, a
   missing one 428.
3. **Every write appends a full snapshot** of title, body, props and tags to an
   append-only table. No deltas.
4. **A restore writes a new revision** copied from an old one. History is never
   rewritten.
5. **Everything is kept in v1.** Purging a trashed node deletes its history.
6. **A per-owner sequence orders every change,** so a client can ask what changed
   since a cursor. A delete leaves a tombstone.
7. **Ids are UUIDs the client generates,** version 7, so a create can be retried and
   an offline client can make nodes.

## Consequences

- An offline body edit conflicts with a move made elsewhere. The client refetches and
  retries. Accepted.
- Storage grows with every write. A retention setting is future work.
- Open: whether the server refuses an id that is not version 7, and whether ids are
  stored as blobs or text.

## Amendment, 2026-11-25: what slice 4 decided

Status: accepted (owner, 2026-11-25, as slice 4's D2, D3, D4, D9 and D11)
Plan: [slice 4](../2026-11-25-slice-4-nodes.md)

1. **An id must be a UUID of version 7.** Any other is refused. The id's time is
   not checked against the server's clock. This closes the record's open question.
2. **A node is made by `PUT` to its id with `If-None-Match: *`,** and answers 412
   when the id is in use. So "a write must carry `If-Match`" reads: a write carries
   `If-Match`, or `If-None-Match: *` to make the node. With neither it is 428.
3. **The ETag is the revision in quotes.** `If-Match` is accepted only as one such
   tag. `*`, a list and a weak tag are refused: `If-Match: *` would overwrite
   whatever is there.
4. **A replace sends the whole content.** There is no `PATCH`. Every accepted write
   is a new revision, the same content too.
5. **The versioned write is a table** (ADR-0007):
   [machines/write.md](../machines/write.md).
6. **A snapshot also holds the content type and the author.** Tags and the parent
   join it with the slices that bring them.
7. **A body is kept once, in its snapshot.** A node's row holds no body: its body
   is the snapshot at its revision. Read with 100 bodies of 1 MiB, a column behind
   the body cost 17 ms a list and under 1 ms without one.
8. **A node has an integer key beside its id,** which never leaves the database.
   A search index points at a row by number, and SQLite may renumber a table that
   has no integer key when it is vacuumed.
9. **A body may be 1 MiB,** a title 1,000 characters, a request 2 MiB. The cap is
   "for now" (owner): a larger one wants the key checked before the body is read.

**Consequences**

- Reading a node is two lookups.
- Slice 7's search index is built over a view of each node and its newest
  snapshot, with its trigger on `revisions`. Probed, not measured at size.
- A node written 2^53 times can never be written again: no `If-Match` names its
  next revision. Not guarded.
- The lifecycle (archive, trash, purge) is slice 4b.

## Amendment, 2026-11-25: a state change, and a purge

Status: accepted (owner, 2026-11-25: "i approve L1 - 10"; L11 on 2026-11-26)
Plan: [slice 4b](../2026-11-25-slice-4b-node-lifecycle.md)

1. **A state change bumps the revision and writes no snapshot.** Archive,
   unarchive, trash, untrash and purge each take the owner's next sequence
   number. So "every write appends a full snapshot" reads: every write of
   content does.
2. **A node's body is its newest snapshot's,** not the snapshot at its revision.
   This replaces point 7's second sentence above.
3. **A purge deletes the node's snapshots and empties its row,** in one
   transaction. It is the one thing that removes history. The row stays, so the
   id is never used again by anyone, and the integer key is never reused.
4. **A purge's change row is the tombstone.** No change row for the node follows
   it.

**Consequences**

- A node's revisions list has gaps where its state changed. The feed has every
  number.
- A purge writes every freed page as zeros: about 2 ms a MiB of history, with
  the writer held. Through the real route: 0.45 s for 200 MiB and 0.73 s for
  400 MiB on a quiet disk, 1.4 s for 200 MiB on a busy one. Accepted (L11).
  Nothing caps a node's history: past the 10 s deadline (about 4.5 GiB quiet,
  1.5 GiB busy) the purge answers 504 while its job runs on.
- `open-techo-db` turns `secure_delete` on itself, so the zeros do not depend on
  how SQLite was built. The purged text can stay in the `-wal` until the next
  write. The file does not shrink.
- Reads are not held: 3 ms at worst during a 200 MiB purge.
- A purge leaves the row's times, the earlier change rows, and backups.

## Amendment, 2026-11-26: a move

Status: accepted (owner, 2026-11-26, as slice 5a's T4 and T7)
Plan: [slice 5a](../2026-11-26-slice-5a-tree.md)

1. **A move bumps the revision and writes no snapshot,** as a state change. A
   snapshot holds no parent, so a restore never undoes a move. This replaces
   "the parent joins it" in the first amendment's point 6.
2. **A bulk move moves a node's children without their own `If-Match`.** It is
   the one write that is: the request carries the node's revision, which the
   move does not change. It loses no content. A moved child's pending write
   meets a 412.

## Amendment, 2026-11-26: a link is no write to a node

Status: accepted (owner, 2026-11-26, as slice 5b's K4 and K5)
Plan: [slice 5b](../2026-11-26-slice-5b-links.md)

1. **A link made or removed changes neither node.** No revision is bumped, no
   snapshot written, and the request carries no `If-Match`. This is the second
   exception to "every write carries `If-Match`", after a bulk move's children.
   A link is there or not, so two devices cannot conflict over one.
2. **Its cost:** a restore brings back no old links, and a node's `ETag` says
   nothing of its links.
3. **Each link made or removed writes one change row on the source,** `link` or
   `unlink`, at the source's present revision. So two rows of a node can carry
   one revision. The row names no target; slice 8 decides what the feed says.
4. **A purge writes its own row only,** however many links it removes: no row
   on the nodes at their other ends. A purge's row means every link of the
   node is gone.
5. **A purge of a node with 181,667 links held the writer 0.6 s** and grew the
   `-wal` to 70 MB, cut to 16 MiB at the next commit. Accepted, as a large
   history's purge is.
