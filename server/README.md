# Voice Diary — server

FastAPI backend, **seeded from `diary-processor/webapp/` on 2026-04-24**. Already a working app with entity detection, LightRAG ingest, review UI, admin UI, and Harvest integration. The remaining work is removing n8n wiring and adding iOS-specific routes.

## Status

- `webapp/` — copied wholesale from diary-processor, still has n8n references. Being cleaned up in milestone S1.
- `docker-compose.yml` — copied, needs a Whisper service added in S1.
- `.env.example` — copied, still has `N8N_WEBHOOK_URL` and `CALENDAR_WEBHOOK_URL` (to be removed in S1).
- `docs-archive/` — 8 historical design docs from diary-processor. Reference only.

## What lives here

```
server/
├── README.md                    (this file)
├── .env.example                 needs n8n vars removed (S1)
├── docker-compose.yml           needs Whisper service added (S1)
├── docs-archive/                historical design docs (reference)
└── webapp/                      FastAPI app
    ├── Dockerfile               needs ffmpeg apt-get install (S1)
    ├── requirements.txt         needs msal added (S2)
    ├── main.py                  ~60 routes; see CLAUDE.md for what to modify
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
