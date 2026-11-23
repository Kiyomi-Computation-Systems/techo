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
