# 0007: Behaviour is modelled as transition tables in Scheme, verified three ways

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §6

## Context

- The owner wants the API and its data handling modelled as state machines, planned up
  front and well documented.
- A diagram in a document drifts from the code.
- `AGENTS.md` asks for a functional core and an imperative shell.

## Decision

1. **A machine is data:** a table of `(state event next effects)` rows, in Scheme.
2. **A pure step function** reads the table: `(step state event)` gives the next state
   and the effects to perform. The shell performs them.
3. **The first machines:** a node's lifecycle (active, archived, trashed, purged); a
   task's status; an API key's lifecycle; the versioned write.
4. **Three layers of verification:**
   - **the table itself:** every state reachable, no two rows for one state and event,
     no dead end that was not meant. Exhaustive, since a table is finite;
   - **generated diagrams:** the documents' diagrams are rendered from the table;
   - **model-based tests:** random event sequences run against the real handlers and
     SQLite, and are compared with the step function.
5. **TLA+ is optional,** and only for the multi-client conflict protocol.

## Consequences

- A small table library comes first, in the slice that has the first machine.
- The same approach was offered to chez-http-server for `await-outside`.

## Amendment, 2026-11-24: a table may have no end

Status: accepted (owner, 2026-11-24, with slice 3's D5)

A key's lifecycle never ends: a revoked key is still checked and still refused.
`(techo machine)` called every state of such a table a dead end.

- **`machine-problems` takes `#f` for its terminal states to mean "no end, on
  purpose".** The dead-end check is skipped; every other check runs.
- **An empty list is still checked,** so forgetting the terminals is still caught.

## Amendment, 2026-11-25: the node's lifecycle

Status: accepted (owner, 2026-11-25, as slice 4b's L1, L2, L5 and L8)
Plan: [slice 4b](../2026-11-25-slice-4b-node-lifecycle.md)

- **The states are `active`, `archived`, `trashed` and `purged`.** `purged` is
  the one end, and no client sees it.
- **Archive and trash can be undone. A purge cannot.** Untrash always lands on
  `active`. A purge is allowed only from `trashed`.
- **A trashed node takes no write.** An archived one does.
- The table is [machines/lifecycle.md](../machines/lifecycle.md).
- **Two tables answer one request through one pure function,** which takes what
  was found, the state and the event. Stale is answered before the state, and
  the state before the kind.

## Amendment, 2026-11-26: a move in the lifecycle

Status: accepted (owner, 2026-11-26, as slice 5a's T8)
Plan: [slice 5a](../2026-11-26-slice-5a-tree.md)

- **The lifecycle's table gains `move`,** refused for a trashed node, and
  `move-children`, allowed in every state.
- **The one function takes two facts more:** the verdict on the new parent, and
  whether the node has children. The order is: stale, the state, the parent,
  the children.

## Amendment, 2026-11-26: links in the lifecycle

Status: accepted (owner, 2026-11-26, as slice 5b's K6)
Plan: [slice 5b](../2026-11-26-slice-5b-links.md)

- **The lifecycle's table gains `link`,** refused for a trashed node, and
  `unlink`, allowed in every state. They are not among the events
  `node-command` answers.
- **A second pure function, `link-command`, answers a link's request:** from
  the two ends' states, the event, and whether the link is there. It asks the
  lifecycle's table of each end. Both 404s come before any 409, and a link
  that is there is kept before a state is asked.
- **The handler performs the command it names,** and reads whether the link is
  there before it writes: the write's own count decides no answer.

## Amendment, 2026-11-27: the task's table

Status: accepted (owner, 2026-11-27, as slice 6's P7)
Plan: [slice 6](../2026-11-27-slice-6-kinds-and-props.md)

- **A Task's status is a table:** `TODO`, `DONE`, `WONTDO`, by `done`,
  `wontdo` and `reopen`. Every move between two different statuses is allowed.
  It has no end. It is [machines/task.md](../machines/task.md).
- **A third pure function, `task-command`, answers a transition.** It asks
  `node-command` as for a replace, then the kind, then this table: 404, 412,
  `wrong_state`, `not_a_task`, `wrong_status`.

## Amendment, 2026-11-27: a retag in the lifecycle

Status: accepted (owner, 2026-11-27, as slice 7a's G8)
Plan: [slice 7a](../2026-11-27-slice-7a-tags.md)

The lifecycle's table gains one event, `retag`: a rename or a removal of a
tag reaching a node. It is allowed in `active`, `archived` and `trashed`, and
leaves the state as it is. A purged node has no tags, so that cell cannot
happen. `node-command` does not answer it, as it answers no link event. The
store's list of states a step may touch is held equal to the table's by a
test.
