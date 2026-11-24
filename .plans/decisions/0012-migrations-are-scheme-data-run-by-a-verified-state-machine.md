# 0012: Migrations are Scheme data, run forward only by a verified state machine

Date: 2026-11-23
Status: accepted (owner, 2026-11-23, answering the slice 2 plan's D2 to D5)
Plan: [the slice 2 plan](../2026-11-23-slice-2-migrations.md)

## Context

- A database file outlives the binary that made it. Each binary must know whether a
  file is its own, and at which schema.
- One binary is the server and the CLI (ADR-0009), so there are no files to find at
  run time.
- Several v1 table shapes are still open: the node lifecycle's states, a Contact's
  fields, how tags are stored.
- Two `techo migrate` runs can meet, a run can fail part way, and a run can be killed.
  The owner asked that the process be modelled as a state machine and verified.
- The owner runs SQLite in WAL mode. A file must migrate safely after a long run in
  WAL, an unclean stop included.

## Decision

1. **Tables arrive with the slice that uses them.** Slice 2 ships the machinery and one
   migration, which only marks the file as Techo's. [schema.md](../schema.md) sketches
   every v1 table, each marked decided or open.
2. **Ids are stored as 16-byte blobs.** The API shows the usual text form.
3. **A migration is Scheme data in the binary:** a version, a name and a list of single
   SQL statements, in `(techo migrations)`.
4. **Migrations only go forward.** There is no "down". A migration that fails is rolled
   back by its transaction. To undo one that succeeded, restore a backup.
5. **The version is SQLite's `user_version`,** the number of the last migration
   applied. `application_id` is `0x74656368` ("tech"). There is no bookkeeping table.
   Both are written inside the migration's transaction.
6. **`techo migrate` is a transition table and a pure step function** (ADR-0007). The
   shell is a loop that performs one SQLite call for each command and feeds the outcome
   back. The plan holds the table, its properties M1 to M12 and ML1 to ML3, and what it
   assumes of SQLite.
7. **It is verified in six layers:** static checks on the table; every row driven;
   every small world explored, with two runs, failures and deaths in every order; the
   model's traces replayed on real SQLite; real processes; and a diagram generated
   from the table.
8. **`techo serve` refuses a file that is not current and in WAL.** Its check opens the
   file read-only, and never creates or changes one.
9. **A file that will be refused is only ever opened read-only.** A read-write open and
   close folds a leftover `-wal` into the main file, even of another program's file.
   So the path may not end in a slash: SQLite would open the file while Chez's
   `file-exists?` called it missing, and the read-only look would be skipped.
10. **`migrate`'s connection has foreign keys off,** and checks them with
    `PRAGMA foreign_key_check` before each version is stamped. Every other connection
    has them on.

## Rules

- **A shipped migration is never edited.** A change is a new migration. A test holds
  the shipped list to a recorded copy.
- **A migration's statements are single statements.** None begins or ends a
  transaction, attaches a database, or is a `PRAGMA`. Migration 1's one statement,
  which sets the id, is the exception.
- **Stop the server before migrating.** The server checks the schema only at its
  start.
- **Table conventions:**
  - `STRICT` tables;
  - ids are 16-byte blobs;
  - times are whole milliseconds since 1970, UTC;
  - JSON is text with a `json_valid` check;
  - every index made by `CREATE INDEX` on an owner-scoped table begins with the
    owner. A primary key or a `UNIQUE` column's own index need not;
  - foreign keys are declared.

## Consequences

- The whole schema is not in one place until slice 8. `schema.md` is the map until
  then.
- A shipped migration that was edited is caught by a test, not by the file. A file
  cannot tell which binary migrated it.
- Nothing stops a `migrate` beside a running server. It succeeds, and the server meets
  the new schema at its next read. Slice 2b can close this.
- A file in rollback mode whose writer was killed mid-transaction has a hot journal.
  The read-only look cannot roll it back, so `migrate` and `serve` both refuse it
  until some read-write open has. Techo's own files are in WAL and never reach this.
  The refusal names the case and says what to do; `migrate` does not recover it
  (owner, 2026-11-23).
- The table library `(techo machine)` and the explorer are there for every later
  machine.
- A restored `VACUUM INTO` backup is not in WAL. `techo migrate` converts it, so
  `migrate` is run after a restore.

## Amendment, 2026-11-23: what holds when `migrate` runs beside a server

Status: accepted (owner, 2026-11-23, answering the slice 2b plan's D6)

- **"Stop the server before migrating" stays the rule.** Nothing stops a `migrate`
  that breaks it.
- **What holds then** is ADR-0013's item 6: every job of the server reads
  `user_version` first, inside its transaction, and does not run if it has moved.
- **`forbidden-statement?` is exported** from `(techo migrations)`. The doorway's
  handle refuses the same first words a migration may not use.
