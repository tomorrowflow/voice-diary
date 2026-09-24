# 03 · Voxtral in the live walkthrough

Labels: needs-triage, type/feature, area/tts, area/ios, area/walkthrough
Type: AFK

## Parent

[Voxtral TTS Integration PRD](../../prd/voxtral-tts-integration.md)

## What to build

Wire the user's chosen Voxtral voices into the real evening walkthrough so that every utterance kind — opener, follow-up, todo confirmation, closing prompt — speaks through Voxtral when selected, with no regression in walkthrough behavior. Most of this slice is verification and small fixes rather than new infrastructure, because `WalkthroughCoordinator` already resolves engines through `VoiceRegistry` at call time. The point is to prove that nothing in the state machine or the multi-language script dispatch path leaks past the `VoiceRegistry` seam.

Free reflection mode and the wake-word enrichment "einen Moment" cue are in scope to verify (they share the same engine selection path) but should not require code changes. This slice also lands the DEVELOPMENT.md milestone entries for S5 / M13 since the milestone is now user-observable.

## Acceptance criteria

- [ ] A real evening walkthrough with one calendar event, Voxtral selected for DE, runs end-to-end and produces Voxtral voice on: the session opener, the per-event opener, the AI follow-up question, each todo confirmation prompt at CLOSING, and the closing free-reflection prompt.
- [ ] The same walkthrough with Voxtral selected for EN handles an English event opener correctly when a calendar event title is in English (verifies the multi-span DE-frame + EN-title script dispatch path).
- [ ] Drive-by capture mode is unaffected: no TTS calls are made, no `voxtral` server traffic is generated. Verified manually on the iPhone with `docker compose logs voxtral`.
- [ ] The wake-word enrichment "einen Moment, ich schaue nach…" cue speaks in the user's chosen Voxtral voice when one is selected.
- [ ] Free reflection mode at end of session uses the chosen Voxtral voice (no code change expected; verification only).
- [ ] Switching the German voice from a Piper voice to a Voxtral voice and back across two consecutive walkthroughs produces no state corruption; the second walkthrough uses the newly chosen voice.
- [ ] `DEVELOPMENT.md` gains entries for S5 (server route) and M13a / M13b (iOS engine + production polish) with exit criteria copied from the PRD's milestone table.
- [ ] No new design-system violations introduced.

## Blocked by

- [02 · Voice catalog + per-language voice picker](./02-voice-catalog-picker.md)
