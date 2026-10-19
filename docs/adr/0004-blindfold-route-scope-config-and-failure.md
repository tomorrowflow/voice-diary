# The Blindfold route covers the main analysis call only, is env-configured, and fails closed

**Status:** accepted (2026-10-18)

Builds on ADR 0001 (blindfolded cloud egress is an explicit opt-in) and ADR 0002 (the failure
contract). It fixes the shape of the first Blindfold route.

- **Scope.** Only the main narrative analysis call (`analyze_transcript`) goes through Blindfold.
  The context summary stays on local Ollama, so raw LightRAG retrievals never egress. Its
  *output*, the author's name, role and company, and the full transcript still egress inside the
  analysis prompt, and the docs say so.
- **Config.** Environment only, never the admin settings UI: `ANALYSIS_ROUTE=local|blindfold`
  (default `local`), `BLINDFOLD_BASE_URL`, `BLINDFOLD_API_KEY` (optional), `BLINDFOLD_ANALYSIS_MODEL`
  (no code default), `BLINDFOLD_ANALYSIS_TIMEOUT`. A `blindfold` route with a missing base URL or
  model refuses to start.
- **Failure.** A Blindfold outage, timeout or error never falls back, neither to a cloud provider
  nor silently to local Ollama. The session becomes `pending_analysis` with `blindfold_unavailable`,
  `blindfold_timeout` or `blindfold_engine_error` (upstream `blindfold`). The operator sets
  `ANALYSIS_ROUTE=local` to retry locally.
- **Gates.** The server work merges default-off. Blindfold #69, #76 and #79 gate only the
  operator's first enable.

## Considered options

- **Route the context summary too** — rejected: it would send raw multi-day LightRAG retrievals,
  far more diary content than the session being analysed.
- **Fall back to local Ollama on Blindfold failure** — rejected: the operator chose this route for
  frontier quality, and a silent downgrade would mix narrative quality across days with no trace.
  `pending_analysis` already keeps the data safe (ADR 0003).
- **A runtime switch in the admin UI** — rejected: egress should need a deliberate config change
  and a restart, not a click.

## Consequences

- `upstream` in the ADR 0002 contract gains `blindfold`; `/health` gets a `blindfold` entry only
  when the route is `blindfold`, and the app's failure copy and auto-retry learn about it.
- Each saved narrative records its analysis route, so the operator can tell which days egressed.
