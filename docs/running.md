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

## Make an account

Nobody signs up over the API. You make accounts at the command line:

```sh
printf 'correct horse battery\n' | TECHO_DB_PATH=/var/lib/techo/techo.db \
  make run ARGS='user add --username ada --email ada@example.com'
```

```
added ada ada@example.com 0193a5c0-7b1e-7000-8000-0123456789ab
```

The password is **never** an option: it would show in `ps`. Techo reads it from
standard input.

- At a terminal it asks twice, and shows nothing as you type. The two must match.
  It needs `stty` to hide what you type. Without it the command refuses, so pipe
  the password in.
- From a pipe or a file it takes the first line. It drops one `\r` at the end.
- **Spaces are part of the password,** at the start and end too. An empty line is refused.

The rules:

| | Rule |
|---|---|
| username | 1 to 32 characters: lowercase letters, digits, `_` and `-`. It starts with a letter or digit. |
| email | One `@` with text on each side, no spaces, 254 bytes at most. It is kept in lower case. |
| password | 8 characters or more, and 1,024 bytes at most. |

Then the person can [log in](api.md#log-in).

To set a new password (a forgotten one), or to cut off every device at once:

```sh
printf 'a brand new password\n' | TECHO_DB_PATH=/var/lib/techo/techo.db \
  make run ARGS='user password --email ada@example.com'
```

```
password set for ada@example.com; 1 key revoked
```

It **revokes every key** of the account. Each device must log in again.

A device that keeps trying the old password uses up the email's 5 tries, and the new
password then gets a `429` too. Wait 15 minutes, or restart the server to clear the
counts.

Both commands work while the server runs. Run them where the database file is.

| Status | Meaning |
|---|---|
| `0` | Done. |
| `1` | Refused, with a line on standard error: a name or email already taken, a bad value, no such email, no password given, or the database is missing, not migrated or busy. |
| `2` | The command line or a setting is wrong. For a bad command line the usage is printed. |
| `255` | Stopped with Ctrl-C at the password prompt. The echo is restored. |

A refused command changes nothing. `user add` on a missing or unmigrated file makes
no file: run `techo migrate` first. Both commands look at the name, the email and
the database before they ask for the password.

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
| `account` | The account's id, once Techo had checked the key. That includes a `500` or `504`. `-` with no key or a bad one, and when the request never got that far: still queued, or waiting for the write lock. Such a write may still commit afterwards. A login shows the account only when the password matched. |
| `address` | The client's address. Behind proxies, with [`TECHO_BEHIND_PROXY`](#behind-a-proxy) set, it is the entry Techo takes from `X-Forwarded-For`. Otherwise, or when that entry is no address, it is whoever connected. |

Two other lines can appear:

- `request-refused 400 …`: the server refused the request before Techo saw it. There
  is no `request` line for it.
- `handler-failed …`: beside a `500`'s `request` line, with what went wrong.

A field with nothing to show is `-`. The line never holds a query string, a
header or a body, so it never holds a key.

## Login limits

Login is limited so nobody can guess a password:

- **5 tries for one email**, and **20 tries from one address**, in 15 minutes.
- A good login counts toward the address's 20 as well. Only the email's count is
  cleared by it.
- The window starts at the first try. The next try after the limit is a `429` with
  `Retry-After`.
- A good login clears the email's count.

The counts live **in memory**. So:

- A restart forgets them.
- Two servers on one database file each keep their own. **Run one `serve` for each
  database file.** Nothing enforces it.

Two costs you should know about:

- Anyone who knows an email can send 5 wrong tries and block **new** logins for
  that email for 15 minutes. Keys already issued keep working.
- Someone with many addresses can fill the table of 10,000 counts, and block every
  login for a while. Techo logs one `limiter full=1` line when that happens. A login
  then gets a `429` with `Retry-After: 60`.

The address is the one that connected, unless you [tell Techo about your
proxies](#behind-a-proxy).

## Behind a proxy

If a proxy (nginx, a load balancer, a CDN) sits in front of Techo, every request
seems to come from the proxy. Techo limits logins by address, so it needs the
client's real address. A proxy writes that into the `X-Forwarded-For` header.
`TECHO_BEHIND_PROXY` says how far to trust it.

**The number is how many proxies you run in front of Techo that add to
`X-Forwarded-For`.** `0` (the default) means none: Techo uses the address that
connected and ignores the header.

Each proxy **appends** the address that connected to it. So the header is a list,
the oldest on the left, and the entry Techo takes is the Nth from the **right**.
That is the one entry no client can write: your own proxy wrote it.

**How to count:** list what a request passes through between the client and Techo.
Count each hop that adds to the header. Do not count Techo.

### One proxy (nginx)

```
client 203.0.113.9  ->  nginx  ->  Techo
```

nginx adds the client's address, with `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`.
Techo receives:

```
X-Forwarded-For: 203.0.113.9
```

Set `TECHO_BEHIND_PROXY=1`. Techo takes the 1st from the right: `203.0.113.9`.

If the client sends its own `X-Forwarded-For: 1.2.3.4`, nginx appends and Techo gets
`1.2.3.4, 203.0.113.9`. The 1st from the right is still `203.0.113.9`. The lie is
ignored.

### A CDN in front of a proxy

```
client 203.0.113.9  ->  CDN edge 198.51.100.7  ->  nginx  ->  Techo
```

The CDN adds the client. nginx adds the CDN's address. Techo receives:

```
X-Forwarded-For: 203.0.113.9, 198.51.100.7
```

Two hops add to it, so set `TECHO_BEHIND_PROXY=2`. The 2nd from the right is
`203.0.113.9`: the client. (With `1` you would take `198.51.100.7`, the CDN, and
every visitor would share one count.)

### What goes wrong

- **The number is too low.** Techo takes a proxy's address, not the client's. Every
  client shares one count, and **20 tries of any kind, good logins too, lock everyone
  out** for 15
  minutes. With `0` behind a proxy, that is the proxy's own address.
- **The number is too high, or Techo's port can be reached directly.** A client can
  write its own address into the header, and a different one on each try, to dodge
  the per-address limit. Put Techo where only your proxy can reach it
  (`CHEZ_HTTP_HOST=127.0.0.1`, or a firewall).
- **A proxy that replaces the header** (it writes one entry and drops what came
  before) hides every hop before it. Techo sees a list of one. So count that proxy
  as the **only** hop, and you get the address that proxy saw. If a CDN sits in
  front of that proxy, that address is the CDN's, and the client is lost. Set the
  proxy to append instead. Check what yours does: send `X-Forwarded-For: 1.1.1.1`
  and look at what arrives.
- **A CDN that can be bypassed.** If people can reach your proxy without going
  through the CDN, the header has one entry fewer than you counted, and the 2nd from
  the right is the client's own forgery. Allow only the CDN's addresses to reach the
  proxy, or count only what you can force.

### What Techo understands

- An entry with a port (`203.0.113.9:5555`) or brackets (`[2001:db8::1]`,
  `[2001:db8::1]:443`) is read as the address alone.
- A list with fewer entries than the number, or an entry that is not an address
  (`unknown`, a host name), falls back to the address that connected. Behind a proxy
  that is the proxy's: everyone then shares one count.
- The `Forwarded` header is **not** read, only `X-Forwarded-For`.
- An IPv6 client is counted by its `/64`: two addresses in the same `/64` share a
  count. IPv4 addresses are counted one by one.
- The [request log](#the-request-log)'s `address` is the same address the login
  limit counts: the client's when the number finds one, else whoever connected.
  So a wrong number shows up in the log: every line with the proxy's own address
  means it is too low.

A number that is not `0` to `8` stops Techo before it listens, with status 2. The
line names `TECHO_BEHIND_PROXY`, not what you wrote.

## Memory

A login checks the password with Argon2, which is slow and large on purpose. Each
login hashes with **64 MiB**, one at a time, in about 50 ms. A wrong password costs
twice that: Techo also does one more hash so a wrong email and a wrong password take
the same time.

- Up to 8 hashes wait in a queue: 8 good logins, or 4 wrong ones, since a wrong one
  hashes twice. When it is full the next login gets a `503` with `Retry-After`.
- If the machine is short of memory, a login may answer `503`. Under a container
  limit the kernel may kill the process instead. Give the container at least 64 MiB
  more than Techo uses when idle.

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
| `TECHO_BEHIND_PROXY` | no | How many proxies sit in front and add to `X-Forwarded-For`: `0` to `8`. Default `0`. [Read this section first](#behind-a-proxy) if you run one. |

A setting that is missing or wrong stops Techo before it listens. It says
which one, and exits with status 2. A port that is already in use is not a
wrong setting: the server's own error is printed, and the status is 1.

## Commands

| Command | What it does |
|---|---|
| `techo migrate` | Prepares or upgrades the database. |
| `techo serve` | Runs the server. |
| `techo user add --username NAME --email EMAIL` | Makes an account. The password is read from standard input. |
| `techo user password --email EMAIL` | Sets a password and revokes the account's keys. |
| `techo version` | Prints the version. |
| `techo help` | Lists the commands. |
