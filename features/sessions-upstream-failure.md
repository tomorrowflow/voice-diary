# Feature: sessions-upstream-failure

Source: `server/webapp/routers/sessions.py` (`POST /api/sessions` Whisper preflight,
`GET /api/sessions/{id}/status`), `server/webapp/upstream_failure.py`. Contract: SPEC §10.5,
§10.6.1; ADR 0002. This is the failure path of session ingest: the iOS app keeps the recording
and reads the reason from `code` / `upstream`.

The verify stack has no Whisper (`whisper` does not resolve), so the real preflight fails. The
processing path (a mid-run Whisper, Ollama or LightRAG failure) needs those upstreams and is
covered by pytest (`test_sessions_upstream_failure.py`), not here.

## Drive

Driver subcommands (full command: SKILL.md → Drive):
`… run --rm --no-deps -T driver python /drive.py <subcommand> [args]`.

1. `session-upload-whisper-down <session_id>` — `POST /api/sessions` (multipart manifest + one
   segment) without bearer → **401**. With bearer → **503**
   `{"detail": "whisper_unavailable", "code": "whisper_unavailable", "upstream": "whisper",
   "retryable": true}` and no `Retry-After` header. Then `GET /api/sessions/<id>/status` → **404**
   `session_not_found`: nothing was persisted.
2. Seed two `session_ingests` rows with `psql` (below), then
   `session-status <id> legacy` → **200**, every segment has `code` and `upstream` null and keeps
   its `error` (a row written before the contract has no such keys); and
   `session-status <id> coded` → **200**, the failed segment carries `whisper_timeout` / `whisper`
   and the `pending_analysis` segment `ollama_unavailable` / `ollama`.

Seed (separate step; ids `ufh01-legacy` and `ufh01-coded`, rows in
`features/verify-server/seed-ufh01-sessions.sql`), run from the worktree root:

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < features/verify-server/seed-ufh01-sessions.sql > features/evidence/<run>/db-seed.txt 2>&1
```

Expect `INSERT 0 2`.

## Side effects

- After the 503: `SELECT count(*) FROM session_ingests WHERE session_id = '<id>'` → `0`, and the
  webapp log has one `POST /api/sessions … 503` line.
- Cleanup of the seeded rows: `DELETE FROM session_ingests WHERE session_id LIKE 'ufh01-%'` (the
  stack's volumes are removed by Cleanup anyway).

## Evidence

`session-upload-whisper-down.txt`, `session-status-legacy.txt`, `session-status-coded.txt`
(request/response JSON, PASS lines), the `psql` outputs, and the matching `webapp.log` lines.
