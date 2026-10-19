# 06 · iOS: Blindfold failure copy and retry waits for Blindfold

Track: ios
Type: AFK

## Parent

[Opt-in Blindfold Analysis Routing PRD](../../prd/blindfold-analysis-routing.md)

## What to build

Teach the app to explain and wait for a Blindfold outage, with no egress UI of its own. Add `(code, upstream)` failure copy in German and English for `blindfold_unavailable`, `blindfold_timeout` and `blindfold_engine_error`, through the string catalog, with the same impact line as Ollama ("Analysis is delayed; your texts are saved."); an unknown `blindfold` code gets that upstream's generic "failed" copy. The pure auto-retry decision keeps requiring Ollama and LightRAG healthy and additionally requires `blindfold` to be `ok` when `/health` contains a `blindfold` entry; with no entry (default route, or an old server) it is unchanged. Update SPEC §15.1 and the §10.6.1 paragraph that names the health conditions for the app-driven retry.

## Acceptance criteria

- [ ] Copy for each of the three codes and the generic `blindfold` fallback, German and English, from the string catalog (extends the failure-catalog and enrichment-copy tests).
- [ ] Retry policy table tests: a non-`ok` `blindfold` entry gives no retry; `ok` retries as before; no entry is unchanged.
- [ ] An old server without the `blindfold` fields, and a default-route server, behave exactly as before; no empty message, no new UI.
- [ ] SPEC §15.1 and §10.6.1 updated; the `ios` build and tests pass (DEVELOPMENT.md §7.4).

## Blocked by

- [02 · Blindfold failure codes](./02-blindfold-failure-codes.md)
- [03 · `/health` Blindfold entry](./03-health-blindfold-entry.md)
