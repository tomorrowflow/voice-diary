# Voice Diary

A personal voice-journaling system: an iPhone app captures voice notes during the day and runs a guided evening walkthrough; a server turns the recordings into diary narratives and a knowledge graph.

## Language

### Capture

**Session bundle**:
One evening walkthrough as it exists on the phone, in progress or finished: its segments, their audio, and everything the manifest will say about them. The unit that gets uploaded.
_Avoid_: session directory, session folder, staging dir

**Segment**:
One typed piece of a session bundle: a calendar event, a general section, a free reflection, an attached voice note, or an empty block. Maps 1:1 to a manifest segment.
_Avoid_: recording, clip

**Chunk**:
One continuous recording that makes up part of a segment, produced when the walkthrough is paused and resumed mid-segment. Chunks are merged into one segment before upload.
_Avoid_: part, resume segment

**Voice note**:
A short capture recorded outside the walkthrough (lock screen, Action Button). Lives on its own until a walkthrough surfaces it and attaches it to a session bundle as a segment.
_Avoid_: drive-by (legacy name), seed (legacy name), memo

**Pickup**:
Re-entering an unfinished session bundle after a pause, cancel or app kill, continuing at the last recorded segment.
_Avoid_: resume (reserved for un-pausing within a running walkthrough), restore

### Server dependencies

**Upstream**:
An external service the server calls to do its work: Whisper (transcription), Ollama (analysis, enrichment summaries), LightRAG (diary memory), Microsoft Graph (calendar, email), Voxtral (server-side speech). Postgres and Qdrant are infrastructure, not upstreams. The phone never talks to an upstream directly.
_Avoid_: backend (ambiguous with the server itself), dependency, provider

**Pending analysis**:
The state of an uploaded session whose transcripts are safely stored but whose session-level analysis or LightRAG ingest failed. No data is lost; it is retried by the server (startup sweep) or on request (`retry-analysis`).
_Avoid_: stuck, failed (a failed segment has no transcript and needs a re-upload)

**Failure code**:
The stable snake_case identifier the server puts in an error response (`code`) when an upstream fails, together with `upstream` and `retryable`. The app keys its explanation copy and retry behaviour on it, never on the human-readable message.
_Avoid_: error string, error message (those are free-form and may change)
