# Running Techo

Techo is one program. It is the server and the admin tool.

## What it needs

libsodium 1.0.18 or later, on the machine. Techo uses it for hashing and random
bytes. Without it, every command (`migrate`, `serve`, even `version`) stops at
the start with the library's own message and a non-zero status. Install the
package, then run it again.

## Prepare the database

```sh
TECHO_DB_PATH=/var/lib/techo/techo.db make run ARGS=migrate
```

It makes the file if it is missing, and brings it to the schema this Techo
expects. The directory must exist.

```
converted the database to WAL
applied migration 1
the database is at version 1
```

Run it:

- before the first start;
- after each upgrade;
- after restoring a backup.

**Stop the server first** ([Upgrading](#upgrading) says what happens if you
do not). Running it twice is safe: the second run prints `nothing to do`.

It exits 0 when the database is ready, and 1 when it is not:

| It says | What it means |
|---|---|
| `refused: this binary is older than the database` | A newer Techo made this file. Use that one. |
| `refused: not Techo's database` | The file belongs to another program. It was not changed. |
| `busy` | Something else holds the file: another `migrate`, or a reader. It can take 20 seconds to say so. Run it again. |
| `failed` | A migration did not apply. The line says why. |
| `the database's version is unknown` | The last step failed part way. Run it again. |
| `cannot open the database` | The line says why. Often the path, the directory or the permissions. |

A failed migration is undone, and the file stays at the version before it.

If it says `an interrupted write is still in the database`, the file was
restored or copied while something was writing it. Open it once with
`sqlite3 FILE 'select 1'`, then run `techo migrate` again.

Migrations only go forward. To undo one, restore a backup.

## Start it

```sh
TECHO_DB_PATH=/var/lib/techo/techo.db make run ARGS=serve
```

It prints `listening 127.0.0.1 8080` once it is ready.

It will not start on a database that is missing, empty, behind, newer than
it, not in WAL mode, not its own, or that it may not write. It says which, and exits with status 1. Most of the time the
answer is to run `techo migrate`.

## The request log

Each request Techo answers writes one line to standard output, when its answer ends:

```
request method=GET path=/v1/keys status=200 ending=written ms=4 db_ms=1 account=0193a5c0-7b1e-7000-8000-0123456789ab address=203.0.113.9
```

| Field | What it is |
|---|---|
| `method`, `path` | What was asked. |
| `status` | The status the client got. `-` if Techo never answered. |
| `ending` | How the answer ended: `written` is the normal one. |
| `ms` | How long the request took. |
| `db_ms` | How long the database part took, queue included. `-` if it had none. |
| `account` | The account's id, when Techo answered or refused the request for that account. `-` with no key or a bad one, and on a `500`, `503` or `504`. |
| `address` | Who connected. |

Two other lines can appear:

- `request-refused 400 …`: the server refused the request before Techo saw it. There
  is no `request` line for it.
- `handler-failed …`: beside a `500`'s `request` line, with what went wrong.

A field with nothing to show is `-`. The line never holds a query string, a
header or a body, so it never holds a key.

## Check it

```sh
curl http://127.0.0.1:8080/health
```

```json
{"status":"ok"}
```

## In the Guix container

The container has its own environment and its own network. Set the variables
inside it, and check it from inside it too:

```sh
scripts/guix-env sh -c 'TECHO_DB_PATH=/var/lib/techo/techo.db make run ARGS=serve'
```

`curl` on the host cannot reach a server in the container.

## Stop it

Send it SIGTERM, or press Ctrl-C. It finishes the requests in hand, prints
`stopped`, closes the database, and exits.

- It waits up to 10 seconds for requests in hand (`CHEZ_HTTP_DRAIN_TIMEOUT`).
- Then it waits for a write that is still running, however long that takes.
- So give it 30 seconds before you kill it. Docker's default is 10: set
  `stop_grace_period: 30s`.

A second SIGTERM or Ctrl-C while it waits for that write kills it at once.

Killing it is safe. A write that was running is either all there or not there
at all. The next start takes a moment longer.

## Upgrading

In this order:

1. Stop the server.
2. Back up the database file.
3. Run the new `techo migrate`.
4. Start the new `techo serve`.

No request uses the database yet, so today none of this can be seen from
outside. It is how the server behaves once one does.

**If `migrate` runs while an old server is still up,** the migration succeeds
and the old server stops using the database. It will not read or write a
schema it does not know.

How to tell:

- every request that needs the database gets `503`;
- `/health` still says `ok`, because it does not touch the database;
- the server prints this, once:

```
database moved: the file is at version 3 and this server expects 2; a newer techo migrate ran beside it; database requests get 503 until the newer techo serves
```

The cure: stop the old server and start the new one. No data is lost.

**Restoring a backup is different.** The server cannot see a file swapped
under it, and keeps writing to the old one. Always stop the server before a
restore.

## When a request fails

| Status | What it means | Retry? |
|---|---|---|
| `503` with `Retry-After` | Techo did not do it: it is busy, stopping, or the database moved (above). | Yes, later. |
| `504` | It took too long. A write may or may not have happened: the log line says `504`, and the write can still land after it. | Yes: a write is safe to send again. |
| `500` | Something broke. A write may or may not have happened. | Yes, once; then look at the log. |

If the log says `database unavailable: a connection was closed after a failed
rollback`, restart Techo.

## Settings

Every setting is an environment variable. There is no configuration file.

| Variable | Needed | What it is |
|---|---|---|
| `TECHO_DB_PATH` | yes | Where the database file lives. An absolute path to a file. |
| `TECHO_DB_READERS` | no | How many threads read the database: 1 to 16. Default `2`. One more thread always writes. |
| `CHEZ_HTTP_HOST` | no | The address to listen on. Default `127.0.0.1`. |
| `CHEZ_HTTP_PORT` | no | The port. Default `8080`. `0` picks a free one, and the `listening` line says which. |

A setting that is missing or wrong stops Techo before it listens. It says
which one, and exits with status 2. A port that is already in use is not a
wrong setting: the server's own error is printed, and the status is 1.

## Commands

| Command | What it does |
|---|---|
| `techo migrate` | Prepares or upgrades the database. |
| `techo serve` | Runs the server. |
| `techo version` | Prints the version. |
| `techo help` | Lists the commands. |
