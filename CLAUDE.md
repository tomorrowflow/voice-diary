# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

**Design complete. Server code seeded. Implementation about to begin.**

- `SPEC.md` — full product + technical specification. Single source of truth for behavior.
- `DEVELOPMENT.md` — milestone plan for both tracks (server S1–S4 + iOS M1–M12).
- `server/webapp/` — already populated with a working FastAPI codebase (seeded from `diary-processor/webapp/` on 2026-04-24). ~2200 lines of `main.py`, 17 other Python modules, Postgres schema, HTMX templates.
- `ios/` — empty. Populated in iOS M1.

Always read `SPEC.md` and `DEVELOPMENT.md` before making changes.

## What this repo is

A **monorepo** with two independently-deployable components:

- **`ios/`** — Swift 6 / SwiftUI iOS app for iPhone 17 Pro on iOS 26. Drive-by capture + structured evening walkthrough.
- **`server/`** — FastAPI backend (Python 3.12, Dockerized) seeded from `diary-processor`. Owns the full pipeline: ffmpeg → Whisper → transcript correction → 4-pass entity normalization → Ollama analysis → narrative generation → LightRAG ingest. Plus new iOS-specific routes (MS Graph proxy, enrichment, session ingest) and the existing review/admin UIs.

Both live here; both target the same user; both ship together logically.

## What this repo is not

- **Not a backend rewrite.** The server is seeded from `diary-processor/webapp/`. Most of the work in S1–S3 is removing n8n wiring and adding iOS routes, not rebuilding the pipeline.
- **Not cross-platform.** iOS only, specifically iPhone 17 Pro + iOS 26.
- **Not a product.** Personal tool, no multi-user, no cloud auth, no App Store.
- **Not an Obsidian replacement.** Obsidian is retired from this workflow.
- **Not dependent on `diary-processor` at runtime.** It has been absorbed. The old repo is archived and no longer runs. No data migration — Voice Diary starts with fresh Postgres + Qdrant.

## Layout

```
voice-diary/
├── README.md                   (top-level orientation)
├── CLAUDE.md                   (this file)
├── SPEC.md                     (full product + technical spec)
├── DEVELOPMENT.md              (build, deploy, milestones)
├── LICENSE
├── ios/                        (iOS app — empty until M1)
│   └── README.md
└── server/                     (FastAPI backend — populated, working)
    ├── README.md
    ├── .env.example            (has n8n vars to remove in S1)
    ├── docker-compose.yml      (needs Whisper service added in S1)
    ├── docs-archive/           (historical diary-processor design docs)
    └── webapp/                 (FastAPI app, ~2200 LOC, 17 Python modules)
        ├── Dockerfile
        ├── main.py             (~60 routes; see below for what to modify)
        ├── db.py, document_processor.py, entity_detector.py, ...
        ├── requirements.txt    (needs `msal` added in S2)
        ├── schema.sql, seed.sql
        ├── skeleton/           (markdown used by prompts)
        ├── templates/          (HTMX review + admin UI)
        └── static/
```

When working in one component, stay inside that component's directory. Changes that cross the `ios/` ↔ `server/` boundary (e.g. a manifest schema change) must touch both sides in the same commit and update SPEC.md if the contract changes.

## End-to-end data flow

```
iOS drive-by capture (M4A, AAC-LC 16 kHz mono)
        │   on-device: Parakeet v3 streaming hypotheses
        │   wake-word: "hey voice diary" → ENRICHMENT branch (network round-trip)
        ▼
Evening walkthrough state machine (per-event loop)
  IDLE → BRIEFING → WALKING → CLOSING → INGESTING → DONE
        │   per-segment manifest: calendar_ref, todos_detected, ai_prompts[]
        ▼
POST /api/sessions   (multipart bundle, bearer token, Tailscale only)
        ▼
ffmpeg (→ 16 kHz mono WAV)  →  Whisper sidecar  →  transcript_corrector (Ollama)
        ▼
entity_detector  (4-pass: exact / normalized / fuzzy ≤2 / first-name)
        │   short-circuited for attendees when calendar_ref is present
        ▼
document_processor  →  narrative markdown (with KW / quarter / month anchors)
        ▼
LightRAG ingest  +  Qdrant vectors  +  Postgres rows
        ▼
HTMX review UI (entity correction)  →  dictionary growth
```

Enrichment is the only mid-session network path. Everything else on the phone is on-device.

## SPEC.md section map

`SPEC.md` is the single source of truth for behaviour. Quick index for future Claude:

- §3 — System architecture (component boundaries)
- §4 — On-device stack (engines + model files)
- §5 — Capture modes (drive-by, walkthrough, free reflection)
- §6 — Walkthrough state machine (full transitions)
- §7 — Enrichment wake-word flow
- §8 — Todo capture (explicit + implicit)
- §9 — Multilingual support (DE/EN routing, fallback rules)
- §10 — Ingest contract (manifest schema, segment types, endpoints)
- §11 — Opener templates (DE + EN tables, selection rule)
- §12 — Settings model
- §13 — Storage (retention, locations)
- §14 — Onboarding
- §15 — Error handling (error UI states, manual scenarios)

## What's in `server/webapp/` already (do not rewrite)

These are working and carry over:

- **Entity detection** (`entity_detector.py`) — 4-pass: exact / normalized / fuzzy (Levenshtein ≤ 2) / first-name. Dictionary grows per review session.
- **Document processing** (`document_processor.py`) — LightRAG context retrieval, Ollama analysis, narrative markdown generation with temporal anchors (KW, quarter, month), LightRAG ingest. Docstring explicitly says "ports the n8n Analysis → LightRAG workflow to Python" — this is already local.
- **Transcript correction** (`transcript_corrector.py`) — Ollama-based ASR error correction.
- **Skeleton sync** (`skeleton_sync.py`, `bone_generator.py`) — structural entity graph synced to LightRAG as discrete "bones".
- **Review UI** (`templates/` + HTMX) — human-in-the-loop entity correction.
- **Admin UI** — persons/terms/variations management.
- **Harvest integration** (`harvest_llm.py`, `harvest_patterns.py`) — calendar → Harvest pattern matching and time-entry generation.
- **Vector store** (`vector_store.py`) — Qdrant client for contextual learning.
- **Postgres schema** (`schema.sql`) — 17 tables. No changes needed for iOS.

## What needs modification in `server/webapp/main.py`

S1 removes n8n and pulls audio processing in-process. The full task list with exact env-var names, call-site counts, and exit criteria lives in **DEVELOPMENT.md §4.3** — read it there rather than duplicating it here. All other routes carry over unchanged.

## What gets added

- `webapp/routers/` — iOS-specific routers (calendar in S2; email, sessions, lightrag, health land in S3). Mounted into the existing FastAPI app. Bearer-token `Depends` is per-router, not global.
- `webapp/routers/auth.py` — bearer-token `Depends` (S2).
- `webapp/msgraph_client.py` — MSAL public client + persistent token cache, async Graph wrapper (S2).
- `scripts/msgraph_bootstrap.py` — one-time device-code OAuth flow (S2).
- `scripts/issue_ios_token.py` — bearer-token generator (S2).
- ffmpeg installed in `webapp/Dockerfile` (S1).
- Whisper service in `docker-compose.yml` (S1, with CPU/GPU image variants via `WHISPER_IMAGE_TAG`).

## On-device stack (iOS)

| Layer | Engine |
|---|---|
| STT | Parakeet v3 via `FluidInference/FluidAudio` |
| TTS | Piper via `k2-fsa/sherpa-onnx` iOS xcframework (`de_DE-thorsten-high` + `en_US-lessac-high` bundled) |
| Dialog LLM | Apple Foundation Models (iOS 26) |
| Wake-word detection | Streaming regex on Parakeet output |
| Audio encoding | AAC-LC (16 kHz, mono, 64 kbps) in M4A |

Gemma 4 E4B via MLX Swift is the documented fallback if Apple Foundation Models proves insufficient. Keep the dialog LLM interface abstracted so the swap is a single-file change.

## Server stack

| Layer | Choice |
|---|---|
| Framework | FastAPI |
| Runtime | Python 3.12 in Docker |
| Database | PostgreSQL 16 (Docker sidecar) |
| Vector store | Qdrant (Docker sidecar) |
| ASR | Whisper HTTP service (Docker sidecar, added in S1) |
| Audio conversion | ffmpeg installed in webapp container |
| LLM | Ollama (external, reachable by URL) |
| Knowledge graph | LightRAG (external, reachable by URL) |
| Microsoft Graph | MSAL device-code flow, refresh tokens in `data/msal_cache.bin` |
| Exposure | Tailscale interface only, port 8000 |
| Auth to iOS | Single bearer token in `.env`, validated on iOS-only routes |

## Target device

**iPhone 17 Pro, iOS 26.** No need to support older devices or older iOS versions. The iOS code may use any iOS 26 API without guards.

## Commands

### Server

```bash
# First-time setup
cd server
cp .env.example .env                                    # then edit; required vars in DEVELOPMENT.md §4.4
docker compose up -d                                    # brings up webapp + postgres + qdrant + whisper

# One-time MSAL device-code OAuth (after S2 lands)
docker compose run --rm webapp python scripts/msgraph_bootstrap.py

# Day-to-day
docker compose logs -f webapp                           # tail webapp logs
docker compose restart webapp                           # after a code change without rebuild
docker compose build webapp && docker compose up -d webapp   # after a Dockerfile / requirements change

# Smoke-test an iOS-only endpoint over Tailscale
curl -H "Authorization: Bearer $IOS_BEARER_TOKEN" http://<tailnet-host>:8000/health

# Tests (run inside the webapp container so deps + env match prod)
docker compose run --rm webapp pytest webapp/tests/                        # full suite
docker compose run --rm webapp pytest webapp/tests/test_sessions.py        # single file
docker compose run --rm webapp pytest webapp/tests/test_sessions.py::test_post_session_happy_path  # single test
```

### iOS (after M1)

```bash
open ios/VoiceDiary.xcodeproj

# Build for the user's device
xcodebuild -scheme VoiceDiary -destination 'platform=iOS,name=Florian iPhone' -configuration Debug build

# Tests on the iPhone 17 Pro simulator
xcodebuild test -scheme VoiceDiary -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Single test class
xcodebuild test -scheme VoiceDiary \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:VoiceDiaryTests/StateMachineTests
```

The iOS app reads server URL + bearer token from Keychain (set during onboarding); no plist edits required.

## Sibling repos (reference only — never modified)

- **`murmur`** — macOS reference for Swift patterns: Parakeet STT via FluidAudio (`SharedSources/`), PTT state machine (`Sources/main.swift`), local HTTP server (`Sources/MurmurHTTPServer.swift`), podcast interrupt pattern (`Sources/PodcastManager.swift`). Note: murmur uses Kokoro TTS which does NOT support German; Voice Diary uses Piper via sherpa-onnx. Do not port murmur's TTS code verbatim.
- **`obsidian-voice-ai-journal`** — v1 predecessor. Origin of the "Hey Voice AI Journal" trigger, echoed here as "hey voice diary". No code dependency.
- **`diary-processor`** — archived. Its `webapp/` has been copied into this repo's `server/webapp/`. Do not reference or update the original repo.

## Development conventions

- **iOS**: Swift 6, SwiftUI App lifecycle, iOS 26 SDK, Xcode 16.2+, SwiftPM. UI strings in German (primary) + English (fallback). Code and comments in English.
- **Server**: Python 3.12, FastAPI, Pydantic v2, asyncpg. The existing codebase uses plain dicts and manual SQL in places — follow the existing style; don't introduce SQLAlchemy or a different ORM.
- **Commit style**: short, imperative, no Claude attribution (mirrors the convention in `murmur/CLAUDE.md`).
- **No telemetry, ever.** Errors log locally only. No outbound traffic except to the user's own server over Tailscale.
- **Test before claiming done.** For UI and voice features, actually run the feature on a real iPhone end-to-end before reporting completion. For server changes, `docker compose up -d` and hit the affected endpoint.
- **Secrets never committed.** `.env`, Keychain entries, `data/msal_cache.bin` stay out of git. `.gitignore` must cover these.

## Key constraints (load-bearing — do not relax without re-reading SPEC.md)

1. **Audio is never chopped.** The wake-word span is filtered from transcripts only. The raw M4A keeps everything.
2. **Max one follow-up question per event.** The AI opens a door; it does not interview.
3. **All Microsoft Graph access is on the server.** No MSAL on the phone. No OAuth UI on the phone.
4. **Todos are detected implicitly on-device but confirmed only at CLOSING.** Never interrupt mid-flow for a todo candidate.
5. **Enrichment is the only path that uses the network mid-session.** Everything else is on-device. Enrichment has an audible "einen Moment…" cue specifically so the user knows why there's latency.
6. **Tailscale, not public endpoints.** The server must never be publicly reachable.
7. **Segmented ingest, not monolithic.** Per-calendar-event segments with explicit `calendar_ref`. Drive-by seeds are their own segment type. Empty blocks are their own type. Free reflection is its own type. AI prompts live in `ai_prompts[]`, never in narrative transcripts.
8. **No n8n.** Anywhere. If you encounter n8n references in copied code, remove them as part of S1.

## When implementing

- **Always consult SPEC.md for behavior questions.** Single source of truth for state machine, manifest, endpoints, UX defaults.
- **Follow DEVELOPMENT.md's milestone order.** Do not skip ahead to M6 dialog work before M2 capture and M3 upload are dogfoodable. Server milestones (S1–S4) gate specific iOS milestones (M3, M5, M7) — see §6 dependency diagram.
- **Read existing code before changing it.** The `webapp/` is a copy of a working app. Understand what a route does before modifying it. Check imports before moving files.
- **Prefer simpler implementations.** The spec already rejected several over-engineered options (audio chopping, on-device Graph OAuth, trained wake-word models, separate server component). When in doubt, pick the simpler path and note it for review.
- **Update docs alongside code.** If you change a manifest field or an endpoint shape, update SPEC.md in the same commit.

## Language support

German is the primary language. English is a first-class second language. The user explicitly records in both and may switch mid-session. Do not treat English as a fallback or a secondary concern. The settings model allows independent control of recording language, response language, and voice per language.

## Testing

- **Server unit tests**: FastAPI test client against each router. Mock MSAL, LightRAG, Ollama, Whisper.
- **Server integration tests**: real `docker compose up`, hit endpoints with `httpx`, verify side effects.
- **iOS unit tests**: opener template selection, manifest encoding, state machine transitions, wake-word matcher.
- **iOS integration tests**: `ServerClient` against a local `docker compose up` of `server/`.
- **Manual scenarios per milestone** in DEVELOPMENT.md §7. Run them before merging anything to main.
