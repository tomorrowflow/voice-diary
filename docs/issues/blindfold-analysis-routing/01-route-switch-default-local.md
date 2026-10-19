# 01 · Analysis route switch: Blindfold analysis, default local

Track: server
Type: AFK

## Parent

[Opt-in Blindfold Analysis Routing PRD](../../prd/blindfold-analysis-routing.md)

## What to build

The thinnest complete path for the opt-in. A global `ANALYSIS_ROUTE` setting (`local` default, or `blindfold`) read from the environment at start-up and validated. With `blindfold`, the main narrative analysis call is posted in the existing OpenAI chat-completions shape to `BLINDFOLD_BASE_URL`, with `BLINDFOLD_ANALYSIS_MODEL`, JSON mode, the `BLINDFOLD_ANALYSIS_TIMEOUT` read timeout (default: the local analysis timeout) and `Authorization: Bearer` when `BLINDFOLD_API_KEY` is set. The context summary and every other LLM call stay on local Ollama. Both callers of the shared narrative stage follow the route: the iOS session pipeline (first run, `retry-analysis`, start-up sweep, reading the route at run time) and the HTMX review stream.

Start-up validation refuses to start on an unknown route value, or on `blindfold` with a missing or empty base URL or model, with a message naming the variable. It never falls back to local. When routed, start-up logs one WARNING that analysis egress is enabled, naming the base URL and model, never the key. With `local` it logs nothing new.

Failure handling for a routed call is ticket 02; until then a routed failure behaves as any analysis failure does today.

## Acceptance criteria

- [ ] Default configuration: a full session ingest makes no request to any Blindfold URL and the analysis goes only to the local Ollama URL; a transport that fails on any unexpected host enforces it.
- [ ] Routed configuration: the analysis request goes to the Blindfold base URL and nowhere else, with the configured model, JSON mode, and the bearer header when a key is set and none when not; the context-summary request still goes to Ollama.
- [ ] The HTMX review stream follows the same route (one routed and one default case).
- [ ] A retry or sweep run uses the route in force when it runs.
- [ ] Unknown route value, and `blindfold` without base URL or model, each fail at start-up naming the variable; a valid routed config starts; the key never appears in the start-up log; the WARNING appears only when routed.
- [ ] Tests use the existing injected-`httpx`-transport style on the session-ingest seam (PRD Testing Decisions); no live Blindfold or cloud call.
- [ ] `server/.env.example` replaces the "needs its own opt-in knob" comment with the five variables (full disclosure text is ticket 05). Server test suite passes (DEVELOPMENT.md §7.4).

## Blocked by

None (can start immediately)
