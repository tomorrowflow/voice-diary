---
name: verify-server
description: Drive a real Voice Diary server route against an isolated Docker Compose stack (launch, doctor, drive, evidence, cleanup) and keep proof inside the worktree. Use when a server change must be shown working in the running app, not just in pytest.
---

# verify-server

Runs the real FastAPI webapp (built from `server/webapp`) with real Postgres and Qdrant in
its own Compose project `vd-verify`, calls a mapped route over HTTP from a one-shot
`driver` container on the stack network, checks the response **and** its side effects,
saves evidence under `features/evidence/<run>/`, and tears down only that project.

The route map is `features/README.md`; one file per feature in `features/`.

## Files

All under `features/verify-server/`:

- `compose.verify.yml` — override on `server/docker-compose.yml` (never edited): no host
  port, no `server/.env`, project-scoped `/data` volume, only webapp + postgres + qdrant,
  a webapp healthcheck, and the `driver` service (profile `drive`).
- `verify.env` — committed **throwaway** values (dummy tailnet IP, fixed test
  password/bearer, `MSGRAPH_FIXTURE_MODE=true`). Not secrets; never put real ones here.
- `drive.py` — stdlib HTTP driver run inside the `driver` container.

## Rules (from CLAUDE.md)

- **Auth is not bypassed.** Every route except `/health` needs the bearer. `drive.py`
  asserts the 401 without bearer before the authed call, and never prints the token.
- **No secrets.** The stack never reads `server/.env`, `server/data/` or
  `data/msal_cache.bin`. Scan evidence for the `verify.env` values before keeping it.
- **Tailnet-only.** No host port is published at all; the webapp is reachable only from
  inside the `vd-verify_default` network. `TAILNET_IP` is a dummy value for `bind_guard`.
- **Real boundaries.** Real webapp, Postgres, Qdrant, auth and request-log middleware.
  Microsoft Graph uses the server's own `MSGRAPH_FIXTURE_MODE`, not a stub endpoint.
- **Do not change server behavior** to make a run pass.
- **Only tear down what you started.** Every command is `docker compose -p vd-verify …`.
  No `docker system prune`, no `down` without `-p vd-verify`, no touching other projects.
- Host `curl` is not used (denied by policy); HTTP goes through the `driver` service.

## Command prefix

All steps use this prefix (run from the worktree root). It is written out in full below:

```
docker compose -p vd-verify --project-directory server \
  --env-file features/verify-server/verify.env \
  -f server/docker-compose.yml -f features/verify-server/compose.verify.yml
```

Pick an evidence dir first and reuse it: `features/evidence/<run>/` (e.g. `run-1`).

```bash
mkdir -p features/evidence/<run>
```

## Launch

Refuse to start if a `vd-verify` stack already exists (the `ps` must list nothing):

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml ps -a
```

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml up -d --build --wait webapp > features/evidence/<run>/launch.log 2>&1
```

Starts postgres + qdrant, builds the webapp image, and waits until postgres, qdrant
and webapp are `Healthy` (first build downloads the embedding model; needs network).
Last lines of `launch.log` must show the three containers healthy.

## Doctor

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml run --rm --no-deps -T driver python /drive.py doctor > features/evidence/<run>/doctor.txt 2>&1
```

Exit non-zero unless: `/health` is 200 without bearer with `postgres: ok`, `qdrant: ok`,
`msgraph: fixture`; a route without bearer is 401 `missing_bearer_token`; the same route
with the bearer is 200. `health.status` itself is expected to be `down`/`degraded`
(Whisper, Voxtral, Ollama, LightRAG are not in this stack). Then record the service list:

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml ps -a --format 'table {{.Service}}\t{{.State}}\t{{.Health}}\t{{.Ports}}' > features/evidence/<run>/compose-ps.txt
```

Expect exactly `postgres`, `qdrant`, `webapp`, all running, and no `->` in `Ports`
(exposed-only, nothing published on the host). If doctor fails, read `doctor.txt` and
`… logs webapp`; do not edit the server to make it pass.

## Drive

`drive.py` subcommands: `health`, `calendar-today`, `sessions-dates`,
`static-entity-create <name>`, `static-entity-list <name>`, `static-entity-delete <id>`.
Each run is:

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml run --rm --no-deps -T driver python /drive.py <subcommand> [arg] > features/evidence/<run>/<name>.txt 2>&1
```

The default proof route is the DB-writing one, `features/admin-static-entities.md`:
`static-entity-create verify-ka8-probe` (prints `ENTITY_ID=<n>`), `static-entity-list
verify-ka8-probe`, a `psql` check (below), `static-entity-delete <n>`, a second `psql`
check. Side-effect queries (separate step, in the postgres container):

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT id, name, entity_type, status FROM static_entities WHERE id = <n>"' > features/evidence/<run>/db-row-after-create.txt 2>&1
```

(`count(*)` instead of the column list after the delete → `0`.) See each feature file
for its requests and expected responses.

## Evidence

Everything above already lands in `features/evidence/<run>/` via redirects. Add the app log
(the JSON request-log lines are the server-side proof of each call; `Authorization` is
stripped by the logger) and scan for the throwaway secrets:

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml logs --no-color --no-log-prefix webapp > features/evidence/<run>/webapp.log 2>&1
```

```bash
grep -rlE "verify-only-(bearer|not-a-secret)" features/evidence/<run> || echo clean
```

Must print `clean`. Evidence is git-ignored (`features/evidence/*/`); commit a run
deliberately with `git add -f features/evidence/<run>`.

## Cleanup

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml down -v --remove-orphans --rmi local > features/evidence/<run>/cleanup.log 2>&1
```

Removes this project's containers, network, volumes (`pgdata`, `qdrant_data`,
`verify_data`) and the locally built `vd-verify-webapp` image. Then confirm and
that evidence survived:

```bash
docker ps -a --filter label=com.docker.compose.project=vd-verify --format '{{.Names}}' > features/evidence/<run>/post-cleanup-containers.txt
```

(file must be empty) and `ls features/evidence/<run>`. Always run Cleanup, also after a
failed Launch or Drive.

## Adding a feature

Copy a file in `features/`, map the route (auth, request, response, side effects), add
a function and an entry in `COMMANDS` in `drive.py`, and list it in `features/README.md`.
