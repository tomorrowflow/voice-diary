# 05 · Fallback policy + reachability surfacing

Labels: needs-triage, type/reliability, area/tts, area/server, area/ios, area/settings
Type: AFK

## Parent

[Voxtral TTS Integration PRD](../../prd/voxtral-tts-integration.md)

## What to build

Make Voxtral failures invisible to the walkthrough flow and visible to the user out of session. On iOS, extract the per-utterance fallback decision into the deep `TTSFallbackPolicy` module so that any error from `VoxtralTTSClient` resolves to either "use the user's chosen Piper voice for this utterance" or "use the user's chosen Apple voice" without interrupting the walkthrough state machine. On the server, extend `/health` with a `voxtral` reachability field. In Settings and at the end of onboarding, surface that reachability so the user knows up front whether the Voxtral voice they picked will actually work tonight.

This slice depends only on slice 01 (the engine being callable), so it can run in parallel with slices 02–04.

## Acceptance criteria

- [ ] `TTSFallbackPolicy` is a pure decision module with a single public method along the lines of `decide(error, language, preferences) -> FallbackDecision`, where the return type enumerates `usePiper(stem) / useApple(identifier) / giveUp`. No IO, no async, no dependencies on `TTSEngine`.
- [ ] `VoxtralTTS.speak()` and `.prefetch()` invoke the policy on every error from `VoxtralTTSClient` and re-dispatch the same utterance through the chosen fallback engine, transparently to the caller.
- [ ] A walkthrough started with Voxtral selected for DE, where the server is forcibly made unreachable mid-session (Tailscale down, or `voxtral` container stopped), continues to completion: the next utterance speaks in the user's chosen Piper voice, no crash, no stall, no visible error to the user inside the walkthrough.
- [ ] Each fallback event is logged locally with the error class and the chosen fallback engine, so the user can find it later without real-time babysitting.
- [ ] `/health` returns a `voxtral` field with one of `ok` / `degraded` / `down`, populated by a tight-timeout reachability probe through `voxtral_client`.
- [ ] `VoiceSettingsView` shows a reachability indicator next to the "Voxtral (Server)" section header, refreshed on view appear, that reflects the current `/health` status.
- [ ] Onboarding's success screen mentions Voxtral availability when a server URL and bearer token are configured, including the case where the server is reachable but Voxtral is `down`.
- [ ] Pre-flight check before BRIEFING: if the user's selected German or English voice is a Voxtral voice **and** `/health` reports `voxtral: down` at session start, the walkthrough surfaces a non-blocking notice ("Voxtral nicht erreichbar — fällt auf Piper zurück") so the voice shift across the session is not a surprise.
- [ ] No automated tests in this slice (per PRD test-scope decision); the policy is verified by the manual mid-walkthrough disconnect scenario above.

## Blocked by

- [01 · Hello, Voxtral — first end-to-end utterance](./01-hello-voxtral.md)
