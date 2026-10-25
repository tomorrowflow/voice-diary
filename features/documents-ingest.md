# Feature: documents-ingest

Source: `server/webapp/main.py` (`ingest_document`, `POST /api/documents/{doc_id}/ingest`, the
review UI's manual ingest), `server/webapp/session_ingest.py` (`SessionIngest.narrative_date`).
Contract: SPEC §10.6.1 "The day narrative"; ADR 0006. The manual ingest sends one saved document to
LightRAG and takes the same hold on the document's date as every session narrative writer, so it
never interleaves with one, and it refuses a document that has a newer version.

Only the refusals are driven here. The verify stack has no LightRAG, and an ingest that gets as far
as sending is preceded by a best-effort skeleton sync that retries every bone (hundreds) against
the missing LightRAG, which takes tens of minutes per call. The ingest with the date hold, and the
whole-day input of the session writers (original ingest, `retry-analysis`, the sweep), need Whisper,
Ollama and LightRAG and are covered by pytest (`test_session_day_narrative.py`), not here.

## Drive

1. `document-ingest-refusals` (full command: SKILL.md → Drive):
   `… run --rm --no-deps -T driver python /drive.py document-ingest-refusals`.
   - `POST /api/documents/999999/ingest` without bearer → **401** `missing_bearer_token`.
   - The same with bearer → **404** `{"status": "error", "message": "Document not found"}`: the
     handler runs and looks the document up in the stack's Postgres, before any date is taken.
2. Seed (separate step; transcript `9001` with document versions `9001` older and `9002` newer,
   rows in `features/verify-server/seed-ftr01-documents.sql`), run from the worktree root:

   ```bash
   docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < features/verify-server/seed-ftr01-documents.sql > features/evidence/<run>/db-seed.txt 2>&1
   ```

   Expect `INSERT 0 1` and `INSERT 0 2`. Then `document-ingest-outdated 9001` →
   `POST /api/documents/9001/ingest` with bearer → **409**
   `{"status": "error", "message": "Document is outdated: a newer version exists"}`, answered at
   once: the date is held, the document and its transcript's latest version are read, and nothing is
   sent.

## Side effects

- `SELECT lightrag_ingested FROM processed_documents WHERE id IN (9001, 9002)` → `f` for both after
  the 409: a refused ingest marks nothing.
- The webapp log has one `POST /api/documents/<id>/ingest` line per call (401, 404, 409).

## Evidence

`document-ingest.txt`, `document-ingest-outdated.txt` (request/response JSON, PASS lines), the
`psql` outputs and the matching `webapp.log` lines.
