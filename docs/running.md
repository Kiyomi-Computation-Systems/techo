# Running Techo

Techo is one program. It is the server, and it will be the admin tool too.

## Start it

```sh
TECHO_DB_PATH=/var/lib/techo/techo.db make run ARGS=serve
```

It prints `listening 127.0.0.1 8080` once it is ready.

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
`stopped`, and exits.

## Settings

Every setting is an environment variable. There is no configuration file.

| Variable | Needed | What it is |
|---|---|---|
| `TECHO_DB_PATH` | yes | Where the database file lives. An absolute path. |
| `CHEZ_HTTP_HOST` | no | The address to listen on. Default `127.0.0.1`. |
| `CHEZ_HTTP_PORT` | no | The port. Default `8080`. `0` picks a free one, and the `listening` line says which. |

A setting that is missing or wrong stops Techo before it listens. It says
which one, and exits with status 2. A port that is already in use is not a
wrong setting: the server's own error is printed, and the status is 255.

`TECHO_DB_PATH` is checked but not opened yet: there is no database until
the next release.

## Commands

| Command | What it does |
|---|---|
| `techo serve` | Runs the server. |
| `techo version` | Prints the version. |
| `techo help` | Lists the commands. |
