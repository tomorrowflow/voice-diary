# 02 · Server: recover a failed segment

Track: server
Type: AFK

## Parent

[Failed-Transcription Recovery PRD](../../prd/failed-transcription-recovery.md), [ADR 0005](../../adr/0005-failed-transcription-recovery-is-user-triggered.md), [ADR 0007](../../adr/0007-recovery-status-is-additive-and-interruption-never-retranscribes.md)

## What to build

The thinnest complete server path for a recovery: `POST /api/sessions/{session_id}/segments/{segment_id}/retry-transcription` (bearer token, no body) transcribes one `failed` segment again from its retained audio, and the user's day narrative then includes it.

The request checks run in this order and change nothing until all pass: unknown session or segment `404` (`session_not_found`, `segment_not_found`); a segment that is not `failed` (processed, `pending_analysis`, already `transcribing`) `409 segment_not_failed`; missing manifest entry or audio `409 segment_audio_missing`; Whisper unreachable `503 whisper_unavailable` in the shared failure shape; another run holding the session (ingest, analysis retry, sweep, another segment's recovery) `409 session_busy`. The session is then claimed, the checks that can change are repeated under the claim, and the segment is persisted as `transcribing`; the response is `202` with the updated session status. A repeated request for a segment that is no longer `failed` has no processing side effect.

The attempt runs in the background and continues whether or not the client stays connected. It reuses the per-segment transcription pipeline (Whisper, correction, entities, persistence) for that one segment, and never touches any other segment's result. When the transcript and its entities are saved, the segment is `pending_analysis` with its `transcript_id`, then the day narrative from ticket 01 runs and the segment becomes `processed`; a session whose segments were all `failed` becomes `done`. If the narrative fails, the segment stays `pending_analysis` with the usual `analysis_pending: …` error and the existing automatic retry finishes it. If transcription fails, the segment returns to `failed` with the new `error`, `code` and `upstream` replacing the old, and the audio is untouched. An earlier attempt may have left a transcript row (transcripts are unique per file name and date): the attempt reuses or replaces it, so no orphan or duplicate row is ever left, and a segment is never linked to a transcript without its entities.

Status gains the segment value `transcribing`, an optional `recoverable` flag on failed segments (`true` while the manifest entry and the audio exist, `false` otherwise, absent elsewhere and on older servers), and the session `state` is `processing` while any segment is `transcribing`. A segment is never `pending_analysis` without a transcript while it is recovering. Automatic analysis retry and the sweep still never transcribe a `failed` segment.

Update SPEC §10.5 (the new status, `recoverable`, the route and its errors), §10.6.1 (recovery next to analysis retry) and the `server/README.md` failure-modes section.

## Acceptance criteria

- [ ] Success: a `failed` segment becomes `transcribing` (response `202`), then `pending_analysis`, then `processed`; its transcript appears, the other segments' transcripts are unchanged, and the day narrative contains both the recovered and the previously processed segments.
- [ ] An all-failed session becomes `done` after one successful recovery; a session with other failed segments stays `partial`.
- [ ] Each request error returns its documented status and code in the documented order, and the Whisper, missing-segment and missing-audio cases persist nothing and start no work; a second request for the same segment, a processed or `pending_analysis` segment, or a second segment of a busy session has no processing side effect.
- [ ] A transcription failure returns the segment to `failed` with the latest `error`, `code` and `upstream`; the audio is intact; the next request can succeed.
- [ ] A failure after Whisper succeeded (entity detection or storage) leaves no orphan or duplicate transcript row, and the next attempt succeeds.
- [ ] A narrative or LightRAG failure leaves the recovered segment `pending_analysis` with its transcript, and the existing retry completes it; nothing in recovery makes the automatic analysis retry pick up a `failed` segment.
- [ ] Whisper recovery does not wait for or block a concurrent upload, and a disconnect of the requesting client does not stop or duplicate the attempt.
- [ ] The status shows `transcribing` and `processing` while the attempt runs; `recoverable` is `true` for a failed segment with audio and `false` once the audio or manifest entry is gone.
- [ ] Tests through the session-ingest seam and its route with the existing fakes and an injected Whisper reachability check (PRD Testing Decisions); the ingest module still imports no HTTP types.
- [ ] SPEC §10.5, §10.6.1 and `server/README.md` updated; server test suite passes.

## Blocked by

- [01 · Server: one day narrative across sessions](./01-server-day-narrative-across-sessions.md)
