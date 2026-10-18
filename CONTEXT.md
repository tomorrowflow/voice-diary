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
An external service the server calls to do its work: Whisper (transcription), Ollama (analysis, enrichment summaries), LightRAG (diary memory), Microsoft Graph (calendar, email), Voxtral (server-side speech), and Blindfold when the analysis route is set to it. Postgres and Qdrant are infrastructure, not upstreams. The phone never talks to an upstream directly.
_Avoid_: backend (ambiguous with the server itself), dependency, provider

**Pending analysis**:
The state of an uploaded session whose transcripts are safely stored but whose session-level analysis or LightRAG ingest failed. No data is lost; it is retried by the server (startup sweep) or on request (`retry-analysis`).
_Avoid_: stuck, failed (a failed segment has no transcript and needs a re-upload)

**Failure code**:
The stable snake_case identifier the server puts in an error response (`code`) when an upstream fails, together with `upstream` and `retryable`. The app keys its explanation copy and retry behaviour on it, never on the human-readable message.
_Avoid_: error string, error message (those are free-form and may change)

**Optional upstream**:
An upstream whose outage never changes the overall `/health` status and never blocks a workflow. Today only Voxtral: the app consults its health entry only when a Voxtral voice is selected, and falls back to Piper/Apple per utterance.
_Avoid_: soft dependency, non-critical

### Analysis routing

**Narrative analysis**:
The once-per-session LLM call that turns the combined session transcript, with a short summary of recent diary history, into the structured relationships, decisions, todos and insights behind the day's narrative.
_Avoid_: document processing (the whole pipeline), session analysis

**Analysis route**:
Where the narrative analysis is sent: local Ollama (the default) or Blindfold. A single global operator setting, not a per-session choice.
_Avoid_: provider, backend, LLM mode

**Blindfold**:
A pseudonymizing proxy between the server and a frontier cloud model. It swaps entity names and contact identifiers for surrogates on the way out and restores them on the way back. Journal content and dates still leave the machine.
_Avoid_: privacy proxy, anonymizer (it pseudonymizes, and only entities)

**Egress**:
Diary content leaving the operator's machines for a third party. Today the only egress is an analysis route set to Blindfold; everything else is local.
_Avoid_: upload (that is phone to server), leak
