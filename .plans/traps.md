# Traps

Ways this project has gone wrong, each reproduced before it was written down. A trap
has: what was expected, what happened, how to see it again, and the rule that avoids
it.

## `diff -r` fails on a dangling symbolic link

- **Expected:** `diff -rq` of a fetched tree against its archive's own files answers
  nothing when they are the same.
- **Happened:** it printed `No such file or directory` and exited 2 on a correct tree.
  threading 0.1.1's Akku archive holds
  `tests/fixtures/imports/litter/.#threading.sls`, an Emacs lock file: a link to
  nothing. `diff` follows links.
- **See it again:** make two directories, each with `ln -s nowhere l`, and run
  `diff -rq a b`. It exits 2. With `--no-dereference` it exits 0.
- **Rule:** a comparison of fetched trees uses `diff -rq --no-dereference`, as
  `scripts/fetch-akku-lock` does. circuit's copy of that script lacks the flag.

## Two `make` runs at once broke each other's library links

- **Expected:** `make test` in one shell and `make deps` in another both pass.
- **Happened:** suites died with `library (srfi :64) not found`, and `make deps` failed
  with `rm: cannot remove 'build/scheme-libs/srfi': Directory not empty`. The step that
  links chez-srfi into `build/` deleted the whole directory first, then linked it
  again, on every run.
- **See it again:** restore `rm -rf $(SRFI_LIBS)/srfi` at the head of `link-srfi`, loop
  `make deps` forty times in the background, and run `make test` twelve times beside
  it. Eleven of twelve failed.
- **The first fix failed too.** It named each new link `.tmp.$$.NAME`. Every
  `scripts/guix-env` container counts PIDs from 1, so two runs chose the same name:
  `scripts/guix-env sh -c 'sh -c "echo \$\$"'` prints `2` every time. Worse, `ln -s`
  onto a name that is already a link to a directory makes the link *inside* that
  directory, which here was the fetched chez-srfi tree.
- **Rule:** a step that every run repeats never clears shared build output. It keeps
  what is already right and renames each new piece into place. A temporary name
  comes from `mktemp`, never from `$$`. A link is made with `ln -sT`.

## A shallow checkout has no tags

- **Expected:** `git rev-parse v0.1.2^{commit}` resolves in a submodule that CI checked
  out.
- **Happened:** it fails. `actions/checkout` fetches a submodule with `--depth=1`: the
  pinned commit and no tags.
- **See it again:** clone a superproject with `--depth=1`, run
  `git submodule update --init --depth=1`, then `git -C vendor/NAME tag`. It lists
  nothing.
- **Rule:** a pin is a full commit SHA, with its tag in a comment.

## A benchmark that times `fsync` measures everything else writing to the disk

- **Expected:** a commit's worst time on a quiet-looking host describes SQLite.
- **Happened:** worst commits of 60 ms, 15 s and 31 s in three runs. The host was
  unpacking a download, and each run began by copying a 950 MB database. On the
  container's memory-backed `/tmp` the same benchmark's worst commit was 25 ms.
- **See it again:** `cat /proc/pressure/io` while the benchmark runs. A `full avg60`
  far above zero means the disk is busy with someone else's work.
- **Rule:** before timing anything that syncs, read `/proc/pressure/io`, run `sync`
  after any large copy, and run once on memory-backed storage to split SQLite's cost
  from the disk's.

## A `;` inside a string is not a comment

- **Expected:** stripping `;` to the end of each line removes a manifest's comments.
- **Happened:** chez-http-server's manifest has a `;` in its description string. The
  strip ate the string's closing quote, and `check-manifest-deps` read no `depends` at
  all.
- **See it again:** `printf '(x "a ; b")\n' | sed 's/;.*//'` prints `(x "a `.
- **Rule:** skip comments in the same pass that tracks strings, never before it.

## `equal-hash` reads only the start of a value

- **Expected:** a hashtable made with `equal-hash` spreads large, distinct values
  across its buckets.
- **Happened:** Chez's `equal-hash` stops after about 20 pairs, or 5 levels of nesting.
  Values that differ only past that all hash alike, so every lookup walks one bucket.
  The explorer's table of worlds crawled.
- **See it again:** hash `(append (make-list 40 'q) (list n))` for n from 0 to 999:
  one distinct hash. The same for `n` nested six lists deep.
- **Rule:** a hashtable keyed on deep structures gets a hash of its own. `explore`
  takes one as its fifth argument.

## `pkill -f` kills the shell that runs it

- **Expected:** `pkill -f test-machine.sps` kills only the hung suite.
- **Happened:** the calling shell's own command line holds the pattern, so it was
  killed too, with exit 144, and the rest of the command never ran.
- **See it again:** `sh -c 'pkill -f some-unique-word; echo still here'` prints
  nothing.
- **Rule:** kill by process id, from `pgrep` or `ps`.

## A statement a job leaves open outlives its transaction

- **Expected:** after `ROLLBACK` answers ok and `in-transaction?` says no, the
  connection is clean for the next job.
- **Happened:** a statement stepped once and never finished keeps its read snapshot.
  Every later read on that connection saw the old rows, in and out of a transaction.
  On a writer, every later `COMMIT` was refused as busy, "SQL statements in progress".
- **See it again:** `prepare-statement` a `SELECT`, `step!` once, `ROLLBACK`, commit a row from another
  connection, and count on the first. chez-sqlite3's traps record both halves.
- **Rule:** a job gets the doorway's handle, never the connection (ADR-0013). The
  handle's three procedures finish their statement on every way out.

## SQLite can end a transaction and raise in the same call

- **Expected:** a call that raises leaves the transaction as it was.
- **Happened:** `INSERT OR ROLLBACK` on a conflict raised a constraint error with the
  transaction already rolled back. A job that caught the raise and wrote on wrote in
  autocommit: its second half was committed alone. A column declared `UNIQUE ON
  CONFLICT ROLLBACK` does it with a plain `INSERT`, and so do an interrupted write
  and a full disk.
- **See it again:** `BEGIN IMMEDIATE`, insert A, `INSERT OR ROLLBACK` a duplicate
  under a `guard`, insert B. Another connection sees B and not A.
- **Rule:** look at `in-transaction?` on every way out of a call, a raise too. The
  handle does (ADR-0013).

## A `PRAGMA` run inside a transaction can outlive it

- **Expected:** what a job does is undone by its `ROLLBACK`.
- **Happened:** `PRAGMA query_only = 1`, `locking_mode = exclusive` and
  `busy_timeout = 0` each stayed on the connection, and `user_version = 99` was
  committed with the job. Every later write then failed, one of them as "busy".
- **See it again:** `BEGIN IMMEDIATE`, `PRAGMA query_only = 1`, `ROLLBACK`, then
  `BEGIN IMMEDIATE` again on the same connection: it raises `readonly`.
- **`EXPLAIN` does not stop it.** SQLite applies a flag pragma while it prepares the
  statement, so `EXPLAIN PRAGMA query_only = 1` sets the flag too.
- **Rule:** a job runs no `PRAGMA`. The handle refuses the words a migration may not
  begin with, `EXPLAIN` among them, before the statement runs.

## A read-only connection that closes last leaves the `-wal`

- **Expected:** when the last connection closes, SQLite checkpoints and removes the
  `-wal` and `-shm` files.
- **Happened:** only a read-write connection does that. With the writer closed first
  and a reader last, both files stayed, at full size, until the next read-write open
  and close. A read-only open also creates them when they are missing, and fails in
  a directory it cannot write.
- **See it again:** on a WAL file, open a read-write and a read-only connection,
  write a row, close the read-write one, then the read-only one, and list the
  directory.
- **Rule:** readers stop before the writer. A test that looks for "no `-wal`" looks
  before it opens the file again.

## A read-write open of a file you may only read succeeds

- **Expected:** opening a read-only file read-write fails.
- **Happened:** SQLite fell back to a read-only connection without a word. `BEGIN
  IMMEDIATE` succeeded on it too. Only the first write raised `readonly`.
- **See it again:** `chmod 444` a database in a directory you can write, open it
  read-write, `BEGIN IMMEDIATE`, then insert.
- **Rule:** a connection that must write proves it at its set-up, with a write it
  rolls back.

## `exit` does not wait for threads

- **Expected:** `(exit n)` on the main thread lets other threads finish, or at least
  their tear-downs run.
- **Happened:** the process ended at once with status n, two threads still running.
  A worker's write would be cut and its connection never closed.
- **See it again:** fork two threads that sleep, then `(exit 7)`: status 7, at once.
- **Rule:** stop every worker before `exit`. `serve`'s loop calls `exit` only when its
  table says "end".

## Lines written from two threads run together

- **Expected:** a line written to standard output from a worker thread arrives whole.
- **Happened:** each `put-string` is whole, but a line built from several calls, or a
  string and then `newline`, was cut by another thread's: about a third of 80,000
  lines ran together.
- **See it again:** four threads, each writing 20,000 lines to one port as a string
  and then a `newline`. Count the lines longer than one line's text.
- **Rule:** a log line is one `put-string`, newline included, and the server's lines
  are written from the loop's thread.

The siblings' traps apply wherever Techo touches the same ground. Read them there:

- chez-sqlite3: `.plans/traps.md`
- chez-libuv: `AGENTS.md`, "Traps this repo has already hit"
- SRFI-64's: Techo's own `AGENTS.md`, "Testing & mutation discipline"
