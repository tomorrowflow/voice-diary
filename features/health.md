# Feature: health

Source: `server/webapp/health_checks.py` (`check_health` owns probe orchestration and
status folding via `overall_status`) and `server/webapp/routers/health.py` (a thin router that
validates and serves the snapshot). The only route without bearer auth — iOS probes it before
onboarding.

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

## Standing and conditional keys

The seven keys above are standing: `check_health` always probes them. An eighth key,
`blindfold`, is conditional: it exists only when the analysis route is Blindfold
(`ANALYSIS_ROUTE=blindfold`) and is probed after the standing ones. With the default `local`
route the response has no `blindfold` key and nothing is sent to a Blindfold URL.

Rules, as implemented in `health_checks.py`:

- Routed probe: `GET <BLINDFOLD_BASE_URL>/v1/models` with no API key, so it checks that the
  host is up, not that the key is valid. It runs under the same 2 s `PROBE_TIMEOUT` as the
  other probes.
- Any answer below 500 (including 401 and 404) is `ok`; a 5xx, timeout or connection error is
  `down`.
- `blindfold: down` is neither essential nor optional, so it degrades the overall status to
  `degraded` and never to `down`.
- `postgres` or `whisper` being `down` makes the overall status `down`, routed or not.
- Optional `voxtral` reports its real probe result but never changes the overall status.

### What backs these rules

Unit tests, not the isolated stack:
`server/webapp/tests/test_health_checks.py` (fake dependencies and a mock HTTP transport) and
`server/webapp/tests/test_health.py` (the `/health` route wired through the router).

- Local route has no `blindfold` key and sends nothing:
  `test_default_local_route_has_no_blindfold_entry_and_sends_nothing_to_it`,
  `test_default_route_has_no_blindfold_key_and_sends_nothing`.
- Below 500 is `ok`, 5xx and unreachable are `down` and `degraded`:
  `test_routed_blindfold_below_500_is_ok`, `test_routed_blindfold_5xx_is_down_and_degraded`,
  `test_routed_blindfold_unreachable_is_down_and_degraded`.
- `/v1/models`, no API key, `PROBE_TIMEOUT`, probed after the standing probes:
  `test_blindfold_probe_sends_no_api_key_and_uses_the_tight_timeout`,
  `test_blindfold_is_probed_separately_after_the_standing_probes`.
- Blindfold alone never makes the status `down`: `test_blindfold_down_alone_is_degraded_never_down`.
- Postgres/Whisper make it `down`: `test_essential_down_is_down_routed_or_not`.
- Voxtral never changes it: `test_optional_voxtral_down_is_reported_but_stays_ok`.

### What the isolated stack proves

The driver run covers only the default-local case: neither `compose.verify.yml` nor
`verify.env` sets `ANALYSIS_ROUTE`, so the stack runs the local route and the Expected values
above are the standing keys. The `health` subcommand asserts only the `postgres`, `qdrant` and
`msgraph` keys; it does not assert that `blindfold` is absent. The routed rules have not been
driven against the isolated stack, and no driver subcommand exercises them. The first-enable
check against a real Blindfold endpoint is separate operator work, not covered here.

## Side effects

None. The request still appears in the webapp request log.

## Evidence

`health.txt` (request/response JSON record + PASS lines) and the `/health` line in `webapp.log`.
