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
  comes from `mktemp`, never from `$$`. A link is made with `ln -sn` and renamed
  into place with the flag `scripts/mv-no-follow-flag` finds: GNU's `mv -T` or BSD's
  `mv -h` (2026-11-24; it was `ln -sT`, which macOS does not have).

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

## `rm -rf` stops at a directory it may not write

- **Expected:** `make clean` removes `build/`, whatever is in it.
- **Happened:** a probe left a directory with its write permission taken away, and
  `rm -rf build` failed on each file in it with "Permission denied".
- **See it again:** `mkdir -p d/ro && touch d/ro/f && chmod a-w d/ro && rm -rf d`.
- **Rule:** `clean` runs `chmod -R u+w` first. A probe that takes a permission away
  gives it back before it ends.

## A variable on make's command line does nothing to a path the recipe spells out

- **Expected:** `make clean BUILD_DIR=/tmp/scratch` removes the scratch directory.
- **Happened:** the recipe was `rm -rf build`, so it removed the real `build/`, and
  with it two other agents' work in progress.
- **See it again:** `git show f1d5b44:Makefile | grep -n 'rm -rf build'`.
- **Rule:** before a test runs a target that deletes, it runs it with `make -n` and
  checks the command names the scratch path (`tests/check-makefile.sh`).

## `number->string` writes hex in capitals

- **Expected:** `(number->string 244 16)` is `"f4"`.
- **Happened:** Chez answers `"F4"`. A test that compared a hash with Python's
  lowercase hex failed on case alone.
- **See it again:** `(number->string 244 16)` at a Chez prompt.
- **Rule:** hex that is compared, stored or hashed is lowercased on purpose. A key's
  hash is taken over its text (slice 3's D3), so one capital letter is another key.

## Chez does not evaluate arguments left to right

- **Expected:** `(append (list (act!)) (list n))` reads `n` after `act!` has changed it.
- **Happened:** it answered `(acted 0)`: `n` was read first. A test that did an action
  and read a counter in one call compared against the count from before.
- **See it again:** `(define n 0) (define (act!) (set! n (+ n 1)) 'acted)`, then
  `(append (list (act!)) (list n))`.
- **Rule:** bind an action's result with `let` or `let*` before reading what it
  changed.

## `parameterize` does not work on `(rnrs)`'s `current-output-port`

- **Expected:** `(parameterize ((current-output-port p)) …)` sends output to `p`.
- **Happened:** "incorrect number of arguments". `(rnrs)`'s `current-output-port` is
  a plain procedure of no arguments. Chez's own is the parameter.
- **See it again:** import `(rnrs)` and only `parameterize` from `(chezscheme)`, then
  run the form above.
- **Rule:** to capture output, import Chez's `current-output-port` under another
  name and parameterize that (`tests/http-support.sls`, `capture-output`).

## Chez's `map` does not go left to right

- **Expected:** `(map (lambda (i) (start-call! i)) '(1 2 3 4 5 6 7 8))` starts the
  calls in order.
- **Happened:** they started as 7 8 5 6 3 4 1 2. A test that queued eight jobs with
  `map` queued them in that order.
- **See it again:** `(map (lambda (i) (display i) i) '(1 2 3 4 5 6 7 8))`.
- **Rule:** never run side effects through `map`. Use `for-each` or a named `let`.
- **A call's arguments are the same** (slice 5b's routes task; reproduced):
  `(append (say 1) (say 2) (say 3))` ran 3, 2, 1, while `(list ...)` ran 1, 2, 3
  in the same program. R6RS fixes no order. A test that made requests as
  arguments ran its reads before its writes. Sequence them with `let*`.

## `#\xe9;` starts a comment

- **Expected:** `(list #\xe9;)` is a list of one character, as `"\xe9;"` is a string
  of one.
- **Happened:** "unexpected end-of-file reading list". The character is `#\xe9`, and
  the semicolon comments out the rest of the line.
- **See it again:** a program whose body is `(write (list #\xe9;))`.
- **Rule:** the semicolon belongs to the escape only inside a string. Write a
  character as `#\xe9` or `(integer->char #xe9)`.

## A program that imports `(rnrs)` cannot define `fields` or `port?`

- **Expected:** `(define (fields n) n)` is a new procedure.
- **Happened:** "multiple definitions for fields in body". `(rnrs)` exports `fields`
  (for `define-record-type`) and `port?`.
- **See it again:** `(import (rnrs))` then `(define (fields n) n)`.
- **Any name `(rnrs)` exports does it:** `real?` in a program, `member` in a
  library, and my own probe's `log` (slices 5b and 6; reproduced).
- **Rule:** pick another name, or import `(rnrs)` with `except`.

## `get-bytevector-all` on an empty file answers the eof object

- **Expected:** an empty bytevector.
- **Happened:** the eof object, and `bytevector=?` on it raised.
- **See it again:** `(call-with-port (open-file-input-port "an-empty-file")
  get-bytevector-all)`.
- **Rule:** test `eof-object?` before comparing a file's bytes.

## `(file-options no-fail append)` empties the file at every open

- **Expected:** opening a file with `no-fail append` adds to what is there.
- **Happened:** each open emptied it first. A child that reported a number after
  each batch held only its last number, and for a moment, between the open and the
  write, nothing. A kill in that moment left an empty report, and three integration
  tests failed: once in a while locally, and once in CI (slice 3b's last pull
  request).
- **See it again:** open a file three times with those options, writing a line each
  time, and read it: one line.
- **Rule:** to add to a file, say `(file-options no-fail no-truncate append)`.
- **How it was found:** the suite printed only a failing test's name. It now prints
  what it expected and what it saw, and six copies of it pinned to two cores
  (`taskset -c 0,1`) showed the failure in one run.

## A closure does not hold a variable it only names

- **Expected:** a mutant that puts a request into a job's closure, as
  `(begin req ...)`, is caught by the test that walks the closure for it
  (`reaches?`).
- **Happened:** the mutant survived. Chez's optimizer drops a reference whose
  value is not used, so the closure never held the request (slice 4, task 3).
- **See it again:** `(lambda (y) (begin extra (+ y 1)))` against
  `(lambda (y) (if (eq? (car extra) 'never) 0 (+ y 1)))`, each walked with
  `reaches?` for `extra`'s value: `#f`, then `#t`.
- **Rule:** a mutant that tests what a closure holds must use the value.

## A column behind a large text costs a walk of the text's pages

- **Expected:** a list that does not select `body` is cheap however large the
  bodies are.
- **Happened:** with 100 rows of 1 MiB, reading `revision` and `created` took
  17 ms when they came after the body in the table, and under 1 ms when the body
  was last (slice 4's plan review). SQLite walks a row's overflow pages to reach
  a later column. `ALTER TABLE ADD COLUMN` always adds behind.
- **A probe can miss it:** the integers 0 and 1 are kept in the row's header and
  cost nothing to read. Store real values.
- **Rule:** a large column is the table's last, and a table that will grow has
  none.

## A variable set on the host does not reach the Guix container

- **Seen:** `TECHO_NODES_MODEL_SEED=17 scripts/guix-env make test ...` ran the
  whole model suite, not the replay (slice 4b's model task). Reproduced:
  `FOO=17 scripts/guix-env sh -c 'echo ${FOO:-unset}'` prints `unset`.
- **A probe can miss it:** nothing fails. The suite runs with its defaults and
  passes.
- **Rule:** set it inside: `scripts/guix-env sh -c 'FOO=17 make test ...'`.

## A measurement in `:memory:` is not one of the server

- **Seen:** a purge of 3 MiB of snapshots took 1 ms in `:memory:`; of 200 MiB on
  a file in WAL, 390 ms, and it left a `-wal` of 211 MB (slice 4b's plan
  review). This SQLite is built with `SECURE_DELETE`, and a commit to a file is
  synced.
- **Rule:** measure a write on a file opened by `open-techo-db`, at the largest
  size the limits allow.

## A recursive query can be driven from the wrong table

- **Seen:** all descendants of 11,111 nodes took 57 s written `FROM nodes n JOIN
  down ON n.parent = down.id`, and 5 ms written `FROM down CROSS JOIN nodes n
  WHERE n.parent = down.id` (slice 5a's probe). The walk up took 375 ms a walk
  written `FROM up JOIN nodes n ON n.id = up.id WHERE n.owner = ?`, and 0 ms
  with `CROSS JOIN` (its plan review). SQLite read every node of the owner at
  each step.
- **A probe can miss it:** one extra term (`n.parent IS NOT NULL`) made my first
  walk fast by luck. And a cap on the depth hides nothing: the slow one answers
  the same rows.
- **Rule:** put the recursive table first with `CROSS JOIN`, and hold the plan
  with a test.

## Parsed JSON: null is a symbol, false is `#f`, `{}` is `'()`

- **Seen:** through circuit's reader (jsonparse), `{"parent": null}` reads as
  `(("parent" . null))`, `{"parent": false}` as `(("parent" . #f))`,
  `{"parent": {}}` as `(("parent"))` and `{}` as `()` (slice 5a's pure task;
  reproduced with `build/task5a-2/probe-json.sps`).
- **What it breaks:** `(null? v)` takes `{}` for JSON null. `(and m (cdr m))` and
  `(if v ...)` cannot tell `false` from a member that is not there.
- **Rule:** find a member with `assoc` and keep the pair. Test its value with
  `(eq? v 'null)`, never `null?`, and never by truth.

## SQLite can pass over the index made for a statement

- **Seen, three ways,** on a real file with no `sqlite_stat1` (slice 5b's
  probes, `build/probe-5b/p2.sps` and `p3.sps`; its plan review's
  `build/review-5b/plans.sps`, rerun):
  - `DELETE FROM links WHERE owner = ? AND target = ?` searched the primary
    key by owner alone: 28 ms for five rows, under 0.1 ms with
    `INDEXED BY links_target`.
  - A page of one type's backlinks joined to `nodes` did the same: 28 ms
    against 0.05 ms. Without the join it chose well.
  - With `type = ?` and `(type, source) > (?, ?)` both in, the range left the
    search: 39 ms a page against 0.47 ms with `source > ?` alone.
- **Naming an index where it does not fit is as bad:** `INDEXED BY
  links_target` on a read by source sorts in a temp b-tree.
- **A timing can miss it:** on a dense node the wrong plan was fast. A fresh
  file of five nodes shows the wrong plan, so a test can hold it.
- **A plan's words change with SQLite's version:** a delete by `links_target`
  reads `USING INDEX` in 3.53 and `USING COVERING INDEX` in 3.37.2 and 3.45.1,
  and the test that held the line whole failed on CI's 3.45.1 (slice 5b's
  first CI run; seen again with a 3.45.1 built by `guix shell
  --with-source=sqlite=<its tarball>`). The search and its terms were the same.
- **Rule:** hold the plan's `SEARCH` line, whole, by a test, for every
  statement on a table with two indexes. `ANALYZE` mends some; nothing runs it.

## `INSERT OR IGNORE` hides more than a duplicate

- **Seen:** with a null in a `NOT NULL` column, `INSERT OR IGNORE` raised
  nothing and `changes()` was 0, as for a row already there
  (`build/review-5b/ignore.sps`, rerun). A foreign key and a `STRICT` type
  still raised. `ON CONFLICT (...) DO NOTHING` raised on the null.
- **Rule:** look for the row first, then a plain `INSERT` that must make one.

## A table with no end passes its checks when it is empty

- **Seen:** `machine-problems`, told the table has no end, answers no problem
  for a table of no rows (slice 6's task 2; reproduced with
  `build/task6-2/probe-empty.sps`). A test of "no problems" then holds
  nothing.
- **Rule:** beside the check, count the rows.

## Chez drops a pure call whose result is unused

- **Seen:** `(let ((p (list? v))) ...)` with `p` unused cost 0 µs on a list of
  a million; with `p` used, 2.3 ms (slice 6's task 1; reproduced with
  `build/task6-1/probe/unused.sps`).
- **What it breaks:** a mutant that adds a slow call and ignores its answer
  changes nothing, and is "caught" by no test for the wrong reason.
- **Rule:** a mutant uses what it computes.

## An opaque record hides what it holds from the job tests

- **Seen:** `reaches?` in `tests/http-support.sls`, which looks for a request's
  values inside a job's closure, cannot look inside an opaque record: Chez's
  inspector calls one `simple`, and `record?` answers `#f` for it (slice 6's
  routes task; reproduced with `build/task6-3/probe/opaque.sps`). A Task's
  Draft is opaque.
- **What it breaks:** "the parsed JSON never reaches a job" holds for what is
  inside a Draft only by reading the code.
- **Rule:** such a test names what it can see: here, that the job holds the
  Draft and never the props member as read.

## `number->string` writes hex in capitals

- **Seen:** `(number->string 254 16)` is `"FE"` (slice 6's integration task;
  reproduced). The server writes an id in lower case, so a test id built from
  a hex number of 10 or more never equals the answer's.
- **Rule:** `string-downcase` an id built that way before comparing it.

## Lowercasing a normalised string leaves it not normalised

- **Seen:** `(string-downcase (string-normalize-nfkc "W\x30A;"))` is `w` and
  U+030A, and normalising that gives `ẘ` (U+1E98): Unicode has `ẘ` and no
  capital of it (slice 7a's plan review; reproduced with
  `build/verify-7a/v.sps`). A tag folded once and folded again differed for
  up to 0.2% of generated strings.
- **Rule:** normalise, lowercase, normalise again. Hold "folding twice is
  folding once" by a test over generated strings.

## Normalising can grow a string 18 times

- **Seen:** U+FDFA becomes 18 characters under NFKC. Two million of them took
  2.5 to 7.5 s to fold (the same review; reproduced).
- **Rule:** bound a string's length before normalising it, not after.

## A `+` in a query is a space

- **Seen:** `?tag=a+b` arrives from circuit's params as `a b`, and `?tag=c++`
  as `c` and two spaces (the same review's `build/review-7a/query.sps`;
  rerun). Bad UTF-8 in a percent sequence arrives as U+FFFD, not as an error.
- **Rule:** a guide that puts free text in a query says to percent-encode it,
  `+` as `%2B`.

## `(chez-sqlite3)` exports `step!` and `changes`

- **Seen:** a library that imports it and defines `step!` fails with
  "multiple definitions" (the same review; both names checked).
- **Rule:** name nothing in the store `step!` or `changes`.

## jsonparse writes a list as an object

- **Seen:** `(json->string '())` is `"{}"`, an alist member whose value is
  `'()` is written `{}`, and a list of strings raises (slice 7a's pure task;
  reproduced with `build/verify-7a/j.sps`). An empty list of tags would read
  as an empty object.
- **Rule:** a JSON array is a vector. Turn a list into one before it reaches
  the writer, the empty one too.

## A raise caught inside a write job commits what ran before it

- **Seen:** `purge-node!` deletes, then checks the revision and raises on a
  stale one. A job that catches that raise and returns is committed: the
  snapshots were gone for good (slice 7a's store task; reproduced with
  `build/task7a-2/caught-commits.sps`). No route catches inside a job; a test
  did.
- **Rule:** a job never catches a store procedure's raise and returns. A test
  that looks inside a job after a raise raises again, so the job rolls back.

## Two runs of one suite in one directory break each other

- **Seen:** `test-node-store.sps` keeps its files in `build/test-node-store/`
  and deletes them at its start. A second run beside the first failed 110 of
  280 (the same task: a mutant run beside another agent's `make test`).
- **Rule:** a mutant run beside any other run gets its own working directory,
  with the library path made absolute.

## A STRICT TEXT column takes an integer, as text

- **Seen:** inserting the integer 1 into a `TEXT` column of a `STRICT` table
  stores `"1"`: STRICT converts what converts without loss, and raises only
  for what does not (slice 7a's routes task; reproduced with
  `build/task7a-3/strict-converts.sps`). A snapshot's `tags` holding a
  number, which no write can make, would restore as the tag `"1"`.
- **Rule:** STRICT is no check of a value's JSON type. Where the type
  matters, check it: `json_type`, or the code.

## An older SQLite sorts a join that needs no sort

- **Seen:** the filter by tags joins `node_tags` once a tag, each join
  `CROSS JOIN`, ordered by the first tag's key. SQLite 3.53 walks it in
  order. SQLite 3.45.1 added `USE TEMP B-TREE FOR ORDER BY` to two of the
  thirty statements, `nodes-tagged-10` and `nodes-tagged-top-9`, and to no
  other: it would read every match before the first 51 (slice 7a's first CI
  run; reproduced with a 3.45.1 built in `build/ci-sqlite/`). `CROSS JOIN`
  fixes the order of the tables, not the index of each: with two indexes to
  choose from at each of ten tables the planner lost track of the order.
  `EXISTS` in place of the joins did not cure it.
- **Rule:** a statement that joins many tables and must come out in order
  names each table's index with `INDEXED BY`. Its plan is then the same on
  every SQLite, and its plan test holds one plan, not a choice.

## One below U+E000 is a surrogate

- **Seen:** a test of a range's edges took the code point one below U+E000,
  U+DFFF. `integer->char` raises for a surrogate, and in a suite's top level
  the suite dies with no test named (slice 7a's last task; reproduced in the
  container).
- **Rule:** the code point below the private-use area is U+D7FF. A sweep of
  every character skips U+D800 to U+DFFF.

The siblings' traps apply wherever Techo touches the same ground. Read them there:

- chez-sqlite3: `.plans/traps.md`
- chez-libuv: `AGENTS.md`, "Traps this repo has already hit"
- SRFI-64's: Techo's own `AGENTS.md`, "Testing & mutation discipline"
