# Feature: health

Source: `server/webapp/routers/health.py`. The only route without bearer auth — iOS
probes it before onboarding.

## Drive

Driver subcommand `health` (full command: SKILL.md → Drive):
`… run --rm --no-deps -T driver python /drive.py health`.

`GET http://webapp:8000/health` from the driver container, no Authorization header.

## Expected

- HTTP 200, JSON `{"status": ..., "upstream": {...}}`.
- `upstream` has keys `postgres qdrant whisper lightrag ollama msgraph voxtral`.
- In the isolated stack: `postgres: ok`, `qdrant: ok`, `msgraph: fixture`,
  `lightrag`/`ollama: skipped` (empty URLs in the generated env), `whisper`/`voxtral: down`
  (services not started). Overall `status` is therefore `down` — expected, not a failure.
- Body contains no token, no PII.

## Side effects

None. The request still appears in the webapp request log.

## Evidence

`health.txt` (request/response JSON record + PASS lines) and the `/health` line in `webapp.log`.
