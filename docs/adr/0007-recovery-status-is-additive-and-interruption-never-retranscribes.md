# Recovery shows in the session status as an additive `transcribing` state

**Status:** accepted (2026-10-24)

Builds on ADR 0002 (additive contract) and ADR 0005. It fixes how a running recovery is observed
and what a restart does to one.

A recovery attempt must be visible when the user returns to the screen, and distinguishable from a
final `failed` and from `pending_analysis` (a transcript exists, analysis is incomplete). The status
has only `processed`, `failed` and `pending_analysis` today, and a lost response must not be read
as a failure.

Decision:

- **A new segment status `transcribing`**: set when the server accepts a request, left only by the
  attempt's outcome. The route answers `202` with the session status; the attempt runs in the
  background. A segment is never `pending_analysis` without a transcript while it is recovering, so
  the existing crash-resume of untranscribed segments cannot pick it up.
- **The session `state` is `processing` while any segment is `transcribing`.** Other states are
  derived as before.
- **`recoverable` on `failed` segments**: an optional boolean, `true` while the manifest entry and
  the retained audio exist, `false` otherwise. Absent on other segments and on older servers; the
  app shows the action only for `true`.
- **Outcomes.** Transcript saved with its entities: `pending_analysis` with its `transcript_id`, then
  `processed` after the day narrative. Attempt failed: `failed` again, with the new `error`, `code`
  and `upstream` replacing the old; audio untouched. The transcript row and its entities are saved
  together or the next attempt reuses or replaces the row, so no orphan or duplicate transcript
  remains (`transcripts` is unique per file name and date).
- **Restart.** At startup, before the sweep, any `transcribing` segment is reconciled without
  calling Whisper: with a saved transcript it becomes `pending_analysis` and the sweep analyses it;
  without one it becomes `failed` with the code `recovery_interrupted` (no upstream, `retryable`
  true) and waits for another tap.
- **Request errors**, all before any change: `404 session_not_found` / `segment_not_found`; `409
  segment_not_failed` (processed, `pending_analysis`, or already `transcribing`; a duplicate tap does
  nothing); `409 segment_audio_missing`; `503 whisper_unavailable` (the shared failure shape); `409
  session_busy` when another run holds the session (ingest, analysis retry, sweep, or another
  segment's recovery). One operation runs per session; the other segment waits for a new tap.

## Considered options

- **Keep `failed` and add a `recovering` flag** — rejected: every client would have to know a
  `failed` can be non-final, and "failed" would no longer mean one thing.
- **A synchronous request like `retry-analysis`** — rejected: the outcome of a request that outlives
  the client would be unknowable, and the in-flight state could not be shown after leaving the screen.
- **Resume interrupted recoveries on restart** — rejected by ADR 0005: only a tap starts Whisper.

## Consequences

- An older app build shows `transcribing` through its fallback "Unknown" pill and no action; the
  server ships first.
- `SessionStatus.state` finally has a reader: `processing` while a recovery runs.
