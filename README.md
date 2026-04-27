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
├── ios/                (Swift 6 / SwiftUI — populated in iOS M1)
│   └── README.md
└── server/             (FastAPI — already populated, needs n8n cleanup + iOS routes)
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

Design complete and server seeded from `diary-processor` as of 2026-04-24.

- Server track: implementation starts at S1 (n8n removal + local audio pipeline). See `DEVELOPMENT.md §4`.
- iOS track: implementation starts at M1 (Xcode project foundation). See `DEVELOPMENT.md §5`.
- The prior `diary-processor` repo is archived; no data migration is carried over.
