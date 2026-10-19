# PRD: Opt-in Blindfold Analysis Routing

Status: Draft (2026-10-19). Specified through a grill session; implementation tracked as slice issues in `docs/issues/blindfold-analysis-routing/`, not as DEVELOPMENT.md milestones. Specifies Sandcastle issue #44; #43 (the OpenAI-shape port) is already merged.
Owner: Florian
Authored: 2026-10-19
Related: `docs/adr/0001-blindfolded-cloud-egress-opt-in.md`, `docs/adr/0004-blindfold-route-scope-config-and-failure.md`, `docs/adr/0002-additive-upstream-failure-contract.md`, `docs/adr/0003-upstream-outages-never-block-capture.md`, `SPEC.md` §10 (ingest contract, retry, health), §15.1, `CONTEXT.md`, `docs/issues/blindfold-analysis-routing/`

## Problem Statement

The once-per-session **narrative analysis** is the step where model quality shows most in the diary: it turns a day of transcripts into relationships, decisions, todos and insights. It runs on a local Ollama model, and the operator finds the result materially worse than what a frontier model produces. Until now the system has had zero **egress**, so using a frontier model has meant giving up the "everything stays on my machines" property outright.

**Blindfold** is a pseudonymizing proxy that sits in front of a cloud model: it replaces entity names and contact identifiers with surrogates on the way out and restores them on the way back. It makes a frontier model usable for this one step at an accepted, limited level of exposure, but only if the operator can turn it on deliberately, the default stays local, a Blindfold failure never loses data or quietly downgrades the result, and the operator can always tell which days left the machine and what the documentation promises about them.

## Solution

An **analysis route** setting with two values: `local` (default, today's behavior) and `blindfold`. It is global server configuration, read from the environment at start-up. With `blindfold` the main analysis call is sent to the configured Blindfold base URL in the OpenAI `/v1/chat/completions` shape that #43 already put in place, with an operator-chosen model and an optional bearer token. Nothing else changes route: the context summary, transcript correction, enrichment and every other LLM call stay on local Ollama.

The route is opt-in in three senses. The default sends nothing to Blindfold, ever. An incomplete `blindfold` configuration refuses to start instead of quietly running locally. A Blindfold failure leaves the session `pending_analysis` and visible, never silently re-run locally or sent anywhere else; the operator may switch the route back to `local` and retry.

Because this is the first egress, it is disclosed: the README, SPEC, DEVELOPMENT and `.env.example` stop claiming local-only analysis and list the known limits; the server logs a start-up warning naming the route and base URL; each saved narrative records which route produced it; `/health` reports Blindfold when routed; and the iOS app explains a Blindfold outage in its own failure copy and waits for Blindfold before auto-retrying. Whether pseudonymization actually works is proven by an operator-run end-to-end check before the first enable, not by the automated suite.

## User Stories

1. As the operator, I want the default configuration to send nothing to Blindfold or any cloud service, so that I can upgrade the server without changing what leaves my machine.
2. As the operator, I want one environment setting to turn Blindfold analysis on, so that using a frontier model is a deliberate act with a restart behind it.
3. As the operator, I want egress to be impossible to switch on from the web admin UI or the phone, so that nobody flips it by a stray click.
4. As the operator, I want to set the cloud model id myself with no built-in default, so that I choose what quality and cost I accept and the code never picks a provider for me.
5. As the operator, I want the Blindfold base URL and an optional API key in the environment, so that Blindfold can run on any host and be secured as I see fit.
6. As the operator, I want a half-configured `blindfold` route (missing base URL or model, or an unknown route value) to stop the server at start-up with a clear message, so that I never believe analysis is going to the cloud, or staying local, when it is not.
7. As the operator, I want the server to log a warning at start-up that names the route and the Blindfold base URL, never the API key, so that the log shows when egress was possible.
8. As the operator, I want only the main analysis call to use Blindfold, so that the raw multi-day LightRAG retrievals behind the context summary never leave my machine.
9. As the operator, I want the documentation to say that the analysis prompt still contains the transcript, the context summary and the author's name, role and company, so that I know what the accepted exposure actually is.
10. As the operator, I want the documentation to say that dates, journal content and relationships still egress and that entities Blindfold misses (nicknames, unlisted companies) may too, so that I do not mistake entity pseudonymization for content privacy.
11. As the operator, I want a Blindfold outage, timeout or error to leave the session `pending_analysis` with a specific code, so that I can see it is Blindfold and not Ollama, and no diary data is lost.
12. As the operator, I want no automatic fallback to local Ollama or to a direct cloud provider, so that narrative quality does not silently change from day to day and nothing is sent anywhere I did not configure.
13. As the operator, I want to be able to set the route back to `local` and retry a pending session, so that I can still get an analysis during a long Blindfold outage.
14. As the operator, I want a session retried after the route changed to follow the route in force at retry time, so that the setting I see is the setting that applies.
15. As the operator, I want each saved narrative to record whether it came from the local or the Blindfold route, so that I can tell which days egressed.
16. As the operator, I want `/health` to report `blindfold` only when the route is `blindfold`, so that a default install shows the same health output as today.
17. As the operator, I want `/health` to read `degraded` while Blindfold is unreachable, so that I can see a routed analysis is going to wait.
18. As the operator, I want the Ollama health entry to stay as it is when routed, so that the summary, correction and enrichment steps are still monitored.
19. As the operator, I want a documented end-to-end check on a synthetic diary day that shows what the cloud upstream actually receives, so that I verify pseudonymization on my own deployment instead of trusting a unit test.
20. As the operator, I want a documented outage and recovery check, so that I know a stopped Blindfold gives `pending_analysis` and a restarted one recovers by retry.
21. As the operator, I want the documentation to name the three Blindfold fixes (#69 non-blocking L3 and adjudicator timeout, #76 dedicated OpenAI upstream base URL, #79 surrogate collision) as conditions of the first enable, so that I do not turn the route on against a Blindfold that is not ready.
22. As the operator, I want the server work merged with the route off, so that the Blindfold fixes do not hold up unrelated server changes.
23. As a Voice Diary user, I want a session whose analysis waits for Blindfold to show the same "processing, your texts are saved" behavior as a wait for Ollama, so that I do not worry about my recording.
24. As a Voice Diary user, I want the app to tell me the analysis service is the one that is down when the server reports Blindfold, in German and English, so that I am not shown a generic server error.
25. As a Voice Diary user, I want the app to retry a waiting session when Blindfold is healthy again, so that my entry appears without my action.
26. As a Voice Diary user on the default route, I want nothing about the app to change, so that I never see a cloud-related message I cannot act on.
27. As a Voice Diary user with an older app build and a routed server, I want the old status-based messages to keep working, so that nothing breaks while the app update is pending.
28. As the operator reviewing a day in the HTMX review UI, I want the same route to apply there, so that the review flow and the phone flow cannot disagree about where analysis goes.
29. As a developer, I want a test that proves the default configuration makes no request to any Blindfold URL, so that the opt-in guarantee is checked on every change.
30. As a developer, I want a test that proves a routed analysis goes to the Blindfold base URL alone, with the configured model, the bearer token when one is set, and JSON mode, so that a regression cannot leak a request to Ollama or elsewhere.

## Implementation Decisions

### Architecture

- **Analysis route** is a single global server setting with values `local` and `blindfold`. It is not a per-session or per-segment choice (ADR-0001) and is not editable at runtime.
- **Scope: the main analysis call only** (ADR-0004). The call that produces the structured analysis is routed. The context summary is still produced by local Ollama. The route also covers both callers of the shared narrative stage: the iOS session pipeline (first run, `retry-analysis`, start-up sweep) and the HTMX review stream.
- **What egresses when routed.** The analysis prompt: the full session transcript with entity names already normalized, the locally produced context summary, the persons and terms lists, and the author's name, role and company, which are fixed values in the pipeline today. Blindfold is expected to pseudonymize the entities in all of it. Dates in the prompt and diary prose are not pseudonymized (Blindfold's date shift is not wired; ADR-0001). Journal content and relationships are not protected at all.
- **No fallback** (ADR-0004). A Blindfold failure is never retried against local Ollama or a cloud provider by the server. The recovery paths are the existing ones: the app's auto-retry, `retry-analysis`, the start-up sweep, and the operator's route switch.
- **Retry follows the current route.** A retry or sweep run reads the route at run time. A session that went `pending_analysis` under `local` and is retried after the operator switched to `blindfold` is analysed through Blindfold, and its narrative records `blindfold`. An ingest-only retry re-sends a saved narrative to LightRAG and does no analysis, so it keeps the route already recorded.
- **Restored text.** The narrative that is saved and ingested into LightRAG is built from Blindfold's restored response. Surrogates must never reach Postgres or LightRAG. The server does not detect un-restored surrogates itself; this is a Blindfold responsibility, verified by the operator-run E2E and, for the collision case, by Blindfold #79.

### Modules — server

- **Analysis route configuration.** Reads `ANALYSIS_ROUTE`, `BLINDFOLD_BASE_URL`, `BLINDFOLD_API_KEY`, `BLINDFOLD_ANALYSIS_MODEL` and `BLINDFOLD_ANALYSIS_TIMEOUT` once at start-up and validates them. An unset `ANALYSIS_ROUTE` means `local`; any value other than `local` or `blindfold` is a start-up error. With `blindfold`, a missing or empty base URL or model is a start-up error that names the variable. The timeout defaults to the local analysis timeout. The API key is optional and is never logged. The existing local settings (`OLLAMA_BASE_URL`, `OLLAMA_ANALYSIS_MODEL`, `OLLAMA_ANALYSIS_TIMEOUT`) are untouched and still drive the `local` route and every other Ollama call.
- **Analysis call.** The existing OpenAI-shape chat call takes its destination, model, timeout and optional `Authorization: Bearer` header from the active route. The request body shape (messages, temperature, `response_format` JSON mode, `stream: false`) is the same on both routes, so the model's answer is parsed by the existing code. The context-summary call keeps using the local route unconditionally.
- **Failure classification.** The shared upstream-failure helper gains the upstream `blindfold` and three codes, parallel to Ollama's: `blindfold_unavailable` (connection refused, DNS failure; 503, retryable), `blindfold_timeout` (read or connect timeout; 503, retryable), `blindfold_engine_error` (any HTTP error status, or a response body that cannot be read; 502, retryable). A 401 or 403 from Blindfold is an engine error whose message says so; the operator fixes the key. Local-route failures keep their `ollama_*` codes.
- **Session status.** A routed analysis failure leaves every transcribed segment `pending_analysis` with the usual `analysis_pending: …` error and the new `code` and `upstream` fields, exactly as an Ollama failure does today.
- **Health.** `/health` gets a `blindfold` entry only when the route is `blindfold`; with `local` the key is absent and the response is unchanged. The probe is a reachability check on the base URL (`GET /v1/models`); any answer below HTTP 500 means reachable, so the probe does not depend on Blindfold serving that path. Unreachable or 5xx gives `down`. A `blindfold` entry that is not `ok` makes the overall status `degraded`; it never makes it `down`, because Postgres and Whisper alone decide that. The Ollama entry is unchanged.
- **Narrative metadata.** The saved document metadata gains `analysis_route` (`local` or `blindfold`), set from the route that produced the analysis. It is stored with the narrative and may travel with the existing document metadata; the narrative text is unchanged. Rows written before this change have no key and are `local` by definition.
- **Start-up warning.** When the route is `blindfold`, start-up logs one WARNING that says analysis egress is enabled and names the base URL and model, never the key. With `local` it logs nothing new.

### Modules — iOS

- **Failure copy.** `(code, upstream)` entries for the three `blindfold_*` codes in German and English, through the string catalog. The impact line is the same as Ollama's ("Analysis is delayed; your texts are saved."). An unknown `blindfold` code gets that upstream's generic "failed" copy, as for every other upstream.
- **Auto-retry policy.** The pure retry decision requires `ollama` and `lightrag` healthy, as now, and additionally requires `blindfold` to be `ok` when `/health` contains a `blindfold` entry. With no entry (local route, or an old server) the decision is unchanged.
- **No egress UI.** The app shows no setting, banner or badge about egress. The operator is the only user and chooses in server configuration (ADR-0001); the app is unaware of the route except through failures and health.

### API contract

- `upstream` in the ADR 0002 failure contract gains `blindfold`; the code table in SPEC §10.6.1 gains the three rows above. Response shape, `retryable` and the `Retry-After` rule are unchanged.
- `/health`: optional `blindfold` entry with results `ok` or `down`, present only when routed.
- No route or request-body changes. `retry-analysis`, the status endpoint and upload are untouched.

### Storage

- No schema change. `analysis_route` is a new key in the existing document metadata JSON; absent means `local`.

### Settings model

| Variable | Default | Meaning |
|---|---|---|
| `ANALYSIS_ROUTE` | `local` | `local` or `blindfold` |
| `BLINDFOLD_BASE_URL` | none | Required when routed; base of the OpenAI-shape endpoint |
| `BLINDFOLD_API_KEY` | none | Optional bearer token |
| `BLINDFOLD_ANALYSIS_MODEL` | none | Required when routed; the cloud model id, chosen by the operator |
| `BLINDFOLD_ANALYSIS_TIMEOUT` | local analysis timeout | Read timeout in seconds |

### Documentation updated with the code

README (components list and the "local Ollama" wording), SPEC (§1 and §3 local-first claims, §10 narrative stage, §10.6.1 code table and retry, §10.7 health, §15.1), DEVELOPMENT.md (server environment and milestone notes), `server/README.md` (prerequisites and common failure modes), `server/.env.example` (replace the "needs its own opt-in knob" comment with the five variables and a plain statement of what egresses), and a short limits section listing: dates, journal content and relationships, the context summary, the author fields, and entities Blindfold does not detect.

## Testing Decisions

A good test checks external behavior at the highest seam: which URL a request goes to, what the stored status and health say. It does not assert Blindfold's pseudonymization, which this repo cannot see. Existing style: the injected `httpx` transport on the analysis call, FastAPI `TestClient` for routers, pure table tests for iOS policy.

### Server tests (in scope)

- **Primary seam: session ingest with the injected transport.** Prior art: the session upstream-failure tests and the document-processor tests.
  - Default configuration: a full ingest makes no request to any Blindfold URL, and the analysis goes only to the local Ollama URL. A transport that fails the test on any unexpected host enforces this.
  - Routed configuration: the analysis request goes to the Blindfold base URL and nowhere else, with the configured model, JSON mode, and `Authorization: Bearer` when a key is set and no header when not. The context-summary request still goes to Ollama.
  - Routed failures: connection error, timeout and an HTTP error each leave the session `pending_analysis` with `blindfold_unavailable`, `blindfold_timeout` and `blindfold_engine_error` and upstream `blindfold`; no request is made to Ollama for the analysis afterwards.
  - Retry after a route change: a session pending under `local` and retried under `blindfold` records `blindfold`; an ingest-only retry keeps the recorded route.
  - Saved narrative: `analysis_route` is `local` by default and `blindfold` when routed.
- **Health.** With `local` the response has no `blindfold` key. When routed: reachable gives `ok`, an unreachable or 5xx base URL gives `down` and an overall `degraded`, any answer below 500 (including 404) is `ok`, and Postgres or Whisper down still makes the overall `down`.
- **Configuration validation at start-up.** An unknown route value, and `blindfold` with a missing base URL or model, each fail with a message naming the variable; a valid routed config starts; the API key never appears in the start-up log; the start-up warning appears only when routed.
- **Review stream.** The HTMX review path follows the same route (one routed and one default case), since it shares the narrative stage.

### iOS tests (in scope)

- **Failure copy** for the three `blindfold_*` codes and the generic `blindfold` fallback, German and English (extends the failure-catalog and enrichment-copy tests).
- **Retry policy** table tests: with a `blindfold` health entry that is not `ok`, no retry; `ok`, retry as before; no entry, unchanged.

### Modules built without automated tests

- **Documentation and `.env.example`** edits are checked by review against this PRD, not by tests.
- **The effectiveness of pseudonymization** is not automated anywhere. Automated tests do not claim it.

### Operator-run checks

These cannot run on a factory node: they need a deployed Blindfold, a cloud model account, and the operator's own hands. All three are done **at merge, before the route is first switched to `blindfold`**, with the flag still off. Merging is safe on its own because the default sends nothing. The route stays off until all three pass.

1. **Operator-run: Blindfold fixes deployed.** The operator confirms the Blindfold build they run includes #69 (non-blocking L3 and adjudicator timeout), #76 (dedicated OpenAI upstream base URL) and #79 (surrogate collision fix). The node has no GitHub access and cannot verify this; a passing local suite says nothing about it.
2. **Operator-run: redaction end-to-end on a synthetic diary day.** The operator ingests a made-up session containing fake persons, a fake organization, an email address and a phone number, with the route set to `blindfold`. They capture the request body that reaches the cloud upstream, using a stand-in upstream or Blindfold's own request log, and check that none of the seeded strings, nor the author's name, role and company, appear in it. They then check that the saved narrative shows the real names restored and no surrogates. They also read the capture for dates and journal content, which are expected to be present, to confirm the documented limits match what actually left. Nothing real is used for this check.
3. **Operator-run: Blindfold outage and recovery.** With the route on, the operator stops Blindfold and uploads a synthetic session: it must land `pending_analysis` with `blindfold_unavailable`, `/health` must show `blindfold` down and overall `degraded`, and the app must show the Blindfold copy. They then start Blindfold, foreground the app (or call `retry-analysis`), and confirm the session becomes processed. They also confirm that no analysis request reached Ollama during the outage, and that setting `ANALYSIS_ROUTE=local` and retrying produces a local analysis recorded as `local`.

## Out of Scope

- Per-session or per-segment egress choice, and any UI for it (ADR-0001).
- Content-level protection: summarize-then-send or local pre-processing before egress (ADR-0001 option, may come later).
- Routing the context summary, transcript correction, fluency or validation steps, or enrichment through Blindfold.
- Fallback from Blindfold to local Ollama or to a direct cloud provider, automatic or manual-in-app (ADR-0004).
- Changing Blindfold: its fixes (#69, #76, #79), its date shift (ADR-0005/#25), its configuration. The diary is an ordinary client (ADR-0001).
- A runtime admin-UI switch, or storing the key in the database.
- Picking, benchmarking or hard-coding a cloud model.
- Egress indicators in the app, or a per-day egress badge in the review UI (the metadata is recorded; displaying it is later).
- Detecting un-restored surrogates in Blindfold's response.
- Making the author name, role and company configurable (they stay fixed, and are documented as egress).
- Telemetry (SPEC §15.3 stands: none).

## Further Notes

- **Order of work.** The server ticket ships first and is a strict superset of today's behavior, so it is safe default-off. The iOS ticket follows; a new app on an old server sees no `blindfold` entry and behaves as today, and an old app on a routed server falls back to status-based messages.
- **Existing comment to retire.** `server/.env.example` currently says routing the analysis call elsewhere "needs its own opt-in knob". This work is that knob, and the comment is replaced, not kept beside it.
- **Why the author fields are called out.** They are fixed values added to every analysis prompt, and they are the most identifying strings in it. Whether Blindfold treats them as entities is exactly what the E2E has to show.
- **Prompt language.** The analysis prompt is in German. Whether Blindfold's detection performs the same on German prose is part of what the operator's E2E observes, and is a reason to read the capture rather than only count matches.
- **Probe choice.** The reachability probe is deliberately weak (anything below 500) because this repo cannot check what Blindfold serves. A stronger check is possible later.
- **Sweep behavior while routed and down.** The start-up sweep tries each pending session once per start. With Blindfold down it fails fast, leaves them pending, and logs each one; it does not loop.
