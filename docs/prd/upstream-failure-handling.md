# PRD: Upstream Failure Handling

Status: Draft (2026-10-14). Specified through a grill session; implementation tracked as slice issues in `docs/issues/upstream-failure-handling/`, not as DEVELOPMENT.md milestones. Closes the "Graceful handling of upstream failures" bullet of DEVELOPMENT.md S4.
Owner: Florian
Authored: 2026-10-14
Related: `SPEC.md` §10 (ingest contract, retry), §15 (error handling), `DEVELOPMENT.md` S4, `docs/adr/0002-additive-upstream-failure-contract.md`, `docs/adr/0003-upstream-outages-never-block-capture.md`, `docs/issues/upstream-failure-handling/`

## Problem Statement

The server depends on five **upstreams**: Whisper (transcription), Ollama (analysis and enrichment summaries), LightRAG (diary memory), Microsoft Graph (calendar and mail) and Voxtral (server-side speech). When one of them is down, slow or rate-limited, the phone cannot tell which one, nor what it means for tonight's walkthrough.

Today each router reports failures its own way: free-form strings (`ollama_unavailable: <reason>`, a raw `str(exc)` on the Graph routes), a dict `{error, detail}` on the TTS route, a legacy `{status, message}` body on the manual-ingest routes. A Graph rate limit surfaces as a 502 `rate_limited: backoff_exhausted`; some Graph transport errors are not wrapped at all and become a bare 500. The iOS `ServerClient` only reads a string `detail`, so `ConnectionDiagnosis` classifies by HTTP status alone: "Server-Fehler" for every 5xx. A calendar failure at walkthrough start puts the walkthrough in `.failed` with a raw error string. Enrichment says "Server nicht erreichbar" for connectivity and one generic line for everything else. Sessions left `pending_analysis` by an Ollama or LightRAG outage are only retried on server restart; the app never asks for a retry and never explains why a session is still "Processing". The upload queue retries with backoff, but the user cannot see why a session is waiting.

None of this loses data (SPEC §15.2 holds: audio and transcripts are persisted before analysis), but the user cannot see that, and cannot tell a transient hiccup from something that needs the operator.

## Solution

One server-side contract and one app-side interpretation of it, built so that an outage degrades the app and never blocks capture or loses data.

**Server.** Every upstream failure is raised through one shared helper and reported with the same shape: the existing string `detail` plus top-level `code`, `upstream` and `retryable`, and a `Retry-After` header where a wait is known. Status mapping is uniform: 503 for down or timed out, 502 for an upstream error answer, 429 for Graph rate limits. Per-segment results in the session status carry the same `code` and `upstream`. `/health` keeps its shape; its overall status rules are made explicit, with Voxtral an optional upstream that never affects the overall status.

**App.** The app parses the contract and explains the impact in German and English, in the place the user meets it: spoken enrichment failures, the walkthrough-start calendar failure (retry, or start without the calendar), the Server settings screen (one impact sentence per unhealthy upstream), a non-blocking notice at walkthrough start, the pending-upload indicator, and the Verlauf status pill for failed segments. Pending-analysis sessions are retried automatically once per foreground when Ollama and LightRAG are healthy. Old servers without the new fields keep today's status-based behavior.

## User Stories

1. As a Voice Diary user, I want the app to tell me which service is down (transcription, analysis, memory, calendar), so that I know what to expect instead of seeing "Server-Fehler".
2. As a Voice Diary user, I want to know that my recording is safe when the server cannot transcribe, so that I do not re-record or worry.
3. As a Voice Diary user, I want an upload that the server rejects because Whisper is down to stay on my phone and retry by itself, so that I never have to babysit it.
4. As a Voice Diary user, I want to see in Mehr → Server why a session is waiting to upload, so that "2 sessions pending upload" is not a mystery.
5. As a Voice Diary user, I want a session whose analysis failed because Ollama or LightRAG was down to be retried automatically when they are back, so that my diary entry appears without me doing anything.
6. As a Voice Diary user, I want my transcripts to be kept when analysis fails, so that an outage never costs me what I said.
7. As a Voice Diary user, I want the walkthrough to offer "Erneut versuchen" or "Ohne Kalender starten" when the calendar cannot be loaded, so that a Microsoft outage does not stop my evening reflection.
8. As a Voice Diary user, I want the walkthrough never to start silently without my calendar, so that I do not wonder why my meetings were skipped.
9. As a Voice Diary user, I want an enrichment question that fails to be answered with a spoken reason specific to what is down, so that I know whether to try again or move on.
10. As a Voice Diary user, I want the spoken failure line to end with "Anreicherung übersprungen", so that the walkthrough continues without me wondering whether something is pending.
11. As a Voice Diary user, I want a short, non-blocking notice at walkthrough start when an upstream is unhealthy, so that I know what will be degraded tonight before I begin.
12. As a Voice Diary user, I want Mehr → Server to show one sentence of impact next to each unhealthy upstream, so that I can judge the situation without reading logs.
13. As a Voice Diary user, I want a Graph rate limit to be treated as "try again in a moment" and not as a broken server, so that I do not reconfigure anything.
14. As a Voice Diary user, I want to be told when Microsoft Graph is not set up on the server (not bootstrapped), and that it needs the operator, so that I do not keep retrying.
15. As a Voice Diary user, I want a failed segment in Verlauf to say why it failed, so that I know whether it is my audio or the server.
16. As a Voice Diary user, I want all failure copy in my app language, German by default and English first-class, so that errors are not in jargon or English-only.
17. As a Voice Diary user, I want a Voxtral outage to never change the overall server status, so that "degraded" means something I can act on.
18. As a Voice Diary user on an app build older or newer than the server, I want failures to still be classified sensibly, so that an update gap never produces a wrong or empty message.
19. As a Voice Diary maintainer, I want one server helper that produces every upstream failure response, so that a new router cannot invent a new shape.
20. As a Voice Diary maintainer, I want a documented catalogue of failure codes with their status, `retryable` flag and app consequence, so that server and app stay in step.
21. As a Voice Diary maintainer, I want the new response fields to be additive, so that installed app builds keep working while the server ships first.
22. As a Voice Diary maintainer, I want every Graph transport or MSAL error wrapped into a coded failure, so that no Graph problem becomes a bare 500.
23. As a Voice Diary maintainer, I want per-segment failure codes in the session status, so that a failed segment can be diagnosed without reading server logs.
24. As a Voice Diary maintainer, I want the iOS decision about which failures to retry automatically to be a pure, named module, so that changing the rule is a one-file change with a unit test.
25. As a Voice Diary maintainer, I want the failure copy to live in the app's string catalog, so that wording changes do not need a server release.
26. As a Voice Diary maintainer, I want mocked-transport tests for each router's upstream failures, so that a status-mapping regression is caught before the app misreports it.
27. As a Voice Diary maintainer, I want SPEC §10, §15 and the server README's failure-modes section updated in the same change as the code, so that the contract is documented where the next reader looks.

## Implementation Decisions

### Architecture

- Upstreams are Whisper, Ollama, LightRAG, Microsoft Graph and Voxtral (see `CONTEXT.md`). Postgres and Qdrant are infrastructure and stay out of the contract.
- The contract is **additive** (ADR 0002): `detail` remains a string so installed builds keep working; `code`, `upstream`, `retryable` are new top-level fields. Ship order: server, then app.
- Outages **degrade, never block or lose** (ADR 0003): capture and upload data are never deleted on a failure; start is never blocked by an upstream.
- Out of scope for this work because they already exist: structured JSON logging with correlation IDs (`logging_setup.py`), `server/scripts/backup.sh`, and the README logs, backup and bearer-rotation sections.

### Modules — server

- **Failure helper** (new, deep): one exception type, `UpstreamFailure`, carrying `code`, `upstream`, `status_code`, `retryable`, `message`, optional `retry_after`, and an exception handler that renders the response. Also a small mapping function from each upstream client's exception classes (`Asr*`, `Ollama*`, `LightRAG*`, `TTS*`, `MSGraph*`, `EnrichmentSummariserUnavailable`) to an `UpstreamFailure`. Routers raise or translate through it; none builds an upstream `HTTPException` by hand.
- **`routers/sessions.py`**: the Whisper preflight raises `whisper_unavailable` through the helper. Per-segment phase-1 errors and the session-level `analysis_pending` errors record `code` and `upstream` on the segment result in addition to the existing `error` string. Exceptions that escape the clients raw (the `document_processor` analysis path raises plain `httpx` errors and `RuntimeError("LLM analysis timed out …")`) are classified at the narrative boundary into `ollama_*` / `lightrag_*`; anything unclassifiable gets no `code`.
- **`routers/lightrag.py`, `email.py`, `calendar.py`, `tts.py`**: raise through the helper. The Ollama summariser failure (`EnrichmentSummariserUnavailable`) is split by reason into `ollama_unavailable`, `ollama_timeout`, `ollama_engine_error`.
- **`msgraph_client.py`**: wraps every transport exception and MSAL failure into `MSGraphError` or `MSGraphNotBootstrapped`; exposes the 429 `Retry-After` value on the exception so the mapping can emit `msgraph_rate_limited` with the header.
- **`routers/health.py`**: response shape unchanged (`status`, `upstream{}`). Overall rules: `down` only if `postgres` or `whisper` is `down`; `degraded` if any non-optional, non-`skipped`, non-`fixture` probe is not `ok` (including Graph `not_bootstrapped`); `ok` otherwise. Voxtral is excluded from the overall computation. The Graph probe still checks the MSAL token cache, not live Graph.
- **`models.py`**: `SegmentResult` gains optional `code` and `upstream`.
- The legacy `main.py` manual-ingest routes (`/api/ingest/*`, review UI only) keep their own response shape and are not touched.

### Modules — iOS

- **`UpstreamFailure`** (new value type) and the extraction in `ServerClient.assertOK`: decode `code`, `upstream`, `retryable` and `Retry-After` into `ServerClientError.http` alongside the existing status and detail. Missing fields yield nil, i.e. today's behavior.
- **Failure copy** (new, pure): maps `(code, upstream)` to title, hint and one-line impact in German and English, resolved through `Localizable.xcstrings`. `ConnectionDiagnosis.classify` consults it first and falls back to its existing status-based cases when there is no code.
- **`EnrichmentService.failureMessage`**: per-upstream spoken line chosen by code, each ending "Anreicherung übersprungen" / "Enrichment skipped"; without a code, the existing connectivity-vs-generic split.
- **`WalkthroughCoordinator`**: a calendar fetch failure at start no longer ends in `.failed`; it enters a state that shows the diagnosis with two actions, retry or start without the calendar (general sections, free reflection and voice notes only). A non-blocking start notice (like the Voxtral preflight) states the impact of any unhealthy upstream.
- **`SessionUploader`**: `UploadOutcome.classify` keeps its 409, 400/404/422 and default rules and additionally: honours `Retry-After` when longer than the backoff step; treats `retryable: false` as non-automatic (the entry waits, not marked permanent, until the next foreground or a settings change); stores the last failure `code` on the queue entry (optional, defaults to nil when decoding old queue files). Audio is never deleted on failure.
- **Pending-upload indicator** (new, minimal): Mehr → Server shows "N Sitzungen warten auf Upload" and the last failure's explanation, as SPEC §10.6 already promises. The only pending-upload UI today is the count in DangerZoneView.
- **Retry-analysis policy** (new, pure; in the style of `TTSFallbackPolicy`): decides whether to call `POST /api/sessions/{id}/retry-analysis` from the session status (`pending_analysis` segments with `analysis_pending` errors) and the latest health (Ollama and LightRAG `ok`). Triggered once per foreground (the `scenePhase == .active` hook that already kicks the uploader) over locally known sessions uploaded in the last 14 days. A `409 session_busy` is silently skipped. `failed` segments are never retried this way.
- **Server settings and Verlauf**: `ServerSettingsView` shows one impact sentence per non-`ok` upstream; the Verlauf status pill for a `failed` segment shows the explanation for its `code`.
- **Voxtral**: no change to `TTSFallbackPolicy` or `VoxtralTTS` (already fall back per utterance); the TTS error body now follows the shared shape.

### API contract

Error response (all upstream failures):

```json
{ "detail": "whisper_unavailable: connection refused",
  "code": "whisper_unavailable",
  "upstream": "whisper",
  "retryable": true }
```

Status: **503** the upstream is down or timed out; **502** the upstream answered with an error; **429** (+ `Retry-After`) Graph rate-limited. `Retry-After` is emitted only where a wait is known.

Failure codes:

| Code | Upstream | Status | Retryable | Source today |
|---|---|---|---|---|
| `whisper_unavailable` | whisper | 503 | yes | sessions preflight, `AsrUnavailableError` |
| `whisper_timeout` | whisper | 503 | yes | `AsrTimeoutError` |
| `whisper_engine_error` | whisper | 502 | yes | `AsrEngineError` |
| `ollama_unavailable` | ollama | 503 | yes | `OllamaUnavailableError`, summariser unreachable |
| `ollama_timeout` | ollama | 503 | yes | `OllamaTimeoutError`, analysis timeout |
| `ollama_engine_error` | ollama | 502 | yes | `OllamaEngineError`, empty or bad response |
| `lightrag_unavailable` | lightrag | 503 | yes | `LightRAGUnavailableError` |
| `lightrag_timeout` | lightrag | 503 | yes | `LightRAGTimeoutError` (today folded into unavailable) |
| `lightrag_engine_error` | lightrag | 502 | yes | `LightRAGEngineError` (today `lightrag_status_N` / `lightrag_bad_response`) |
| `msgraph_not_bootstrapped` | msgraph | 503 | no | `MSGraphNotBootstrapped` |
| `msgraph_rate_limited` | msgraph | 429 | yes | 429 backoff exhausted (today 502 `rate_limited`) |
| `msgraph_unavailable` | msgraph | 503 | yes | network error, timeout |
| `msgraph_engine_error` | msgraph | 502 | yes | `upstream_5xx`, `graph_error`, unwrapped errors |
| `voxtral_unavailable` | voxtral | 503 | yes | existing |
| `voxtral_timeout` | voxtral | 503 | yes | existing (today 504) |
| `voxtral_engine_error` | voxtral | 502 | yes | existing |
| `unknown_voice` | voxtral | 400 | no | existing; field `error` becomes `code` |

Existing non-upstream codes (`session_busy`, `session_not_retryable`, `session_not_found`, auth codes) are unchanged and carry no `upstream`.

Session status: each segment in `GET /api/sessions/{id}/status` and the `retry-analysis` response gains optional `code` and `upstream`. `error` is unchanged.

App copy (German; English key in the string catalog; impact sentences):

| Upstream | Impact sentence |
|---|---|
| whisper | Aufnahmen bleiben auf dem Handy und werden später hochgeladen. |
| ollama / lightrag | Auswertung verzögert sich, deine Texte sind gespeichert. |
| msgraph | Kalender und Mail sind gerade nicht erreichbar. |
| msgraph (not bootstrapped) | Kalender ist auf dem Server nicht eingerichtet. Das muss am Server erledigt werden. |
| voxtral | Server-Stimmen fallen auf Piper zurück. |

Spoken enrichment failures: Ollama "Die Zusammenfassung ist gerade nicht verfügbar. Anreicherung übersprungen."; LightRAG "Das Tagebuch-Gedächtnis ist gerade nicht erreichbar. Anreicherung übersprungen."; Graph "Kalender und Mail sind gerade nicht erreichbar. Anreicherung übersprungen."; English equivalents in the catalog.

### Storage

- Server: the segment `code`/`upstream` are persisted with the rest of the segment result in the `session_ingests.segments` JSONB column. No migration; rows written before simply lack the keys and read back as null.
- iOS: `QueueEntry` gains an optional last-failure code; a custom decoder default keeps old `upload_queue.json` files readable.

### Settings model

No new user settings.

### Documentation updated with the code

SPEC.md §10.5 (segment `code`/`upstream`), §10.6/§10.6.1 (Retry-After, `retryable`, app-driven retry-analysis), §10.7 (`/health` semantics), §15.1 (new category rows); DEVELOPMENT.md S4 failure-handling bullet marked done; `server/README.md` "Common failure modes" refreshed with the code table.

## Testing Decisions

Test through behavior at the contract boundary, not implementation. Existing style: injectable `httpx.MockTransport` for clients, FastAPI `TestClient` for routers, `monkeypatch` for upstream clients.

### Server tests (in scope)

- **Failure helper**: each upstream client exception maps to the right `(code, upstream, status, retryable)`; response body contains string `detail`, `code`, `upstream`, `retryable`; `Retry-After` present only when known.
- **Per router** (`sessions`, `lightrag`, `email`, `calendar`, `tts`): with the upstream mocked to be down, slow and erroring, the response carries the documented code and status. No router tests exist for lightrag, email, calendar or tts today, so these are new files.
- **Graph**: 429 exhaustion yields `msgraph_rate_limited` with `Retry-After`; an `httpx.RemoteProtocolError` and an MSAL exception yield a coded failure, not a 500.
- **Sessions**: Whisper down at preflight returns 503 `whisper_unavailable` and persists nothing; a mid-run Whisper failure and an Ollama/LightRAG failure record `code`/`upstream` on the segment alongside the unchanged `error` string.
- **Health**: overall status for every combination that matters (Postgres/Whisper down; Ollama/LightRAG/Graph down or `not_bootstrapped`; Voxtral down or skipped alone leaves `ok`). No health tests exist today beyond the bearer-gating check.

### iOS tests (in scope)

- **`ServerClient` error extraction**: the error body with and without the new fields; `Retry-After` parsing.
- **Failure copy / `ConnectionDiagnosis` / `EnrichmentService.failureMessage`** by code and upstream, German and English, and the fallback when there is no code (extends `EnrichmentFailureCopyTests`).
- **`UploadOutcome`**: Retry-After, `retryable: false`, existing 409/400/404/422 rules unchanged (extends `UploadOutcomeTests`); the queue file decodes without the new field.
- **Retry-analysis policy**: pure table tests: which statuses and health states trigger, which do not, `session_busy` skipped, `failed` never retried.

### Modules built without automated tests

- SwiftUI changes (Server settings impact lines, pending-upload indicator, Verlauf pill, calendar retry / start-without-calendar screen, start notice) are verified by the manual scenarios below.

### Manual scenarios that must pass

1. Stop Whisper, finish a walkthrough: the upload is rejected, the session stays queued with the Whisper explanation shown in Mehr → Server, and uploads after Whisper returns, with no audio lost.
2. Stop Ollama, upload a session: it lands `pending_analysis`; after Ollama returns and the app is foregrounded, the session becomes processed without user action.
3. Make Graph unreachable, start a walkthrough: retry and start-without-calendar are offered; starting without it completes a walkthrough with general sections and free reflection.
4. Ask an enrichment question with LightRAG stopped: the spoken line names the memory, ends "Anreicherung übersprungen", and the walkthrough continues.
5. Stop Voxtral with a Voxtral voice selected: overall `/health` stays `ok`, the walkthrough falls back to Piper, and the existing Voxtral notice shows.
6. New app against a server without the new fields (or the reverse): copy falls back to the status-based messages with no crash and no empty text.

## Out of Scope

- Re-transcribing segments that `failed` before transcription from the audio already on the server. The audio is not lost, but today nothing re-runs it; see Further Notes.
- Structured logging, correlation IDs, backup script, bearer rotation and README setup sections (already exist).
- A live Microsoft Graph probe in `/health` (it keeps checking the token cache).
- Changes to the legacy `main.py` manual-ingest and review-UI response shapes.
- Per-upstream circuit breakers, server-side request queues, or retries beyond what the clients already do.
- A user-facing manual "retry analysis" button.
- Telemetry (SPEC §15.3 stands: none).

## Further Notes

- **Decision: failed-segment recovery is user-triggered.** A segment that fails after the Whisper preflight passed (Whisper dies mid-run) is recorded `failed` with no transcript. The phone has already dropped the queue entry on the 2xx, and the audio sits in `server/data/sessions/{id}/`. The [PROTO-1] prototype compared automatic recovery on foreground or health recovery (option A) with an explicit user action (option B); the operator accepted it and chose option B. Recovery of a `failed` segment will therefore start only when the user asks for it, never automatically. The evidence is `docs/prototypes/PROTO-1/failed-transcription-recovery.html`, delivered in PR #160 (branch `factory/06098127-3d85-488f-8e9c-d693dd95d95e`); it is not on `main` until that PR lands.
  - **Tradeoff.** Deliberate recovery avoids unsolicited changes to finished entries and repeated automatic attempts against an upstream that may still be down. The cost is that the user has to notice the failed segment and start recovery themselves.
  - **Constraints for a future recovery spec.** Automatic retry-analysis keeps excluding `failed` segments (`docs/issues/upstream-failure-handling/07-ios-auto-retry-analysis.md`, "segments with `failed` status are never retried this way"). Recovery must leave successfully transcribed segments untouched, depend on the retained server audio in `server/data/sessions/{id}/`, and keep capture available while it runs (`docs/adr/0003-upstream-outages-never-block-capture.md`).
  - **Not decided here.** Endpoint contracts (including any `retry-transcription` route), the exact UI and health gating, retry scheduling and the implementation are future specification work. This is a policy record, not an implementation commitment: no production behaviour is approved by it, and the Out of Scope entry on re-transcribing `failed` segments stands. This work only makes the failure explainable.
- **SPEC drift found.** SPEC §10.6 says the UI shows "2 sessions pending upload"; no such indicator exists, only the DangerZoneView count. The pending-upload indicator is added here.
- **SPEC drift found.** SPEC §10.7 says `/health` returns `ok` only when LightRAG, Ollama, Whisper and Postgres are reachable; the code also degrades on Qdrant, Graph and Voxtral. This work fixes the Voxtral part and documents the rest.
- `Reachability.refresh` calls `todayCalendar` on every refresh to validate the bearer, which makes every health refresh touch Graph. Non-401 failures already fall through, so this is harmless to this contract, but a cheaper bearer check would be a separate cleanup.
- Voxtral's `/health` probe is accurate while the engine sleeps because the voxtral-gate answers it without waking the engine (`server/voxtral-gate/README.md`).
- Rollout: the server ships first and is a strict superset of today's responses; the app then adopts the fields.
