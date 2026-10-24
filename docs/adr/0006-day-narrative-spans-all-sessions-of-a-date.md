# The day narrative is rebuilt from every transcribed segment of the date, across sessions

**Status:** accepted (2026-10-24)

Builds on ADR 0005. It fixes what a recovered transcript changes in the diary.

Today each session builds one narrative from its own segments and ingests it into LightRAG under
the fixed id `diary:{date}`. Two sessions recorded for the same date therefore overwrite each
other's document (the last writer wins), and `retry-analysis` narrates only the segments that are
still `pending_analysis`. That was tolerable while a session's narrative was written once.
Recovering a segment into a session that already has a narrative would make it routine: a retry
over only the recovered segment would replace the whole day with a fragment, and recovering an older
session could overwrite newer content from the same date.

Decision:

- **One day narrative per date.** Whatever writes `diary:{date}` (original ingest, analysis retry,
  startup sweep, transcription recovery, and the review UI's manual ingest) assembles its input
  from **every transcribed segment of every session whose manifest date is that date**, in session
  start order and then manifest order, with each session's own headers and todos. Transcripts that
  already exist stay unchanged; the narrative is regenerated.
- **Assemble after taking the day.** Narrative writes for one date run one at a time. A writer
  gathers its input only once it has the date, from what is stored then, so a late writer cannot
  publish a stale view over newer content. Only the narrative stage is serialized; recording,
  uploading and transcription of other segments are not.
- **Status stays per session.** A successful run marks the segments of the session that triggered it
  `processed`. Other sessions' `pending_analysis` segments keep their status and are completed by
  their own retry, which rebuilds the same whole day.
- **Publication must not lose content.** The new narrative is saved to Postgres before it is
  published. If publication fails, the saved narrative stays unpublished and retryable (the
  saved-document re-ingest, keyed by day rather than by a session's segments); the segments stay
  `pending_analysis`. How LightRAG treats a second insert of `diary:{date}` (replace, reject or
  duplicate) is unverified and is settled by the first implementation ticket before anything depends
  on it.

## Considered options

- **Narrate only the session (or only the recovered segment)** — rejected: overwrites the day with
  a part of it.
- **Per-session lock only** — rejected: two sessions of one date can still publish over each other.
- **Serialize all ingest and uploads** — rejected: capture and new uploads must stay available
  (ADR 0003).
- **Append the recovered segment to the existing document** — rejected: LightRAG documents are
  replaced, not edited, and the narrative must be coherent over the whole day.

## Consequences

- Original ingest also changes: a second session on a date now yields a narrative of both.
- Regenerating a day costs one narrative analysis per run; a recovery of one segment pays it once.
- `SPEC.md` §10.5, §10.6.1, §13.1.2 and the glossary's *narrative analysis* are updated with the
  implementation.
