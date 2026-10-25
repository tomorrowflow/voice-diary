# Voice Diary

A personal voice-journaling system: an iPhone app captures voice notes during the day and runs a guided evening walkthrough; a server turns the recordings into diary narratives and a knowledge graph.

Architecture map: docs/architecture/*.json (SeeCode specs, evidence-linked; rules in docs/architecture/README.md).

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

**Session ingest**:
What the server does with an uploaded session bundle from acceptance to settled status, owned by one module (`session_ingest`) that the HTTP routes and the startup lifespan only call. It accepts the bundle (the session is `processing`), processes it in the background (transcribe, correct, detect entities per segment, then one narrative analysis per session, which ADR 0006 widens to the whole **day narrative**), retries a session's analysis on request, recovers a failed segment on request, and sweeps the sessions a restart stranded. A session settles as `done`, `partial` or `failed`; it never processes twice at once, and an interrupted session resumes from its stored audio, except that a failed segment is never transcribed again without a request. Refusals are domain errors (unknown session, busy, not retryable, bundle manifest gone); only the routes turn them into HTTP statuses.
_Avoid_: session processing, session lifecycle (as module names), processor

**Segment ingest**:
What the server does with one segment of a session, owned by one module (`segment_ingest`) that each **Session ingest** is given: read the stored audio, transcribe and persist it, correct it against the Dictionary (seeding a calendar event's attendees), detect entities and persist them. It runs the same way for the original ingest and for the resume of a stored bundle, and raises on failure; the session's lifecycle decides what a failed segment means.
_Avoid_: segment processing, segment pipeline

**Pending analysis**:
The state of an uploaded session whose transcripts are safely stored but whose session-level analysis or LightRAG ingest failed. No data is lost; it is retried by the server (startup sweep) or on request (`retry-analysis`).
_Avoid_: stuck, failed (a failed segment has no transcript; it is recovered from retained audio on request, ADR 0005, not by re-upload)

**Failed segment**:
A segment whose transcription failed and that has no usable linked transcript. Distinct from **pending analysis**, where the transcript is safe. It is recovered only by an explicit user request. While a recovery attempt runs it is `transcribing`, not `failed`.
_Avoid_: pending analysis, stuck segment

**Transcription recovery**:
One explicitly requested attempt, one per tap, to transcribe a failed segment again from its retained audio. Never started by the app or the server on their own (foreground, health recovery, restart, scheduler). It leaves every transcript that already exists untouched.
_Avoid_: retry-transcription as a product term (that is only the route), re-upload, auto-retry

**Retained audio**:
The audio of a segment as stored on the server under its session bundle. Transcription recovery needs it; the copy on the phone is not used, and a phone-side re-upload is not a recovery path.
_Avoid_: backup, local audio

**Day narrative**:
The combined narrative for one calendar date, built from every transcribed segment of every session recorded for that date and ingested as the date's single `diary:{date}` document. It is not a synonym for a session's narrative; any session's ingest, analysis retry or recovery rebuilds the whole day (ADR 0006).
_Avoid_: session narrative, diary entry (ambiguous with the LightRAG document)

**Unknown outcome**:
The state of a recovery request whose result the app never saw (timeout, connection loss, app killed). The app reads the server status to find out and never silently resubmits.
_Avoid_: failed (the attempt may have succeeded)

**Failure code**:
The stable snake_case identifier the server puts in an error response (`code`) when an upstream fails, together with `upstream` and `retryable`. The app keys its explanation copy and retry behaviour on it, never on the human-readable message.
_Avoid_: error string, error message (those are free-form and may change)

**Optional upstream**:
An upstream whose outage never changes the overall `/health` status and never blocks a workflow. Today only Voxtral: the app consults its health entry only when a Voxtral voice is selected, and falls back to Piper/Apple per utterance.
_Avoid_: soft dependency, non-critical

### Transcript correction

**Dictionary**:
What the user has taught the server about their own vocabulary: persons and terms with their variations, learned text corrections, and entity dismissals. Both transcript pipelines (the HTMX review stream and the iOS per-segment pipeline) read it as one snapshot, loaded once per run, and pass it to the shared correction chain.
_Avoid_: word list, lexicon, vocabulary

### Analysis routing

**Narrative analysis**:
The LLM call that turns the combined transcript of a **day narrative**, with a short summary of recent diary history, into the structured relationships, decisions, todos and insights behind the day's narrative. It ran once per session over that session's segments only; ADR 0006 widens its input to the whole day.
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
