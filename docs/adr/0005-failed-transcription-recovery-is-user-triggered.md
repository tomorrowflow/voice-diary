# Failed segments are recovered only by an explicit user request, from retained server audio

**Status:** accepted (2026-10-24)

Builds on ADR 0002 (failure contract) and ADR 0003 (outages never block or lose capture), and
turns the PROTO-1 outcome recorded in DOC-9 (`docs/prd/upstream-failure-handling.md`, Further
Notes; branch `factory/e4b3b042-2d69-4a93-9409-f8cc2e1ec475`, not on `main` when this was
written) into a contract. The spec is `docs/prd/failed-transcription-recovery.md`.

A segment that fails after the Whisper preflight passed is recorded `failed` with no transcript.
The phone dropped its queue entry on the 2xx and a re-upload answers `409 session_exists`, which
the app treats as success, so nothing recovers it today. ADR 0002 says such segments "need a
re-upload"; that was never possible and is **superseded by this ADR**. ADR 0002 stays as the
record of the contract it decided; only that sentence is withdrawn.

Decision:

- **Only a tap starts a transcription attempt.** Never on foreground, on Whisper coming back, on
  server restart or on any scheduler. One tap is one attempt, per failed segment. There is no
  retry-all, cooldown, attempt cap or stored attempt counter.
- **Any failed segment is eligible**, whatever its error (Whisper failure, empty transcript,
  conversion failure, no code), provided its manifest entry and its retained server audio exist.
  With the audio gone the segment stays `failed`, the app explains it and drops the action.
  Recovery from the phone's copy is out of scope.
- **Health gates the button, not the work.** The app enables the action only while the last-known
  `/health` says Whisper is `ok`; unknown or unreachable disables it. Health coming back never
  starts anything. The server separately refuses with `whisper_unavailable` before changing
  anything. Ollama, LightRAG and Blindfold outages never block recovery: the transcript is saved
  and the segment becomes `pending_analysis`.
- **Automatic analysis retry stays as it is** (`docs/issues/upstream-failure-handling/07-ios-auto-retry-analysis.md`):
  it never transcribes a `failed` segment. A recovered segment whose analysis fails joins the
  `pending_analysis` flow and that retry.
- **Recovery is observable and survives the client leaving.** Once accepted, the server finishes the
  attempt whether or not the user leaves the screen, backgrounds the app or loses the connection.
  The app learns the outcome by reading status. A lost response is an *unknown outcome*, never
  proof of failure.
- **An interrupted attempt is not resumed automatically.** If the server restarts mid-attempt, a
  segment with a saved transcript continues as `pending_analysis`; one without goes back to `failed`
  and waits for another tap. The existing crash-resume of untranscribed segments must never pick
  up recovery audio.

## Considered options

- **Automatic recovery on foreground or health recovery (PROTO-1 option A)** — rejected: it
  changes finished entries unasked and hammers an upstream that may still be down. The cost of the
  chosen option is that the user has to notice the failed segment.
- **Recovery by re-uploading from the phone** — rejected: the audio may be deleted locally, the
  route would need new `409` semantics, and the server already holds the audio.
- **Retry-all for a session** — rejected for now: one tap, one attempt keeps the cost and the
  outcome of each attempt legible.
- **Gating on every upstream's health** — rejected: only Whisper can make the attempt pointless.

## Consequences

- The glossary gains *failed segment*, *transcription recovery*, *retained audio* and *unknown
  outcome* (`CONTEXT.md`).
- SPEC §10.5, §10.6.1 and §15.1 are updated by the implementation tickets, not by this ADR.
- Session audio retention becomes a feature dependency: nothing deletes it today, and any future
  retention job must keep audio of segments that can still be recovered.
