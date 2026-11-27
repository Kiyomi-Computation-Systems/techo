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

## Amendment, 2026-11-26: links

Status: accepted (owner, 2026-11-26, as slice 5b's K1, K2, K6 and K7)
Plan: [slice 5b](../2026-11-26-slice-5b-links.md)

1. **Three link types, fixed on the server:** `related`, `mentions`, `blocks`.
   The code's list is the truth. A new one is a release; one once shipped
   stays.
2. **A link is directed and stored once,** and read from either end. There is
   one per source, type and target, and none from a node to itself.
3. **Both ends are live nodes of one account.** Only the code keeps it so: the
   foreign keys take a purged row, a self link and another account's owner.
4. **No link is made to or from a trashed node.** One is removed whatever the
   states. Trash and archive leave links as they are, and a list shows them
   with the other node's state.
5. **A purge removes the node's links, both ways.** Links do not block it, and
   nothing caps how many a node has.

## Amendment, 2026-11-27: each kind's props

Status: accepted (owner, 2026-11-27, as slice 6's P2 to P5, P8, P9 and P13)
Plan: [slice 6](../2026-11-27-slice-6-kinds-and-props.md)

1. **Each kind has a fixed set of props,** checked before any write, stored in
   one canonical form of at most 4,096 bytes. This replaces "props must be
   `{}`" in the first amendment.
2. **Props only grow.** A member is only ever added, optional, with a default,
   last in its object. None is removed, renamed or made required, and no
   value's rule is tightened: an old snapshot must still restore, and an old
   client must be able to send back what it does not know.
3. **A Project and a Journal have none.** **A Note** may have `at`, a When.
   This replaces point 6's "carries a timestamp": a Journal's Note need not.
4. **A Task** has `status`, `closed`, `deadline` and `scheduled`. One stored
   before this, as `{}`, reads as `TODO`: no migration.
5. **A Contact is a subset of JSContact (RFC 9553),** its names and shapes
   exactly: `kind`, `name`, `organizations`, `titles`, `emails`, `phones`,
   `addresses`, `anniversaries`, `links`, `onlineServices`, `speakToAs`. This
   settles point 8. Techo refuses a member it does not know, so it is no
   JSContact processor. A country code is two capitals, not checked further.
6. **The cap is raised when real use asks.** Past about 8 KiB the fix is a
   migration that puts `props` last in `nodes`, or in its own table.
