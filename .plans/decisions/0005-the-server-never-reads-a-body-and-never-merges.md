# 0005: The server never interprets a body, and never merges

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §2

## Context

- The first client stores org text. Another may store markdown.
- A client keeps its own files and its own version tracking, and syncs.
- The server cannot merge text whose format it does not know.

## Decision

1. **A body is opaque text.** Each node carries a `content_type`, such as `text/org`.
2. **A conflicting write is refused** (ADR-0004). The client merges and writes again.
3. **Search indexes the raw text** of title and body.
4. **The client can fetch any old revision,** so it can find a common ancestor for a
   three-way merge.

## Consequences

- Search sees markup as words. Accepted for v1.
- A link written inside a body is invisible to the server. Only typed links (ADR-0003)
  are known to it.
