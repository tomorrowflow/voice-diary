# Voice Diary — server

FastAPI backend, **seeded from `diary-processor/webapp/` on 2026-04-24**. Working app with entity detection, LightRAG ingest, review UI, admin UI, and Harvest integration. Audio ingest is local (ffmpeg + Whisper sidecar); Microsoft Graph access goes through MSAL device-code on the server. Remaining work is the iOS session ingest + enrichment routes (S3).

## Status

- `webapp/` — n8n removed (S1 ✅). Audio uploads run ffmpeg + Whisper in-process. Calendar served via Microsoft Graph (S2 ✅).
- `docker-compose.yml` — Whisper sidecar (S1 ✅). CPU + GPU image variants selected via `WHISPER_IMAGE_TAG`.
- `.env.example` — n8n vars removed (S1 ✅). MSAL + bearer-token vars added (S2 ✅).
- `webapp/routers/calendar.py` — `/today/calendar` + `/calendar/event/{id}` for iOS, bearer-token gated (S2 ✅).
- `docs-archive/` — 8 historical design docs from diary-processor. Reference only.

## Microsoft Graph bootstrap (S2)

One-time setup:

1. **Entra app registration** in the user's tenant. Type: *Public client*. Delegated scopes: `Calendars.Read`, `Mail.Read`, `offline_access`. *Allow public client flows* = yes. No redirect URI, no client secret. Note the application (client) ID and tenant ID.
2. **Set env vars** in `server/.env`: `MSGRAPH_CLIENT_ID`, `MSGRAPH_TENANT_ID`.
3. **Run the bootstrap** (interactive — you sign in once):

   ```bash
   docker compose run --rm webapp python scripts/msgraph_bootstrap.py
   ```

   The script prints a code + URL. Sign in with the Entra account, grant the requested scopes, return to the terminal. The refresh token persists in `data/msal_cache.bin` (mode 0600). The token auto-refreshes silently afterwards.
4. **Issue the iOS bearer token**:

   ```bash
   docker compose run --rm webapp python scripts/issue_ios_token.py
   ```

   Paste into `IOS_BEARER_TOKEN=` in `.env`, restart the webapp, and paste the same value into the iOS app during onboarding.

## What lives here

```
server/
├── README.md                    (this file)
├── .env.example
├── docker-compose.yml           webapp + postgres + qdrant + whisper
├── docs-archive/                historical design docs (reference)
└── webapp/                      FastAPI app
    ├── Dockerfile               python:3.11-slim + ffmpeg
    ├── requirements.txt         includes msal
    ├── main.py                  ~60 routes; see CLAUDE.md for what to modify
    ├── msgraph_client.py        MSAL public client + token cache (S2)
    ├── routers/                 iOS-facing routers (bearer-token gated)
    │   ├── auth.py              bearer-token Depends
    │   └── calendar.py          /today/calendar, /calendar/event/{id}
    ├── db.py
    ├── document_processor.py    LightRAG context + Ollama analysis + narrative + ingest
    ├── entity_detector.py       4-pass entity normalization
    ├── fluency_checker.py       Ollama fluency correction
    ├── transcript_corrector.py  Ollama ASR correction
    ├── llm_validator.py         streaming entity validation
    ├── vector_store.py          Qdrant client
    ├── bone_generator.py        LightRAG skeleton sync — bones
    ├── skeleton_sync.py         LightRAG skeleton sync — engine
    ├── harvest_llm.py
    ├── harvest_patterns.py
    ├── import_nocodb.py
    ├── schema.sql               17-table Postgres schema
    ├── seed.sql
    ├── skeleton/                markdown skeleton for prompts
    ├── templates/               HTMX review + admin UI
    └── static/
```

Planned additions during S1–S3:

- `webapp/routers/` — iOS-specific FastAPI routers.
- `webapp/msgraph_client.py` — MSAL + Graph HTTP client.
- `scripts/msgraph_bootstrap.py`, `scripts/issue_ios_token.py`.
- `data/sessions/`, `data/msal_cache.bin` at runtime.

## What to read before editing anything here

1. [../SPEC.md §3](../SPEC.md#3-system-architecture) — system architecture.
2. [../SPEC.md §10](../SPEC.md#10-ingest-contract) — API contract the iOS app expects.
3. [../DEVELOPMENT.md §4](../DEVELOPMENT.md#4-server-track-server) — milestone plan.
4. [../CLAUDE.md](../CLAUDE.md) — agent guidance and load-bearing constraints. Includes a list of what to modify in `webapp/main.py`.

## Deploy

```bash
cd server
cp .env.example .env
# Edit .env (required vars: DATABASE_URL, OLLAMA_BASE_URL, LIGHTRAG_URL, LIGHTRAG_API_KEY,
# QDRANT_URL, WHISPER_URL, HARVEST_*, MSGRAPH_CLIENT_ID, MSGRAPH_TENANT_ID, IOS_BEARER_TOKEN, TZ)

# One-time OAuth (after S2 completes the msgraph_bootstrap.py script):
docker compose run --rm webapp python scripts/msgraph_bootstrap.py

# Start everything:
docker compose up -d

curl -H "Authorization: Bearer $IOS_BEARER_TOKEN" http://<tailnet-host>:8000/health
```

See DEVELOPMENT.md §4.4 for full details.

## Runtime external dependencies

- **LightRAG** on its own host (URL from `.env`).
- **Ollama** on its own host (URL from `.env`). Recommended: `qwen2.5:14b` for German.
- **Microsoft Graph** (Entra app registration, delegated `Calendars.Read` + `Mail.Read` scopes). Bootstrapped via device-code flow, cached server-side.
- **Tailscale** — the only network exposure.
