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

## Amendment, 2026-11-25: a list may page by a number

Status: accepted (owner, 2026-11-25, with slice 4's plan)
Plan: [slice 4](../2026-11-25-slice-4-nodes.md)

A node's revisions are listed newest first. Their `after` and `next` are revision
numbers, not ids, and the page starts below `after`. Every other rule of paging
holds. Three codes join the error format: `precondition_failed` (412),
`precondition_required` (428) and `kind_fixed` (409).

## Amendment, 2026-11-25: slice 4b's routes

Status: accepted (owner, 2026-11-25, as slice 4b's L3, L6 and L9)
Plan: [slice 4b](../2026-11-25-slice-4b-node-lifecycle.md)

- **Archive, unarchive, trash and untrash are `POST` commands** on the node.
  They answer the node without its body.
- **A purge is `DELETE` on the node,** with `If-Match`. It answers 204.
- **The nodes list shows active nodes,** or one other state with `?state=`.
- **One code more:** `wrong_state` (409), when the node's state does not allow
  the request.

## Amendment, 2026-11-26: slice 5a's routes

Status: accepted (owner, 2026-11-26, as slice 5a's T3, T7, T9 and T10)
Plan: [slice 5a](../2026-11-26-slice-5a-tree.md)

- **A move is `POST /v1/nodes/{id}/move`,** and a bulk move of a node's children
  `POST /v1/nodes/{id}/move-children`. Each takes `{"parent": id or null}`.
- **The nodes list takes `?parent=`,** an id or `null` for the top level.
- **Three codes more,** all 409: `invalid_parent`, `would_loop`, `has_children`.
- **A command is one event of a table, and may need facts beside the state:**
  a move's answer also takes what was found of the new parent.

## Amendment, 2026-11-26: slice 5b's routes

Status: accepted (owner, 2026-11-26, as slice 5b's K3 and K8)
Plan: [slice 5b](../2026-11-26-slice-5b-links.md)

- **A link is `PUT` and `DELETE /v1/nodes/{id}/links/{type}/{target}`,** with
  no request body and no precondition. The `PUT` answers 201 when it makes the
  link and 200 when it was there; the `DELETE` 204.
- **A node's links are `GET /v1/nodes/{id}/links`,** with `direction` (`out` or
  `in`) and `type`, paged. An item carries the node at the other end, without
  its body.
- **No new code.** A missing end, and a link that is not there, are 404.

## Amendment, 2026-11-27: slice 6's routes, and a When

Status: accepted (owner, 2026-11-27, as slice 6's P6, P7 and P11)
Plan: [slice 6](../2026-11-27-slice-6-kinds-and-props.md)

- **A Task's status changes by `POST /v1/nodes/{id}/done`, `/wontdo` and
  `/reopen`,** each with `If-Match`.
- **A When is the one exception to "a time is whole milliseconds".** A date
  or time the user sets in props is a string in one of three forms: a date
  `2026-12-01`, a local time `2026-12-01T15:00`, a moment
  `2026-12-01T20:00:00Z`. The server checks it, stores it as given, and never
  converts or compares it. A time the server sets stays milliseconds.
- **The forms are fixed:** a fourth would break a client that reads the three.
- **Four codes more:** `props_too_large` (413); `not_a_task`, `wrong_status`
  and `status_fixed` (409).
