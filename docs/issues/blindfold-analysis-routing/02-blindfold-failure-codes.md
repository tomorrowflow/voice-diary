# 02 · Blindfold failures stay `pending_analysis` with their own codes

Track: server
Type: AFK

## Parent

[Opt-in Blindfold Analysis Routing PRD](../../prd/blindfold-analysis-routing.md)

## What to build

Make a routed analysis failure visible, recoverable and never silently re-routed. The shared upstream-failure helper gains the upstream `blindfold` with three codes: `blindfold_unavailable` (connection refused or DNS failure; 503, retryable), `blindfold_timeout` (503, retryable) and `blindfold_engine_error` (any HTTP error status, or an unreadable body; 502, retryable; a 401 or 403 says the key was rejected in the message). A routed failure leaves every transcribed segment `pending_analysis` with the usual `analysis_pending: …` error and the new `code` and `upstream` fields, exactly as an Ollama failure does today. The server makes no call to Ollama or any other provider as a fallback. Local-route failures keep their `ollama_*` codes.

Update the SPEC §10.6.1 code table and the sentence that says which analysis failures get a code, and add `blindfold` to the upstream list in §10.5 / §10.6.1.

## Acceptance criteria

- [ ] Connection error, timeout and HTTP error status on the routed call give `blindfold_unavailable`, `blindfold_timeout` and `blindfold_engine_error`, with upstream `blindfold`, the documented HTTP status and `retryable: true`, in the unchanged response shape (`detail` string, `code`, `upstream`, `retryable`).
- [ ] Each leaves the session `pending_analysis` with an `analysis_pending: …` error and `code`/`upstream` on the segment status; no transcript or audio is lost.
- [ ] After a routed failure no analysis request is made to Ollama or any other host.
- [ ] `retry-analysis` and the start-up sweep recover the session once Blindfold answers; with the route switched to `local` they produce a local analysis.
- [ ] Local-route failures still report `ollama_*`; a default-route test shows no `blindfold` code can occur.
- [ ] SPEC §10.5, §10.6.1 updated; server test suite passes.

## Blocked by

- [01 · Analysis route switch](./01-route-switch-default-local.md)
