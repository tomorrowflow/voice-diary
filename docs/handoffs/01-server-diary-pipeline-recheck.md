# Handoff 01 re-check (2026-09-28, `main` @ `d386eeb`)

Re-check of [01-server-diary-pipeline.md](01-server-diary-pipeline.md) against current `main`.
**Filed 2026-09-28** after the decisions were settled: T1 → #49, T2+T3 → #50 (blocked by #49), T4 → #51, T5 → #52 (blocked by #50). #12 and #43 closed as merged.

## What has landed since `7ad3de1`

| Handoff friction | Status |
|---|---|
| No LLM seam (#11) | `ollama_client.OllamaClient` is used by enrichment, transcript_corrector, fluency_checker, llm_validator and harvest_llm. `document_processor` has its own `_call_llm` in the `/v1/chat/completions` shape (#43). |
| Whisper/ffmpeg twice (#12) | `asr_client.AsrClient`, merged in `356b759` / `e76c78c`. **Issue still open, so close it.** |
| LightRAG access split (#18) | `lightrag_client.LightRAGClient` is used by document_processor, skeleton_sync and routers/lightrag. |
| In-memory `_session_status` (#14) | Persisted to `session_ingests`. |
| Upload vs sessions pipelines (#15) | `transcript_ingest.transcribe_and_persist` is shared (`06e78eb`, `f632690`). |
| `/v1/chat/completions` (#43) | Merged (`c99824f`, via `e76c78c`). **Issue still open, so close it.** The "merge blocked" comment is stale. |
| Blindfold opt-in (#44) | Open. Blocked by blindfold#69, #76 and #79, which are external. Out of scope here. |

## What is still true

1. **Two narrative pipelines.** `main.py::process_document_stream` (HTMX SSE) and
   `routers/sessions.py::_run_session_document_processor` each put together the same five
   `document_processor` steps (context query → summarize → enrich → analyze → narrative →
   save). The failure policy differs:
   - LightRAG context query fails: SSE continues with empty context. Sessions aborts the analysis
     and every segment goes to `pending_analysis`.
   - Summarize fails: SSE falls back to "Keine historischen Daten verfügbar.". Sessions aborts.
   - Ingest: SSE doesn't ingest; the user clicks `/api/documents/{id}/ingest`. Sessions ingests
     inline, and a failure marks the whole session `pending_analysis` even though the documents
     were already saved.
2. **Bug: sessions never marks documents ingested.** `_run_session_document_processor` calls
   `ingest_to_lightrag` but never calls `db.mark_document_ingested`. Only `main.py:635` does. So
   every iOS-ingested day shows as "not ingested" on `/process/{id}`, and the re-ingest button
   re-posts it.
3. **`pending_analysis` is a dead end.** The db.py comment at the SRV-A6 section says the
   persisted rows "make pending_analysis segments retryable". Nothing retries them: no route, no
   startup sweep, no button.
4. **The correction chain differs between paths.** The HTMX `process_transcript_stream` runs
   dictionary text corrections → vector few-shot examples → LLM correction → fluency → entity
   detection → dismissal filtering → vector usage samples → llm_validator. The iOS
   `_process_segment` runs only LLM correction (no few-shot) → entity detection with attendee
   seeding.
5. **Hidden side effect.** `document_processor.ingest_to_lightrag` runs
   `skeleton_sync.sync_incremental` first.
6. **Test surface.** `tests/test_sessions.py` covers status and the transcribe core. Nothing
   exercises the narrative stage end to end, because it would need monkeypatching across
   document_processor, db and lightrag.

## Draft tickets (pending grill)

All `track:server`. Each is an AFK slice for Sandcastle with pytest verification.

### T1: Mark session-ingested documents as ingested (bug, no decision needed)
After `ingest_to_lightrag` succeeds in the sessions path, call `db.mark_document_ingested` for
every `processed_documents` row saved for that session. Regression test with a fake LightRAG
client and a fake db.

### T2: One narrative module for both entry points (DiaryPipeline)
A deep module, for example `narrative.py::build_day_narrative(text, entities, date, *, ports,
on_step=None) -> NarrativeResult`, owns context → summary → enrich → analysis → narrative and a
single failure policy. It sits behind injected ports: `LightRAGClient` (context), an analysis-LLM
callable (the #44 plug point) and a repository (save). `process_document_stream` passes an
`on_step` that emits its SSE events. The sessions path calls it with no callback. Acceptance: one
test file drives the whole narrative through fakes at the ports, and both routes' existing
behaviour is covered. *Depends on decision D1.*

### T3: Make pre-ingest skeleton sync explicit
Move `skeleton_sync.sync_incremental` out of `ingest_to_lightrag` into an explicit step of the
caller (or of T2's module). Could be folded into T2.

### T4: Shared transcript-correction core for iOS sessions (behaviour change)
Pull out the non-interactive part of `process_transcript_stream` (dictionary text corrections,
vector few-shot examples, dismissal filtering) and use it in `_process_segment`. The interactive
parts (fluency hints, llm_validator) stay HTMX-only. *Depends on decision D2.*

### T5: Retry `pending_analysis` sessions
A route (and optionally a startup sweep) that re-runs the narrative stage for a session whose
transcripts exist but whose analysis or ingest failed. *Depends on decision D3; best after T2.*

## Decisions (settled 2026-09-28, all as recommended)

- **D1 LightRAG failure policy.** Recommended: context or summary failure falls back to "no
  history" in both paths, so the diary entry is still written. An ingest failure keeps the saved
  document, leaves it unmarked and makes it retryable (with T5).
- **D2 iOS correction chain.** Recommended: dictionary corrections, few-shot and dismissals yes;
  fluency and llm_validator no, because they only produce review-UI hints.
- **D3 Retry trigger.** Manual route or button only, or also a startup sweep?
- **Housekeeping.** Close #12 and #43 as merged.
