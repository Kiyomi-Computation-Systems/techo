# 0010: Attachments are deferred, and their shape is fixed now

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §8

## Context

- Org notes often link images, so attachments will be wanted.
- They bring upload limits, quotas, garbage collection and a second thing to back up.
  None of the node, versioning or sync work depends on them.

## Decision

1. **Not in v1.**
2. **An attachment is its own resource, owned by a node.** It is not a node kind, so
   bodies stay text.
3. **A blob is addressed by its SHA-256** and kept in an object store, S3 or one like
   it. Its metadata is in SQLite.
4. **Storage sits behind a small interface,** with a filesystem adapter for tests.
5. **A client uploads straight to the store** through a presigned URL.

## Consequences

- Until then a client keeps attachments itself, and a link in a body is plain text.
- chez-curl gains a server-side use, and chez-sodium's second tier (SHA-256,
  HMAC-SHA256) is for this.
