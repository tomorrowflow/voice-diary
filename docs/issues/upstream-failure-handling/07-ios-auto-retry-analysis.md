# 07 · iOS: retry pending-analysis sessions once per foreground

Track: ios
Type: AFK

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md)

## What to build

Add a pure retry-analysis policy, in the style of `TTSFallbackPolicy`, that decides whether to call `POST /api/sessions/{id}/retry-analysis` from a session's status (segments `pending_analysis` with an `analysis_pending` error) and the latest health (Ollama and LightRAG both `ok`). Add `ServerClient.retryAnalysis(sessionID:)`. Trigger it once per foreground, from the `scenePhase == .active` hook that already kicks the uploader, over locally known sessions uploaded in the last 14 days. A `409 session_busy` or `session_not_retryable` is skipped silently; segments with `failed` status are never retried this way. There is no retry button; the existing "Processing" pill in Verlauf reflects progress.

Update SPEC §10.6.1 to say the app drives the retry.

## Acceptance criteria

- [ ] Policy table tests: triggers only when a segment is `pending_analysis` and Ollama and LightRAG are `ok`; does not trigger on degraded LightRAG or Ollama, on `failed`-only sessions, or on `processed` sessions.
- [ ] `session_busy` and `session_not_retryable` responses are skipped without an error surface.
- [ ] At most one attempt per session per foreground transition.
- [ ] Manual scenario 2 in the PRD passes: after Ollama returns and the app is foregrounded, the session becomes processed without user action.
- [ ] SPEC §10.6.1 updated; `ios` build and tests pass.

## Blocked by

- [01 · Failure contract: helper, Whisper preflight, segment codes](./01-failure-contract-whisper-sessions.md)
- [04 · iOS: parse the contract, failure copy, spoken enrichment lines](./04-ios-parse-contract-and-copy.md)
