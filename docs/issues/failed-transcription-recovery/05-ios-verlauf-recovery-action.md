# 05 · iOS: the Verlauf recovery action

Track: ios
Type: HITL

## Parent

[Failed-Transcription Recovery PRD](../../prd/failed-transcription-recovery.md), [ADR 0005](../../adr/0005-failed-transcription-recovery-is-user-triggered.md), PROTO-1 option B (`docs/prototypes/PROTO-1/failed-transcription-recovery.html`)

## What to build

The user-visible recovery. A failed segment in a Verlauf session shows "Transkription fehlgeschlagen. Die Aufnahme ist auf dem Server gesichert." and a full-width primary button "Erneut transkribieren" in the existing failed row, driven by the policy and runner from ticket 04.

- The button is enabled only while the last-known `/health` says Whisper is `ok`; the detail screen refreshes health when it appears. Otherwise it is disabled with "Whisper ist gerade nicht erreichbar."
- After a tap the pill reads "Wird transkribiert…" and the body "Die Aufnahme wird erneut transkribiert."; repeat taps and the other failed segments of that session do nothing, the latter with "Eine andere Aufnahme dieser Sitzung wird gerade transkribiert."
- While the screen is visible and a segment is `transcribing`, the status refreshes every few seconds (an injected constant, 3 s proposed) until the segment leaves it; leaving the screen stops the refresh and returning reconciles. The once-per-view status fetch becomes repeatable after an attempt.
- When the segment is finished the row shows the normal processed or "Wird verarbeitet" state; when the attempt failed again it shows the failed state with the latest reason.
- With the audio gone (`recoverable: false`, or `segment_audio_missing`) the row says "Die Aufnahme ist nicht mehr auf dem Server." and shows no action. An older server (no `recoverable`) shows no action at all.
- No session-list badge, no retry-all, nothing runs unless the user taps. Recording and walkthroughs are untouched while an attempt runs.
- English strings through the string catalog: "Retry transcription"; "Transcription failed. The recording is safely stored on the server."; "Transcribing…"; "The recording is being transcribed again."; "Whisper isn't reachable right now."; "The recording is no longer on the server."; "Another recording of this session is being transcribed." Styling uses the design-system button style and `Theme` tokens; the pill follows the existing Verlauf pill look.

Update SPEC §15.1 (the failed-segment row and the new states).

## Acceptance criteria

- [ ] The failed row, in-flight row, Whisper-disabled row, missing-audio row and sibling-running row show the documented German and English copy, and the button is the primary full-width style.
- [ ] The action is wired only to the policy and runner of ticket 04; no automatic path (appearing, foreground, health recovery) starts an attempt.
- [ ] The status refreshes while the screen is visible and an attempt runs, stops when the screen is left and reconciles on return; after a finished attempt the row reflects the new status.
- [ ] A new app against an older server shows no recovery action; an older app is unaffected (server ships first).
- [ ] No new SwiftUI view-test suite; the pure policy and runner keep their tests from ticket 04. The `ios` build and tests pass, lint clean.
- [ ] SPEC §15.1 updated.
- [ ] **Operator-run:** on a real device, check the PROTO-1 layout and the German and English copy for each state above (failed, in flight, Whisper disabled, missing audio, sibling running). Before merge.
- [ ] **Operator-run:** with the live Whisper stopped mid-attempt, the segment returns to failed with the Whisper explanation and the audio stays; starting Whisper only enables the button; a second tap recovers the segment and the day's diary text includes it. Before merge.
- [ ] **Operator-run:** start an attempt, leave the screen or background the app, return; the screen shows the real outcome and the segment was not transcribed twice. Before merge.
- [ ] **Operator-run:** record a voice note and start a walkthrough while an attempt runs; both work. Before merge.

## Blocked by

- [04 · iOS: client, status fields and recovery policy](./04-ios-client-status-and-recovery-policy.md)
