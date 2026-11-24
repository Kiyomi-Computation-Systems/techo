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
