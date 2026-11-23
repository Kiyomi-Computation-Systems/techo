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

The siblings' traps apply wherever Techo touches the same ground. Read them there:

- chez-sqlite3: `.plans/traps.md`
- chez-libuv: `AGENTS.md`, "Traps this repo has already hit"
- SRFI-64's: Techo's own `AGENTS.md`, "Testing & mutation discipline"
