# Feature: documents-ingest

Source: `server/webapp/main.py` (`ingest_document`, `POST /api/documents/{doc_id}/ingest`, the
review UI's manual ingest), `server/webapp/session_ingest.py` (`SessionIngest.narrative_date`).
Contract: SPEC §10.6.1 "The day narrative"; ADR 0006. The manual ingest sends one saved document to
LightRAG and takes the same hold on the document's date as every session narrative writer, so it
never interleaves with one.

Only the refusals are driven here. The verify stack has no LightRAG, and the ingest itself is
preceded by a best-effort skeleton sync that retries every bone (hundreds) against the missing
LightRAG, which takes tens of minutes per call. The ingest with the date hold, and the whole-day
input of the session writers (original ingest, `retry-analysis`, the sweep), need Whisper, Ollama
and LightRAG and are covered by pytest (`test_session_day_narrative.py`), not here.

## Drive

Driver subcommand `document-ingest-refusals` (full command: SKILL.md → Drive):
`… run --rm --no-deps -T driver python /drive.py document-ingest-refusals`.

1. `POST /api/documents/999999/ingest` without bearer → **401** `missing_bearer_token`.
2. The same with bearer → **404** `{"status": "error", "message": "Document not found"}`: the
   handler runs and looks the document up in the stack's Postgres, before any date is taken.

## Side effects

None (a read). The webapp log has one `POST /api/documents/999999/ingest` line per call, 401 and 404.

## Evidence

`document-ingest.txt` (request/response JSON, PASS lines) and the matching `webapp.log` lines.
