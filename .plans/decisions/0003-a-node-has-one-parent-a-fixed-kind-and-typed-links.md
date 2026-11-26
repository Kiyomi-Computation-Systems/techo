# 0003: Everything is a node, with one parent, one of five kinds, and typed links

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §3

## Context

- The owner wants one generic object that different clients can use, specialised into
  Project, Journal, Note, Task and Contact.
- "Collections" and "moving a node" imply containment. "Graph" implies links between
  any two nodes. These are two different relations.
- A kind decides which properties a node has. Letting clients invent kinds would leave
  the server unable to validate any of them.

## Decision

1. **One table of nodes.** Each has an id, an owner, an author, a kind, a title, a
   body, a content type, JSON props, tags, a parent, a revision and timestamps.
2. **Five kinds, fixed on the server:** Project, Journal, Note, Task, Contact. Props
   are validated per kind.
3. **Containment is a tree.** A node has one parent or none. A move changes it.
4. **Links are separate:** a typed edge between any two nodes.
5. **The server stores no order among siblings.** The client sorts.
6. **A Journal entry is a Note** whose parent is a Journal and which carries a
   timestamp. Several may share a day.
7. **A Task's status is `TODO`, `DONE` or `WONTDO`.** `deadline` and `scheduled` are
   date props, not states.
8. **A Contact starts from vCard's basics:** names, emails, phones, addresses,
   organisation.
9. **Every node is private to its owner in v1.** Owner and author are both stored, and
   are the same account, so sharing can come later without a migration of meaning.

## Consequences

- A new kind is a server release.
- Which kinds may contain which is a rule for slice 5 to write down: a Journal holds
  Notes; a Project holds anything.
- A move must refuse a cycle.

## Amendment, 2026-11-25: what slice 4 decided

Status: accepted (owner, 2026-11-25, as slice 4's D7 and D8)
Plan: [slice 4](../2026-11-25-slice-4-nodes.md)

1. **A node's kind is set when it is made and never changes.** A replace that names
   another kind is refused, 409.
2. **Props must be `{}` until slice 6** decides each kind's.
3. **Another account's node is a missing node:** 404 on every route.
4. **An id is unique across accounts.** So one query has no owner: whether an id is
   in use, which reads the id alone. A create on an id another account holds is
   412. Someone who already knows an id learns it is in use. Accepted.

## Amendment, 2026-11-26: the tree

Status: accepted (owner, 2026-11-26, as slice 5a's T2, T5, T6, T7 and T8)
Plan: [slice 5a](../2026-11-26-slice-5a-tree.md)

1. **Only a Project or a Journal has children.** A Project holds any kind,
   Projects too. A Journal holds only Notes. A Note holds nothing: a Contact
   joins a Note by a link.
2. **A parent is set when a node is made, and changed only by a move.**
3. **A move under itself or a descendant is refused.** A parent may have at most
   63 ancestors. The cap is on the new parent, so a moved subtree can reach
   deeper; every walk has its own cap.
4. **Trashing or archiving a node touches that node only.** Its children keep
   their state. "In the trash if any ancestor is" can be computed on read later,
   with no migration.
5. **A purge is refused while the node has children.** A purged row has no
   parent.
6. **Nothing is made in or moved into a trashed node,** and a trashed node is
   not moved. An archived node is as an active one here.
7. **A parent that is missing and one that is another account's get one
   answer.**
