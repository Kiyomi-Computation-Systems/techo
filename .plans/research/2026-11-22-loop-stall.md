# Loop stall: how long does one SQLite query hold the event loop?

Spike for slice 1 §4 and ADR-0008. Run 2026-11-22. Code: `.plans/research/spike/`. Raw output: `build/spike/` (git-ignored; file names are given beside each table).

## The question and the answer

Techo runs every SQLite query synchronously on the HTTP server's one loop thread. How long does each representative query block it, on a realistic database?

**Answer.** Reads, lists, the change feed, and searches for mid-frequency and rare words stay under 5 ms at every size, with one exception that is not SQLite's: Chez's garbage collector paused the spike for about 7 ms now and then (see "What surprised me"). A search for a word that is in nearly every note, with results ranked, costs 13 ms at medium and 141 ms at large, and while it runs it blocks `/health` for that long (12.8 ms median at medium, 167 ms at large). The same search without ranking costs 0.15 ms at every size. Writes and checkpoints have a median under 10 ms, but their tail is set by the disk's fsync: the worst write at medium was 34 to 141 ms in five runs, and the worst checkpoint was 11 ms to 958 ms across five runs. By the rule below, that last result is over 50 ms: **this goes to the owner**, with the caveat that a bare 1-row commit on this disk had a worst of 28 to 38 ms by itself. A rerun the same day (next section but one) found the cause: the host's disk was busy with other work, and with fsync taken away a write's worst is 25 ms and a checkpoint's is 2 ms.

## Verdict against the thresholds

Rule: worst case at medium size, per operation. Under 5 ms: ADR-0008 stands. 5 to 50 ms: it stands for v1, plan a worker thread. Over 50 ms: stop, bring the numbers to the owner.

"Worst" is the worst of the n timed calls in a run. Several rows have more than one run; all are listed.

| Operation (medium) | Median ms | Worst ms, each run | Verdict |
|---|---|---|---|
| read | 0.074 | 7.5, 7.5 | 5 to 50, but the 7.5 is a GC pause; the query is about 0.1 ms |
| list (100 children) | 0.37 to 0.47 | 8.0, 7.8 | 5 to 50, same GC pause |
| search, common word, ranked | 13.1 to 13.2 | 20.3, 22.4 | 5 to 50 |
| search, common word, unranked | 0.14 | 0.24, 0.89 | under 5 |
| search, mid word (400 docs), ranked | 0.40 to 0.44 | 2.6, 1.0 | under 5 |
| search, rare word (5 docs), ranked | 0.045 | 0.11, 0.09 | under 5 |
| feed (500 changes) | 1.3 | 2.9, 3.3 | under 5 |
| write, synchronous=FULL | 1.6 to 11.4 | 34.0, 141.2, 62.5, 61.3, 63.2 | **over 50 in 4 of 5 runs** |
| write, synchronous=NORMAL | 0.32 to 0.52 | 36.3, 47.3, 35.2, 47.2, 52.6 | 5 to 50, at the edge (one run over) |
| checkpoint, ~1000 frames, FULL | 3.7 to 9.7 | 65.2, 958, 11.1, 21.3, 12.1 | **over 50 in 2 of 5 runs** |
| checkpoint, ~1000 frames, NORMAL | 6.8 to 20.2 | 29.8, 27.6, 20.4, 71.3, 216.8 | **over 50 in 2 of 5 runs** |

Where the runs come from: the first run of each is `bench-medium-cache2000.out`; the second is `bench-medium-cache65536.out` (64 MiB page cache, same everything else); the rest are `repeat-writes-medium-1..3.out`, which I added because the first write numbers surprised me (they are writes and checkpoints only, 2,000 writes and 100 checkpoints each).

My reading, which the owner can overrule: the three worst numbers are fsync stalls on a shared consumer NVMe, not SQLite compute. But the rule is mechanical, and a stall that long on the loop thread is a stall for every request, so I have not softened the verdict.

## Verification: the write and checkpoint tails are the host's disk

Rerun the same day by the lead, with no other agents running. Command: `bench.sps medium 2000 2000 writes-only` on a fresh copy of `medium.db`.

**On the disk** (ext4 on LVM on LUKS on a consumer NVMe), three runs:

| Operation (medium) | Median ms | p99 ms | Worst ms |
|---|---|---|---|
| write, FULL | 7.3, 8.8, 8.6 | 25.7, 1492, 16567 | 60.7, 15636, 31007 |
| write, NORMAL | 0.36, 0.33, 18.6 | 19.9, 85.6, 10673 | 61.8, 156.7, 27923 |
| checkpoint, FULL | 6.8, 5.4 | 19.9, 331 | 50.8, 407 |
| checkpoint, NORMAL | 20.6, 89.7 | 69.2, 622 | 84.1, 636 |

The third run was stopped before its checkpoints. During these runs the host was unpacking a large download: `/proc/pressure/io` read `full avg300=64.97`, and the load average was about 10. Each run also began by copying the 950 MB database, which queues its own writeback ahead of the benchmark's fsyncs.

**In memory** (the container's tmpfs `/tmp`, so fsync costs nothing), two runs:

| Operation (medium) | Median ms | p99 ms | Worst ms |
|---|---|---|---|
| write, FULL | 0.32, 0.32 | 3.75, 3.79 | 26.2, 24.6 |
| write, NORMAL | 0.32, 0.32 | 3.75, 3.77 | 25.0, 26.1 |
| checkpoint, FULL | 0.61 | 1.72 | 1.81 |
| checkpoint, NORMAL | 0.65 | 1.85 | 1.90 |

**How the in-memory runs were made.** `bench.sps` has its path fixed at `build/spike/medium.bench.db`, so that name and its `-wal` were made symbolic links to `/tmp`, which inside the container is a tmpfs:

```sh
ln -s /tmp/medium.bench.db build/spike/medium.bench.db
ln -s /tmp/medium.bench.db-wal build/spike/medium.bench.db-wal
scripts/guix-env sh -c 'cp build/spike/medium.db /tmp/medium.bench.db && $CHEZ --libdirs "$(make -s libdirs):.plans/research/spike/lib" --program .plans/research/spike/bench.sps medium 2000 2000 writes-only'
```

The first in-memory run lacked the `-wal` link, so it has no checkpoint rows. The raw output of this section's runs was not kept: these tables are all there is.

**What this shows.**

- SQLite's own work on a write has a median of 0.3 ms and a worst of about 25 ms. That worst is the same in all four runs, so it is one repeatable event, not noise. It is not yet explained. The two candidates are a Chez collection of an old generation, which must sweep the spike's own 4-million-slot word table, and an FTS5 segment merge inside a commit. To tell them apart: log `(collections)` per sample, then rerun with FTS5's `automerge` at 0.
- Everything above that is the time the disk takes to answer `fsync`. Techo does not control it, and it has no upper bound: a busy disk held one commit for 31 seconds.
- `synchronous=NORMAL` removes the fsync from most commits but not from checkpoints, so it shrinks the tail and does not bound it.
- No clean disk number exists yet. It needs a quiet host, and the database copy flushed with `sync` before timing starts.

**What it means for ADR-0008.** The verdict table above stands as measured, but its over-50 rows measure this host, not SQLite. The real finding is that a commit on the loop thread stalls every request for as long as the disk stalls. That is a case for moving the database to a worker thread (chez-http-server's `await-outside`), and it is the owner's call when.

## The three worst numbers found anywhere

1. checkpoint (PASSIVE, FULL), medium, 64 MiB cache: **957.9 ms** (p99 587 ms over 100). Not reproduced at that size; the four other FULL runs had a worst of 11 to 65 ms.
2. search, common word, ranked, large: **225.8 ms** (64 MiB cache run; 183.9 ms with the default cache; median 141 to 143 ms). Reproduced in both runs.
3. checkpoint (PASSIVE, NORMAL), medium, repeat 3: **216.8 ms** (p99 179 ms).

Also: `/health` under the common-word search load, large: median 167 ms, worst 196 ms.

## Environment

| | |
|---|---|
| CPU | Intel Core Ultra 5 125H, 18 logical processors |
| Memory | 62 GiB; the 2.8 GB large database fits in the OS page cache |
| Disk | Kingston SNV3S500G NVMe (not rotational), ext4 on LVM, `noatime`, scheduler mq-deadline |
| Host load | Shared: other agents were building and testing in the same tree. Load average was 1.0 to 1.7 |
| Run in | the Guix container, `scripts/guix-env` |
| Chez | the container's Chez 10.4.1 (threaded) |
| SQLite | 3.53.1, `libsqlite3.so.0` from the Guix profile |
| Page size | 4096 |
| Pragmas in force | `journal_mode=wal`, `synchronous=FULL` (2) unless a row says NORMAL, `cache_size=-2000` (2000 KiB) unless a table says 64 MiB, `busy_timeout=5000`, `foreign_keys=1`, `wal_autocheckpoint=1000` |

**WAL's default `synchronous` in this build is FULL.** The compile options hold `DEFAULT_SYNCHRONOUS=2` and `DEFAULT_WAL_SYNCHRONOUS=2`; `pragma synchronous` on a fresh connection read 2. (Stock SQLite builds default WAL to FULL too, unless the distribution changes it; some people expect NORMAL.) Both modes are measured below.

Clock: Chez `(current-time 'time-monotonic)`, nanoseconds. Each timed call includes turning the rows into Scheme values. Each operation is warmed with 100 untimed calls first. All timings are on a warm database: the files had just been written, so the OS cache held them.

## FTS5 and JSON: present

`build/spike/check.out`:

```
version: "3.53.1"
fts5: (#("a"))        <- create virtual table t using fts5(title, body); insert; select ... match 'hello'
json: (#(7))          <- select json_extract('{"a":[1,2,{"b":7}]}', '$.a[2].b')
```

The compile options include `ENABLE_FTS5`, `ENABLE_FTS3`, `ENABLE_FTS4`. The JSON functions work and the schema's `check (json_valid(props))` ran on every insert. The brief asked about Ubuntu 24.04's SQLite too (slice plan §4): **not checked**, there is no Ubuntu in this container.

## The throwaway schema

`lib/spike.sls`, `create-schema!`. WAL, foreign keys on.

- `nodes`: `id` 16-byte blob primary key, owner, kind, title, body, content_type, `props` JSON text (`json_valid` check), parent, revision, created, updated. Index `nodes_parent(parent, id)`.
- `revisions`: full snapshot per write, primary key (node_id, revision).
- `changes`: per-owner sequence, primary key (owner, seq), `without rowid`.
- `nodes_fts`: **external-content** FTS5 over title and body (`content='nodes'`), kept in step by three triggers. I chose it over a plain FTS5 table because a plain one stores a second copy of every 2 KB body; and over contentless because contentless cannot return the stored columns and needs the same delete-with-old-values dance. The cost: an update must tell the index the old values, so each write pays a delete plus an insert in the index.
- `nodes_vocab`: an `fts5vocab` view, used only to find which words are common and which are rare.

No obvious index was missing, so there are no before and after numbers: the list query uses `nodes_parent`, the feed uses the `changes` primary key, a read uses the `nodes` primary key.

Data: a seeded xorshift32 generator; a vocabulary of 50,000 made-up words; Zipf(1) skew; bodies about 2,000 characters (about 300 words), titles 3 to 7 words. One owner. One in 200 nodes is a Project and the rest are its children (about 200 each). Every snapshot has its own text; the node holds the last one.

## Fill: time and size on disk

`build/spike/fill.out`. Filled with `synchronous=NORMAL`, 500 nodes per transaction. Sizes are in bytes, read just after the last insert, then after `wal_checkpoint(TRUNCATE)`.

| Size | Nodes | Revisions per node | Revision rows | Fill time | DB file | WAL before truncate | DB file in MB | Pages |
|---|---|---|---|---|---|---|---|---|
| small | 1,000 | 5 | 5,000 | 1.0 s | 27,168,768 | 14,317,032 | 27 | 6,633 |
| medium | 20,000 | 10 | 200,000 | 34.3 s | 953,712,640 | 36,639,192 | 954 | 232,840 |
| large | 200,000 | **2** | 400,000 | 155.6 s | 2,833,989,632 | 28,543,392 | 2,834 | 691,892 |

**Deviation:** large has 2 revisions per node, not 10, as the brief said. Ten would be about 4 GB of snapshots on top of what is here (by my arithmetic from the table, about 9 to 10 GB; I did not build it). The medium database is 954 MB for 20,000 notes of 2 KB: about 4.7 KB per snapshot, more than twice the text. Probably a 2 KB row plus its key does not fit twice on a 4 KB page, so each `revisions` row takes a page of its own; I did not check with `dbstat`. This is a finding for ADR-0004, not a thing I tuned.

## Results

All tables: median, 99th percentile and worst in ms. Default cache (2000 KiB), `synchronous=FULL` except where a row says otherwise. The terms used are in the raw files (`# common terms`, and so on): the common words occur in 100% of notes; the "mid" words in 2% (400 at medium, about 4,000 at large); the rare words in 5 notes at small and medium and **about 90 at large**, because the vocabulary is fixed and a large corpus has no word that rare. A different term is used on each call, rotating through 5 common, 10 mid and 20 rare words.

How many calls: small and medium 2,000 each; large 500 each, except common-word ranked search at large 300 (each is 140 ms); checkpoint 100 each at small and medium and 60 at large, for each of FULL and NORMAL.

What each does:
- read: one node by primary key, all columns.
- list: `where parent = ? order by id limit 100`.
- search: `... from nodes_fts f join nodes n on n.rowid = f.rowid where nodes_fts match ? order by rank limit 50` (ranked, with bm25), and the same without `order by rank` (unranked).
- feed: `where owner = 1 and seq > ? order by seq limit 500`, at a random cursor.
- write: one `with-transaction`: `update nodes ... returning`, insert the snapshot, select the next sequence number, insert the change row; the FTS update happens in the trigger. A new random 2 KB body each time (generated before the clock starts). `wal_autocheckpoint` is at its default of 1000, so some writes include a checkpoint; that is what the tail shows.
- checkpoint: see "What was not measured": I time an explicit `pragma wal_checkpoint(PASSIVE)` on a WAL of about 1,000 frames (the default auto-checkpoint size), not a write that happens to trigger it.

### Small

`build/spike/bench-small-cache2000.out`

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| read | small | 2000 | 0.074 | 0.14 | 7.576 |
| list (100 children) | small | 2000 | 0.345 | 0.473 | 7.901 |
| search common (ranked) | small | 2000 | 0.785 | 0.967 | 1.249 |
| search common (unranked) | small | 2000 | 0.143 | 0.177 | 0.257 |
| search mid (ranked) | small | 2000 | 0.1 | 0.142 | 1.156 |
| search rare (ranked) | small | 2000 | 0.054 | 0.067 | 0.106 |
| feed (500 changes) | small | 2000 | 1.301 | 1.445 | 1.918 |
| write (synchronous=FULL) | small | 2000 | 7.549 | 16.652 | 60.94 |
| write (synchronous=NORMAL) | small | 2000 | 0.311 | 18.676 | 77.076 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | small | 100 | 4.417 | 10.11 | 12.517 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | small | 100 | 9.356 | 16.135 | 17.774 |
# checkpointed frames per checkpoint: min=1000 median=1009 max=1725

### Medium

`build/spike/bench-medium-cache2000.out`

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| read | medium | 2000 | 0.074 | 0.1 | 7.541 |
| list (100 children) | medium | 2000 | 0.472 | 0.646 | 7.996 |
| search common (ranked) | medium | 2000 | 13.161 | 16.875 | 20.342 |
| search common (unranked) | medium | 2000 | 0.138 | 0.173 | 0.237 |
| search mid (ranked) | medium | 2000 | 0.438 | 0.557 | 2.578 |
| search rare (ranked) | medium | 2000 | 0.044 | 0.068 | 0.113 |
| feed (500 changes) | medium | 2000 | 1.306 | 2.199 | 2.87 |
| write (synchronous=FULL) | medium | 2000 | 1.598 | 8.762 | 33.959 |
| write (synchronous=NORMAL) | medium | 2000 | 0.321 | 10.986 | 36.315 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | medium | 100 | 6.018 | 49.872 | 65.16 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | medium | 100 | 20.165 | 28.939 | 29.798 |
# checkpointed frames per checkpoint: min=1000 median=1012 max=1654

### Large

`build/spike/bench-large-cache2000.out`

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| read | large | 500 | 0.075 | 0.327 | 7.515 |
| list (100 children) | large | 500 | 0.527 | 0.88 | 8.144 |
| search common (ranked) | large | 300 | 140.996 | 181.724 | 183.945 |
| search common (unranked) | large | 500 | 0.147 | 0.197 | 0.244 |
| search mid (ranked) | large | 500 | 3.013 | 3.427 | 8.335 |
| search rare (ranked) | large | 500 | 0.406 | 0.494 | 0.514 |
| feed (500 changes) | large | 500 | 1.299 | 1.43 | 1.761 |
| write (synchronous=FULL) | large | 500 | 8.218 | 36.475 | 45.015 |
| write (synchronous=NORMAL) | large | 500 | 0.324 | 45.497 | 48.137 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | large | 60 | 4.369 | 15.82 | 15.82 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | large | 60 | 20.194 | 31.514 | 31.514 |
# checkpointed frames per checkpoint: min=1000 median=1012 max=1647

### Medium and large, 64 MiB page cache

`bench-medium-cache65536.out`, `bench-large-cache65536.out`. Same runs, `cache_size=-65536`.

**medium**

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| read | medium | 2000 | 0.074 | 0.112 | 7.477 |
| list (100 children) | medium | 2000 | 0.372 | 0.617 | 7.835 |
| search common (ranked) | medium | 2000 | 13.107 | 17.099 | 22.353 |
| search common (unranked) | medium | 2000 | 0.147 | 0.297 | 0.889 |
| search mid (ranked) | medium | 2000 | 0.404 | 0.493 | 0.952 |
| search rare (ranked) | medium | 2000 | 0.045 | 0.054 | 0.091 |
| feed (500 changes) | medium | 2000 | 1.312 | 1.549 | 3.264 |
| write (synchronous=FULL) | medium | 2000 | 11.364 | 36.455 | 141.177 |
| write (synchronous=NORMAL) | medium | 2000 | 0.524 | 22.149 | 47.252 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | medium | 100 | 9.668 | 587.244 | 957.93 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | medium | 100 | 9.649 | 26.535 | 27.587 |
# checkpointed frames per checkpoint: min=1000 median=1012 max=1654

**large**

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| read | large | 500 | 0.076 | 0.096 | 7.415 |
| list (100 children) | large | 500 | 0.553 | 0.705 | 8.559 |
| search common (ranked) | large | 300 | 142.594 | 193.682 | 225.829 |
| search common (unranked) | large | 500 | 0.14 | 0.17 | 0.205 |
| search mid (ranked) | large | 500 | 2.544 | 2.783 | 3.016 |
| search rare (ranked) | large | 500 | 0.271 | 0.33 | 0.364 |
| feed (500 changes) | large | 500 | 1.298 | 1.551 | 5.707 |
| write (synchronous=FULL) | large | 500 | 7.678 | 37.814 | 43.142 |
| write (synchronous=NORMAL) | large | 500 | 0.319 | 43.472 | 92.333 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | large | 60 | 4.656 | 17.695 | 17.695 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | large | 60 | 20.871 | 29.505 | 29.505 |
# checkpointed frames per checkpoint: min=1000 median=1012 max=1647

A bigger cache changed nothing that matters: the common-word search is CPU-bound (it scores 200,000 documents), and the write numbers are the disk's.

### Medium writes and checkpoints, three more runs

`repeat-writes-medium-1.out`, `-2.out`, `-3.out`. Fresh copy of the medium database each time, default cache, 2,000 writes per mode and 100 checkpoints per mode.

run 1

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| write (synchronous=FULL) | medium | 2000 | 9.059 | 23.331 | 62.488 |
| write (synchronous=NORMAL) | medium | 2000 | 0.342 | 7.628 | 35.18 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | medium | 100 | 3.797 | 9.424 | 11.056 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | medium | 100 | 9.538 | 19.751 | 20.356 |

run 2

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| write (synchronous=FULL) | medium | 2000 | 7.775 | 19.84 | 61.302 |
| write (synchronous=NORMAL) | medium | 2000 | 0.347 | 17.496 | 47.213 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | medium | 100 | 6.094 | 13.736 | 21.3 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | medium | 100 | 18.954 | 29.427 | 71.325 |

run 3

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| write (synchronous=FULL) | medium | 2000 | 7.76 | 18.788 | 63.156 |
| write (synchronous=NORMAL) | medium | 2000 | 0.336 | 18.597 | 52.57 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=FULL) | medium | 100 | 3.735 | 7.765 | 12.057 |
| checkpoint (PASSIVE, ~1000 frames, synchronous=NORMAL) | medium | 100 | 6.818 | 179.425 | 216.759 |

### The disk alone

`build/spike/fsyncprobe.out`: 5,000 one-row insert transactions in a WAL database with `synchronous=FULL` (no FTS, no 2 KB rows), run twice. This is about as cheap as a durable commit gets on this machine.

| operation | size | n | median ms | p99 ms | worst ms |
|---|---|---|---|---|---|
| 1-row insert commit, FULL (autocheckpoint on) | - | 5000 | 0.981 | 1.974 | 28.144 |
| 1-row insert commit, FULL (autocheckpoint on) | - | 5000 | 0.982 | 4.534 | 38.38 |

`dd bs=4k count=2000 oflag=dsync` (`dd-dsync.out`) wrote 8.2 MB in 2.09 s, about 1.0 ms per synchronous 4 KB write.

So the disk's own floor is about 1 ms per commit, with a worst of 28 to 38 ms in 5,000. A real Techo write is 8 to 10 times the median of that floor in most runs, and in the first medium run it was 1.6 ms. I do not know why that run was fast (see "What surprised me").

## Under load, through a real server

`server.sps` is a circuit app: `GET /health` returns `ok` with no database; `GET /search?q=WORD` runs the ranked FTS query above, synchronously on the loop thread, against a copy of the medium database and then of the large one, and returns the row count. `load.sh` starts it in the container, then:

- **idle**: 500 `GET /health` requests.
- **under load**: a `curl` process requests `/search?n=[1-1000000]&q=WORD` in a tight loop on its own connection (curl's URL globbing, so it is one process on one kept-alive connection). Two seconds later the second client times 500 `/health` requests. Done once with the common word and once with a rare one.

Two ways to time `/health`, so that curl's own cost is visible:

- **curl per request**: a shell loop, one `curl -w '%{time_total}'` process and connection per request. `time_total` starts at the process's first byte of work for the transfer, so it includes the TCP connect but not the process start. The idle row of this kind is the client's own overhead.
- **one curl, kept-alive**: one curl process, `/health?[1-500]`, one connection reused. This is the least client overhead I can get from curl. The idle row is the server's floor.

### Medium database (`load-medium.table`)

| /health client | requests | median ms | p99 ms | worst ms |
|---|---|---|---|---|
| idle, curl per request | 500 | 0.307 | 0.671 | 0.788 |
| idle, one curl, kept-alive | 500 | 0.035 | 0.109 | 0.326 |
| under /search?q=beba, curl per request | 500 | 12.778 | 14.474 | 20.143 |
| under /search?q=beba, one curl, kept-alive | 500 | 16.645 | 18.371 | 22.299 |
| the /search?q=beba requests themselves (as the loop client saw them) | 911 | 16.810 | 19.636 | 26.317 |
| under /search?q=bebakode, curl per request | 500 | 0.235 | 1.054 | 1.163 |
| under /search?q=bebakode, one curl, kept-alive | 500 | 0.092 | 0.202 | 0.398 |
| the /search?q=bebakode requests themselves (as the loop client saw them) | 26852 | 0.098 | 0.357 | 16.549 |

### Large database (`load-large.table`)

| /health client | requests | median ms | p99 ms | worst ms |
|---|---|---|---|---|
| idle, curl per request | 500 | 0.200 | 0.476 | 0.592 |
| idle, one curl, kept-alive | 500 | 0.029 | 0.062 | 0.279 |
| under /search?q=beba, curl per request | 500 | 167.433 | 175.109 | 196.188 |
| under /search?q=beba, one curl, kept-alive | 500 | 172.669 | 179.683 | 186.041 |
| the /search?q=beba requests themselves (as the loop client saw them) | 911 | 172.944 | 180.189 | 202.253 |
| under /search?q=bebidimi, curl per request | 500 | 0.375 | 2.098 | 2.952 |
| under /search?q=bebidimi, one curl, kept-alive | 500 | 0.296 | 0.542 | 0.652 |
| the /search?q=bebidimi requests themselves (as the loop client saw them) | 9103 | 0.322 | 0.844 | 159.126 |

Reading these:

- Idle, `/health` costs 0.03 ms median on a kept-alive connection and 0.2 to 0.3 ms with a new curl process and connection per request: that gap, about 0.2 ms, is the per-request overhead of the client.
- Under the common-word search loop, `/health` waits for the search in flight: its latency is about the length of the search. At medium, 12.8 to 16.6 ms median, 20 to 22 ms worst; at large, 167 to 173 ms median, 186 to 196 ms worst. The searches' own latency, as the looping client saw it, is the last row of each group and matches.
- The kept-alive row is slightly slower than the per-process row under load at medium (16.6 against 12.8 ms). I did not dig into why.
- Under a rare-word search loop the effect disappears: `/health` is 0.09 to 0.3 ms median at both sizes.
- The 159 ms and 16.5 ms "worst" on the rare-word searches' own rows look like the first rare-word request waiting behind the common-word search that was in flight when the previous client was killed (about 170 ms and 17 ms are those searches' lengths). They are not rare-word search costs. I have not re-run to confirm this; it is my explanation, not a measurement.

## What surprised me

1. **The 7.5 ms worst on `read` and `list` is the same in every run, every size.** A point read by primary key cannot take 7.5 ms. I measured it again with a GC hook (`diag.sps`, `diag.out`): of 3,000 reads, 2 were over 1 ms (6.6 and 6.9 ms), and Chez ran two collections of 6.5 and 6.8 ms. So they are collector pauses, not SQLite. They may come from my spike's 32 MB sampling table sitting in the heap; I did not test that, so I do not know whether Techo's collections will pause as long.
2. **A ranked search for a word in every note is the expensive query**, 13 ms at medium and 141 ms at large, roughly linear in the corpus (20,000 notes against 200,000: 10 times the notes, 10.8 times the time). Unranked, the same search is 0.15 ms at every size, because it stops after 50 rows. A real search box sends such words (stop-word-like terms) all the time. This is the one query where the page cap of ADR-0002 does not bound the work: the limit applies after the ranking.
3. **Write medians moved a lot between runs of identical code**: FULL at medium was 1.6, 7.8, 7.8, 9.1 and 11.4 ms. I measured it again three times, as the table shows; the answer is that it is not stable on this machine, not that the first run was wrong. I do not know the cause. The disk was shared with other agents; the bare-commit probe had a stable median (0.98 ms) but a heavy tail.
4. **The NORMAL write p99 is its checkpoint.** A NORMAL write's median is 0.32 ms, but its p99 is 8 to 45 ms and its worst 35 to 92 ms: the commit that crosses 1,000 frames runs the checkpoint inside it, and the explicit checkpoint costs 7 to 21 ms at the median. So `synchronous=NORMAL` moves the cost from every write to the writes that cross the threshold, and does not remove it from the loop.
5. **Disk use per snapshot is 4.7 KB for 2 KB of text** (see Fill).

## What was not measured

- **A write that triggers a checkpoint, as one call.** I time the PASSIVE checkpoint on its own, after about 1,000 frames of WAL (median 1,009 to 1,012, max 1,725, `# checkpointed frames` line in each output). The write numbers do contain real auto-checkpoints, but I did not mark which writes they were.
- **A cold database** (empty OS cache, empty page cache). Everything is warm.
- **Concurrent access**: no second connection, no admin CLI or backup running beside the server, so no `busy` waits.
- **`synchronous=EXTRA`, `mmap_size`, `journal_size_limit`, larger or smaller `wal_autocheckpoint`.** No tuning, as asked.
- **Ubuntu 24.04's SQLite.** Not available here.
- **Large with 10 revisions per node** (see Fill).
- **Phrase queries, prefix queries, multi-word queries,** snippets, and filters by kind or owner. Only single-word MATCH.
- **The idle loop's own jitter** in a longer run, and **GC pauses with a Techo-shaped heap.**
- **Other hosts.** One machine, shared, one afternoon.
- A client with its own connection pool or HTTP/2. The per-request overhead of curl is stated above.
- **Variation in the common-word search term**: the 5 common words are all in every or nearly every note, so the ranked cost was the same for each.

## How to rerun

From the repository root, on the host:

```
.plans/research/spike/all.sh
```

It fills the three sizes, benchmarks each (default cache, then 64 MiB cache for medium and large), and runs the load test on medium and large; everything lands in `build/spike/`. The fill of large is about 2.5 minutes and the benchmark and load stages took about 20 minutes on this machine. `SIZES="small medium" .plans/research/spike/all.sh` skips large; `SKIP_FILL=1` reuses existing `build/spike/*.db` files. Each program on its own: `.plans/research/spike/run.sh PROGRAM.sps ARGS`, which is `scripts/guix-env sh -c '$CHEZ --libdirs "$(make -s libdirs):.plans/research/spike/lib" --program ...'`.

Files in `.plans/research/spike/`: `lib/spike.sls` (schema, generator, clock, statistics), `fill.sps`, `bench.sps` (`SIZE ITERS CACHE-KIB [writes-only]`), `server.sps`, `load.sh` (runs inside the container), `check.sps`, `diag.sps`, `fsyncprobe.sps`, `run.sh`, `all.sh`.

Note: the `writes-only` argument was added to `bench.sps` after the `bench-*.out` files were made, to take the repeat runs; the three repeats ran the edited file. `all.sh` was run with `SKIP_FILL=1` after a separate run of `fill.sps` for each size (same program, same command, `fill.out`). Rerunning `all.sh` from scratch is the one thing I did not do end to end.
