# 01 · Server: one day narrative across sessions

Track: server
Type: AFK

## Parent

[Failed-Transcription Recovery PRD](../../prd/failed-transcription-recovery.md), [ADR 0006](../../adr/0006-day-narrative-spans-all-sessions-of-a-date.md)

## What to build

Make every writer of a date's diary document build the same **day narrative**, so a later recovery (ticket 02) can never replace the day with a fragment. This is the prefactor the rest of the work stands on, and it is useful on its own: two sessions recorded on one date stop overwriting each other.

Original ingest, `retry-analysis` and the startup sweep assemble their narrative input from every transcribed segment of every session whose manifest date is the session's date: session start order, then manifest order, each segment with its own session's header and todos, from the stored transcripts (corrected text where present, entities as stored). `retry-analysis` no longer narrates only the `pending_analysis` subset. Which segments change status is unchanged: only the triggering session's segments move to `processed`; other sessions' `pending_analysis` segments stay pending and are completed by their own retry. A session whose manifest is unreadable is skipped with a logged line.

Narrative writes for one date run one at a time. A writer gathers its input only after it holds the date, so a late writer sees what the earlier one stored and cannot publish a stale view. Only the narrative stage is serialized: transcription of other segments, uploads and sessions of other dates are not held up. The review UI's manual ingest of a document joins the same date coordination.

Publication saves the new narrative before it is sent to LightRAG. The saved-narrative re-ingest shortcut is keyed by date, not by one session's segment set, so a failed publication stays retryable without regenerating the analysis. The unknown is how LightRAG treats a second insert under the same `diary:{date}` id (replace, ignore or duplicate). Settle it here: if it is not a replace, publish by deleting then inserting, with the saved narrative left unpublished and retryable if the step in between fails.

Update SPEC §10.6.1 (retry builds the whole day), §13.1.2 and the diary-ingest description in §10; the glossary entries already exist.

## Acceptance criteria

- [ ] A session recorded after another on the same date produces a narrative input covering both sessions, in session start then manifest order, with each segment's own header and todos.
- [ ] `retry-analysis` and the sweep over a session with some `processed` and some `pending_analysis` segments narrate all of them, never the pending subset alone; other sessions of that date are included.
- [ ] Only the triggering session's segments change status; another session's `pending_analysis` segments stay pending.
- [ ] Two narrative writers for one date run one at a time and the later one's input includes everything the earlier one stored; writers for different dates do not wait for each other; an upload and a transcription proceed while a narrative stage holds a date.
- [ ] A failed LightRAG publication leaves the saved day narrative unpublished and the segments `pending_analysis`; the next retry or sweep republishes it without re-running analysis, and the day never ends with two documents.
- [ ] A session whose manifest is missing is skipped with one log line and does not fail the run.
- [ ] The review UI's manual ingest takes the same date coordination.
- [ ] Tests through the session-ingest seam with the existing segment-pipeline and narrative-stage fakes and the in-memory repository, covering each case above (PRD Testing Decisions); the ingest module still imports no HTTP types.
- [ ] SPEC §10.6.1 and §13.1.2 updated; server test suite passes (DEVELOPMENT.md §7.4).
- [ ] **Operator-run:** against the live LightRAG, post `diary:{date}` twice for a date that already has a document and record whether it replaces, is ignored or duplicates; the result decides plain re-insert versus delete-then-insert and is written into SPEC §10.6.1. Before merge.

## Blocked by

None (can start immediately)
