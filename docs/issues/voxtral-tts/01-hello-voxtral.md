# 01 · Hello, Voxtral — first end-to-end utterance

Labels: needs-triage, type/feature, area/tts, area/server, area/ios
Type: AFK

## Parent

[Voxtral TTS Integration PRD](../../prd/voxtral-tts-integration.md)

## What to build

The thinnest possible end-to-end path that proves Voxtral synthesis works on this hardware and on this phone. Bring up the `voxtral` sidecar on the server box, expose a single narrow proxy route, and add the minimum iOS engine plus a debug button so that one tap inside the app produces audible German speech through the device speaker.

No voice picker, no fallback, no prefetch, no walkthrough integration in this slice. One hardcoded voice, one hardcoded language, one debug entrypoint. The point of this slice is to de-risk the GPU and vLLM Omni inference path before anything depending on it gets written, and to lock in the deep `voxtral_client` server module along with its full automated test suite (the PRD's only in-scope automated coverage).

## Acceptance criteria

- [ ] `docker compose up -d voxtral webapp` brings both services up; `voxtral` logs show `mistralai/Voxtral-4B-TTS-2603` loaded on GPU 0 with no errors.
- [ ] The `voxtral` service is pinned to GPU 0 via `device_ids: ["0"]` and uses a named volume for the HuggingFace model cache; it is **not** bound to a host port (only reachable on the compose-internal network).
- [ ] `POST /api/tts/synthesize` accepts `{ text, language: "DE", voice, response_format: "wav" }`, requires bearer auth (same `IOS_BEARER_TOKEN` as the other iOS-only routes), and streams back a `audio/wav` body.
- [ ] An on-device debug button in `DebugSettingsView` invokes `VoxtralTTS.speak("Hallo, ich bin die neue Stimme.", language: "DE")` and produces audible German speech through the iPhone speaker.
- [ ] The `voxtral_client` server module is implemented as a pure async HTTP client with injectable httpx transport.
- [ ] The `voxtral_client` pytest suite passes inside the webapp container and covers: happy path returns bytes; unknown voice → `TTSUnknownVoiceError`; connection refused → `TTSUnavailableError`; slow response past timeout → `TTSTimeoutError`; one 5xx then 200 → returns bytes (retry succeeds); three 5xx → `TTSEngineError` (retry exhausted).
- [ ] `SPEC.md` §4 contains a Voxtral row with a one-line CC BY-NC 4.0 note.
- [ ] `SPEC.md` §13 lists `server/data/voxtral-models/` as a new on-disk location and confirms `.gitignore` coverage.
- [ ] `.env.example` documents `VOXTRAL_BASE_URL`, `VOXTRAL_MODEL`, `VOXTRAL_TIMEOUT_SECONDS` with sane defaults.
- [ ] No design-system rule violations: any new UI uses `Theme.*` and existing button styles, not hard-coded colour, spacing, or radius.
- [ ] No public exposure: a `curl` from outside Tailscale to the webapp's TTS route is unreachable; from inside Tailscale with bearer it returns a WAV.

## Blocked by

None — can start immediately.
