# Feature: sessions-retry-transcription

Source: `server/webapp/routers/sessions.py` (`retry_transcription`,
`POST /api/sessions/{session_id}/segments/{segment_id}/retry-transcription`),
`server/webapp/session_ingest.py` (`SessionIngest.recover`). Contract: SPEC §10.5 and §10.6.1
"Recovering a failed segment"; ADR 0005 and 0007. One request transcribes one `failed` segment again
from the audio the server retained and answers `202` with the session status (the segment
`transcribing`); the attempt runs in the background and `GET /api/sessions/{id}/status` shows the
outcome.

Only the refusals are driven here. The verify stack has no Whisper (the route's reachability check
fails, which is itself one of the refusals), so an accepted attempt, its transcript and the day
narrative need Whisper, Ollama and LightRAG and are covered by pytest
(`test_session_recovery.py`), not here.

## Drive

Seed first (two separate steps, run from the worktree root; the session is `ftr02-recoverable`: `s01`
processed, `s02` failed with audio on disk, `s03` failed without audio):

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < features/verify-server/seed-ftr02-session.sql > features/evidence/<run>/db-seed.txt 2>&1
```

Expect `INSERT 0 1`.

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T webapp python - < features/verify-server/seed-ftr02-bundle.py > features/evidence/<run>/bundle-seed.txt 2>&1
```

Expect `seeded /data/sessions/ftr02-recoverable`.

Then `segment-retry-transcription ftr02-recoverable` (full command: SKILL.md → Drive):
`… run --rm --no-deps -T driver python /drive.py segment-retry-transcription ftr02-recoverable`.

- `POST …/s02/retry-transcription` without bearer → **401** `missing_bearer_token`.
- Unknown session → **404** `session_not_found`; unknown segment `s99` → **404** `segment_not_found`.
- `s01` (processed) → **409** `segment_not_failed`.
- `s03` (failed, audio file absent) → **409** `segment_audio_missing`.
- `s02` (failed, audio present) → **503** `{"detail": "whisper_unavailable", "code":
  "whisper_unavailable", "upstream": "whisper", "retryable": true}` and no `Retry-After`: Whisper is
  not in this stack, and the route refuses before changing anything.
- `GET /api/sessions/ftr02-recoverable/status` → **200**, `state` `partial`, statuses unchanged
  (`processed`, `failed`, `failed`); `recoverable` is absent on `s01`, `true` on `s02`, `false` on
  `s03`.

## Side effects

- `SELECT state, segments FROM session_ingests WHERE session_id = 'ftr02-recoverable'` still reads
  as seeded after the run (no `transcribing`, no `recoverable` key stored):

  ```bash
  docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT state, segments FROM session_ingests WHERE session_id = '"'"'ftr02-recoverable'"'"'"' > features/evidence/<run>/db-row-after.txt 2>&1
  ```

- The webapp log has one `POST …/retry-transcription` line per call (401, 404, 404, 409, 409, 503).

## Evidence

`segment-retry-transcription.txt` (request/response JSON, PASS lines), the two seed outputs,
`db-row-after.txt` and the matching `webapp.log` lines.
