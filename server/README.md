# Voice Diary — server

FastAPI backend for the Voice Diary iOS app. Runs the full pipeline end-to-end:
ffmpeg → Whisper ASR → transcript correction → 4-pass entity normalisation →
Ollama analysis → narrative generation → LightRAG ingest. Plus iOS-facing
routes for session ingest, MS Graph (calendar + email) proxy, and enrichment.

Analysis runs on local Ollama by default. An opt-in `ANALYSIS_ROUTE=blindfold` sends
the main analysis prompt to a cloud model through a Blindfold proxy; read the
[limits](../docs/analysis-egress.md) before enabling it.

Seeded from `diary-processor/webapp/` on 2026-04-24. Server milestones S1–S4
removed n8n, added MSAL, added the iOS routes, added structured logging
and a backup script. The HTMX review/admin/Harvest UIs are unchanged.

---

## First-time setup (≤ 20 minutes)

### 1. Prerequisites

- Docker Engine + Compose v2 on the host.
- A Tailscale interface so iOS can reach this server.
- An Ollama instance reachable from the host (recommended model: `qwen2.5:14b`).
  The analysis call in `document_processor.py` needs a large context window;
  since it talks OpenAI-shape `/v1/chat/completions` (no per-request `num_ctx`),
  configure that context length on the Ollama side — see the `OLLAMA_ANALYSIS_*`
  comment block in `.env.example`.
- Optional, off by default: a Blindfold proxy and a cloud model account, only
  if you set `ANALYSIS_ROUTE=blindfold`. The default needs neither and sends
  no diary content to any cloud AI service. The route is a restart-time setting with no fallback to
  Ollama, and it must not be enabled before the first-enable checks pass;
  settings, limits and the gate are in
  [`docs/analysis-egress.md`](../docs/analysis-egress.md).
- A LightRAG instance reachable from the host.
- An Entra (Azure AD) tenant the user already signs into.

### 2. Entra app registration (for Microsoft Graph)

In the Entra admin centre, create an app registration:

- **Account type**: single-tenant.
- **Redirect URI**: leave empty.
- **Authentication → Allow public client flows**: yes.
- **API permissions → Add a permission → Microsoft Graph → Delegated**:
  - `Calendars.Read`
  - `Mail.Read`
  - `offline_access`
- Grant admin consent if your tenant requires it.

Note the *Application (client) ID* and *Directory (tenant) ID*. No client
secret — device-code flow does not need one.

Reference: [Microsoft Learn — register an application](https://learn.microsoft.com/en-us/graph/auth-register-app-v2).

### 3. Configure environment

```bash
cd server
cp .env.example .env
# Edit at minimum:
#   MSGRAPH_CLIENT_ID, MSGRAPH_TENANT_ID
#   OLLAMA_BASE_URL, LIGHTRAG_URL
#   IOS_BEARER_TOKEN  (filled in step 5 below)
```

`WHISPER_IMAGE_TAG=latest` is the CPU build. Use `latest-gpu` and uncomment
the `deploy.resources` block in `docker-compose.yml` if you have CUDA on
the host.

### 4. Microsoft Graph bootstrap (once)

```bash
docker compose run --rm webapp python scripts/msgraph_bootstrap.py
```

The script prints a code + URL. Sign in with the user's Entra account.
The refresh token persists in `data/msal_cache.bin` (mode 0600). It
auto-refreshes silently afterwards.

If the cache is ever wiped or the grant revoked, simply re-run the script.

#### Fixture mode (waiting for admin consent)

If your tenant requires admin consent and you can't sign in yet, flip
`MSGRAPH_FIXTURE_MODE=true` in `.env` and restart:

```bash
docker compose up -d --force-recreate webapp
```

The `/today/calendar`, `/calendar/event/{id}`, `/email/search` endpoints,
the HTMX review UI's calendar widget, and `/api/harvest/suggest` will
return canned data from `webapp/fixture_data/*.json`. `/health` reports
`"msgraph":"fixture"` to make the dev mode obvious. Sessions ingest,
LightRAG enrichment, and the rest of the pipeline are unaffected.

To override the bundled fixtures with your own scenarios, drop
`calendar_today.json` and/or `email_search.json` into
`server/data/fixtures/` (mounted at `/data/fixtures/` in the container).
Files there take precedence over the bundled defaults.

Flip the flag back to `false` (or remove it) and restart the webapp once
the bootstrap script has succeeded.

### 5. Issue the iOS bearer token

```bash
docker compose run --rm webapp python scripts/issue_ios_token.py
# Paste the printed value into IOS_BEARER_TOKEN= in .env
```

Paste the same value into the iOS app's onboarding screen. Restart the
webapp so the new value is picked up:

```bash
docker compose up -d --force-recreate webapp
```

### 6. Start the stack

```bash
docker compose up -d --build
docker compose logs -f webapp        # watch startup
```

### 7. Verify

```bash
TOKEN="$(grep '^IOS_BEARER_TOKEN=' .env | cut -d= -f2)"

# Liveness — does NOT require the bearer (iOS pings this pre-onboarding):
curl -s http://<tailnet-host>:8000/health | jq

# Calendar — requires bearer:
curl -s -H "Authorization: Bearer $TOKEN" \
     "http://<tailnet-host>:8000/today/calendar?date=$(date +%F)" | jq
```

Expected `/health` shape on a healthy host:

```json
{"status":"ok","upstream":{
  "postgres":"ok","qdrant":"ok","whisper":"ok",
  "lightrag":"ok","ollama":"ok","msgraph":"ok","voxtral":"skipped"
}}
```

The overall `status` follows fixed rules (SPEC §10.7):

- `down`: `postgres` or `whisper` is `down`.
- `degraded`: any other non-optional upstream (`qdrant`, `lightrag`, `ollama`, `msgraph`) is not `ok`, including `msgraph: not_bootstrapped`. `skipped` and `fixture` entries are ignored.
- `ok`: otherwise.

`voxtral` is optional: `upstream.voxtral` shows its real state (`ok`, `down` or `skipped`), but it never changes `status`. The `msgraph` probe checks the MSAL token cache, not live Graph.

`blindfold` appears only when `ANALYSIS_ROUTE=blindfold` (see [`docs/analysis-egress.md`](../docs/analysis-egress.md)). It is `ok` or `down`; `down` makes `status` `degraded`, never `down`. With the default route the key is absent.

Every other route — the iOS routers *and* the HTMX review/admin/data UI
(`/`, `/review/*`, `/admin`, `/settings`, `/ingest`, `/harvest`, `/api/*`) —
requires the same bearer. A browser does not send it on its own, so opening
the UI directly returns `401 missing_bearer_token`; use a header-injecting
browser extension that adds `Authorization: Bearer $TOKEN` for the tailnet
host.

---

## Bearer-token rotation

The token in `IOS_BEARER_TOKEN` may be rotated at any time:

```bash
docker compose run --rm webapp python scripts/issue_ios_token.py     # new value
# Edit .env, replace IOS_BEARER_TOKEN
docker compose up -d --force-recreate webapp
# Update the iOS app's onboarding setting; old token is rejected immediately.
```

There is no token versioning or grace period — rotate when convenient.
The MSAL refresh token in `data/msal_cache.bin` is **separate** and is
unaffected by bearer-token rotation.

---

## Logs

`docker compose logs webapp` yields one JSON object per line:

```json
{"ts":"2026-04-27T19:42:13+0200","level":"INFO","logger":"voice_diary.request",
 "msg":"request","method":"POST","path":"/api/sessions",
 "status_code":200,"duration_ms":12183,
 "request_id":"7c2e...","session_id":"2026-04-24T19:30:00+02:00"}
```

Every request gets a `request_id` (UUID4); session-ingest log lines
also carry the iOS `session_id` so a single session can be filtered with
`docker compose logs webapp | jq 'select(.session_id=="...")'`.

`Authorization` headers are stripped from log records. Tokens never appear.

---

## Backup + restore

### Backup

```bash
bash scripts/backup.sh /var/backups/voice-diary
```

Produces `voice-diary-YYYY-MM-DDThh-mm-ss.tar.gz` containing:
- `data/sessions/` — iOS session bundles + transcripts.
- `data/msal_cache.bin` — MSAL refresh-token cache.
- `postgres.sql` — `pg_dump` of `diary_processor`.
- `qdrant_snapshots/storage/` — Qdrant snapshot directory.

### Restore on a fresh host

1. Clone the repo, copy `.env`, restore the `data/` tree from the archive.
2. Bring up the stack: `docker compose up -d`.
3. Wait for Postgres to be ready, then load the dump:
   ```bash
   docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < postgres.sql
   ```
4. Restore Qdrant by copying `qdrant_snapshots/storage/` into the qdrant
   volume directory before bringing up the qdrant container, or use the
   `/snapshots` upload API if the container is already running.

The MSAL bootstrap does **not** need to be re-run if `msal_cache.bin`
was restored intact.

---

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `/health` returns `"msgraph":"not_bootstrapped"` | bootstrap never run, or refresh token revoked | re-run `scripts/msgraph_bootstrap.py` |
| `/today/calendar` → 503 `msgraph_not_bootstrapped` | same | same |
| `/today/calendar` → 429 `msgraph_rate_limited` (with `Retry-After`) | Graph throttling | wait, retry; if persistent reduce poll rate on iOS |
| `/today/calendar` or `/email/search` → 503 `msgraph_unavailable` | no route to Graph or the Entra token endpoint, or a timeout | check the server's outbound network and DNS |
| `/lightrag/query` → 503 `lightrag_timeout` | LightRAG did not answer within 120 s | check the LightRAG container load; retry |
| `/lightrag/query` → 503 `ollama_unavailable` / `ollama_timeout` | the speech summariser could not reach Ollama or ran out of time | check `OLLAMA_BASE_URL` and `OLLAMA_ENRICHMENT_TIMEOUT` |
| `/api/sessions` → 503 `whisper_unavailable` | Whisper sidecar stopped | `docker compose ps whisper` and restart |
| Segments come back with `status: "pending_analysis"` | Ollama or LightRAG was down during ingest | bundle persisted on disk; re-process via `/process/<transcript_id>` once upstream returns |
| Segments `pending_analysis` with `code: "blindfold_*"` | `ANALYSIS_ROUTE=blindfold` and the Blindfold proxy was down, slow or errored; nothing was sent to Ollama | fix or restart Blindfold, then `retry-analysis`; or set `ANALYSIS_ROUTE=local`, restart and retry (no automatic fallback) |
| Server refuses to start with a `BLINDFOLD_*` or `ANALYSIS_ROUTE` message | unknown route value, or `blindfold` without `BLINDFOLD_BASE_URL` / `BLINDFOLD_ANALYSIS_MODEL` | fix `.env` per [`docs/analysis-egress.md`](../docs/analysis-egress.md) |
| `/health` returns `"status":"degraded"` | a non-optional upstream (Qdrant, LightRAG, Ollama, Graph, or Blindfold when routed) is not `ok` | check `upstream` map for the offending service |
| `/health` returns `"status":"down"` | Postgres or Whisper is down | `docker compose ps` and restart the service |
| HTMX review UI returns `401 missing_bearer_token` | browser isn't sending the bearer | add the `Authorization` header for the tailnet host (see First-time setup, step 7) |
| HTMX review UI's calendar widget shows nothing | tenant returned no events for that date, or MSAL bootstrap stale | confirm `/today/calendar` works directly |

### Failure codes

Upstream failures carry a stable `code` and the failing `upstream` next to the string `detail`
(`{"detail": "whisper_unavailable", "code": "whisper_unavailable", "upstream": "whisper",
"retryable": true}`), and the same two fields on failed / `pending_analysis` segments in
`GET /api/sessions/<id>/status`. `Retry-After` is sent only when a wait is known (Graph 429).
Contract and statuses: SPEC §10.6.1; every upstream-facing route uses it (SPEC §10.7).

| Code | Upstream | Status | Retryable | What to check |
|---|---|---|---|---|
| `whisper_unavailable` / `whisper_timeout` / `whisper_engine_error` | whisper | 503 / 503 / 502 | yes | whisper container up and healthy; model loaded |
| `ollama_unavailable` / `ollama_timeout` / `ollama_engine_error` | ollama | 503 / 503 / 502 | yes | Ollama reachable at `OLLAMA_BASE_URL`; model pulled; long analyses may need a higher timeout |
| `blindfold_unavailable` / `blindfold_timeout` / `blindfold_engine_error` | blindfold | 503 / 503 / 502 | yes | only with `ANALYSIS_ROUTE=blindfold`, main analysis call only; Blindfold reachable at `BLINDFOLD_BASE_URL`; a 401/403 is an engine error, check `BLINDFOLD_API_KEY`; never answered by Ollama |
| `lightrag_unavailable` / `lightrag_timeout` / `lightrag_engine_error` | lightrag | 503 / 503 / 502 | yes | LightRAG reachable at its base URL; API key |
| `msgraph_not_bootstrapped` | msgraph | 503 | no | run `scripts/msgraph_bootstrap.py` |
| `msgraph_rate_limited` / `msgraph_unavailable` / `msgraph_engine_error` | msgraph | 429 / 503 / 502 | yes | Graph throttling (`Retry-After` sent when Graph gave one), network or outage; wait |
| `voxtral_unavailable` / `voxtral_timeout` / `voxtral_engine_error` | voxtral | 503 / 503 / 502 | yes | voxtral-gate and engine; a timeout is 503 like the others, not 504 |
| `unknown_voice` | voxtral | 400 | no | the voice id is not in the catalogue |

A segment with no `code` failed for a reason that is not an upstream failure (or predates the
contract); read its `error` string and the webapp log.

---

## Layout

```
server/
├── README.md
├── .env.example
├── docker-compose.yml          webapp + postgres + qdrant + whisper
├── scripts/
│   ├── msgraph_bootstrap.py    one-time MSAL device-code flow
│   ├── issue_ios_token.py      stateless 256-bit bearer generator
│   └── backup.sh               sessions + MSAL + Postgres + Qdrant
├── docs-archive/               historical design docs (reference)
└── webapp/
    ├── Dockerfile              python:3.11-slim + ffmpeg
    ├── requirements.txt        includes msal
    ├── main.py                 FastAPI app + HTMX review/admin/harvest UIs
    ├── logging_setup.py        JSON formatter + correlation-ID middleware
    ├── paths.py                $DATA_DIR resolver (default /data in Docker)
    ├── models.py               Pydantic v2 manifest schema (SPEC §10.3)
    ├── enrichment.py           speech-ready Ollama summariser
    ├── msgraph_client.py       MSAL public client + persistent cache
    ├── routers/
    │   ├── auth.py             bearer-token Depends
    │   ├── calendar.py         /today/calendar, /calendar/event/{id}
    │   ├── email.py            /email/search
    │   ├── lightrag.py         /lightrag/query, /yesterday/open-todos
    │   ├── sessions.py         POST /api/sessions, GET /status
    │   └── health.py           upstream-aware /health (no auth)
    ├── document_processor.py   LightRAG context + Ollama analysis + narrative + ingest
    ├── entity_detector.py      4-pass entity normalisation
    ├── transcript_corrector.py Ollama ASR correction
    ├── fluency_checker.py
    ├── llm_validator.py
    ├── vector_store.py         Qdrant client
    ├── bone_generator.py       LightRAG skeleton bones
    ├── skeleton_sync.py        LightRAG skeleton sync engine
    ├── harvest_llm.py
    ├── harvest_patterns.py
    ├── import_nocodb.py
    ├── schema.sql              17-table Postgres schema
    ├── seed.sql
    ├── skeleton/               markdown skeleton fed to prompts
    ├── templates/              HTMX review + admin UIs
    └── static/
```
