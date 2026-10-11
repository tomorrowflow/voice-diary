# Feature: health

Source: `server/webapp/routers/health.py`. The only route without bearer auth — iOS
probes it before onboarding.

## Drive

```bash
features/verify-server/verify.sh drive health
```

`GET http://127.0.0.1:<port>/health`, no Authorization header.

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

`health.request.txt`, `health.response.{headers,body}`, `health.status`.
