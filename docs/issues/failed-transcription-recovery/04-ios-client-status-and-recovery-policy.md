# 04 · iOS: client, status fields and recovery policy

Track: ios
Type: AFK

## Parent

[Failed-Transcription Recovery PRD](../../prd/failed-transcription-recovery.md), [ADR 0005](../../adr/0005-failed-transcription-recovery-is-user-triggered.md), [ADR 0007](../../adr/0007-recovery-status-is-additive-and-interruption-never-retranscribes.md)

## What to build

Everything the app needs to decide and run a recovery, without any screen yet (ticket 05 adds it).

- **Client.** `ServerClient` gets a call for the recovery route, decoding the `202` session status and the request errors on the shared failure shape (`segment_not_failed`, `segment_audio_missing`, `session_busy`, `whisper_unavailable`). The status decode learns the segment status `transcribing` and the optional `recoverable` flag; both are optional additions, an unrecognised status still maps to "Unknown", and a status without `recoverable` (older server) means no action.
- **`TranscriptionRecoveryPolicy`** (pure, in the style of `RetryAnalysisPolicy`): from a segment's server status, `recoverable`, the last-known Whisper health, whether this screen has an attempt in flight, and whether a sibling segment of the session is `transcribing`, it returns the action state: hidden, disabled with a reason (Whisper not ok or unknown, a sibling running), enabled, or in flight. Unknown or unreachable health counts as not ok. Health coming back changes the state to enabled and never starts an attempt.
- **Recovery runner** (closure-based dependencies, in the style of `AnalysisRetrier`): starts one attempt per call; ignores a call while one is in flight; treats a timeout or lost connection as an unknown outcome and reads the status before any further attempt, never resubmitting on its own; refreshes the status on an injected interval while the screen is visible until the segment leaves `transcribing`, stops when the screen is left, and reconciles on return. A status read is never a retry. A `segment_audio_missing` answer makes the action hidden for that segment; `session_busy` and `whisper_unavailable` leave the segment as it was with a reason the screen can show.

No change to the upload queue, `AnalysisRetrier` or capture. No background `URLSession`: recovery is foreground-only.

## Acceptance criteria

- [ ] Policy table tests: enabled only for a `failed` segment with `recoverable: true`, Whisper `ok`, nothing in flight and no sibling `transcribing`; disabled with the right reason for Whisper degraded, down and unknown, and for a sibling running; in flight while an attempt runs; hidden for `recoverable: false`, for an absent `recoverable` (older server), and for `processed`, `pending_analysis` and `transcribing` segments.
- [ ] Runner tests with closure fakes: one attempt per tap, a double tap while in flight does nothing, refreshing until the segment leaves `transcribing`, stopping when the screen is left and reconciling on return.
- [ ] Runner tests for an ambiguous outcome: after a timeout or lost connection the runner reads the status, follows `transcribing`, `pending_analysis` or `processed`, and for a segment that is still `failed` offers the action again without having resubmitted.
- [ ] `409 segment_audio_missing` hides the action; `session_busy` and `whisper_unavailable` do not change the segment's state in the app.
- [ ] Client tests (stubbed transport): the `202` and each error decode, the status with and without `transcribing` and `recoverable`, and the unknown-status fallback.
- [ ] No recovery request is ever made without an explicit call from the screen: nothing in the foreground hook, the health refresh or the analysis retrier reaches the runner.
- [ ] The `ios` build and tests pass, lint clean.

## Blocked by

- [02 · Server: recover a failed segment](./02-server-recover-a-failed-segment.md)
