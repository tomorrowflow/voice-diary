# Voice Diary — server

FastAPI backend for the Voice Diary iOS app. Runs the full pipeline end-to-end:
ffmpeg → Whisper ASR → transcript correction → 4-pass entity normalisation →
Ollama analysis → narrative generation → LightRAG ingest. Plus iOS-facing
routes for session ingest, MS Graph (calendar + email) proxy, and enrichment.

Seeded from `diary-processor/webapp/` on 2026-04-24. Server milestones S1–S4
removed n8n, added MSAL, added the iOS routes, added structured logging
and a backup script. The HTMX review/admin/Harvest UIs are unchanged.

---

## First-time setup (≤ 20 minutes)

### 1. Prerequisites

- Docker Engine + Compose v2 on the host.
- A Tailscale interface so iOS can reach this server.
- An Ollama instance reachable from the host (recommended model: `qwen2.5:14b`).
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
  "lightrag":"ok","ollama":"ok","msgraph":"ok"
}}
```

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

Every request gets a `request_id` (UUID4); session-processing log lines
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
   docker compose exec -T postgres psql -U diary -d diary_processor < postgres.sql
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
| `/today/calendar` → 502 `rate_limited: backoff_exhausted` | Graph throttling | wait, retry; if persistent reduce poll rate on iOS |
| `/api/sessions` → 503 `whisper_unavailable` | Whisper sidecar stopped | `docker compose ps whisper` and restart |
| Segments come back with `status: "pending_analysis"` | Ollama or LightRAG was down during ingest | bundle persisted on disk; re-process via `/process/<transcript_id>` once upstream returns |
| `/health` returns `"status":"degraded"` | one upstream down | check `upstream` map for the offending service |
| HTMX review UI's calendar widget shows nothing | tenant returned no events for that date, or MSAL bootstrap stale | confirm `/today/calendar` works directly |

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
