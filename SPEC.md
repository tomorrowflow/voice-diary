# Voice Diary — Specification

**Status:** Design complete, ready for implementation.
**Date:** 2026-04-24
**Target iOS platform:** iPhone 17 Pro on iOS 26.
**Target server platform:** Linux host running Docker with a single `docker compose up` stack.
**Primary user:** Florian Wolf (German-speaking CTO). Personal tool, not a product.

---

## 1. Overview

Voice Diary is a **monorepo** containing two tightly coupled components:

- **`ios/`** — a context-aware iOS app for daily spoken reflection. Replaces ad-hoc voice-memo recording with a structured, conversational evening walkthrough of the user's day, plus low-friction drive-by capture during the day.
- **`server/`** — a FastAPI service seeded from the existing `diary-processor` codebase. It owns the full pipeline: audio upload, FFMPEG conversion, Whisper ASR (via a sibling Docker container), 4-pass entity normalization, Ollama-based analysis, narrative generation, LightRAG ingest, and the existing HTMX review/admin UI. For the iOS app it additionally proxies Microsoft Graph (calendar + email) with server-side MSAL tokens and proxies LightRAG queries for enrichment.

The iOS app is the **capture layer**. It does not re-implement ASR, entity normalization, or knowledge-graph ingestion. The `server/` component is the **full backend** — one FastAPI app, one Docker Compose stack, no external workflow engine.

### 1.1 Repo layout

```
voice-diary/
├── README.md
├── CLAUDE.md
├── SPEC.md              (this file)
├── DEVELOPMENT.md
├── ios/                 (Swift 6 / SwiftUI app)
└── server/              (FastAPI service)
```

### 1.2 Relationship to other repos

| Repo | Role for Voice Diary |
|---|---|
| `diary-processor` | **Superseded.** Its `webapp/` source tree has been copied into `server/webapp/` as the seed of the merged server. The original repo is archived; no data migration is carried over — Voice Diary starts with a fresh Postgres and Qdrant. |
| `murmur` | **Reference implementation** for Parakeet STT + push-to-talk state machines + local HTTP server patterns. Source of proven Swift code that the iOS app can adapt. Note: murmur uses Kokoro TTS, which does not support German; Voice Diary uses Piper via sherpa-onnx instead. |
| `obsidian-voice-ai-journal` | **v1 predecessor.** Origin of the "Hey Voice AI Journal" trigger, echoed here as "hey voice diary". Obsidian is not a target of this iteration. |

### 1.3 Why an iOS app, not another Obsidian plugin / macOS app

- The user records diaries in varied contexts (commute, end of day, between meetings). A phone is the only device always present.
- The Action Button on iPhone 15 Pro+ enables single-press drive-by capture that other surfaces can't match.
- iOS 26's Foundation Models + Parakeet via FluidAudio + Piper via sherpa-onnx make a fully on-device conversational stack possible, which is the only way to meet the latency expectation for natural dialog.

---

## 2. Goals & non-goals

### Goals

- Two capture modes: short drive-by thoughts + structured evening walkthrough, both feeding one pipeline.
- Calendar-chronological walkthrough conversation in German or English (user's choice per session, mixed OK).
- On-device generation of voice, text, and audio where possible. Server only for retrieval/enrichment.
- Pre-structured ingest to the server: per-event segmentation, attendee references, pre-extracted todos, stripped AI prompts.
- Offline-tolerant: drive-by capture works without Tailscale; session upload queues and retries.
- Personal-tool ergonomics: no account system, no cloud auth on the phone, no telemetry.

### Non-goals (explicitly parked)

- Weekly retrospective (will be a future extension).
- Apple Watch capture.
- Full offline mode for evening walkthrough (enrichment requires network; first ship is online-only for walkthrough).
- Voice persona / AI name / custom voice cloning.
- Productization / multi-user / App Store distribution.
- Obsidian integration.

---

## 3. System architecture

Two tiers: **iOS app** (this repo, `ios/`) and **the server** (this repo, `server/`). The server is a single FastAPI app with sidecar Docker services (Postgres, Qdrant, Whisper). No workflow engine. One stack, one `docker compose up`.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Tier 1: iPhone 17 Pro / iOS 26                                      │
│                                                                      │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────────────┐    │
│  │  Mic         │──▶│  Parakeet v3 │──▶│  Dialog state machine  │    │
│  │ (AVAudioEng) │   │  (FluidAudio)│   │  + wake-word detector  │    │
│  └──────┬───────┘   └──────────────┘   └───────┬────────────────┘    │
│         │                                      │                     │
│         ▼                                      ▼                     │
│  ┌──────────────┐                   ┌──────────────────────────┐     │
│  │  AAC encoder │                   │  Apple Foundation Models │     │
│  │  (M4A files) │                   │  (dialog LLM, on-device) │     │
│  └──────────────┘                   └──────────────────────────┘     │
│                                                 │                    │
│                                                 ▼                    │
│                                     ┌──────────────────────────┐     │
│                                     │  Piper TTS (sherpa-onnx) │     │
│                                     │  de_DE + en_US voices    │     │
│                                     └──────────────────────────┘     │
│                                                                      │
└──────────────────────────────────────────┬───────────────────────────┘
                                           │ Tailscale
                                           │ HTTPS + bearer token
                                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Tier 2: server/ (this repo) — single Docker Compose stack          │
│  Tailscale-only exposure, port 8000.                                 │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ webapp (FastAPI, Python 3.12, seeded from diary-processor)     │  │
│  │                                                                │  │
│  │  Existing routes carried over (now n8n-free):                  │  │
│  │    POST /api/transcripts           direct audio+transcript in  │  │
│  │    GET  /review/{id}               HTMX entity review UI       │  │
│  │    POST /api/transcripts/{id}/submit  in-app LLM analysis      │  │
│  │    GET  /admin                     persons/terms admin         │  │
│  │    GET  /harvest                   time-tracking UI            │  │
│  │    GET  /ingest                    audio upload page           │  │
│  │    POST /api/ingest/upload         (rewritten: local pipeline) │  │
│  │    + ~50 other routes                                          │  │
│  │                                                                │  │
│  │  New routes for iOS (added as routers):                        │  │
│  │    POST /api/sessions              multipart session ingest    │  │
│  │    GET  /today/calendar            MS Graph via MSAL           │  │
│  │    GET  /calendar/event/{id}       MS Graph                    │  │
│  │    GET  /email/search              MS Graph                    │  │
│  │    POST /lightrag/query            enrichment retrieval        │  │
│  │    GET  /yesterday/open-todos      briefing context            │  │
│  │    GET  /health                    upstream-aware probe        │  │
│  │                                                                │  │
│  │  In-process pipeline (all Python, all local):                  │  │
│  │    ffmpeg (system) → whisper service → transcript_corrector.py │  │
│  │      → entity_detector.py (4-pass) → document_processor.py     │  │
│  │      → LightRAG ingest. Skeleton sync, bone generator, and     │  │
│  │      Qdrant-backed vector store available as before.           │  │
│  └──┬──────────┬────────────┬──────────────┬──────────────┬───────┘  │
│     │          │            │              │              │          │
│     ▼          ▼            ▼              ▼              ▼          │
│  ┌──────┐ ┌─────────┐ ┌─────────┐ ┌──────────────┐ ┌───────────┐     │
│  │ pg   │ │ qdrant  │ │ whisper │ │  LightRAG    │ │  Ollama   │     │
│  │:5432 │ │:6333/34 │ │  :9000  │ │  :9621       │ │  :11434   │     │
│  │compose│ │compose  │ │ compose │ │  external    │ │  external │     │
│  └──────┘ └─────────┘ └─────────┘ └──────────────┘ └───────────┘     │
│                                                                      │
│  Upstream for MS Graph (OAuth bootstrapped once per server):         │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ Microsoft Graph — Exchange calendar + email                  │    │
│  │ (MSAL refresh tokens in server/data/msal_cache.bin)          │    │
│  └──────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.1 Why Microsoft Graph access lives on the server

MSAL-iOS on the phone would require token storage, refresh, background fetch, and re-auth on device loss. The server runs continuously on a persistent host; one OAuth setup there serves any client. The iOS app calls simple REST endpoints over Tailscale and never sees a Microsoft token.

### 3.2 Why Tailscale and not a public endpoint

The server holds OAuth refresh tokens for the user's Exchange account, the full LightRAG knowledge graph of the user's work life, and the Postgres database of persons/terms/transcripts. None of that should touch the public internet. Tailscale gives zero-config secure connectivity between the phone and the server with no ingress exposed.

### 3.3 Why the server is seeded from `diary-processor`, not rebuilt

`diary-processor`'s `webapp/` is an already-working FastAPI app with the entity pipeline, LightRAG ingest, review UI, admin, and Harvest integration. Rewriting that from scratch would waste 6–12 months of prior work. Voice Diary copies it wholesale into `server/webapp/` and extends it:

- Existing routes (`/api/transcripts`, `/review/*`, `/admin/*`, `/harvest/*`) are preserved as-is — they remain useful for processing voice memos and managing the entity dictionary.
- New routes (`/api/sessions`, `/today/calendar`, `/email/search`, `/lightrag/query`, `/yesterday/open-todos`, `/health`) are added as FastAPI routers.
- n8n is removed: audio ingest moves into the webapp (ffmpeg in-container + a Whisper Docker service), calendar fetch moves to direct MS Graph calls, and the vestigial `_forward_to_n8n()` in the submit flow is deleted (`document_processor.py` already does the analysis locally).
- No data migration. Voice Diary starts with fresh Postgres and Qdrant volumes.

### 3.4 Server responsibilities

The server in `server/` is one FastAPI app with three clusters of responsibility:

**Existing (from diary-processor), preserved:**
- Audio ingest (from the web UI and from `process-diaries.sh`-style batch scripts).
- 4-pass entity normalization (persons, terms, variations dictionary).
- Transcript correction via Ollama.
- Document processing: LightRAG context retrieval → Ollama analysis → narrative markdown with temporal anchors → LightRAG ingest.
- HTMX review UI for human-in-the-loop entity correction.
- Admin UI for persons/terms/variations management.
- Harvest time-tracking integration (calendar → pattern matching → time entries).
- Skeleton sync for structural graph bones.

**New for iOS:**
- Session ingest: `POST /api/sessions` receives multipart bundles, runs each segment through the entity pipeline, ingests into LightRAG.
- Microsoft Graph proxy: `/today/calendar`, `/calendar/event/{id}`, `/email/search` with server-side MSAL tokens.
- Enrichment: `/lightrag/query` and `/yesterday/open-todos` call LightRAG (external) and summarise via Ollama.
- Health: `/health` reports upstream liveness for LightRAG, Ollama, Whisper, and Postgres.

**Removed (formerly in n8n):**
- Audio conversion (ffmpeg now runs in the webapp container).
- ASR (Whisper runs as a sibling Docker service called directly).
- LLM analysis routing (the submit flow calls `document_processor.py` directly).
- Calendar webhook (replaced by direct MS Graph calls).

### 3.5 Deployment posture

- Single `docker-compose.yml` under `server/` brings up: webapp + postgres + qdrant + whisper.
- LightRAG and Ollama are external services on the same host or reachable by URL; their endpoints come from `.env`.
- Exposed port is 8000 (matches what any existing external integrations already point at). Bound to the Tailscale interface only.
- Bearer token in `server/.env` authenticates the iOS app for the iOS-only routes. Existing routes remain open to the internal Docker network (same as before).
- MSAL refresh tokens persist under `server/data/msal_cache.bin`. Bootstrapped once via `server/scripts/msgraph_bootstrap.py` (device-code flow), then auto-renewed.

---

## 4. On-device stack

| Layer | Engine | Rationale |
|---|---|---|
| STT | **Parakeet v3 via FluidAudio** | ~210× realtime, multilingual (25 languages incl. DE & EN), streaming hypotheses, already validated in `murmur`. |
| TTS | **Piper via sherpa-onnx iOS xcframework** | Only serious open German voice (`de_DE-thorsten-high`). ~75 MB per voice, Apache 2.0 runtime + MIT weights, RTF ~0.2–0.3 on A-series. Kokoro-82M used in `murmur` does not support German. |
| Dialog LLM | **Apple Foundation Models (iOS 26)** | 3B on-device on ANE, German first-class, zero app-size hit, thermal-efficient, no memory-limit entitlement needed. |
| Enrichment LLM | **Ollama over Tailscale** | Only invoked on wake-word. Server model is bigger and better for summarising retrieved email/LightRAG results. Audible "einen Moment…" cue masks network latency. |
| Wake-word detection | **Streaming regex on Parakeet** | No dedicated model. "hey voice diary" is 3 words — Levenshtein ≤ 2 on the rolling hypothesis is robust. Zero new dependencies, zero extra battery cost during listening states. |
| Audio encoding | **AAC-LC via AVAudioFile** | Speech-optimised: 16 kHz, mono, 64 kbps. ~0.5 MB/min. Perceptually transparent for speech, 10-20× smaller than WAV. |

### 4.1 Apple Foundation Models usage

Used for three jobs, all short-context:

1. **Follow-up question generation** — given an event title + attendees + last user utterance, produce one German (or English) follow-up sentence. Max one per event.
2. **Intent classification on wake-word utterances** — classify `email_lookup | past_diary | calendar_detail | unknown` so `server` can route the enrichment query correctly.
3. **Implicit todo candidate detection** — scan a segment transcript at segment close, flag sentences that look like "I need to X / ich muss noch X" as candidates. Candidates are not confirmed mid-flow; they're presented in batch at session close.

Not used for: heavy summarisation, long-context synthesis, any retrieval. Those go to the server.

### 4.2 Fallback plan

If Apple Foundation Models turns out to be German-weak or tonally wrong in real use, swap the dialog LLM to **Gemma 4 E4B (4-bit MLX Swift)**. Apache 2.0, ~3 GB in bundle, requires `com.apple.developer.kernel.increased-memory-limit` entitlement. The dialog manager's interface should be abstracted so the swap is a single-file change, not a rewrite.

---

## 5. Capture modes

### 5.1 Drive-by capture

Purpose: grab short thoughts during the day without forcing structure. Content surfaces in the evening walkthrough at the matching time slot.

**Triggers:**
- Lock screen widget (tap to start/stop)
- Action Button (press to start, press again to stop, or auto-stop after 3s silence)
- Foreground app (mic button)

**Flow:**
```
IDLE
  ▼ trigger
DRIVEBY_RECORDING
  - Parakeet streams transcript live
  - AVAudioFile writes M4A to local store
  - Haptic pulse on start
  ▼ second trigger OR 3s silence
DRIVEBY_SAVED
  - Transient notification: "12s erfasst — bis heute Abend"
  - Notification auto-dismiss duration: configurable (default 4s)
  - Haptic confirmation pulse
  ▼
IDLE
```

**Metadata captured with each drive-by:**
- Capture timestamp (UTC)
- Duration
- Detected language
- Active calendar event ID if one is currently in progress (from `/today/calendar`)
- No geolocation (parked; may add if the user wants it later)

### 5.2 Evening walkthrough

Purpose: structured reflection across the full workday, with calendar events as conversational anchors.

Entry points:
- Notification at configured end-of-workday time (user-dismissible)
- App foreground during evening window
- Manual launch

See §6 for the full state machine.

---

## 6. Walkthrough state machine

### 6.1 Top level

The walkthrough runs an ordered **section plan** built in `WalkthroughCoordinator.begin()` from `WalkthroughSettingsStore.order` (see §12) plus the day's filtered calendar events plus any unsurfaced drive-by seeds. Three section kinds:

| Kind | Cardinality | Produces |
|---|---|---|
| `general` | 0..N (user-defined) | one `general_section` segment per occurrence |
| `calendar_events` | 0..1 (singleton) | one `calendar_event` segment per event |
| `drive_by` | 0..1 (singleton) | one `free_reflection` segment + one `drive_by` segment per surfaced seed |

The user reorders these in **Mehr → Walkthrough → Reihenfolge** and edits / adds general sections in **Mehr → Walkthrough → Abschnitte**. Default plan = `[calendar_events, drive_by]` (the original behaviour, no generals).

```
IDLE
  │ user opens app in evening window
  ▼
BRIEFING                         ← AI speaks day summary
  │ briefing complete or user says "start"
  ▼
PLAN_LOOP                        ← iterate the section plan
  │
  │  for each section in plan:
  │    case general          → GENERAL_OPENER → GENERAL_LISTENING
  │    case calendar_events  → per-event loop (§6.2), one EVENT_LISTENING per event
  │    case drive_by         → DRIVEBY_OPENER (recap intro) → DRIVEBY_LISTENING (free reflection)
  │
  ▼
TODO_CONFIRM (if implicit candidates) ← per-candidate ja / nein / anders pass (§8.2)
  │
  ├─ if older missing days → GAP_PROMPT (§6.5) → loop back to BRIEFING for that day
  ▼
INGESTING                        ← multipart upload to /api/sessions
  │
  ▼
DONE
```

State cases (`Sources/Dialog/WalkthroughState.swift`): `.briefing`, `.eventOpener(stepIndex, eventIndex)`, `.eventListening(stepIndex, eventIndex)`, `.generalOpener(stepIndex, sectionID)`, `.generalListening(stepIndex, sectionID)`, `.driveByOpener(stepIndex)`, `.driveByListening(stepIndex)`, `.confirmingTodos(index)`, `.ingesting`, `.done`. The legacy `.closingPrompt` / `.closingListening` cases are subsumed by `.driveByOpener` / `.driveByListening` — drive-by surfacing and the closing free reflection are now one section.

### 6.2 Per-event loop

```
EVENT_ENTER
  AI speaks an opener (see §11 for template selection)
  ▼
EVENT_LISTENING  ◀─────────────────────────────────┐
  mic open, user reflects                          │
  │                                                │
  ├─ wake-word detected        → ENRICHMENT ───────┘ (resumes here)
  ├─ explicit todo phrase      → TODO_CAPTURE  ────┘
  ├─ "next" / "skip"           → EVENT_EXIT
  ├─ "back"                    → prev event's EVENT_ENTER (one level only)
  ├─ "pause"                   → SESSION_PAUSED
  ├─ "I'm done talking"        → CLOSING
  ├─ lull 3s                   → keep listening
  ├─ lull 6s, no follow-up yet → FOLLOW_UP_DECISION
  ├─ lull 15s                  → AI: "soll ich weiter?" → yes=EVENT_EXIT, no=keep listening
  └─ drive-by seed time match  → SEED_SURFACE (once per seed per event)

FOLLOW_UP_DECISION
  Apple Foundation Models scores "did the user leave depth on the table?"
  ├─ yes, first time     → FOLLOW_UP_ASK → back to EVENT_LISTENING
  └─ otherwise            → EVENT_EXIT

EVENT_EXIT
  brief beat (~600 ms), then next event or DRIVEBY_RECAP
```

**Hard rule:** max one follow-up question per event. The AI opens a door, does not interview.

### 6.3 Empty-block handling

Between adjacent events, if the gap is ≥ 30 min (configurable) and falls inside configured workday hours:

```
EMPTY_BLOCK
  AI: "Zwischen 14 und 16 Uhr hattest du keinen Termin — irgendwas Wichtiges?"
  ├─ user reflects → captured as free_reflection segment → next event
  └─ "nein" / silence 4s → next event silently
```

### 6.4 Drive-by seed surfacing

Two paths:

**Inline during WALKING** — when the current event overlaps a drive-by seed's capture time (±30 min window):

```
SEED_SURFACE
  AI: "Übrigens — um 11:15 hast du etwas zur Azure-Migration aufgenommen. Willst du das vertiefen?"
  ├─ yes    → Piper plays the seed transcript → back to EVENT_LISTENING; seed now linked to event
  ├─ no     → seed marked dismissed, continue event
  └─ silence 3s → treat as "no"
```

**End-of-day recap** (if toggle enabled in settings):

```
DRIVEBY_RECAP
  if any seeds remain unsurfaced and not dismissed:
    AI: "Drei Notizen sind noch offen — [1/2/3]. Welche willst du noch aufgreifen?"
    user picks 0..N → each becomes its own free-form reflection segment
  else skip to CLOSING
```

Unused seeds still ingest as independent `drive_by` segments with no event linkage.

### 6.5 Multi-day gap handling

The app tracks which dates have been successfully ingested. On entering CLOSING:

```
GAP_PROMPT
  earliest_missing = the oldest date in [today - gap_cap, today] that has no successful ingest
  if earliest_missing < today:
    AI: "Am {earliest_missing} hast du auch kein Diary aufgenommen. Weiter mit dem Tag?"
    ├─ yes → back to BRIEFING for earliest_missing (calendar/emails for THAT day)
    └─ no  → INGESTING for today; older days remain queued
```

Walk forward from oldest to newest so the user always catches up in chronological order. Gap cap configurable, default **7 days**.

### 6.6 User interrupts (available from any listening state)

| Phrase / input | Action |
|---|---|
| "Next" / "weiter" | Skip current event, advance |
| "Skip" / "überspringen" | Same as next |
| "Back" / "zurück" | Return to previous event's opener (one level only) |
| "Pause" / "Pause" | Pause session, resumable |
| "I'm done talking" / "Ich bin fertig" | Jump to CLOSING |
| "Hey voice diary, …" | Enter ENRICHMENT with following query |
| App UI "End session" button | Jump to CLOSING |

### 6.7 Lull thresholds (configurable, defaults shown)

| Duration | Behavior |
|---|---|
| 3s | Nothing. Thinking is fine. |
| 6s | Trigger FOLLOW_UP_DECISION (once per event). |
| 15s | AI gently prompts "soll ich weitermachen?" |

### 6.8 RSVP filtering

Only events matching the user's RSVP filter are walked. Default: `Accepted + Tentative` (both considered "likely attended"). Configurable multi-select with a third option `All` for users who want to reflect even on declined meetings.

### 6.9 Closing

```
CLOSING
  1. AI: "Willst du noch etwas zum ganzen Tag sagen?"
     → free_reflection segment (optional, user can say "nein" to skip)

  2. If implicit todo candidates accumulated:
     AI reads each aloud, user says "ja" / "nein" / "anders: …"
     confirmed = status Offen in manifest
     rejected = discarded
     corrected = text replaced, status Offen

  3. Multi-day gap check (§6.5)

  4. → INGESTING
```

---

## 7. Enrichment wake-word flow

### 7.1 The phrase

**"hey voice diary"** — 6 syllables, phonetically distinct from natural diary prose, works in both German and English sessions because it's an intentional code-switch into English.

### 7.2 Detection

- Streaming regex with Levenshtein ≤ 2 against Parakeet's rolling ASR hypothesis (last ~3s window).
- Scoped to WALKING listening states only. Inactive during BRIEFING, while AI is speaking, during ENRICHMENT itself, or in IDLE.
- Zero new model or dependency.
- During the ~3s match window, Parakeet's language auto-detection is frozen to English to avoid detector wobble on the code-switch.

### 7.3 On match

```
match fires
  ▼
pause segment recording (audio continues to record, but the segment's active flag is cleared)
  ▼
capture continuation utterance until sentence-end or 3s lull
  → this is the enrichment query
  ▼
Apple FM classifies intent: email_lookup | past_diary | calendar_detail | unknown
  ▼
AI speaks ack: "Einen Moment, ich schaue nach…"
  ▼
route to server:
  - email_lookup     → GET /email/search?q=…         (server → MS Graph)
  - past_diary       → POST /lightrag/query          (server → LightRAG)
  - calendar_detail  → GET /calendar/event/{id}      (server → MS Graph)
  - unknown          → AI: "Kannst du das anders formulieren?"
  ▼
server summarises result via Ollama to 2–3 sentences in target response language
  ▼
Piper speaks the answer
  ▼
AI: "Zurück zum Termin…"
  ▼
resume segment recording
```

### 7.4 Audio & transcript handling

**Audio:** raw M4A stays untouched. No chopping.

**Transcript:** the wake-word span + enrichment query + AI answer are filtered out of the segment's final `transcript` field before ingest. The full exchange is preserved in the manifest's `ai_prompts[]` array for audit.

Filter logic is text-only:
```
original transcript:
  "… dann mit Monica gesprochen hey voice diary was hat Christian geschrieben
   zurück zum Termin … und danach Mittagspause"

filtered transcript:
  "… dann mit Monica gesprochen. … und danach Mittagspause"

ai_prompts[]:
  [{
    at: "2026-04-24T19:42:13+02:00",
    wake_word_matched: "hey voice diary",
    query: "was hat Christian geschrieben",
    intent: "email_lookup",
    answer: "Christian hat am Dienstag gefragt, ob …"
  }]
```

---

## 8. Todo capture

### 8.1 Explicit (inline, confirmed immediately)

Trigger phrases:
- German: "Todo:", "Aufgabe:", "Merke:", "Ich muss dringend"
- English: "Todo:", "Task:", "Remember:", "I need to urgently"

Flow:
```
TODO_CAPTURE
  parser extracts: text + optional due date (e.g. "bis Donnerstag", "by Friday")
  AI speaks short confirm: "Notiert: Board-Deck bis Donnerstag."
  append to session's explicit todos list, type=explicit, status=Offen
  ▼
  back to previous listening state
```

### 8.2 Implicit (batched, confirmed at CLOSING)

- Apple FM scans each segment transcript at segment close (not live — it's batch at segment boundaries).
- Flags sentences matching "ich muss noch X", "ich sollte Y", "I need to Z", "I should W" and similar patterns.
- Candidates are NOT interrupted or confirmed mid-flow. They accumulate silently.
- At CLOSING, AI reads each candidate aloud and asks for confirmation:

```
"Ich habe drei mögliche To-dos gefunden:
 1. Board-Deck vorbereiten
 2. Mit Christian telefonieren
 3. Azure-Zertifikat erneuern
 Welche bestätigen?"
```

- User says "ja, 1 und 3", "nein", or "1 korrigieren: Deck bis Dienstag, dann bestätigen".
- Confirmed = type=implicit, status=Offen.
- Rejected = discarded.
- False-positive rate accepted as a tunable target; ingest stores `type=implicit` vs `type=explicit` for later analysis.

### 8.3 Backend side

The server hands todos to the existing `document_processor.py` pipeline. The pipeline's narrative generation embeds todos with their German status labels (Offen / InArbeit / Abgeschlossen / Blockiert) so LightRAG sees them as typed entities. Todos ingested via `/api/sessions` enter in `Offen` status. State transitions in future sessions update the same LightRAG entities.

---

## 9. Multilingual support

### 9.1 Requirement

- Recording in German or English.
- Response in German or English.
- Mixed-language sessions (e.g. user speaks German, AI replies English) are valid, not edge cases.

### 9.2 Settings

| Setting | Values |
|---|---|
| Recording language | Auto-detect / German / English |
| Response language | Match input / Always German / Always English |
| German voice | Thorsten (high) / Eva / Karlsson |
| English voice | Lessac (high) / Alan (British) / Ryan |

### 9.3 Auto-detect behaviour

Parakeet v3 reports per-utterance language confidence. The app:
- For events ≥ 10 words: use Parakeet's detected language.
- For very short utterances (drive-by < 10 words or interjections): fall back to `Recording language` setting.
- Per-turn, the detected input language is plumbed to the dialog LLM's system prompt.
- The `Response language` setting determines which voice TTS uses and which language Apple FM is instructed to reply in.

### 9.4 Voice bundling

Three Piper voice models shipped inside the `.ipa`:
- `de_DE-thorsten-high` (required)
- `en_US-lessac-high` (default English)
- `en_GB-alan-medium` (alternative English, smaller; optional)

Total ~220 MB voice models in bundle. If bundle size is a concern later, voices 2 and 3 can move to in-app download.

### 9.5 Wake-word across languages

"hey voice diary" works regardless of the session's recording language — it's an English phrase, and Parakeet handles the code-switch cleanly. No per-language wake-word needed.

---

## 10. Ingest contract

The iOS app talks only to the server (`server/webapp/` — the merged FastAPI app). All routes below live in the same app. For each segment, the server runs the full diary-processor pipeline (ffmpeg → whisper → transcript_corrector → entity_detector → document_processor → LightRAG ingest) in-process.

### 10.1 Endpoint

**`POST /api/sessions`** — receives the multipart bundle, persists it under `server/data/sessions/{session_id}/`, then processes each segment synchronously (or via a background task for long sessions). There is no external hand-off.

### 10.2 Transport

`multipart/form-data` with:
- One `manifest.json` part (structured JSON, schema below).
- N audio parts, one per segment (`segments/s01.m4a`, `segments/s02.m4a`, …).
- One full-session audio part: `raw/session.m4a`.

All `audio_file` fields in the manifest reference these part names as relative paths.

### 10.3 Manifest schema

```json
{
  "session_id": "2026-04-24T19:30:00+02:00",
  "date": "2026-04-24",
  "device": "iphone-17-pro",
  "app_version": "0.1.0",
  "locale_primary": "de-DE",
  "audio_codec": {
    "codec": "aac-lc",
    "sample_rate": 16000,
    "channels": 1,
    "bitrate": 64000
  },
  "segments": [
    {
      "segment_id": "s01",
      "segment_type": "calendar_event",
      "calendar_ref": {
        "graph_event_id": "AAMkAD...",
        "title": "BYOD Policy Sync mit Monica",
        "start": "2026-04-24T10:00:00+02:00",
        "end": "2026-04-24T11:00:00+02:00",
        "attendees": ["monica.breitkreutz@enersis.com", "florian.wolf@..."],
        "rsvp_status": "accepted"
      },
      "audio_file": "segments/s01.m4a",
      "transcript": "Das Meeting mit Monica war produktiv ...",
      "language": "de-DE",
      "todos_detected": [
        { "text": "Board-Deck bis Donnerstag entwerfen", "type": "explicit", "due": "2026-04-30", "status": "Offen" }
      ],
      "linked_seed_ids": ["seed-2026-04-24T11:15:00"]
    },
    {
      "segment_id": "s02",
      "segment_type": "drive_by",
      "captured_at": "2026-04-24T11:15:00+02:00",
      "audio_file": "segments/s02.m4a",
      "transcript": "Gedanke zur Azure-Migration ...",
      "language": "de-DE",
      "linked_calendar_event_id": "AAMkAD...",
      "seed_id": "seed-2026-04-24T11:15:00"
    },
    {
      "segment_id": "s03",
      "segment_type": "free_reflection",
      "captured_at": "2026-04-24T19:42:00+02:00",
      "audio_file": "segments/s03.m4a",
      "transcript": "Generell heute war der Tag ...",
      "language": "de-DE"
    },
    {
      "segment_id": "s04",
      "segment_type": "empty_block",
      "time_range": { "start": "14:00", "end": "16:00" },
      "audio_file": "segments/s04.m4a",
      "transcript": "In der Zeit habe ich ...",
      "language": "de-DE"
    }
  ],
  "todos_implicit_confirmed": [
    { "text": "Azure-Zertifikat erneuern", "type": "implicit", "due": null, "status": "Offen", "source_segment_id": "s03" }
  ],
  "todos_implicit_rejected": [
    { "text": "Mit Christian telefonieren", "type": "implicit", "source_segment_id": "s01" }
  ],
  "drive_by_seeds_surfaced": ["seed-2026-04-24T11:15:00+02:00"],
  "drive_by_seeds_unsurfaced": [],
  "raw_session_audio": "raw/session.m4a",
  "ai_prompts": [
    { "at": "2026-04-24T19:31:00+02:00", "segment_id": "s01", "role": "opener", "text": "Wie ist das 10-Uhr Meeting mit Monica gelaufen?" },
    { "at": "2026-04-24T19:42:13+02:00", "segment_id": "s01", "role": "enrichment_query", "wake_word_matched": "hey voice diary", "query": "was hat Christian geschrieben", "intent": "email_lookup" },
    { "at": "2026-04-24T19:42:16+02:00", "segment_id": "s01", "role": "enrichment_answer", "text": "Christian hat am Dienstag gefragt, ob ..." }
  ],
  "response_language_setting": "match_input"
}
```

### 10.4 Segment types

| `segment_type` | Meaning |
|---|---|
| `calendar_event` | Reflection anchored to a specific Graph calendar event. `calendar_ref` required. |
| `drive_by` | Ad-hoc thought captured during the day. `captured_at` required. May be linked to an event via `linked_calendar_event_id`. Also written by the drive-by walkthrough section when surfacing existing seeds (one segment per seed, populated from the on-disk metadata). |
| `free_reflection` | Unanchored reflection captured during the drive-by section's listening phase or in response to an empty-calendar day. |
| `empty_block` | Reflection prompted by an empty block in the schedule. `time_range` required. |
| `general_section` | User-defined opener (§6 / §12). Required fields: `section_id` (stable UUID), `title`, `prompt_text` (the TTS line), plus the usual `audio_file` / `transcript` / `language`. |

Manifest-level fields tied to the drive-by section:

| Field | Meaning |
|---|---|
| `drive_by_seeds_surfaced` | seed_ids reviewed during this session's drive-by section. Server treats these as consumed — they will not be re-surfaced in future walkthroughs. |
| `drive_by_seeds_unsurfaced` | seed_ids the user explicitly skipped (or that aged out of retention without surfacing). Kept for narrative context. |

### 10.5 Response

```json
{
  "status": "accepted",
  "session_id": "2026-04-24T19:30:00+02:00",
  "received_at": "2026-04-24T20:05:12+02:00",
  "processing_status_url": "/api/sessions/2026-04-24T19:30:00+02:00/status"
}
```

Processing (Whisper re-transcription, entity normalization, LightRAG ingest) happens asynchronously on the server. The iOS app does not wait for processing to complete; it only needs successful upload.

### 10.6 Retry & offline behaviour

- On upload failure, back off exponentially (1s, 2s, 4s, 8s, 30s, 60s, ... max 10 min).
- If Tailscale unreachable, queue locally. Resume queue when reachability returns.
- Queue is first-in-first-out by `session_id` (which is the session start timestamp).
- User-facing UI shows queue status ("2 sessions pending upload") — non-intrusive.

### 10.7 Other backend endpoints

The iOS app also consumes these read endpoints on `server` over Tailscale:

| Endpoint | Purpose | Upstream |
|---|---|---|
| `GET /today/calendar?date=YYYY-MM-DD` | Day's calendar events. RSVP filter applied server-side. | MS Graph |
| `GET /yesterday/open-todos` | Open todos from LightRAG for briefing context. | LightRAG |
| `GET /email/search?q=...&from=ISO&to=ISO` | Email search for enrichment. | MS Graph |
| `POST /lightrag/query` | Natural-language query against LightRAG for enrichment. Body: `{ "query": "...", "mode": "hybrid" }`. | LightRAG |
| `GET /calendar/event/{graph_event_id}` | Full detail for a specific event (for enrichment "tell me more about this meeting"). | MS Graph |
| `GET /health` | Tailscale reachability + upstream health probe. Returns `ok` only when LightRAG, Ollama, Whisper, and Postgres are reachable. | self |

All endpoints require a simple bearer token set during onboarding. No per-user OAuth on the phone. `server` holds the MSAL refresh token for Microsoft Graph and reuses it transparently for each request.

---

## 11. Opener templates

### 11.1 Selection rule (deterministic, on-device, no LLM)

```
if position_in_day == "first"        → first_event
elif position_in_day == "last"       → last_event
elif attendee_count == 0             → deep_work_block
elif is_recurring_instance           → recurring_ritual
elif attendee_count >= 3             → group_meeting
elif duration_minutes < 30           → short_meeting
elif duration_minutes >= 90          → long_meeting
elif has_external_attendee           → external
else                                 → one_on_one
```

Template selection is pure logic. Only the **follow-up** question (at 6s lull) uses Apple FM.

### 11.2 German templates

| Slot | Template |
|---|---|
| first_event | "Heute früh hattest du {title}. Wie ist der Tag gestartet?" |
| one_on_one | "Um {time} hattest du {title} mit {who}. Wie ist das gelaufen?" |
| group_meeting | "{title} um {time} — etwas Erwähnenswertes aus der Runde?" |
| recurring_ritual | "{title} heute — was Besonderes?" |
| deep_work_block | "Von {time_range} hattest du einen Block für {title}. Bist du vorangekommen?" |
| short_meeting | "Kurzer Termin {time} mit {who} — relevant für den Tag?" |
| long_meeting | "{title} ging {duration} — was kam dabei raus?" |
| external | "{title} mit {who} — wie war der Eindruck?" |
| last_event | "{title} war dein letzter Termin — was nimmst du mit?" |
| empty_block | "Zwischen {time_range} hattest du keinen Termin — irgendwas Wichtiges in der Zeit?" |

### 11.3 English templates

| Slot | Template |
|---|---|
| first_event | "You kicked off the day with {title}. How did it get going?" |
| one_on_one | "At {time} you had {title} with {who}. How did it go?" |
| group_meeting | "{title} at {time} — anything worth noting from the room?" |
| recurring_ritual | "{title} today — anything unusual?" |
| deep_work_block | "You had {time_range} blocked for {title}. Did you get somewhere?" |
| short_meeting | "Short one at {time} with {who} — relevant to the day?" |
| long_meeting | "{title} ran {duration} — what came out of it?" |
| external | "{title} with {who} — what was your read?" |
| last_event | "{title} was your last meeting — what are you taking away?" |
| empty_block | "You had nothing scheduled between {time_range} — anything worth capturing from that?" |

### 11.4 Follow-up templates

Used at 6s lull, one per event max.

- DE options (rotate): "Etwas Konkretes, das du mitnehmen willst?" / "Irgendwas, das dich noch beschäftigt?" / "Willst du noch einen Aspekt vertiefen?"
- EN options (rotate): "Anything concrete you want to keep?" / "Anything still on your mind?" / "Any angle you want to dig into?"

When Apple FM is used for dynamic follow-ups, the prompt is:
> "The user just reflected on a calendar event: `{event_title}` with `{attendees}`. Their response was: `{user_transcript}`. Generate one short conversational follow-up question in {language} (max 12 words) that invites more depth. Return only the question, no preamble."

---

## 12. Settings

### 12.1 Categories & fields

**Language & voice**
- Recording language: `Auto-detect | German | English` (default: `Auto-detect`)
- Response language: `Match input | Always German | Always English` (default: `Match input`)
- German voice: dropdown of bundled German Piper voices
- English voice: dropdown of bundled English Piper voices

**Schedule**
- Workday start time (default 08:00)
- Workday end time (default 18:00)
- Evening diary notification time (default 20:00)

**Walkthrough**
- **Sections** (Mehr → Walkthrough → Abschnitte): list of user-defined `general` sections. Each has `id` (stable UUID), `title` (header text + manifest field), `introText` (TTS opener line). Stored in `UserDefaults` under `walkthrough.generals.v1`.
- **Reihenfolge** (Mehr → Walkthrough → Reihenfolge): ordered list of `WalkthroughSection` (`.general(id) | .calendarEvents | .driveBy`). Drag to reorder. The two system sections (`calendarEvents`, `driveBy`) always appear once each; if missing from the stored order they're appended in default order on read. Stored in `UserDefaults` under `walkthrough.sectionOrder.v1`. Default order = `[.calendarEvents, .driveBy]`.
- RSVP filter: multi-select `Accepted | Tentative | All` (default: Accepted + Tentative)
- Multi-day gap cap: integer days (default 7)
- Lull thresholds: three sliders for 3s / 6s / 15s (defaults shown)
- Empty-block threshold: minutes (default 30)
- Empty-block behaviour: `Ask once | Never ask` (default Ask once)
- End-of-day drive-by recap: toggle (default on)

**Capture**
- Drive-by notification duration: seconds (default 4)
- Drive-by auto-stop silence: seconds (default 3)

**Storage**
- Raw audio retention: `1 month | 3 months | Forever` (default 3 months)
- Transcript retention: `3 months | 6 months | Forever` (default Forever)
- Conversation history in UI: `Last 7 days | 30 days | All` (default 30 days)

**Backend**
- Server endpoint URL (set during onboarding, e.g. `http://my-server.tailnet.ts.net:8000`)
- Bearer token (set during onboarding)
- Tailscale health indicator (read-only, shows last successful contact time)

**About**
- App version
- Voice model versions
- Parakeet model version
- Reset app (clear all local data)

### 12.2 Parked settings (not exposed yet)

- Enrichment wake-word customization
- Custom opener templates
- Haptic patterns
- Notification sound

---

## 13. Storage

### 13.1 Local data layout

```
~/Library/Application Support/VoiceDiary/
├── sessions/
│   └── 2026-04-24T19:30:00+02:00/
│       ├── manifest.json
│       ├── segments/
│       │   ├── s01.m4a
│       │   └── ...
│       └── raw/session.m4a
├── driveby_seeds/
│   └── 2026-04-24T11:15:00/
│       ├── audio.m4a
│       └── metadata.json
├── upload_queue.json
├── settings.plist
└── caches/
    └── calendar_cache/       # short-lived, for current session
```

### 13.2 Retention

- **Raw audio**: respects `Raw audio retention` setting. Background task runs daily at 03:00 local time, deletes session folders older than setting.
- **Transcripts & manifests**: respect `Transcript retention` setting. Kept longer than audio because they're much smaller.
- **Drive-by seeds**: deleted after successful ingest in the evening session, regardless of retention setting.
- **Upload queue**: never pruned by retention — entries stay until successfully uploaded.

### 13.3 Encryption

- iOS Data Protection class `NSFileProtectionComplete` on all audio and manifest files.
- No separate password layer — relies on device passcode.

---

## 14. Onboarding

First launch flow (one-time):

```
1. Welcome screen — short description, privacy statement.
2. Microphone permission request.
3. Notification permission request.
4. Diary-processor endpoint setup:
   - URL (Tailscale hostname, e.g. "http://my-server.tailnet.ts.net:8000")
   - Bearer token (user copies from `server`'s `.env`)
   - Test connection (calls GET /health, shows result)
5. Language setup:
   - Primary recording language pick
   - Voice preview: AI says a sentence in German and English so user picks
6. Workday hours setup.
7. Lock screen widget install prompt (deep link to widget gallery).
8. Action Button binding prompt (deep link to Settings → Action Button).
9. First drive-by tutorial: "Try it now" → records "Hallo Voice Diary", plays back transcript.
10. Done — app ready.
```

Graph OAuth setup is a one-time step the user runs on the server (`server/scripts/msgraph_bootstrap.py`) before first iOS launch — not on the phone.

---

## 15. Error handling

### 15.1 User-visible error categories

| Category | Examples | User message |
|---|---|---|
| Capture | Mic permission revoked, audio engine fails | "Microphone not available. Check Settings." |
| Network | Tailscale unreachable during enrichment | "Can't reach server. Enrichment skipped." |
| Ingest | Upload fails repeatedly | "2 sessions pending upload. Tap to retry." |
| LLM | Apple FM generation fails | Silent fallback to canned follow-up template. |
| TTS | Piper model fails to load | Fallback to AVSpeechSynthesizer for that language. |

### 15.2 Never-fail principles

- A drive-by capture must always save locally, even if STT fails completely.
- A session upload failure must never lose audio or transcript data.
- A walkthrough interrupted by a crash must resume from the last committed segment.

### 15.3 Telemetry

None. Errors log locally to a rolling file viewable in Settings → About → Diagnostics. No data leaves the phone except to the user's own `server` over Tailscale.

---

## 16. Open questions & future work

Parked for now, listed for continuity:

- **Weekly retrospective** — dedicated extension that reads open todos aloud on a configured day and walks confirmation.
- **Apple Watch capture** — drive-by from wrist.
- **Full offline walkthrough** — local LightRAG mirror on device for offline enrichment.
- **Gemma 4 E4B swap** — if Apple Foundation Models prove insufficient for German nuance.
- **Voice persona design** — the AI is currently anonymous. Could have a name, tone, consistency across sessions.
- **Geolocation tagging** — attach coarse location to drive-by seeds if useful.
- **Enrichment wake-word customization** — let users pick their own trigger.
- **Harvest time-tracking integration in the briefing** — surface today's logged hours during briefing. The Harvest integration is already carried over from diary-processor (`harvest_llm.py`, `harvest_patterns.py`); exposing it to iOS is an extra endpoint plus briefing text.
- **Productization** — multi-user, cloud auth, App Store. Explicitly out of scope for v1.

---

## 17. Glossary

- **Segment** — a chunk of user audio+transcript tagged with a type (calendar_event / drive_by / free_reflection / empty_block).
- **Drive-by seed** — a drive-by capture from earlier in the day, pending surfacing in the evening walkthrough.
- **Briefing** — the opening summary the AI speaks at the start of an evening session.
- **Walkthrough** — the chronological traversal of the day's calendar events.
- **Enrichment** — mid-dialog retrieval from email / LightRAG / calendar, triggered by wake-word.
- **Opener** — the AI's first sentence when entering a calendar event's dialog node.
- **Follow-up** — the AI's optional single additional question at a 6s lull.
- **Lull** — a gap in the user's speech. Measured in three thresholds.
- **Empty block** — a gap in the schedule ≥ 30 min within workday hours.
- **Manifest** — the JSON summary uploaded alongside audio to `/api/sessions`.
