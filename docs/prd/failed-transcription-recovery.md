# PRD: Failed-Transcription Recovery

Status: Draft (2026-10-24). Specified through a grill session after the PROTO-1 decision (DOC-9); implementation tracked as slice issues in `docs/issues/failed-transcription-recovery/`, not as DEVELOPMENT.md milestones. Specification only: this document approves no production behaviour until its tickets are built.
Owner: Florian
Authored: 2026-10-24
Related: `SPEC.md` §10.5, §10.6.1, §15.1, §15.2, `docs/prd/upstream-failure-handling.md` (Further Notes; DOC-9 records the decision on branch `factory/e4b3b042-2d69-4a93-9409-f8cc2e1ec475`, which was not merged to `main` when this was written), `docs/prototypes/PROTO-1/failed-transcription-recovery.html` (PR #160, option B), `docs/adr/0002-additive-upstream-failure-contract.md`, `docs/adr/0003-upstream-outages-never-block-capture.md`, `docs/adr/0005-failed-transcription-recovery-is-user-triggered.md`, `docs/adr/0006-day-narrative-spans-all-sessions-of-a-date.md`, `docs/adr/0007-recovery-status-is-additive-and-interruption-never-retranscribes.md`, `docs/issues/failed-transcription-recovery/`

## Problem Statement

A walkthrough upload passes the server's Whisper preflight, the phone drops its queue entry on the 2xx, and then Whisper dies, times out or chokes on one segment. The server records that segment `failed` with no transcript and carries on with the rest. The audio is safe on the server, the other segments are transcribed and analysed, and the day's diary entry is written without the missing part.

Nothing can fix that today. The phone cannot re-upload (the server answers `409 session_exists`, which the app treats as success), the startup sweep and `retry-analysis` look only at `pending_analysis` segments, and the automatic analysis retry deliberately never touches a `failed` one. The user sees a red "Fehlgeschlagen" pill in Verlauf with an explanation of why it failed (upstream failure handling) and no way to act on it. The glossary and ADR 0002 even say such a segment "needs a re-upload", which is not possible.

Recovery also cannot be a bolt-on, for a second reason. The server builds one narrative per day and ingests it under one LightRAG id per date. A recovered segment must change that narrative, and today `retry-analysis` would narrate only the pending segments, and two sessions of one date already overwrite each other. Recovering a segment of an older session must not overwrite what a newer session added the same day.

## Solution

An explicit, per-segment **Erneut transkribieren** action in Verlauf, backed by one server route that transcribes the failed segment again from its **retained audio**, and a whole-day narrative so the recovered text lands in the diary without erasing anything else.

**User.** Open a session in Verlauf. A failed segment says "Transkription fehlgeschlagen. Die Aufnahme ist auf dem Server gesichert." and offers a full-width primary button "Erneut transkribieren". The button is enabled only while the server's Whisper is known to be healthy; otherwise it is disabled with "Whisper ist gerade nicht erreichbar." After a tap the pill reads "Wird transkribiert…", the body "Die Aufnahme wird erneut transkribiert.", and repeat taps are ignored. The user can leave the screen, background the app or lose the connection: the server finishes anyway, and returning to the screen shows the outcome. A new recording or upload is never blocked. Nothing ever retries on its own: not on foreground, not when Whisper returns, not after a restart.

**Server.** `POST` on a failed segment answers `202` and runs the attempt in the background. The segment is `transcribing`, then `pending_analysis` (transcript saved) and `processed` (after the day narrative), or `failed` again with the new reason. Only one operation runs per session. The narrative stage runs one writer at a time per date and always assembles every transcribed segment of the date, across sessions, after it has taken the date.

## User Stories

1. As a Voice Diary user, I want a failed segment in Verlauf to say its recording is safe on the server, so that I do not re-record or worry.
2. As a Voice Diary user, I want an "Erneut transkribieren" button on a failed segment, so that I can recover what I said without help from the operator.
3. As a Voice Diary user, I want the button to start only when I tap it, so that nothing about a finished entry changes without my intent.
4. As a Voice Diary user, I want no retry to start by itself when I open the app, when Whisper comes back or after a server restart, so that a transcription that may still be broken is not hammered.
5. As a Voice Diary user, I want the button disabled with "Whisper ist gerade nicht erreichbar." while Whisper is down or its health is unknown, so that I do not tap into a certain failure.
6. As a Voice Diary user, I want Whisper coming back to only enable the button, so that I stay in charge of when the attempt runs.
7. As a Voice Diary user, I want to see "Wird transkribiert…" while an attempt runs, so that I know it was accepted.
8. As a Voice Diary user, I want repeat taps and the other failed segments of that session to do nothing while an attempt runs, so that I cannot start two attempts at once.
9. As a Voice Diary user, I want to leave the screen, switch apps or lose the connection while it runs, so that a long attempt does not hold me hostage.
10. As a Voice Diary user, I want the screen to show the real outcome when I return, so that I do not have to guess whether it worked.
11. As a Voice Diary user, I want a lost response to be treated as "unknown", not as "failed", so that I am not told it failed when it actually succeeded.
12. As a Voice Diary user, I want the app to read the server status before offering another attempt after a lost response, so that I never double-transcribe by accident.
13. As a Voice Diary user, I want the screen to refresh itself while it is visible and an attempt runs, so that the pill changes without pulling to refresh.
14. As a Voice Diary user, I want that refresh to stop when I leave the screen, so that the app does not poll in the background.
15. As a Voice Diary user, I want the transcripts that already worked to stay exactly as they were, so that recovery cannot damage my entry.
16. As a Voice Diary user, I want the recovered text to appear in that day's diary narrative, so that the entry is complete again.
17. As a Voice Diary user who recorded two sessions on one day, I want recovering the older one not to overwrite what the later one added, so that I lose no diary content.
18. As a Voice Diary user, I want an analysis outage during recovery not to throw away the recovered transcript, so that the text is kept and analysed later by the existing automatic retry.
19. As a Voice Diary user, I want a failed attempt to leave the segment failed with the latest reason, so that I can judge whether to try again.
20. As a Voice Diary user, I want a failed attempt never to delete the recording, so that I can try as often as I like.
21. As a Voice Diary user, I want to be told when the recording is no longer on the server, and the button to disappear, so that I do not keep tapping something that cannot work.
22. As a Voice Diary user, I want recording a voice note or starting a walkthrough to work normally while a recovery runs, so that recovery never costs me a moment of capture.
23. As a Voice Diary user, I want the same behaviour in English as in German, so that the copy matches my app language.
24. As a Voice Diary user, I want an empty-transcript or conversion failure to be retryable too, so that I decide, not the app, whether a segment is hopeless.
25. As a Voice Diary user on an older server, I want no recovery button at all rather than one that fails, so that an update gap does not show a broken control.
26. As a Voice Diary maintainer, I want transcription recovery distinct from pending analysis in the status, so that "transcript safe, analysis pending" and "no transcript" never blur.
27. As a Voice Diary maintainer, I want the automatic analysis retry to keep ignoring `failed` segments, so that UFH-07 holds.
28. As a Voice Diary maintainer, I want `retry-analysis`, the startup sweep, the original ingest and recovery to build the same whole-day input, so that no writer can regress the diary to a fragment.
29. As a Voice Diary maintainer, I want narrative writes for one date to run one at a time and to read their input only once they hold the date, so that a stale writer cannot publish over newer content.
30. As a Voice Diary maintainer, I want an attempt that fails midway to leave no orphan or duplicate transcript, so that retries are idempotent.
31. As a Voice Diary maintainer, I want a restart during an attempt to keep a saved transcript and never re-transcribe on its own, so that the "only a tap" rule survives crashes.
32. As a Voice Diary maintainer, I want a failed publication to LightRAG to keep the new day narrative saved and retryable, so that the previous diary content is not silently lost or duplicated.
33. As a Voice Diary maintainer, I want the new errors on the shared failure shape, so that the app handles them with the code it already parses.
34. As a Voice Diary maintainer, I want the button logic in a pure, named policy with fakes around the client, so that changing a rule is a one-file change with a unit test.
35. As a Voice Diary maintainer, I want SPEC §10.5, §10.6.1, §15.1 and the server README updated in the same change as the code, so that the contract is documented where the next reader looks.

## Implementation Decisions

### Architecture

- **User-triggered, per segment, from retained audio** (ADR 0005). No automatic recovery of any kind, no retry-all, no cooldown, no attempt cap, no stored attempt counter. The phone's local copy of the audio and a phone-side re-upload are not part of recovery.
- **Failed transcription is not pending analysis.** A `failed` segment has no transcript and is recovered only by request. A `pending_analysis` segment has its transcript and uses the existing automatic analysis retry. Recovery crosses from one to the other: a saved transcript makes the segment `pending_analysis`.
- **The day narrative spans all sessions of a date** (ADR 0006), and applies to every writer: original ingest, analysis retry, startup sweep, recovery and the review UI's manual ingest.
- **Recovery is observable through an additive segment status `transcribing`** and an additive `recoverable` flag (ADR 0007). The server ships first; an older app shows `transcribing` as "Unknown" and never shows the action.
- Capture and upload stay available (ADR 0003): recovery holds only its own session and, briefly, the date's narrative stage.

### Segment state model

| From | Event | To |
|---|---|---|
| `failed` (`recoverable: true`) | accepted request | `transcribing` (session `processing`) |
| `transcribing` | transcript and entities saved | `pending_analysis`, with `transcript_id` |
| `transcribing` | Whisper, conversion or any other failure | `failed`, new `error`, `code`, `upstream`; audio untouched |
| `transcribing` | server restart, transcript saved | `pending_analysis`, picked up by the sweep |
| `transcribing` | server restart, no transcript | `failed`, code `recovery_interrupted`, waits for a tap |
| `pending_analysis` (this segment) | day narrative published | `processed` |
| `pending_analysis` | day narrative fails | stays `pending_analysis` with `analysis_pending: …`, existing automatic retry |

A segment is never `pending_analysis` without a transcript while it is recovering. `processed` and `pending_analysis` segments are never changed by a recovery request.

### Modules — server

- **Session ingest** (deep, one new entry point): a recovery operation that validates, claims the session, flips the segment to `transcribing`, and runs the attempt in the background. It reuses the per-segment transcription pipeline (Whisper, correction, entities, persistence), with these differences from the original ingest: it targets one named segment; it records the outcome as the segment's status; it reuses or replaces a transcript row an earlier attempt left behind, because transcripts are unique per file name and date; and it never touches other segments' results.
- **Day narrative stage** (prefactor): assembles the input for a date from every session whose manifest date is that date, in session start order then manifest order, each segment with its own session's header and todos, from the stored transcripts (corrected text where present, entities as stored). One writer per date at a time; the input is gathered after the date is taken. Original ingest, analysis retry and the sweep call it instead of narrating only their own segments. A session whose manifest is unreadable cannot supply headers and is skipped with a logged line.
- **Day publication**: the new narrative is saved before it is published; the existing "re-ingest the saved narrative" shortcut is keyed by date, not by a session's segment set. The treatment of a second insert under the same LightRAG id is unverified (see Further Notes) and is the first ticket's deliverable.
- **Startup reconciliation**: before the sweep, every `transcribing` segment is settled as in the state table, without calling Whisper.
- **Status**: `SegmentResult` gains the status `transcribing`; failed segments carry `recoverable`; the session `state` is `processing` while any segment is `transcribing`. Everything else about the status is unchanged.
- The legacy review-UI manual ingest keeps its behaviour but takes the same date coordination.

### Modules — iOS

- **`ServerClient`**: a call for the recovery route, decoding `202`, the new request errors and the new status fields (`transcribing`, `recoverable`) as optional additions; an unrecognised status still maps to "Unknown".
- **`TranscriptionRecoveryPolicy`** (new, pure, in the style of `RetryAnalysisPolicy`): from a segment's server status, `recoverable`, the last-known Whisper health, whether this view has an attempt in flight, and whether a sibling segment of the session is `transcribing`, it returns the action state: hidden, disabled with a reason, enabled, or in flight.
- **Recovery runner** (closure-based dependencies, in the style of `AnalysisRetrier`): starts the attempt, treats a timeout or lost connection as an unknown outcome, reads the status before any further attempt, and refreshes the status on an interval while the screen is visible until the segment leaves `transcribing`. It stops when the screen is left and reconciles on return. A status read is never a retry.
- **Verlauf detail**: the failed segment row shows the PROTO-1 body, the "Erneut transkribieren" primary button (full width, design-system button style), and the in-flight pill and body; the existing status fetch is repeated after an attempt instead of once per view. No session-list badge.
- **Whisper health**: the detail screen refreshes `/health` when it appears and reads the `whisper` entry; unknown or unreachable counts as not ok.
- **Copy** lives in the string catalog, German and English. The wording fixed by the operator: button "Erneut transkribieren"; failure body "Transkription fehlgeschlagen. Die Aufnahme ist auf dem Server gesichert."; pill "Wird transkribiert…"; in-flight body "Die Aufnahme wird erneut transkribiert."; disabled reason "Whisper ist gerade nicht erreichbar." Proposed English: "Retry transcription"; "Transcription failed. The recording is safely stored on the server."; "Transcribing…"; "The recording is being transcribed again."; "Whisper isn't reachable right now." Proposed wording for the two new states: missing audio "Die Aufnahme ist nicht mehr auf dem Server." / "The recording is no longer on the server."; a sibling running "Eine andere Aufnahme dieser Sitzung wird gerade transkribiert." / "Another recording of this session is being transcribed."
- No change to the upload queue, `AnalysisRetrier`, or capture. Recovery is foreground-only: no background `URLSession` is added.

### API contract

`POST /api/sessions/{session_id}/segments/{segment_id}/retry-transcription` (bearer token, no body).

Checks run in this order and change nothing until all pass: unknown session or segment → `404` (`session_not_found`, `segment_not_found`); segment not `failed` (processed, `pending_analysis`, or already `transcribing`) → `409 segment_not_failed`; audio or manifest entry missing → `409 segment_audio_missing`; Whisper unreachable → `503 whisper_unavailable` in the shared failure shape (`code`, `upstream`, `retryable`, optional `Retry-After`); another run holds the session → `409 session_busy`. The session is then claimed, the checks that can change (segment state, audio) are repeated under the claim, and the segment is persisted as `transcribing`. Response `202` with the updated `SessionStatus`.

```json
{ "session_id": "2026-10-24T18:00:00+02:00", "state": "processing",
  "segments": [
    { "segment_id": "s01", "status": "processed", "transcript_id": 41 },
    { "segment_id": "s02", "status": "transcribing", "transcript_id": null } ] }
```

`GET /api/sessions/{id}/status` is the only way to see the outcome. A failed segment reports `recoverable: true|false`; `false` once the manifest entry or the audio is gone. After a failed attempt the segment's `error`, `code` and `upstream` hold the latest failure; `recovery_interrupted` is a new code with no upstream and `retryable: true`. A repeated request for a segment that is no longer `failed` has no processing side effect.

### Storage

- No schema change. The new status, `recoverable` (computed on read) and the new code live in the existing `session_ingests.segments` JSON; rows written before simply lack the keys.
- A recovered transcript is a normal transcript row, linked from the segment. The day narrative is saved as processed documents against the transcripts it covers, as today.

### Settings model

No new user settings.

### Documentation updated with the code

SPEC §10.5 (statuses, `recoverable`, `recovery_interrupted`, the route), §10.6.1 (the route, whole-day narrative, sweep and reconciliation), §13.1.2 and the retention note (audio is a recovery dependency), §15.1 (the failed-segment row and the new states); `server/README.md` failure-modes section. The glossary and ADRs 0005–0007 are written with this spec.

## Testing Decisions

A good test drives the behaviour through the public seam and asserts what a caller sees: the response, the status, the stored transcripts and narrative, the requests that reached the fakes. It does not assert call order or private helpers.

### Server (one seam)

The seam is the session ingest module, exercised through its route, with the existing fakes: the segment pipeline fake (with a per-segment failure map), the narrative stage fake, the in-memory session repository and an injected Whisper reachability check. Prior art: the session-ingest and session-route tests, including the upstream-failure ones. Cases:

- **Recovery**: success makes the transcript appear and the segment `processed`; failure leaves it `failed` with the new code and the audio untouched; an all-failed session becomes `done`; a repeated request has no side effect.
- **Eligibility and errors**: every error in the contract, with the check order, and that Whisper rejection, a missing segment and missing audio persist nothing.
- **Whole day**: a recovery in an older session leaves the newer same-day session's content in the narrative; processed and recovered segments are both in the input; original ingest, analysis retry and the sweep also build the whole day; a retry never narrates only the pending subset.
- **Coordination**: two writers for one date run one at a time, the later gathers its input after the earlier published; two sessions of different dates do not wait for each other; recording and upload stay available during a recovery; a second request for the same session is `session_busy`.
- **Interruption**: a restart with `transcribing` segments settles them as in the state table with no Whisper call; a failure after Whisper succeeded leaves no orphan or duplicate transcript and the next attempt succeeds.
- **Publication**: a failed LightRAG ingest leaves the saved day narrative unpublished and retryable and the segments `pending_analysis`; the sweep and `retry-analysis` finish it.
- **Isolation**: the ingest module still imports no HTTP types.

### iOS (two seams)

- **`TranscriptionRecoveryPolicy`**: table tests over status, `recoverable`, Whisper health (ok, degraded, down, unknown), in-flight and sibling-running; the older-server case (no `recoverable`) is hidden.
- **Recovery runner and client** with closure fakes (extends the style of the analysis-retrier tests) and a stubbed transport for the client: starting an attempt, double taps, polling until the segment leaves `transcribing`, stopping when the screen is left and reconciling on return, a lost response treated as unknown with a status read before any new attempt, a `409 segment_audio_missing` hiding the action, `session_busy` and `whisper_unavailable` handling, and the status decode with and without the new fields.

### Modules built without automated tests

No new SwiftUI view-test suite: the Verlauf row, pill, button and copy layout are verified by the manual scenarios.

### Manual scenarios that must pass

1. **Operator-run:** on a real device, a failed segment shows the PROTO-1 layout and the German and English copy (failed, in flight, disabled, missing audio, sibling running). Before merge of the Verlauf ticket.
2. **Operator-run:** with the live Whisper stopped mid-attempt, the segment returns to `failed` with the Whisper explanation, the audio stays, and starting Whisper only enables the button; a second tap then recovers the segment and the day's diary text includes it. Before merge of the Verlauf ticket.
3. **Operator-run:** start an attempt, leave the screen or background the app, return: the screen shows the real outcome and the session was not transcribed twice. Before merge of the Verlauf ticket.
4. **Operator-run:** record a voice note and start a walkthrough while an attempt runs; both work. Before merge of the Verlauf ticket.
5. **Operator-run:** restart the live server during an attempt: no automatic re-transcription follows; the segment is `pending_analysis` if its transcript was saved, otherwise `failed` with `recovery_interrupted`. At merge of the reconciliation ticket.
6. **Operator-run:** against the live LightRAG, re-post `diary:{date}` for a date that already has a document and record whether it replaces, rejects or duplicates it. Before merge of the first server ticket.
7. A new app against an older server shows no recovery action and no empty text, and an older app against the new server shows `transcribing` as "Unknown" with no action. Checked with the automated decode tests and, on a device, at merge.

## Out of Scope

- Automatic recovery of any kind, retry-all, cooldowns, attempt caps and attempt counters.
- Recovery from the phone's copy of the audio, and re-uploading a session.
- A user cancel for a running attempt.
- A session-list badge for sessions with failed segments.
- Background execution of the request on the phone (no background `URLSession`).
- Changing automatic `retry-analysis` eligibility, which still ignores `failed` segments.
- A retention or cleanup policy for session audio (none exists; it must keep audio of recoverable segments if ever added).
- Merging HTMX-review transcripts into the iOS day narrative, beyond the review UI's manual ingest taking the date coordination.
- Editing `docs/prd/upstream-failure-handling.md`; DOC-9 owns its own text.

## Further Notes

- **DOC-9 is not merged** to `main` as of this writing; this spec cites its ticket and branch. The decision it records (user-triggered recovery, preserved successful segments, retained audio, capture availability) is carried unchanged by ADR 0005.
- **Unverified: LightRAG replacement of `diary:{date}`.** The server client only posts to the text-insert endpoint and has a delete call used by the skeleton sync. Whether a second insert under the same id replaces, is ignored or duplicates is not known. The first server ticket must settle it (Operator-run scenario 6) and, if it is not a replace, publish by deleting then inserting, keeping the saved narrative retryable between the two steps.
- **Whole-day assembly is a behaviour change for original ingest**: a second session on a date now yields a narrative covering both, where the last writer used to win. Sessions with an unreadable manifest are skipped and logged.
- **Cost.** Every recovery, and every analysis retry, pays one narrative analysis over the whole day.
- **Other sessions' `pending_analysis` segments** stay pending after a recovery in a different session; their own retry rebuilds the same day.
- **A failed attempt after Whisper succeeded** (entity detection, storage) must leave the recovered row reusable, because `transcripts` is unique per file name and date: this is a technical acceptance requirement, not a product choice.
- **Polling interval** while the screen is visible is a few seconds (3 s proposed); the value is an injected constant, not a user setting.
- Marker convention: scenarios and acceptance checks that no factory node can run (a physical device, a live Whisper, LightRAG or server restart, the operator's hands) are marked `Operator-run:` here and in the ticket files.
