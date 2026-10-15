# 01 · Failure contract: helper, Whisper preflight, segment codes

Track: server
Type: AFK

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md) · ADRs [0002](../../adr/0002-additive-upstream-failure-contract.md), [0003](../../adr/0003-upstream-outages-never-block-capture.md)

## What to build

Introduce the shared failure contract and prove it end to end on the ingest path, the one that matters most for data safety. Add the `UpstreamFailure` exception and its exception handler (deep module): the response body keeps the string `detail` and adds top-level `code`, `upstream`, `retryable`, with `Retry-After` only when a wait is known. Add the mapping from each client's exception classes (`Asr*`, `Ollama*`, `LightRAG*`, `TTS*`, `MSGraph*`, `EnrichmentSummariserUnavailable`) to a failure; later slices reuse it.

Wire it into `routers/sessions.py`: the Whisper preflight raises `whisper_unavailable` (503) and still persists nothing. Per-segment phase-1 errors and the session-level `analysis_pending` errors record `code` and `upstream` on the segment result next to the unchanged `error` string. Failures that escape the clients raw (the `document_processor` analysis path raises plain `httpx` errors and `RuntimeError("LLM analysis timed out …")`) are classified into `ollama_*` / `lightrag_*` at the narrative boundary; anything unclassifiable gets no code. `SegmentResult` gains optional `code` and `upstream`; they are stored in the `session_ingests.segments` JSONB (no migration) and returned by `GET /api/sessions/{id}/status` and `retry-analysis`.

Update SPEC §10.5/§10.6.1 for the segment fields and the failure shape, and add the code catalogue to `server/README.md` "Common failure modes".

## Acceptance criteria

- [ ] Every upstream client exception maps to the documented `(code, upstream, status, retryable)`; the helper has a unit test table covering all of them.
- [ ] Response bodies contain string `detail`, `code`, `upstream`, `retryable`; `Retry-After` is present only when known.
- [ ] Whisper down at upload returns 503 `whisper_unavailable` with nothing persisted (test).
- [ ] A mid-run Whisper failure, an Ollama failure and a LightRAG failure each record `code` and `upstream` on the affected segments, with the existing `error` string unchanged (tests).
- [ ] A raw `httpx` timeout from the analysis path is classified `ollama_timeout`; an unclassifiable error leaves `code` null.
- [ ] A session status written before this change (segments without the new keys) reads back with null `code`/`upstream`.
- [ ] SPEC §10.5/§10.6.1 and the README failure-modes section updated in the same change; `server` tests and ruff pass (DEVELOPMENT.md §7.4).

## Blocked by

None — can start immediately.
