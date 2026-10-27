# Feature: sessions-general-section

Source: `server/webapp/models.py` (`GeneralSectionSegment`), `server/webapp/routers/sessions.py`
(`POST /api/sessions`, `GET /api/sessions/{id}/status`, `POST …/segments/{segment_id}/retry-transcription`),
`server/webapp/session_ingest.py` (`load_manifest`, `_segment_header`). Contract: SPEC §10.4 and
§10.6.1. A `general_section` segment (the user-defined walkthrough section: `section_id`, `title`,
`prompt_text` plus the usual segment fields) is accepted by the manifest and goes through the same
segment pipeline as every other type; its title reaches the day narrative as a header; the prompt stays
out of the transcript and the narrative input.

The verify stack has no Whisper, Ollama or LightRAG, so what is driven here is what a stack without
them can reach: the manifest is validated before the Whisper preflight, so an accepted manifest shows
as that preflight's 503 and a refused one as a 422; and the stored bundle of a seeded session must
reload, which the status route's `recoverable` flag and the recovery route's checks depend on. The
transcription itself, the narrative header, resume and retry-analysis need Whisper, Ollama and
LightRAG and are covered by pytest (`test_session_general_section.py`), not here. The audio is
synthetic (a stub file that is never transcribed).

## Drive

Seed first (two separate steps, run from the worktree root; the session is `ftr07-general`: one
failed `general_section` segment `s01` with audio on disk):

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < features/verify-server/seed-ftr07-session.sql > features/evidence/<run>/db-seed.txt 2>&1
```

Expect `INSERT 0 1`.

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T webapp python - < features/verify-server/seed-ftr07-bundle.py > features/evidence/<run>/bundle-seed.txt 2>&1
```

Expect `seeded /data/sessions/ftr07-general`.

Then `session-general-section ftr07-upload` (full command: SKILL.md → Drive; the argument is the id
of the uploaded, refused session):
`… run --rm --no-deps -T driver python /drive.py session-general-section ftr07-upload`.

- `POST /api/sessions` without bearer → **401**.
- With bearer and a spec-shaped `general_section` manifest → **503**
  `{"detail": "whisper_unavailable", "code": "whisper_unavailable", "upstream": "whisper",
  "retryable": true}`: the manifest passed validation and only the missing Whisper refused the
  upload. `GET /api/sessions/ftr07-upload/status` → **404** `session_not_found`.
- The same manifest without `section_id`, `title` or `prompt_text` → **422** `manifest_invalid: …`
  naming the field, before the preflight and any side effect.
- `GET /api/sessions/ftr07-general/status` → **200**, `s01` `failed` with `recoverable` **true**
  (the stored manifest, `general_section` included, reloaded and its audio was found).
- `POST /api/sessions/ftr07-general/segments/s01/retry-transcription` → **503** `whisper_unavailable`
  (same body as above): the recovery checks passed and only Whisper is missing.

## Side effects

- `SELECT count(*) FROM session_ingests WHERE session_id = 'ftr07-upload'` → `0` after the run
  (the refused uploads persisted nothing):

  ```bash
  docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT count(*) FROM session_ingests WHERE session_id = '"'"'ftr07-upload'"'"'"' > features/evidence/<run>/db-count-upload.txt 2>&1
  ```

- `ftr07-general` still reads as seeded (`failed`, no `transcribing`):

  ```bash
  docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT state, segments FROM session_ingests WHERE session_id = '"'"'ftr07-general'"'"'"' > features/evidence/<run>/db-row-after.txt 2>&1
  ```

- The webapp log has one `POST /api/sessions` line per upload (401, 503, 422 ×3), the status reads,
  and one `POST …/retry-transcription` line (503).

## Evidence

`session-general-section.txt` (request/response JSON, PASS lines), the two seed outputs,
`db-count-upload.txt`, `db-row-after.txt` and the matching `webapp.log` lines.
