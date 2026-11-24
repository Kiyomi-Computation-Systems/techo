# 0002: The API is REST with JSON, and commands are POST sub-resources

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §5

## Context

- Writes must be checked against a version. HTTP already has `If-Match`, `ETag`, 412
  and 428. JSON-RPC would rebuild them inside its envelope.
- circuit gives a router, JSON middleware and handler tests, shaped around resources.
- Some operations are not create, read, update or delete: moving a node, changing a
  task's status, regenerating a key.

## Decision

1. **Resources over HTTP, JSON bodies**: nodes, revisions, links, tags, search,
   changes, API keys.
2. **A command is a `POST` to a sub-resource**, such as `POST /nodes/{id}/move`. Each
   command is one event of one state machine (ADR-0007).
3. **Every refusal uses one error format.**
4. **Every list is paged, with a cap** the server enforces.

## Consequences

- A client needs only an HTTP library. Emacs's own will do.
- The error format and the paging scheme are designed in the slice that first needs
  them, slice 4.

## Amendment, 2026-11-24: the error format, paging, times and the prefix

Status: accepted (owner, 2026-11-24, as slice 3's D7, D8, D9 and D15)
Plan: [slice 3](../2026-11-24-slice-3-accounts.md)

The record left the error format and the paging scheme to slice 4. Slice 3 has the
first refusals and the first list, so they are decided here.

1. **A refusal is RFC 9457 problem details,** sent as `application/problem+json`:
   `type`, `title`, `status`, `detail`, and one member of Techo's own, `code`.
   - `code` is a fixed word a client switches on. `detail` is for a person.
   - `type` is `about:blank`: a self-hosted server has no fixed address for a URI
     for each kind of error. Real ones can come later; a client that reads `code`
     will not notice.
   - One outer middleware puts every answer of 400 or more into the format. What the
     server refuses before any handler runs is not covered.
2. **A list is paged by `limit` and `after`.** `limit` defaults to 50 and is capped at
   100. `after` is the last id seen. The answer is `{"items": [...], "next": id or
   null}`.
3. **A time is whole milliseconds since 1970, UTC,** the number the database holds.
4. **Routes live under `/v1`.** `/health` does not.

**Consequences**

- A client compares and sorts times as numbers, and formats them itself.
- A later slice's list uses the same two parameters.
