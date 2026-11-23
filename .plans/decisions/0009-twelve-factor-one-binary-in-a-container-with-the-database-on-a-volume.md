# 0009: Twelve-factor, one binary, in a container, with the database on a volume

Date: 2026-11-22
Status: accepted (owner, 2026-11-22, in the planning discussion)
Plan: [the outline](../outline.md) §10

## Context

- The owner deploys Docker containers, with SQLite files kept outside the container.
- `AGENTS.md` asks for the 12 Factor Apps philosophy.

## Decision

1. **All configuration comes from the environment.** There is no configuration file.
2. **One binary is the server and the admin CLI:** `techo serve`, `techo user add`,
   and the rest.
3. **SQLite runs in WAL mode.** The database's directory is the mounted volume, so its
   `-wal` and `-shm` files sit beside it.
4. **Backup is a CLI command** that runs `VACUUM INTO`, safe while the server runs.
5. **Migrations run from the CLI.**
6. **The server logs to standard output.**

## Consequences

- The server's host and port are chez-http-server's own variables, `CHEZ_HTTP_HOST`
  and `CHEZ_HTTP_PORT`. Techo does not rename them.
- The Docker image is slice 9.
