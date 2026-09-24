# Voice Diary

Personal voice-diary system for a German-speaking CTO. Two components, one repo:

- **`ios/`** — iOS app (iPhone 17 Pro, iOS 26) for drive-by thought capture and structured evening conversational walkthroughs of the day's calendar.
- **`server/`** — FastAPI backend (seeded from the prior `diary-processor` codebase on 2026-04-24). Owns the full pipeline: audio conversion, Whisper ASR, 4-pass entity normalization, Ollama analysis, narrative generation, LightRAG ingest — plus new iOS-specific routes for session ingest, Microsoft Graph proxy (calendar + email), and enrichment retrieval.

## Quick map

```
voice-diary/
├── README.md           (this file)
├── CLAUDE.md           (instructions for Claude Code working in this repo)
├── SPEC.md             (full product + technical specification)
├── DEVELOPMENT.md      (build, deploy, and milestone plan for both tracks)
├── LICENSE
├── ios/                (Swift 6 / SwiftUI — actively developed, see ios/README.md)
│   └── README.md
└── server/             (FastAPI — n8n removed, iOS routers added on top of the seed)
    ├── .env.example
    ├── docker-compose.yml
    ├── docs-archive/   (historical design docs from diary-processor)
    └── webapp/         (FastAPI app, 17 Python modules, Postgres schema, HTMX UI)
```

## Where to start reading

1. **`SPEC.md`** — what the system does, how the pieces fit, API contract, state machine.
2. **`DEVELOPMENT.md`** — how to build it, what to deploy where, milestone-by-milestone plan.
3. **`CLAUDE.md`** — agent guidance; read this before asking Claude Code to do anything here.

## Runtime dependencies

External services the server talks to:

- **LightRAG** — knowledge graph + hybrid retrieval. Queried for enrichment and for yesterday's open todos.
- **Ollama** — local LLM for ASR correction, transcript analysis, narrative generation, and enrichment summarisation.
- **Microsoft Graph** — Exchange calendar + email. OAuth tokens held server-side; iOS never sees them.

Everything else (Postgres, Qdrant, Whisper, ffmpeg) ships in the server's Docker Compose stack.

## Status

Design complete; both tracks have been in active implementation for a while — this is not a
fresh scaffold. `DEVELOPMENT.md`'s milestone lists describe the original build plan, not a live
status board; check `git log`, `ios/README.md`, and the actual directories for current state.

- Server track: work has landed well beyond the seed — S1's n8n removal and audio pipeline
  (ffmpeg + a Whisper sidecar), S2's MSAL Graph client, and S3's iOS-facing routers
  (`webapp/routers/{calendar,sessions,email,lightrag,health}.py`) are all on disk on top of the
  `diary-processor` seed. See `DEVELOPMENT.md §4` for what's tracked as remaining.
- iOS track: well past M1 — `ios/Sources/` has capture, dialog, TTS, storage and UI modules plus
  a widget extension. See `ios/README.md` for current milestone-by-milestone status.
- The prior `diary-processor` repo is archived; no data migration is carried over.
