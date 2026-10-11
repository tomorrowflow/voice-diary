---
name: verify-server
description: Drive a real Voice Diary server route against an isolated Docker Compose stack (launch, doctor, drive, evidence, cleanup) and keep proof inside the worktree. Use when a server change must be shown working in the running app, not just in pytest.
---

# verify-server

Runs the real FastAPI webapp (built from `server/webapp`) with real Postgres and
Qdrant in its own Compose project, calls a mapped route over HTTP, checks the
response **and** its side effects, saves evidence under `features/evidence/<run>/`,
and tears down only what it started.

The route map lives in `features/README.md`; one file per feature in `features/`.
All steps are implemented by `features/verify-server/verify.sh` — run it from
anywhere inside the worktree, never `cd` out of it.

## Rules (from CLAUDE.md)

- **Auth is not bypassed.** Every route except `/health` needs the bearer. The run
  generates a throwaway `IOS_BEARER_TOKEN` and sends it from a 0600 header file; the
  no-bearer call must come back 401 before the authed call is trusted.
- **No secrets.** The stack never reads `server/.env`, `server/data/`, or
  `data/msal_cache.bin`. Env comes from a generated, ephemeral `.verify/<run>/env`
  (deleted by Cleanup). Evidence is redacted and secret-scanned before it is kept.
- **Tailnet-only.** The webapp is published on `127.0.0.1:<free port>` only. The bind
  guard (`TAILNET_IP`) is satisfied with a dummy CGNAT value that is never exposed.
- **Real boundaries.** Real webapp, real Postgres, real Qdrant, real auth, real
  request-log middleware. Microsoft Graph uses the server's own
  `MSGRAPH_FIXTURE_MODE` (documented in `server/README.md`), not a stub endpoint.
- **Do not change server behavior** to make a run pass. Fix the server in its own ticket.
- **Only tear down what you started** — all docker calls are `-p vd-verify-<id>`;
  never `docker system prune` / `docker compose down` without that project name.

## Prerequisites

Docker + Compose ≥ 2.24 (`!override` tags), `jq`, `curl`, `openssl`, `python3`.
First `launch` builds the webapp image and pulls `postgres:16-alpine` and
`qdrant/qdrant:v1.17.0` (needs network; the build downloads the embedding model).

## Launch

```bash
features/verify-server/verify.sh launch
```

Creates run id `<UTC stamp>-<hex>` and project `vd-verify-<hex>`, writes the
ephemeral env, starts `postgres` + `qdrant` (`--wait` for healthy), builds and starts
`webapp` with `--no-deps` (Whisper, Voxtral and every GPU service are not started),
then polls `/health` for up to 180 s. State is in `.verify/current`.

## Doctor

```bash
features/verify-server/verify.sh doctor
```

Fails (non-zero) unless: webapp/postgres/qdrant are running and nothing else is in the
project; the webapp port is `127.0.0.1:<port>` only; postgres/qdrant publish nothing;
`server/.env` was not used; `/health` is 200 with `postgres: ok`, `qdrant: ok`,
`msgraph: fixture`; a route without bearer is 401 `missing_bearer_token`; the same
route with the generated bearer is 200. `health.status` itself is expected to be
`down`/`degraded` — Whisper/Ollama/LightRAG/Voxtral are intentionally absent.

If doctor fails: read `features/evidence/<run>/doctor.txt`, then
`docker compose -p vd-verify-<hex> logs webapp`. Do not edit the server to pass it.

## Drive

```bash
features/verify-server/verify.sh drive admin-static-entities   # the route with a DB side effect
features/verify-server/verify.sh drive health
features/verify-server/verify.sh drive calendar-today
features/verify-server/verify.sh drive sessions-dates
```

Each target asserts the 401 without bearer, the authed response, and (where the route
writes) the side effects — see its feature file for the exact request, expected
response and side-effect queries. `admin-static-entities` is the default proof route:
it POSTs a row, reads it back via the API, confirms it with `psql` inside the
postgres container, finds the 200 line in the webapp JSON request log, then DELETEs it
and confirms the row is gone.

## Evidence

```bash
features/verify-server/verify.sh evidence
```

Writes `compose-ps.txt`, redacted `webapp.log` / `postgres.log`, `summary.md` next to
the per-call `*.request.txt` / `*.response.*` / `*.status` files in
`features/evidence/<run>/`, then greps the directory for this run's token and
Postgres password and refuses to continue if either is present. Evidence is
git-ignored by default; commit a run deliberately with `git add -f`.

## Cleanup

```bash
features/verify-server/verify.sh cleanup
```

`docker compose -p <project> down -v --remove-orphans --rmi local`, removes
`.verify/<run>/`, then asserts no container or volume labelled with the project remains
and that `features/evidence/<run>/` still exists. Always run it, also after a failure.

## Adding a feature

Copy a file in `features/`, map the route (auth, request, response, side effects,
exact check), add a `drive_*` function and `case` arm in `verify.sh`, list it in
`features/README.md`.
