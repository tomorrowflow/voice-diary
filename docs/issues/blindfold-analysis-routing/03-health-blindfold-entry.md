# 03 · `/health` reports Blindfold when routed

Track: server
Type: AFK

## Parent

[Opt-in Blindfold Analysis Routing PRD](../../prd/blindfold-analysis-routing.md)

## What to build

`/health` gains a `blindfold` upstream entry only when `ANALYSIS_ROUTE=blindfold`; with `local` the key is absent and the response is exactly what it is today. The probe is a reachability check on the base URL (`GET /v1/models`): any answer below HTTP 500 is `ok` (so it does not depend on Blindfold serving that path), unreachable or 5xx is `down`. A `blindfold` entry that is not `ok` makes the overall status `degraded`, never `down`; Postgres and Whisper alone decide `down`. The Ollama entry is unchanged.

Update SPEC §10.7 (the upstream result list and the `degraded` rule).

## Acceptance criteria

- [ ] With the default route the `/health` response has no `blindfold` key and the overall status is unchanged for every existing case.
- [ ] Routed: reachable gives `ok`; unreachable and 5xx give `down` and an overall `degraded`; a 404 answer is `ok`.
- [ ] Postgres or Whisper down still makes the overall status `down`, routed or not.
- [ ] The probe sends no API key, and has a tight timeout like the other probes.
- [ ] SPEC §10.7 updated; server test suite passes.

## Blocked by

- [01 · Analysis route switch](./01-route-switch-default-local.md)
