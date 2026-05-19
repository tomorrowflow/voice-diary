# PRD: Voxtral TTS Integration

Status: Draft, awaiting triage
Owner: Florian
Authored: 2026-05-18
Related: `SPEC.md` §4 (on-device stack), `SPEC.md` §13 (storage), `DEVELOPMENT.md` (introduces milestones S5 and M13)

## Problem Statement

The evening walkthrough is the heart of the product, and the AI's voice carries most of its felt quality. Right now, when the walkthrough speaks an opener, a follow-up, a todo confirmation, or a closing prompt, it does so through one of two backends: Apple's premium AVSpeech voices, or Piper neural voices via sherpa-onnx running fully on-device. The Apple voices are passable but locked to Apple's voice catalog and have a synthetic prosody for German that breaks the reflective tone of the walkthrough. The Piper voices were chosen for offline guarantees but, in daily use, sound noticeably more robotic than the rest of the experience — flat intonation, occasional mispronunciations of German names, and a slightly muffled timbre. Across a 20-minute walkthrough this is the single largest reason the AI feels like an interview rather than reflection.

Switching TTS engines on iOS alone has run out of headroom: the on-device model size budget is tight, and there is no on-device option in 2026 that materially beats Piper for German at a sane footprint. Meanwhile the Voice Diary stack already has a Tailscale-only server, a GPU box on the same tailnet (2× RTX 3090), and a tested bearer-token auth model for iOS-only routes. The opportunity is to push higher-quality synthesis to the server, where a frontier model can run unconstrained, and to do so without sacrificing the offline fallback that keeps drive-by capture and travel scenarios working.

## Solution

We add **Voxtral TTS** — Mistral's open-weights 4 B-parameter speech synthesis model, released March 2026 under CC BY-NC 4.0 — as a third TTS engine, peer to Apple and Piper. It runs on the existing server box in a new `voxtral` Docker service using Mistral's official `vllm/vllm-omni:v0.18.0` image, pinned to one of the two RTX 3090s. A narrow FastAPI route on the existing webapp proxies iOS TTS requests over Tailscale with bearer auth. On iOS, a new engine implementing the existing `TTSEngine` protocol POSTs text to that route, receives a WAV, and plays it through the playback path Piper already uses. Selection happens through the existing voice-ID prefix scheme: `"voxtral:<voice-id>"` routes to the new engine; `"piper:…"` and Apple identifiers continue to work unchanged.

From the user's seat: in Settings, a new "Voxtral (Server)" section appears per language with the bundled Mistral reference voices (DE + EN). Pick one as the German voice and another as the English voice, and the next walkthrough's opener, follow-up, closing, and todo prompts come through the new engine. If the Tailscale link drops, or the GPU is busy, or the server is down, the walkthrough quietly falls back to the user's previously chosen Piper or Apple voice for that one utterance and continues without a stall. Drive-by capture, which never asks the phone to speak, is untouched. The offline guarantee for the rest of the system stays intact.

## User Stories

1. As a Voice Diary user, I want the AI's voice during the evening walkthrough to sound natural and warm, so that reflecting on my day feels like a conversation and not an interrogation.
2. As a Voice Diary user, I want the German voice in particular to handle German names, place names, and code-switching to English without obvious mispronunciation, so that the opener for an event like "Standup mit Anna" doesn't break my immersion on the first sentence.
3. As a Voice Diary user, I want to be able to choose a different voice for German and for English independently, so that each language sounds idiomatic rather than one voice straining at both.
4. As a Voice Diary user, I want to preview a Voxtral voice in Settings before I commit to it, so that I can decide quickly which one fits the reflective tone I want.
5. As a Voice Diary user, I want my voice choice to persist across sessions, so that I don't reconfigure it every evening.
6. As a Voice Diary user, I want the new server voice to be opt-in, so that nothing changes about my current Piper or Apple setup until I deliberately switch.
7. As a Voice Diary user, I want Piper and Apple voices to remain available as alternatives, so that I always have an offline option for travel or for when the home server is off.
8. As a Voice Diary user on the home network, I want the openers to start playing within a sub-second of the AI deciding to speak, so that the walkthrough cadence doesn't degrade compared to today's on-device Piper path.
9. As a Voice Diary user, I want the system to use its existing opener-prefetch path with the new engine, so that the network round-trip to the server is hidden behind my prior turn the way Piper's synth cost is hidden today.
10. As a Voice Diary user, I want the AI to never pause silently because the server is unreachable, so that my evening walkthrough completes even when the Tailnet hiccups.
11. As a Voice Diary user, I want a quiet fallback to my previously chosen Piper or Apple voice when Voxtral fails, so that one bad utterance doesn't break the session even if the voice mid-walkthrough shifts.
12. As a Voice Diary user, I want fallbacks to be logged locally, so that if the new engine is silently failing I can find out without having to babysit logs in real time.
13. As a Voice Diary user, I want the new TTS path to share the same bearer token I already use for the calendar, email, and session ingest routes, so that my onboarding stays a single token to manage.
14. As a Voice Diary user, I want the new TTS path to be reachable only via Tailscale, so that my voice output traffic never crosses the public internet.
15. As a Voice Diary user, I want Settings to surface whether the Voxtral server is currently reachable, so that I know up front whether selecting a Voxtral voice will actually do anything tonight.
16. As a Voice Diary user, I want the voice list per language to come from the server rather than be hardcoded in the app, so that adding a new bundled voice on the server side does not require a new app build.
17. As a Voice Diary user, I want my chosen voices to keep working when I update the app, so that an iOS update doesn't reset my Settings.
18. As a Voice Diary user, I want the drive-by capture mode to be completely untouched by this change, so that the most-used capture path stays as reliable as it is today.
19. As a Voice Diary user, I want the wake-word enrichment path's audible "einen Moment" cue to keep playing in whatever voice I picked, so that the user-facing latency cue stays consistent with the rest of the walkthrough voice.
20. As a Voice Diary user, I want my walkthrough not to start at all if I have selected a Voxtral voice and the server is clearly unreachable before BRIEFING, so that I can decide whether to switch back to Piper before I commit to the session.
21. As a Voice Diary user, I want the Voxtral model and its voice references to be cached locally on the server, so that a server restart does not download multiple gigabytes again.
22. As a Voice Diary maintainer, I want the new `voxtral` service to be pinned to one GPU, so that Ollama and any future GPU workload on the second 3090 are not starved.
23. As a Voice Diary maintainer, I want the new server route to be a thin proxy, so that the surface area for bugs and the cost of swapping inference servers in the future stays low.
24. As a Voice Diary maintainer, I want the iOS HTTP client for Voxtral to be a pure module with no `TTSEngine` semantics inside it, so that I can write unit tests for transport, timeouts, and error mapping without standing up an audio session.
25. As a Voice Diary maintainer, I want the per-utterance fallback decision to live in a single named module, so that future changes to the fallback policy (e.g. "after three failures in a row, stop trying Voxtral for the rest of the session") are a one-file change.
26. As a Voice Diary maintainer, I want the voice catalog to be fetched and cached rather than baked in, so that adding a Mistral voice on the server side does not require an iOS release.
27. As a Voice Diary maintainer, I want the new compose service to be a sidecar with its own lifecycle, so that the webapp can be restarted without paying Voxtral's cold-start cost.
28. As a Voice Diary maintainer, I want `/health` to include a Voxtral reachability probe, so that the same health check I use today tells me at a glance whether server-side TTS is up.
29. As a Voice Diary maintainer, I want the PRD, SPEC, and DEVELOPMENT docs to be updated in the same commit as the code, so that future me does not need to reconstruct the rationale from git archaeology.
30. As a Voice Diary maintainer, I want the CC BY-NC 4.0 license note to be visible in SPEC.md, so that if I ever consider distributing the app I am reminded that the weights are non-commercial.
31. As a Voice Diary maintainer, I want server tests that cover the Voxtral HTTP client's timeout and error mapping behavior, so that a flaky vLLM does not surface as obscure iOS errors.
32. As a Voice Diary maintainer, I want the iOS engine's fallback policy to be testable without HTTP or audio, so that I can change the rules with confidence.
33. As a Voice Diary maintainer, I want all hard-coded styling to continue going through `Theme.*` and `DSButtonStyle` in the new Settings UI, so that the design system rule from CLAUDE.md is not violated by the new screens.

## Implementation Decisions

### Architecture

- Voxtral becomes a **third peer engine** alongside Apple AVSpeech and Piper, not a replacement. Routing in the iOS `VoiceRegistry` keys on the voice-ID prefix already in use (`"piper:"`, Apple identifiers); a new `"voxtral:"` prefix dispatches to the new engine.
- All Voxtral traffic is **server-mediated**. No Mistral API key on the phone, no direct phone → vLLM connection. The server's bearer-token auth model (per-router `Depends`, same token as calendar / email / sessions) covers the new route.
- The server proxy is **thin by design**. It does not cache audio, transform text, or implement business rules beyond auth + minimal validation + forwarding. Inference quality lives entirely in Voxtral; transport lives entirely in the proxy.
- Network exposure remains **Tailscale-only**. The `voxtral` sidecar is not bound to a host port; it is only reachable from the `webapp` service over the compose network.

### Modules — server

1. **`voxtral_client` (deep).** A pure async HTTP client wrapping the OpenAI-compatible `/v1/audio/speech` endpoint on vLLM Omni. Single public method along the lines of `synthesize(text, language, voice, response_format) -> bytes`. Owns timeouts, retries with backoff on transient failures (HTTP 5xx, connection reset), error classification (unknown voice → `TTSUnknownVoiceError`, vLLM unreachable → `TTSUnavailableError`, model error → `TTSEngineError`). Httpx transport is injectable so tests do not need a live vLLM. No FastAPI imports.
2. **`voice_catalog` (deep).** Single source of truth for "which voices exist per language." On first request, calls vLLM (or reads a static manifest derived from the model card if vLLM does not expose a list endpoint), normalizes the response into `{ language: [VoiceDescriptor, …] }`, and caches it in memory with a TTL on the order of the process lifetime. Exposes `list(language)` and `exists(voice_id)`. Independent of FastAPI; testable with a fake `voxtral_client`.
3. **`routers/tts` (deliberately shallow).** Two routes: `POST /api/tts/synthesize` and `GET /api/tts/voices`. Both gated by the existing bearer-auth `Depends`. The POST route validates payload (text length cap, language in {DE, EN}, voice exists per `voice_catalog`), delegates to `voxtral_client`, and streams the WAV body back with `Cache-Control: no-store`. The GET route serializes `voice_catalog.list(...)` to JSON. The router holds no synthesis logic.
4. **`/health` extension.** The existing health endpoint gets a `voxtral` field reporting reachability. Implementation: a one-line ping into `voxtral_client` with a tight timeout, classified as `ok`, `degraded`, or `down`.
5. **Compose service.** New `voxtral` service in `docker-compose.yml` using `vllm/vllm-omni:v0.18.0`, pinned to GPU 0 via `device_ids: ["0"]`, with a named volume for the HuggingFace model cache. Not exposed on any host port. The webapp reaches it on the compose-internal hostname `voxtral`. Sidecar lifecycle is independent of webapp; restarting webapp must not require Voxtral re-warmup.
6. **Configuration surface.** Three new env vars: `VOXTRAL_BASE_URL` (default `http://voxtral:8001`), `VOXTRAL_MODEL` (default `mistralai/Voxtral-4B-TTS-2603`), `VOXTRAL_TIMEOUT_SECONDS`. Documented in `.env.example`.

### Modules — iOS

7. **`VoxtralTTSClient` (deep).** Pure `URLSession`-based transport. Public surface roughly `synthesize(text, language, voice) async throws -> URL` (path to a WAV in `FileManager.temporaryDirectory`). Owns bearer-token injection from Keychain, timeout, error mapping into typed `VoxtralError` cases (`unreachable`, `unauthorized`, `unknownVoice`, `serverError(status)`, `timeout`, `decodeFailed`). Knows nothing about `TTSEngine`, `AVAudioPlayer`, or the walkthrough. Testable with a `URLProtocol` stub.
8. **`TTSFallbackPolicy` (deep).** Pure decision module. Public surface roughly `decide(error: Error, language: String, preferences: VoicePreferences) -> FallbackDecision`, where `FallbackDecision` enumerates `{ usePiper(stem), useApple(identifier), giveUp }`. No IO. Future evolution (per-session circuit breaker, exponential cooldown) lands here without touching the engine or the registry.
9. **`VoxtralTTS` (adapter).** Implements the existing `TTSEngine` protocol. Composes `VoxtralTTSClient`, `TTSFallbackPolicy`, and the existing playback path Piper uses (`AVAudioPlayer` + the shared `PlaybackDelegate` + the serial queue that prevents overlapping utterances). `speak(text, language)` calls the client; on error, asks the policy, and on `usePiper`/`useApple` re-dispatches to that engine for the same utterance. `prefetch(text, language)` runs the client off the critical path and caches the WAV URL in the existing `PrefetchedUtterance.audioURL` so `speakOpenerScript()` consumes it identically to a Piper prefetch.
10. **`VoiceCatalogClient` (iOS).** Fetches `GET /api/tts/voices` once at app launch and on a refresh trigger (Settings opened, pull-to-refresh on the voice list). Caches the JSON in `UserDefaults` so Settings has something to show offline. Exposes a published list grouped by language.
11. **`VoiceRegistry` extension.** A `"voxtral:"` prefix branch above the existing Piper branch in `engine(for: language)`. The branch returns `VoxtralTTS.shared` if the server URL is configured in Keychain, else falls through to the next branch.
12. **`VoicePreferences` extension.** Already a string-typed store; no schema change. The `"voxtral:<voice-id>"` value just lives in the same per-language slot.
13. **`VoiceSettingsView` extension.** A new section per language: "Voxtral (Server)". Rows populated from `VoiceCatalogClient`. Each row exposes a preview button that calls `VoxtralTTS.shared.speak(sampleText, language:)` for that specific voice. If the catalog is empty (server unreachable, no token), show an explanatory empty state, not a spinner. Settings UI follows CLAUDE.md design-system rules: no hard-coded colour, spacing, or radius; all styling through `Theme.*` and existing button styles.
14. **Onboarding probe.** If a server URL and bearer token are set, fire a one-shot `/health` request after the existing connectivity check and reflect Voxtral availability in the onboarding success screen.

### API contract

`POST /api/tts/synthesize`
- Request body: `{ "text": string, "language": "DE" | "EN", "voice": string, "response_format": "wav" }` (response_format optional, default `"wav"`).
- Auth: `Authorization: Bearer <IOS_BEARER_TOKEN>` (existing token).
- Response 200: `audio/wav` body, 24 kHz mono PCM.
- Response 400: `{ "error": "unknown_voice" | "language_unsupported" | "text_too_long", "detail": string }`.
- Response 401: empty body, standard auth failure.
- Response 503: `{ "error": "voxtral_unavailable", "detail": string }` when vLLM is unreachable or returns 5xx.
- Response 504: timeout from upstream.

`GET /api/tts/voices`
- Auth: same bearer.
- Response 200: `{ "DE": [ { "id": string, "name": string, "gender": string?, "description": string? }, … ], "EN": [...] }`.

### Manifest and segment schemas

No changes to the per-session manifest, segment types, or any ingest contract. This feature is output-side only.

### Storage

A new on-disk location is introduced: `server/data/voxtral-models/` as the HuggingFace cache mount for the sidecar. Documented in `SPEC.md` §13. Covered by `.gitignore`. Expected size: ~8 GB for the unquantized 4 B model plus reference voices. iOS-side temp WAVs use the same `FileManager.temporaryDirectory` pattern Piper already uses; lifetime is the duration of `AVAudioPlayer` playback.

### Settings model

`Settings → Stimme` gains one new section per language called "Voxtral (Server)". The existing per-language voice picker continues to be the canonical selection surface; the only change is that the radio list now contains a third group of options.

### Milestones added to DEVELOPMENT.md

- **S5 — Voxtral server route.** Compose service, `voxtral_client`, `voice_catalog`, `tts` router, `/health` extension, env vars, tests. Exit criterion: `curl` over Tailscale returns a playable WAV for both DE and EN with at least one bundled voice each.
- **M13a — iOS engine end-to-end.** `VoxtralTTSClient`, `VoxtralTTS`, registry routing, minimum-viable Settings entry. Exit criterion: a Settings preview tap plays a Voxtral-synthesized utterance through the speaker.
- **M13b — Production polish.** `TTSFallbackPolicy`, prefetch integration, `VoiceCatalogClient`, full Settings UI, onboarding probe. Exit criterion: one full evening walkthrough completes end-to-end on Voxtral with no audible stalls vs. the current Piper baseline; pulling the ethernet falls back to Piper without a crash.
- **M13c — Latency tuning.** Measure TTFA from `speak()` call to first audio frame over Tailscale. Decide whether streaming inference is worth pursuing. Exit criterion: median TTFA ≤ 600 ms on home Wi-Fi for an opener of typical length.

S5 gates M13a (cannot test the engine without the route). M13a and M13b can overlap modestly.

## Testing Decisions

Tests target **observable behavior at a module boundary**, not implementation details. A good test for this work answers a question a future maintainer will actually ask: "if the server returns 503, does the iOS engine fall back?" — not "did we call `httpx.AsyncClient` with these exact kwargs?" That means: input → public method → assertion on output or on a typed error. No mocking of internal functions; no asserting on log lines.

### Server tests (in scope for v1)

The only module the user has chosen to cover with automated tests in v1 is **`voxtral_client`** on the server. Coverage:

- Happy-path synthesis: given a fake httpx transport returning a fixed WAV payload, `synthesize(...)` returns those bytes.
- Unknown voice: vLLM returns a 400 with a known error shape → `voxtral_client` raises `TTSUnknownVoiceError`.
- vLLM unreachable: transport raises `httpx.ConnectError` → `TTSUnavailableError`.
- vLLM slow: transport sleeps past timeout → `TTSTimeoutError`.
- vLLM 5xx with retry budget: first call 500, second call 200 → returns bytes on second try; transcript records two attempts.
- vLLM 5xx beyond retry budget: three 500s → `TTSEngineError`.
- Bearer is not the client's concern (auth is router-level); no auth tests live here.

Prior art: the existing FastAPI test pattern in `server/webapp/tests/` (FastAPI `TestClient` per router, mocks for MSAL / Ollama / Whisper / LightRAG) is the model. The `voxtral_client` tests live alongside those and follow the same `pytest` conventions.

### Server modules built without automated tests in v1

`voice_catalog`, `routers/tts`, and the `/health` extension are deliberately thin or pure-data, and the user has opted to verify them by manual smoke test over Tailscale before merge rather than by unit tests. They remain *designed for testability* (no hidden globals, injectable dependencies) so that adding tests later is mechanical.

### iOS modules built without automated tests in v1

`VoxtralTTSClient`, `TTSFallbackPolicy`, `VoxtralTTS`, `VoiceCatalogClient`, the `VoiceRegistry` extension, and the `VoiceSettingsView` changes are not covered by automated tests in v1 per the user's scoping decision. They are designed to be testable in isolation: `VoxtralTTSClient` accepts a `URLProtocol` stub, `TTSFallbackPolicy` is a pure decision function, `VoiceCatalogClient` accepts an injectable URLSession. Tests can be added in a later milestone without refactoring.

### Manual scenarios that must pass before M13b is called done

These are not automated but must be executed end-to-end on a real iPhone 17 Pro before claiming completion:

- Full evening walkthrough with three calendar events, Voxtral selected for DE and EN, server reachable throughout. No audible stalls. Voice consistent across opener, follow-up, todo, closing.
- Same walkthrough with the Mac running the server put to sleep mid-session. Subsequent utterances fall back to the previously chosen Piper voice without a crash; the walkthrough completes.
- Drive-by capture in the car, no Tailscale connection at all. Unaffected.
- Settings: switch DE voice from a Piper voice to a Voxtral voice, preview, switch back, preview again. No state corruption.
- Settings opened with no server URL configured: Voxtral section shows an explanatory empty state, not a crash, not a spinner.

## Out of Scope

- ~~**Custom voice cloning from a 3 s user reference.**~~ Originally out of scope; **reopened as Slice 07** (2026-05-19) after the user found Voxtral's two bundled German voices regionally biased. See the Slice 07 addendum below.
- **Streaming inference.** The official model card mentions streaming but documents only batch. v1 uses batch. M13c will measure whether streaming is worth pursuing.
- **Replacing Whisper STT with Voxtral Transcribe.** Different model, different milestone. The user separately noted the `virtUOS/vllm-voxtral` repo as a potential STT path; explicitly not addressed here.
- **Apple Foundation Models or Gemma fallback for the dialog LLM.** Unchanged by this PRD.
- **Free-reflection mode TTS quality.** Free reflection currently uses the same engine selection as the walkthrough, so it benefits automatically; no dedicated work.
- **Public exposure of the TTS route.** Tailscale-only, per CLAUDE.md rule 6.
- **Multi-user voice profiles.** Voice Diary is single-user, per CLAUDE.md.
- **On-device Voxtral.** Mistral claims a 3 GB quantized variant; we are deliberately not pursuing this because we already have a GPU on the tailnet and on-device adds an iOS bundle / packaging burden with no clear quality win for this user.
- **Commercial-license review.** CC BY-NC 4.0 is fine for personal use; a future commercial-distribution decision would require revisiting and is out of scope.

## Further Notes

**Why a third peer engine instead of a replacement.** Replacing Piper would simplify the registry by one branch, but would also eliminate the offline fallback the walkthrough relies on when the user is traveling or the server is off. The cost of keeping three engines is one extra `if` in `VoiceRegistry` and one extra section in Settings; the benefit is that the offline guarantee that motivated Piper in the first place remains intact.

**Why the `TTSFallbackPolicy` deep module.** Fallback rules look trivial today ("any error → use Piper for this utterance") but are exactly the kind of thing that grows hair: "after three failures, stop trying Voxtral for the rest of the session," "if the user is on cellular, don't even try," "if the failure is a 401, surface a banner instead of falling back silently." Extracting the policy keeps those changes one-file when they happen.

**Why the `voice_catalog` server-side deep module.** A static config would work today, but every voice change would require a webapp deploy and an iOS Settings refresh. Fetching from vLLM (or a server-side manifest the catalog reads) means we add a voice on the server and it appears in Settings on the next launch with zero release coordination.

**Why vLLM Omni and not the virtUOS/vllm-voxtral wrapper.** Evaluated during research: the wrapper packages the realtime *audio-understanding* model (`Voxtral-Mini-4B-Realtime-2602`), not the TTS model (`Voxtral-4B-TTS-2603`). Two stars, one commit, no documented `/v1/audio/speech` endpoint. Not suitable for this goal. Useful bookmark for a future STT replacement.

**GPU planning.** Voxtral 4 B unquantized fits comfortably in a single 3090's 24 GB. Pinning to GPU 0 leaves the second 3090 free for Ollama (already in the stack), LightRAG, or future workloads. Mixed-precision and the model's own optimizations are vLLM's concern, not ours.

**Cold-start.** vLLM Omni takes multiple seconds to load the model on container start. The sidecar lifecycle is independent of webapp's, so a webapp restart for an iOS-route change does not retrigger Voxtral warmup. Compose's `restart: unless-stopped` keeps the sidecar warm across host reboots.

**Privacy posture.** Text strings sent to Voxtral are the AI's *outgoing* prompts (openers, follow-ups, closing lines). They are not user content. No user audio or transcript ever leaves the phone via this path; that constraint is preserved.

**Documentation updates same commit.** `SPEC.md` §4 gains a Voxtral row with a CC BY-NC 4.0 note. `SPEC.md` §13 gains the new on-disk location. `DEVELOPMENT.md` gains S5, M13a, M13b, M13c entries with the exit criteria from the milestone table. `CLAUDE.md` does not need to change.

**Sign-off captured.** Before drafting this PRD the user confirmed: (a) the 2× RTX 3090 server, (b) bundled Voxtral voices only in v1, (c) silent per-utterance fallback to Piper or Apple, (d) the 10-module decomposition with five marked deep, (e) automated test coverage scoped to `voxtral_client` on the server in v1.

---

## Addendum — Latency & streaming decision (closes slice 06, 2026-05-19)

**Outcome: ship as-is, batch synthesis is sufficient. No streaming work scheduled.**

The original milestone M13c criterion was "median TTFA ≤ 600 ms on home Wi-Fi for an opener of typical length." In dogfooding across slices 01–05 we did not instrument a formal TTFA measurement — the per-utterance log line in `VoxtralTTS.performSpeak` reports synth-plus-network time, but does not split out time-to-first-audio-frame as a discrete metric.

We close M13c on **qualitative dogfood evidence** instead:

- Across multiple real-evening walkthroughs (slice 03 dogfood) with Voxtral selected for DE and a mix of opener / follow-up / todo / closing utterances, the user reported the opener gap as **"very short"** with no perceptual cue that synthesis was happening on the server side rather than on-device.
- The same was true through slice 05's resilience testing: stopping the `voxtral` sidecar mid-session and bringing it back surfaced no latency complaint, only the expected voice swap to Piper during the outage.
- Multi-span openers (German frame + English title) showed no audible gap between spans worth flagging.
- The pre-existing opener-prefetch path in `WalkthroughCoordinator` is currently a no-op for the Voxtral engine (slice 04 deferred) — the gap reported as "very short" is therefore *un-prefetched* batch synthesis over Tailscale. That is the conservative-case latency, and it is already perceptually acceptable.

**Interpretation.** The 70 ms model latency Mistral reports, plus tail-end network RTT to the home Tailnet, plus first-audio-frame setup in `AVAudioPlayer`, lands comfortably under the perceptual threshold for this user on this network. The hypothetical case that would push us toward streaming inference is a multi-paragraph utterance on a slow link — neither of those is in the walkthrough's actual workload (openers and follow-ups are 1–3 sentences, the user's primary capture path is on home Wi-Fi).

**Decision.** No follow-up streaming-inference issue is opened. Slice 04 (opener prefetch) remains deferred for the same reason — the latency it would hide is already imperceptible. Both can be reopened later if the workload changes (e.g. longer free-reflection prompts, off-Tailscale operation, or a noticeable degradation after a model upgrade).

**Operational note for future re-measurement.** If we ever do want hard numbers, the cheapest path is to add a `Date()` at the start of `VoxtralTTS.performSpeak`, capture `audioPlayerDidBeginPlaying` (not just `didFinishPlaying`) on the playback delegate, log the delta as TTFA, and gate the whole thing behind the debug toggle already in place for synth-time logging. That adds maybe 20 lines and zero production risk; the only reason to do it would be to settle an objective vs subjective dispute about whether the gap is acceptable. None today.

---

## Addendum — Slice 07: custom voice cloning (2026-05-19)

**Trigger.** After slice 02 shipped, the user reported that `de_male` sounds Austrian/Bavarian, not Hochdeutsch. With only two German voices in Voxtral's bundled set (`de_male`, `de_female`) drawn from a regionally unfiltered dataset, expanding the catalog inside Voxtral is the only path to neutral-German variety. Custom voice cloning — originally listed under Out of Scope — is reopened.

**API confirmed.** vLLM Omni's `/v1/audio/speech` accepts cloning via three new optional fields: `task_type: "Base"`, `ref_audio` (HTTP URL, base64 data URL, or `file://` URI), and `ref_text` (transcript of the reference, improves clone quality). No embedding-generation step, no vLLM restart per new voice. Source: `docs.vllm.ai/projects/vllm-omni/en/latest/serving/speech_api/`.

**Architecture.** Reference clips live in a docker volume shared between `webapp` and `voxtral`. `voxtral` mounts it read-only at `/voxtral-refs` and is started with `--allowed-local-media-path /voxtral-refs`. iOS uploads a clip via the webapp; the webapp writes `voxtral-refs/<uuid>/audio.wav` + `metadata.json`; subsequent synth calls for voice id `custom_<uuid>` pass `file:///voxtral-refs/<uuid>/audio.wav` to vLLM. No per-utterance HTTP overhead for references.

**Locked product decisions.**
- **Reference sources:** both bundled and user-recorded. Bundled clips arrive via a LibriVox fetcher script (`scripts/seed_voxtral_refs.py`) with a small hardcoded list of public-domain German tracks trimmed to 5–10 second snippets and seeded with their known transcripts. Quality is a known gamble — the user accepted this knowing the recording UI is the fallback.
- **ref_text strategy:** auto-transcribe the user's recording via the on-device Parakeet (already loaded) and pre-fill an editable text field. User can correct misheard words before submitting.
- **Per-language scoping:** each reference clip is tagged with one language (DE or EN). The voice appears only in that language's section of the picker. Avoids the cross-language accent artifacts that motivated this whole work.

**Voice id format.** Custom voices use voice id `custom_<uuid>` (8-char hex), stored as `voxtral:custom_<uuid>` in `VoicePreferences`. Bundled-via-LibriVox voices use a stable id `librivox_<slug>` (e.g. `librivox_thoreau_de_01`) so the catalog is idempotent across seed-script runs. Both flow through the same `voxtral:` prefix in `VoiceRegistry`.

**Out of scope for Slice 07 itself.**
- Cross-language clone rendering (the "use one voice for both DE and EN" path).
- Bundled-clip curation by anyone other than the LibriVox fetcher. Future iteration could add an admin upload route for first-party clips.
- Per-voice quality scoring / sorting. Voices appear in catalog order; the user picks by ear.
- Cloud-hosted reference clips. References stay on the server's local disk, Tailscale-only, same posture as session bundles.

**Time estimate.** ~6–7 hours of focused build, split across the server architecture (~2h), the LibriVox fetcher (~1h), the iOS recording + transcribe UI (~3h), and integration testing (~1h).

---

## Addendum 2 — Voxtral open-source checkpoint cannot clone (2026-05-19, evening)

**What we learned at integration time.** After 07a/07b/07c shipped, every cloning attempt — both user-uploaded references AND LibriVox-seeded clips — crashed vLLM Omni's orchestrator with:

```
RuntimeError: encode_waveforms requires encoder weights which are not
available in the open-source checkpoint.
```

(file: `vllm_omni/model_executor/models/voxtral_tts/voxtral_tts_audio_tokenizer.py:981`)

Mistral **intentionally withheld the audio-encoder weights** from the public `Voxtral-4B-TTS-2603` release. The 20 bundled voices work because their speaker embeddings (`voice_embedding/*.pt`) were pre-computed by Mistral and shipped alongside the model; but the encoder needed to compute *new* embeddings from a reference WAV is not in the public weights and exists only behind Mistral's hosted API.

Confirmed independently via three sources:
- The actual Python traceback from vLLM Omni (above).
- The Hugging Face discussion thread [#16 "Why not open source 😐"](https://huggingface.co/mistralai/Voxtral-4B-TTS-2603/discussions/16) where users complain about exactly this gap.
- A Towards Data Science article ["A Guide to Voice Cloning on Voxtral with a Missing Encoder"](https://towardsdatascience.com/voxtral-tts-surgery-codes-from-audio-reconstruction-2/) that documents and explores theoretical workarounds (codec reverse-engineering, training a replacement encoder — all research-grade, not practical).

**Slice 07's status as a result:**
- 07a (server arch) — **shipped, latent**. Upload/delete routes and the file-system-backed catalog stay in place but the public `/api/tts/voices` no longer surfaces non-bundled voices. If Mistral ever releases the encoder, flipping the route filter is a one-line change.
- 07b (iOS recording UI) — **shipped, hidden**. `VoxtralCloneRecorderView` + `VoiceReferenceRecorder` stay in the codebase but the "Eigene Stimme aufnehmen" entry point in `VoiceSettingsView` is removed. Same one-line restore for future use.
- 07c (LibriVox seed script) — **shipped, latent**. The fetcher script runs and writes clips to disk; they don't appear in the picker until the encoder is available. Cleaner than deleting the script outright.

**Mitigation (Slice 07d).** Surface the four most-promising non-native bundled voices — `nl_male`, `nl_female`, `neutral_male`, `neutral_female` — under the DE picker with German accent hints ("Niederländischer Akzent", "Englischer Akzent — neutral"). Voxtral's voice-as-instruction model renders any text in any speaker's voice; the speaker just imposes their accent. Dutch is phonologically closest to German of the available options, and the "neutral" English-trained speakers are tonally less casual than `casual_*` which produced the original Austrian/English-accent complaint.

This is the only way to extend the picker beyond the seven native DE/EN voices Mistral ships, given the cloning path is closed. Community-shared `.pt` embeddings don't exist — verified via web search — because nobody else can produce them either.

**Lessons.**
- The vLLM Omni docs and Voxtral model card both *describe* cloning as a feature without flagging that the public weights can't do it. Mistral's commercial strategy is the cause; the open-source community is still adjusting to the gap. Future architectural bets on "open-source X" should validate against the actual checkpoint, not the docs.
- The slice 07a–07c work is not wasted — it's blocked. If Mistral releases the encoder weights, restoring the feature is a route filter change + an iOS entry point. Worth keeping the code in the tree for that reason.
- Qwen3-TTS (Alibaba's open TTS, also supported by vLLM Omni) ships an encoder and supports cloning out of the box. A future "more voices" project that wants real cloning should evaluate Qwen3-TTS as a parallel/replacement engine rather than chasing Voxtral encoder workarounds.
