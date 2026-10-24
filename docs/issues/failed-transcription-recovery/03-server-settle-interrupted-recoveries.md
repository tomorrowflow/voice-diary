# 03 · Server: settle interrupted recoveries at startup

Track: server
Type: AFK

## Parent

[Failed-Transcription Recovery PRD](../../prd/failed-transcription-recovery.md), [ADR 0005](../../adr/0005-failed-transcription-recovery-is-user-triggered.md), [ADR 0007](../../adr/0007-recovery-status-is-additive-and-interruption-never-retranscribes.md)

## What to build

Make a server restart in the middle of a recovery safe, and never an automatic re-transcription. Before the startup sweep, every segment left `transcribing` is settled from what is stored, without calling Whisper: with a saved transcript and its entities it becomes `pending_analysis` with its `transcript_id`, so the sweep analyses it over the whole day; without one it becomes `failed` with the new code `recovery_interrupted` (no upstream, `retryable: true`) and waits for the user's next tap. The session `state` is re-derived afterwards, so a session no longer shows `processing`.

A recovering segment must not be mistaken for the crash-orphan case the sweep already resumes (a `pending_analysis` segment with no transcript): the reconciliation, not that machinery, owns interrupted recovery, and a segment is settled only once. A reconciliation that cannot settle one session is logged and does not stop the others or application start.

Update SPEC §10.6.1 (restart behaviour, the new code).

## Acceptance criteria

- [ ] After a simulated restart with a `transcribing` segment that has a saved transcript, the segment is `pending_analysis` and the sweep completes it; no Whisper request is made.
- [ ] After a simulated restart with a `transcribing` segment and no saved transcript, the segment is `failed` with `recovery_interrupted`, `retryable: true` and no upstream; the audio is untouched; no Whisper request is made, by the reconciliation or by the sweep.
- [ ] A session left `processing` only because of a recovery is re-derived to its real state; a session still genuinely `processing` for the original ingest is handled as before.
- [ ] The existing resume of untranscribed `pending_analysis` segments is unchanged and does not see recovery segments.
- [ ] One session's failure to settle is logged and does not stop the others.
- [ ] Tests through the session-ingest seam with the in-memory repository's restart helper and the existing fakes; the Whisper fake records zero calls (PRD Testing Decisions).
- [ ] SPEC §10.6.1 updated; server test suite passes.
- [ ] **Operator-run:** restart the live server during a recovery attempt on the real stack and read the segment's status afterwards: `pending_analysis` if its transcript was saved, otherwise `failed` with `recovery_interrupted`, and Whisper's log shows no new request. At merge.

## Blocked by

- [02 · Server: recover a failed segment](./02-server-recover-a-failed-segment.md)
