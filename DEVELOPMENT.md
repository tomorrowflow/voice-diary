# Voice Diary — Development Plan

**Read SPEC.md first.** This file describes how to build, deploy, and operate the two components (`ios/` and `server/`).

**Status note:** the milestone lists below (§4.3 for `server/`, §5.2 for `ios/`) are the original
build plan, written before either track had code. Both tracks have since had substantial work
land — see `git log`, `server/README.md`, and `ios/README.md` for what is actually done. Do not
infer from a milestone appearing below that it hasn't started.

---

## 1. Repository layout

```
voice-diary/
├── README.md
├── CLAUDE.md
├── SPEC.md
├── DEVELOPMENT.md             (this file)
├── LICENSE
├── ios/                       (Swift 6 / SwiftUI iOS app)
│   └── README.md
└── server/                    (FastAPI companion service)
    └── README.md
```

Both components are developed in the same git repository. They are deployed independently: `ios/` is built and signed in Xcode and installed on the iPhone; `server/` runs as a single Docker Compose stack on the user's Linux host.

---

## 2. Prerequisites

### 2.1 Shared

- Git, SSH keys configured for the repo remote.
- Tailscale installed and joined to the tailnet on: development Mac, iPhone 17 Pro, Linux server.

### 2.2 For iOS development (`ios/`)

- macOS (Apple Silicon) with Xcode 16.2 or newer.
- iOS 26 SDK.
- Swift 6 toolchain.
- iPhone 17 Pro with iOS 26, provisioned for development.
- Apple Developer account (team ID for code signing).
- No MSAL on the phone; all Exchange auth lives in `server/`.

### 2.3 For server development (`server/`)

- Linux host running Docker Engine + Docker Compose v2.
- Python 3.12 locally for development if running outside Docker.
- External LightRAG instance reachable from the host.
- External Ollama instance reachable from the host with a German-capable model pulled (e.g. `qwen2.5:14b`).
- Optional, off by default: a Blindfold proxy and a cloud model account, needed only for `ANALYSIS_ROUTE=blindfold`. Development and the default deployment make no request to either. Read [`docs/analysis-egress.md`](docs/analysis-egress.md) (settings, limits, first-enable gate) before enabling it; the automated suite does not establish that pseudonymization works.
- Microsoft 365 / Exchange admin consent for a Graph app registration granting `Calendars.Read` and `Mail.Read` delegated scopes.
- A client ID + tenant ID for that Graph app registration.

### 2.4 One-time setup outside the repo

- Create the Microsoft Graph app registration in the user's Entra tenant. Note the client ID and tenant ID. Use device-code or authorization-code flow with PKCE; no client secret required for delegated access.
- Generate a bearer token for the iOS app to authenticate to `server`. This lives in `server/.env`.

---

## 3. Development flow

The two components are tightly coupled but independently buildable. The recommended workflow:

1. Work on `server/` milestones until there is a stable backend surface.
2. Develop `ios/` against that surface.
3. Integration milestones (marked ↔ below) require both sides aligned.

Dogfood early. Drive-by capture (iOS M2) + session ingest (Server S1) are usable after ~2 weeks of part-time work. Everything else refines an already-useful baseline.

---

## 4. Server track (`server/`)

The server has been **seeded from the existing `diary-processor/webapp/` codebase** (copied on 2026-04-24). It is already a working FastAPI app with entity detection, LightRAG ingest, review UI, admin UI, and Harvest integration. The server track is about removing n8n, adding local audio processing, and adding the iOS-specific routes — not building from scratch.

### 4.1 Layout as seeded (2026-04-24)

A snapshot of the tree as copied from `diary-processor`, before S1. The "needs …" / "to be
removed" notes are the seed-time to-do list — n8n is gone, Whisper and `msal` are in, and the
iOS routers exist; see §4.2–§4.3 and `server/README.md` for current state.

```
server/
├── README.md
├── .env.example                     # COPIED from diary-processor; still has n8n vars (to be removed)
├── docker-compose.yml               # COPIED from diary-processor; needs Whisper service added
├── docs-archive/                    # Historical design docs from diary-processor (reference only)
└── webapp/                          # COPIED from diary-processor/webapp/
    ├── Dockerfile
    ├── requirements.txt             # needs: msal, ffmpeg-python (or call ffmpeg via subprocess)
    ├── main.py                      # ~2200 lines, ~60 routes; needs n8n removal + iOS routers
    ├── db.py                        # asyncpg queries
    ├── document_processor.py        # narrative gen + LightRAG ingest (in-process Python; analysis on local Ollama unless ANALYSIS_ROUTE=blindfold)
    ├── entity_detector.py           # 4-pass entity normalization
    ├── transcript_corrector.py      # Ollama ASR correction
    ├── fluency_checker.py           # Ollama fluency correction
    ├── llm_validator.py             # streaming entity validation
    ├── vector_store.py              # Qdrant client
    ├── bone_generator.py            # LightRAG skeleton sync — bones
    ├── skeleton_sync.py             # LightRAG skeleton sync — engine
    ├── harvest_llm.py               # Harvest time-tracking LLM hints
    ├── harvest_patterns.py          # Calendar → Harvest pattern matching
    ├── import_nocodb.py             # NocoDB CSV import
    ├── schema.sql                   # 17-table Postgres schema
    ├── seed.sql                     # initial persons/terms/variations
    ├── skeleton/                    # markdown skeleton used by prompts
    ├── templates/                   # HTMX review + admin UI
    └── static/
```

### 4.2 Planned additions

Files the server milestones were planned to create. All of the code files exist on disk by now
(`data/` is gitignored runtime state) — the listing is kept as the original plan; see `git log`
and `server/README.md` for what actually shipped (plus additions the plan didn't name, e.g.
`routers/auth.py`, `routers/tts.py`, and the `voxtral-gate/` lazy-wake proxy):

```
server/
├── webapp/
│   └── routers/                     # NEW — iOS-specific routes as FastAPI routers
│       ├── __init__.py
│       ├── sessions.py              # POST /api/sessions
│       ├── calendar.py              # GET /today/calendar, /calendar/event/{id}
│       ├── email.py                 # GET /email/search
│       ├── lightrag.py              # POST /lightrag/query, GET /yesterday/open-todos
│       └── health.py                # GET /health (upstream-aware)
├── webapp/
│   └── msgraph_client.py            # NEW — MSAL cache + Graph HTTP client
├── scripts/                         # NEW
│   ├── msgraph_bootstrap.py         # One-time OAuth device-code flow
│   └── issue_ios_token.py           # Generates/rotates the bearer token for iOS
└── data/                            # Runtime state (gitignored)
    ├── sessions/                    # iOS session bundles
    └── msal_cache.bin               # MSAL refresh tokens
```

### 4.3 Milestones

Written as the original task breakdown, not a live status board. As of this writing, S1's n8n
removal and audio pipeline, S2's MSAL/Graph client, and the S2–S3 `webapp/routers/` are all present on
disk — see `server/README.md` for current state before treating any task below as unstarted.

#### S1 — Remove n8n, add local audio processing

**Goal:** the server runs without any n8n dependency. Existing `/api/transcripts` and `/api/ingest/upload` paths work end-to-end locally.

Tasks:
1. **Add Whisper service** to `docker-compose.yml` (recommend `onerahmet/openai-whisper-asr-webservice` or equivalent). Expose `http://whisper:9000` to the webapp container only.
2. **Install ffmpeg** in the webapp Dockerfile (`apt-get install -y ffmpeg`). Confirm the image still builds.
3. **Rewrite `/api/ingest/upload`** (currently proxies to n8n): accept the uploaded audio, run ffmpeg to 16 kHz mono WAV (if needed), POST to Whisper, persist the returned transcript via the existing transcript insertion flow.
4. **Delete `_forward_to_n8n()`** in `main.py` (two call sites). Remove the `skip_n8n` flag and always run `document_processor.py` locally.
5. **Remove n8n env vars** from `.env.example`: `N8N_WEBHOOK_URL`, `CALENDAR_WEBHOOK_URL`, `n8n_ingest_webhook_url` (the latter is in the `app_settings` table default — migrate schema or just let it be ignored).
6. **Update `/api/calendar/{date}`** (currently calls n8n): temporarily stub it to return an empty event list; it will be replaced in S2 with direct MS Graph calls.
7. **Update `process-diaries.sh`** (or delete it): point at the local `/api/ingest/upload` endpoint directly.
8. **Update `webapp/templates/data.html`** (has "n8n Audio Ingest Webhook URL" setting): remove the setting field or repurpose it.
9. **Smoke test:** upload an audio file via the `/ingest` UI, watch it flow through ffmpeg → Whisper → `/api/transcripts` → review UI, end-to-end, no n8n involved.

Exit criteria: `docker compose up -d` brings up the full stack, an audio file uploaded via the UI produces a reviewable transcript without any n8n workflow running.

#### S2 — Microsoft Graph integration (calendar)

**Goal:** `/today/calendar` and `/calendar/event/{id}` return real Exchange data.

Tasks:
1. Add `msal` to `requirements.txt`.
2. `webapp/msgraph_client.py` — MSAL token cache wrapper, auto-refresh, thread-safe.
3. `scripts/msgraph_bootstrap.py` — interactive device-code OAuth flow the user runs once, persisting refresh token to `data/msal_cache.bin`.
4. `webapp/routers/calendar.py`:
   - `GET /today/calendar?date=YYYY-MM-DD` — Graph `/me/calendar/events` query, filtered by `rsvp_status` (accepted, tentative by default).
   - `GET /calendar/event/{graph_event_id}` — single-event detail.
5. Replace the old `/api/calendar/{date}` stub with a call to the same underlying Graph client so the HTMX review UI's calendar widget keeps working.
6. Bearer-token `Depends` for the new iOS routes. (SEC-2 later extended the same token to the legacy review/admin/data routes; `/health` is the only open route.)
7. Integration test against a real Exchange tenant.

Exit criteria: user runs the bootstrap once, then the server answers calendar queries for weeks without re-auth. The webapp's existing calendar widget works again.

#### S3 — iOS session ingest + enrichment

**Goal:** iOS `POST /api/sessions` works end-to-end. Enrichment endpoints return speech-ready German/English.

Tasks:
1. `webapp/routers/sessions.py`:
   - `POST /api/sessions` accepts multipart; persists bundle to `data/sessions/{session_id}/`.
   - For each segment, run the in-process pipeline: ffmpeg → Whisper → transcript_corrector → entity_detector → document_processor → LightRAG ingest.
   - The segment's `calendar_ref` from the manifest short-circuits entity resolution for attendees (no fuzzy matching needed — Graph already gave us canonical names).
   - Todos in the manifest's `todos_detected` + `todos_implicit_confirmed` are embedded into the narrative markdown with their status labels.
2. `webapp/routers/email.py`:
   - `GET /email/search?q=&from=&to=` — Graph `/me/messages/search`.
3. `webapp/routers/lightrag.py`:
   - `POST /lightrag/query` — forwards to LightRAG's HTTP API.
   - `GET /yesterday/open-todos` — LightRAG query for open todos.
4. Ollama summarisation for enrichment: given retrieved chunks + user query, produce 2–3 sentences in the requested language. Reuse the existing `document_processor.py` Ollama client patterns.
5. Each enrichment endpoint accepts a `response_language=de|en` query param plumbed into the Ollama system prompt.
6. `webapp/routers/health.py`: upstream-aware `/health` checking Postgres, Qdrant, Whisper, LightRAG, Ollama.

Exit criteria: iOS synthetic session lands on disk, flows through the full pipeline, appears in LightRAG + review UI. Enrichment endpoints return correctly-languaged summaries.

#### S4 — Operational polish

Tasks:
- Structured JSON logging with correlation IDs per iOS session.
- Backup script for `data/msal_cache.bin` and `data/sessions/`.
- Graceful handling of upstream failures (Whisper down, Ollama down, LightRAG down, Graph rate-limited) with clear error codes the iOS app can interpret.
- Update `server/README.md`: first-time setup, OAuth bootstrap, bearer token rotation, log file locations, backup/restore, how to add a new bundled voice (for iOS side reference).

Exit criteria: fresh server deployable in under 20 minutes by following `server/README.md`.

### 4.4 Deploying the server

```bash
# On the Linux host (one Docker Compose stack — no coexisting diary-processor needed):
cd ~/Documents/GitHub/voice-diary/server

# One-time setup:
cp .env.example .env
# Edit .env. Required vars:
#   TAILNET_IP=<this host's Tailscale IPv4, from `tailscale ip -4`; the webapp
#               publishes 8000 on this address only and refuses to start
#               without it — SEC-1)
#   POSTGRES_PASSWORD=<generate with `openssl rand -hex 32`, no default>
#   OLLAMA_BASE_URL=http://<ollama-host>:11434
#   OLLAMA_MODEL=qwen2.5:14b
#   ANALYSIS_ROUTE=local            (default; the opt-in `blindfold` route and
#                                    its settings are in docs/analysis-egress.md)
#   LIGHTRAG_URL=http://<lightrag-host>:9621
#   LIGHTRAG_API_KEY=...
#   QDRANT_URL=http://qdrant:6333
#   WHISPER_URL=http://whisper:9000
#   WHISPER_IMAGE_TAG=latest        (CPU) or latest-gpu (also uncomment the
#                                    whisper deploy.resources block)
#   HARVEST_ACCESS_TOKEN=...
#   HARVEST_ACCOUNT_ID=...
#   HARVEST_USER_ID=...
#   MSGRAPH_CLIENT_ID=<entra app client id>
#   MSGRAPH_TENANT_ID=<entra tenant id>
#   IOS_BEARER_TOKEN=<generate with openssl rand -hex 32>
#   HF_TOKEN=<accept the license at huggingface.co/mistralai/Voxtral-4B-TTS-2603,
#             then generate a token; required for the voxtral-engine service
#             to pull the gated Voxtral weights>
#   TZ=Europe/Berlin

# Microsoft Graph OAuth (once):
docker compose run --rm webapp python scripts/msgraph_bootstrap.py

# Start the stack:
docker compose up -d

# Health check from the tailnet:
curl -H "Authorization: Bearer $IOS_BEARER_TOKEN" \
     http://<tailnet-hostname>:8000/health
```

MSAL refresh tokens auto-renew in the background; re-run the bootstrap only if the token is revoked server-side or scopes change.

---

## 5. iOS track (`ios/`)

Swift 6 / SwiftUI / iOS 26.

### 5.1 Planned project layout

The layout exists on disk by now and drifted past the plan — additions it didn't name include
`Sources/{Intents,Localization,Shared}/`, top-level `WidgetExtension/` (instead of
`Sources/Widget/`), `Tests/`, and `scripts/`; and `Dialog/`'s planned `StateMachine.swift`
shipped as `WalkthroughState.swift` + `WalkthroughCoordinator.swift`, with
`WakeWordDetector.swift` landing in `Capture/`. The listing is kept as the original plan; see
`git log` and `ios/README.md` for what actually shipped.

```
ios/
├── README.md
├── VoiceDiary.xcodeproj            (gitignored — regenerated from project.yml via XcodeGen)
├── project.yml                     (XcodeGen spec — source of truth)
├── Package.swift
├── Config/
│   ├── Info.plist                  (UIAppFonts declares Geist + Geist Mono)
│   └── VoiceDiary.entitlements
├── Sources/
│   ├── App/
│   │   └── VoiceDiaryApp.swift
│   ├── DesignSystem/               (auto-generated outputs + hand-written seam)
│   │   ├── DSColor.swift           (auto-generated)
│   │   ├── DSMetrics.swift         (auto-generated)
│   │   ├── DSSemantic.swift        (auto-generated; light/dark dynamic colors)
│   │   ├── Theme.swift             (Theme.color/spacing/radius/font/motion)
│   │   └── DSButtonStyle.swift     (5 variants × 3 sizes per specs/components/button.json)
│   ├── Capture/
│   │   ├── AudioEngine.swift
│   │   ├── M4AWriter.swift
│   │   └── ParakeetManager.swift
│   ├── TTS/
│   │   ├── PiperEngine.swift
│   │   └── VoiceRegistry.swift
│   ├── Dialog/
│   │   ├── AppleFoundationLLM.swift
│   │   ├── StateMachine.swift
│   │   ├── OpenerTemplates.swift
│   │   └── WakeWordDetector.swift
│   ├── Backend/
│   │   ├── ServerClient.swift
│   │   ├── SessionUploader.swift
│   │   ├── Reachability.swift
│   │   ├── KeychainStore.swift
│   │   └── Logging.swift           (os.Logger subsystems)
│   ├── Models/
│   │   ├── Manifest.swift
│   │   └── DriveBySeed.swift
│   ├── UI/
│   │   ├── Onboarding/
│   │   ├── Walkthrough/
│   │   ├── DriveBy/
│   │   └── Settings/
│   ├── Storage/
│   │   └── LocalStore.swift
│   └── Widget/
│       └── LockScreenWidget.swift
├── Resources/
│   ├── Fonts/                      (Geist + Geist Mono variable TTFs, OFL.txt)
│   └── Models/
│       ├── parakeet-v3.*
│       ├── de_DE-thorsten-high.onnx
│       ├── en_US-lessac-high.onnx
│       └── espeak-ng-data/
└── Tests/
```

### 5.2 Milestones

Written as the original task breakdown, not a live status board. `ios/Sources/` already has
`Capture/`, `Dialog/`, `TTS/`, `Backend/`, `Storage/`, and `UI/` modules plus a widget extension —
roughly M1–M10 have substantial code on disk. `ios/README.md`'s status table lags the code, so
check `git log` and `ios/Sources/` before treating any milestone below as unstarted.

#### M1 — Xcode foundation

- `project.yml` (XcodeGen) is the source of truth; `VoiceDiary.xcodeproj` is generated and gitignored.
- Bundle ID `com.tomorrowflow.voice-diary` (or user's preferred).
- Entitlements: Microphone, Background Audio, App Groups (for widget later). `com.apple.developer.kernel.increased-memory-limit` for the opt-in Gemma 4 E4B dialog backend.
- SwiftPM: add `FluidInference/FluidAudio` for Parakeet.
- Add `k2-fsa/sherpa-onnx` iOS xcframework as a binary framework.
- Bundle Piper voice models and espeak-ng data in `Resources/Models/`.
- Bundle Geist + Geist Mono variable TTFs in `Resources/Fonts/`; declare them in `UIAppFonts`. The DS Swift outputs (`DSColor.swift`, `DSMetrics.swift`, `DSSemantic.swift`, `Theme.swift`, `DSButtonStyle.swift`) live under `Sources/DesignSystem/` and are produced by `bash scripts/build_design_system.sh`.
- Smoke test: app launches on iPhone 17 Pro, prints "Voice Diary ready".

Exit: build + launch on device, all deps resolve.

#### M2 — Drive-by capture MVP

- `AudioEngine.swift`: AVAudioEngine → two sinks (Parakeet PCM stream + AAC-LC file write via `AVAudioFile`).
- `ParakeetManager.swift`: load Parakeet v3 multilingual, stream hypotheses, return final transcript + detected language. Pattern lifted from `~/Documents/GitHub/murmur/SharedSources/`.
- `LocalStore.swift`: persist `driveby_seeds/{timestamp}/audio.m4a + metadata.json`.
- Simple in-app record button for dogfooding.

Exit: record a 10s German drive-by, get a transcript, find the files via Xcode's device browser.

#### M3 ↔ Server S1 — Backend bridge

**Requires Server S1 complete.**

- `VoiceDiaryServerClient.swift`: multipart upload to `POST /api/sessions`, bearer token from Keychain.
- `UploadQueue.swift`: persistent FIFO queue, exponential backoff (1s/2s/4s/8s/30s/60s/600s max).
- `Reachability.swift`: pings `GET /health`, banner when unreachable.
- "Test upload" button that synthesises a fake session and uploads it.

Exit: synthetic session uploaded, lands in `server/data/sessions/`, is processed in-process through ffmpeg → Whisper → entity_detector → document_processor → LightRAG.

#### M4 — Drive-by surfaces

- WidgetKit lock-screen widget (tap → launch app in drive-by recording state).
- ActivityKit Live Activity for "recording now".
- App Intents for Action Button binding.
- Transient local notification on capture complete, auto-dismiss, haptic on start/stop.

Exit: phone locked → Action Button → speak → Action Button again → notification → seed in local store.

#### M5 ↔ Server S2 — Walkthrough skeleton

**Requires Server S2 complete.**

- `VoiceDiaryServerClient`: add `getTodaysCalendar` method.
- `OpenerTemplates.swift`: selection rule + DE + EN tables from SPEC §11.
- `PiperEngine.swift`: wrap sherpa-onnx `OfflineTts`, load German voice at init, synth + play via `AVAudioPlayer`.
- `StateMachine.swift` skeleton: IDLE → BRIEFING → WALKING → CLOSING → INGESTING → DONE. Per-event loop with opener + listening + next/skip/done commands. Stub FOLLOW_UP, ENRICHMENT, SEED_SURFACE.
- Briefing speaks a canned summary.

Exit: open app in evening → hear briefing → hear opener per event → say "weiter" between events → hear closing → session uploads.

#### M6 — Conversational dialog

- `AppleFoundationLLM.swift`: wrap iOS 26 FoundationModels. Methods `generateFollowUp` and `classifyIntent`.
- Integrate follow-up into state machine at 6s lull. Max one per event.
- Lull detection on Parakeet's silence signal (no hypothesis updates for N seconds).
- Dogfood the follow-up prompt until it feels natural.

Exit: full session feels conversational, not interrogative.

#### M7 ↔ Server S3 — Enrichment wake-word

**Requires Server S3 complete.**

- `WakeWordDetector.swift`: rolling Parakeet hypothesis buffer, Levenshtein ≤ 2 match for "hey voice diary".
- ENRICHMENT state: capture continuation query, classify intent via Apple FM, call `server` endpoint, speak summary via Piper, resume.
- Transcript filter: strip wake-word span + enrichment Q&A from segment transcript; full exchange to `ai_prompts[]`.
- Mixed-language drift: freeze Parakeet language detection to English during match window.

Exit: say "hey voice diary, was hat Tobias geschrieben" mid-reflection, hear a German summary, dialog resumes.

#### M8 — Todo capture

- Explicit parser: regex for trigger phrases + due-date extraction (DE + EN).
- Implicit detector: Apple FM scans each segment transcript at segment close.
- CLOSING confirmation pass: read candidates aloud, collect ja/nein/anders responses.

Exit: both paths produce correctly-typed todo entries in the manifest; the server embeds them into the narrative markdown for LightRAG ingest with `Offen` status.

#### M9 — Multilingual

- Bundle English Piper voice.
- `VoiceRegistry.swift`: route by language.
- Parakeet per-utterance language detection + fallback rules per SPEC §9.3.
- Settings UI for language + voice pickers.

Exit: a mixed-language session produces coherent bilingual output.

#### M10 — Multi-day gap + drive-by seed surfacing

- Date ingest tracking in `LocalStore.swift`.
- `GAP_PROMPT` before INGESTING, chains sessions across days.
- Drive-by seed surfacing at matching event times + end-of-day recap toggle.

Exit: skip a day, catch up next evening. Drive-bys from morning surface in matching events.

#### M11 — Settings & onboarding

- Full settings UI (all sections in SPEC §12).
- Onboarding: UX-6a's first-run gate — server setup + explicit permission priming. The rest of the original SPEC §14 flow (voice preview, workday hours, widget install, Action Button deep link, first drive-by tutorial) was dropped at the 2026-07-04 grill and is intentionally not being built (DOC-8). Server setup (UX-7) is followed by a permissions screen (`OnboardingFlowView.swift`), and no permission dialog fires at launch.
- Reset-app action.
- Every screen built with `Theme.*` and `DSButtonStyle`; status indicators use the colour-coded `StatusBadge` pattern from `ServerSettingsView`.

Exit: clean install → onboarding → ready to capture without editing any file manually. **Met** by UX-6a's reduced first-run flow: server setup, then the permission-priming screen, then the tab bar with Recording one tap away (`OnboardingGate.swift`, `OnboardingFlowView.swift`). The bar is that gate, not the full SPEC §14 wizard, which was intentionally dropped (DOC-8).

#### M12 — Polish

- Error UI states per SPEC §15.
- Upload queue status indicator.
- Session history view.
- Diagnostics log viewer.
- Battery + thermal profiling on a 20-minute session.
- TestFlight build.
- Accessibility pass — verify Dynamic Type continues to work with Geist (`.custom(_, size:, relativeTo:)` already opted in via `Theme.font.*`).
- Design-system audit: `grep -RE "Color\\(red:|Color\\.(red|gray|blue)|CGFloat = [0-9]" ios/Sources/` should return zero hits in feature code.

Exit: 2 weeks of daily use without reverting to voice memos.

### 5.3 Building and running the iOS app

Once M1 is complete:

```bash
# Open in Xcode
open ios/VoiceDiary.xcodeproj

# Or from CLI
xcodebuild -scheme VoiceDiary \
           -destination 'platform=iOS,name=Lukas iPhone' \
           -configuration Debug \
           build

```

Test commands live in §7.4.

The app reads its `server` URL + bearer token from Keychain, set during onboarding.

---

## 6. Milestone dependencies at a glance

```
Server:  S1 ───┬────── S2 ─────── S3 ─────── S4
               │         │          │
iOS:     M1 ─ M2 ─ M3 ─ M4 ─ M5 ─ M6 ─ M7 ─ M8 ─ M9 ─ M10 ─ M11 ─ M12
               ↑              ↑         ↑
         needs S1        needs S2   needs S3
```

Rough cadence: ~2 weeks for S1 + M1–M3 (foundation dogfoodable), ~2 weeks for M4 + S2 + M5 (walkthrough skeleton), ~2 weeks for M6 + S3 + M7 (conversational + enrichment), ~2 weeks for M8–M12. **6–8 weeks of part-time work** end to end is a realistic target for a single developer.

---

## 7. Testing strategy

### 7.1 Server (`server/`)

- **Unit tests**: FastAPI test client against each router. Mock MSAL, LightRAG, and Ollama clients. Commands: §7.4.
- **Integration tests**: real `docker compose up`, hit endpoints with `httpx`, verify side effects (files written, LightRAG entries created, transcript rows inserted).
- **Manual smoke tests** per milestone: bootstrap OAuth, hit each endpoint with `curl`, verify responses.

### 7.2 iOS (`ios/`)

- **Unit tests**: opener template selection, manifest encoding, state machine transitions, wake-word matcher.
- **Integration tests**: `VoiceDiaryServerClient` against a local `docker-compose up` of `server/`.
- **Manual scenarios** per milestone (listed in SPEC §15 and under each M above) run on a real iPhone.

### 7.3 Dogfood

From M3 onward, the user should use whatever works every day. Missing features are fine; finding what feels wrong in real use is the whole point.

### 7.4 Running the tests

This is the only place the test commands are documented; other files link here.

**Server** — runs inside the webapp container so dependencies and environment match prod. The image
only copies `webapp/` to `/app` and some tests read other repo files, so the repo is mounted
(`-v ..:/repo`, resolved from `server/`) and pytest runs from `/repo/server`. `--no-deps` skips
postgres, qdrant, and whisper. Avoid `$(...)`, which agent sandboxes reject. A `.env` is required;
on a fresh clone the stub below is enough.

```bash
cd server && printf 'POSTGRES_PASSWORD=test\nTAILNET_IP=127.0.0.1\n' > .env && docker compose -p vd-test run --rm --no-deps -e PYTHONDONTWRITEBYTECODE=1 -v ..:/repo -w /repo/server webapp pytest webapp/tests/ -q -p no:cacheprovider
```

To narrow the run, replace `webapp/tests/` with a file (`webapp/tests/test_sessions.py`) or a test
id (`webapp/tests/test_session_ingest.py::test_retry_marks_only_the_remainder_when_some_rows_were_already_marked`).

**Voxtral gate** — its tests run in the gate image, which has its own dependencies and pytest
settings, so the workdir is `/repo/server/voxtral-gate`. Run from `server/` with the same `.env`
stub; mounting the repo means the run uses the working tree, not the files baked into the image.

```bash
docker compose -p vd-test run --rm --no-deps -e PYTHONDONTWRITEBYTECODE=1 -v ..:/repo -w /repo/server/voxtral-gate --entrypoint pytest voxtral tests/test_gate.py -q -p no:cacheprovider
```

**iOS** — macOS with Xcode 16.2+ and XcodeGen only (`xcodebuild` does not run on Linux). The Xcode
project is generated and gitignored, and `project.yml` includes `project-piper.yml` (gitignored,
normally written by `ios/scripts/fetch_piper_voices.sh`). On a checkout without the Piper bootstrap,
create a no-op stub and an empty `Resources/Models` first (the bundle folder reference), then
generate, boot the simulator, and test:

```bash
cd ios
printf '{}\n' > project-piper.yml
mkdir -p Resources/Models
xcodegen generate
xcrun simctl boot "iPhone 17" || true
xcrun simctl bootstatus "iPhone 17" -b
xcodebuild test -scheme VoiceDiary \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation \
  -derivedDataPath ~/Library/Caches/vd-derived-data
```

- `-skipMacroValidation` is needed because `#huggingFaceLoadModelContainer` (MLXHuggingFace) is a
  package macro that otherwise requires a one-time trust prompt in Xcode.
- Keep `-derivedDataPath` on a Mac-local disk, not a network or synced volume.
- iPhone 17 Pro is the target *device*; tests run on the plain iPhone 17 simulator because the
  iPhone 17 Pro simulator is not available. Add `-only-testing:VoiceDiaryTests/<Class>` to run a
  single test class.
- If the Piper bootstrap has already been run, skip the stub and `mkdir` steps; do not overwrite
  the real `project-piper.yml`.

### 7.5 Continuous integration

`.github/workflows/ci.yml` runs on every pull request, on pushes to `main`, and on manual
dispatch. It uses no secrets (`permissions: contents: read`); the commands are the ones in §7.4.

| Job | Runner | What it does |
|---|---|---|
| `ruff` | `ubuntu-latest` | `ruff check server` with the version pinned in `.pre-commit-config.yaml` and the config in `server/pyproject.toml`. |
| `server-tests` | `ubuntu-latest` | Writes the §7.4 `.env` stub, then runs the §7.4 Compose pytest command. Docker Engine and Compose v2 are preinstalled on the runner. |
| `ios-tests` | `macos-26` | Selects the newest installed Xcode 26, installs XcodeGen/SwiftLint with Homebrew only if the image lacks them, runs `swiftlint lint --strict`, stubs `project-piper.yml` and `Resources/Models`, runs `xcodegen generate`, boots a simulator, then `xcodebuild test -skipMacroValidation`. |

iOS job notes:

- The runner is the standard GitHub-hosted macOS image, free for public repositories; no
  self-hosted or paid larger runner is used. It needs Xcode 26 (the project targets iOS 26).
- The simulator is discovered, not hard-coded: `scripts/ci/select_ios_simulator.py` reads
  `xcrun simctl list devices available -j` and picks the newest installed iOS ≥ 26 runtime, then
  `iPhone 17` if present, else the newest plain iPhone. The job fails with a clear message if the
  image has no such simulator. It tests by UDID, so the name differences in §7.4 do not matter.
- `CODE_SIGNING_ALLOWED=NO` is passed because `project.yml` pins a personal `DEVELOPMENT_TEAM`
  that CI has no certificate for; simulator tests do not need signing.
- SwiftLint runs with `--strict` from the repo root (config and scope live in `.swiftlint.yml`),
  so any violation fails the job.
- Swift packages are resolved on every run (no cache yet), so the first minutes of the job are
  dependency fetches.

To make these checks required, add `Ruff (server)`, `Server pytest (Compose)` and
`iOS (XcodeGen, SwiftLint, xcodebuild test)` as required status checks in the branch protection
for `main`.

---

## 8. Operational notes

### 8.1 Secrets

- iOS: bearer token in Keychain, never UserDefaults, never logged.
- Server: `.env` in `.gitignore`. Contains `BEARER_TOKEN`, `MSGRAPH_CLIENT_ID`, `MSGRAPH_TENANT_ID`, `DIARY_PROCESSOR_URL`, `LIGHTRAG_URL`, `OLLAMA_URL`, `LIGHTRAG_API_KEY` (if applicable), and `BLINDFOLD_API_KEY` when the opt-in analysis route is used ([`docs/analysis-egress.md`](docs/analysis-egress.md)); the server never logs it.
- MSAL refresh token: in `server/data/msal_cache.bin`, file permissions 0600, backed up as part of routine server backups.

### 8.2 Upgrades

- iOS: rebuild and resign via Xcode. No server-side version checks for v1.
- Server: `docker compose pull && docker compose up -d`. MSAL cache survives restarts.
- Incompatible manifest schema changes: bump `app_version` in the manifest; `server` can reject or translate old versions.

### 8.3 Backup

- Server: back up `data/`. Contains session bundles and the MSAL cache.
- iOS: local audio + transcripts are ephemeral by retention policy. Definitive copy lives on the server after ingest. No separate iOS backup is required for recovery.

### 8.4 Observability

- Server: structured JSON logs to stdout, captured by Docker. When the analysis route is `blindfold`, start-up logs one WARNING naming the route, base URL and model (never the key); each saved narrative records `analysis_route` in its metadata. Rotate with `docker-compose` log driver settings.
- iOS: local diagnostics log viewable in Settings → About → Diagnostics. Nothing leaves the device.

---

## 9. Known risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Apple Foundation Models is German-weak | Medium | Gemma 4 E4B via MLX Swift is implemented as an opt-in dialog backend chosen for its stronger German; once selected in Settings → Mehr → Dialog-Modell it is primary for every session, with Apple FM as automatic fallback (SPEC §4.2, §11). |
| Piper Thorsten voice feels monotone | Medium | Evaluate `thorsten_emotional`; Piper is still the only open German option. |
| Parakeet wake-word misses in noisy environments | Medium | Tunable Levenshtein threshold; fallback physical button. |
| Exchange token revocation | Low | `msgraph_bootstrap.py` can be re-run at any time without disturbing other data. |
| `server` crashes mid-upload | Low | iOS upload queue retries with backoff; no data lost. |
| Existing routes break during n8n removal | Medium | Test `/api/ingest/upload` and `/api/transcripts` end-to-end after each S1 task before continuing. |
| User abandons because walkthrough feels like an interview | High | Max-one-follow-up rule, fast "I'm done talking" escape, drive-by recap toggle. Dogfood early and re-tune. |

---

## 10. After v1 ships

Parked features from SPEC §16 that should be revisited after 4 weeks of daily use:

- Weekly retrospective extension.
- Apple Watch capture.
- Full offline walkthrough (local LightRAG mirror).
- Voice persona design.
- Harvest time-tracking in the briefing.
- Enrichment wake-word customization.
- Geolocation tagging on drive-by seeds.
