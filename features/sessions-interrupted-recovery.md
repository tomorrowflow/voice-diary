# Feature: sessions-interrupted-recovery

Source: `server/webapp/session_ingest.py` (`SessionIngest.settle_interrupted_recoveries`, called first
by `sweep()` from the app lifespan in `server/webapp/main.py`), `server/webapp/db.py`
(`find_recovered_transcript`). Contract: SPEC §10.6.1 "Recovering a failed segment" → *Restart*; ADR
0005 and 0007. There is no new route: a server restart in the middle of a recovery leaves a segment
`transcribing`, and the startup settles it before the sweep, without calling Whisper. The result is
read from the existing `GET /api/sessions/{id}/status`.

The verify stack has no Whisper, Ollama or LightRAG, so a segment settled to `pending_analysis` stays
there (its analysis fails with `ollama_unavailable`); the full completion by the sweep is covered by
pytest (`test_session_interrupted_recovery.py`).

## Drive

Seed (separate steps, run from the worktree root; two sessions, `ftr03-saved` with the transcript
row a recovery had saved and `ftr03-unsaved` without one, both with their one segment `s01` left
`transcribing`):

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < features/verify-server/seed-ftr03-session.sql > features/evidence/<run>/db-seed.txt 2>&1
```

Expect `INSERT 0 1` and `INSERT 0 2`.

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T webapp python - < features/verify-server/seed-ftr03-bundle.py > features/evidence/<run>/bundle-seed.txt 2>&1
```

Expect `seeded /data/sessions/ftr03-saved` and `seeded /data/sessions/ftr03-unsaved`.

Restart the webapp so the startup runs against those rows (the restart is the interruption):

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml restart webapp > features/evidence/<run>/restart.log 2>&1
```

```bash
docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml up -d --wait webapp >> features/evidence/<run>/restart.log 2>&1
```

Then `session-interrupted-recovery <id> saved|unsaved` (full command: SKILL.md → Drive):
`… run --rm --no-deps -T driver python /drive.py session-interrupted-recovery ftr03-saved saved`.

- Without bearer → **401** `missing_bearer_token`.
- `ftr03-saved` (`saved`) → **200**, `state` `partial`, `s01` is `pending_analysis` with an integer
  `transcript_id` (not `transcribing`).
- `ftr03-unsaved` (`unsaved`) → **200**, `state` `failed`, `s01` is `failed` with `code`
  `recovery_interrupted`, `upstream` `null`, no `transcript_id`, an `error`, and `recoverable: true`
  (its audio is still on disk).

## Side effects

- `SELECT session_id, state, segments FROM session_ingests WHERE session_id LIKE 'ftr03-%'` shows
  the settled rows (no `transcribing`, no `recoverable` key stored):

  ```bash
  docker compose -p vd-verify --project-directory server --env-file features/verify-server/verify.env -f server/docker-compose.yml -f features/verify-server/compose.verify.yml exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT session_id, state, segments FROM session_ingests WHERE session_id LIKE '"'"'ftr03-%'"'"' ORDER BY session_id"' > features/evidence/<run>/db-row-after.txt 2>&1
  ```

- The webapp log has one `startup recovery reconciliation: session … segment s01 -> …` line per
  session after the restart, and no Whisper request.

## Evidence

`session-interrupted-saved.txt`, `session-interrupted-unsaved.txt` (request/response JSON, PASS
lines), the seed outputs, `db-row-after.txt` and the matching `webapp.log` lines.
