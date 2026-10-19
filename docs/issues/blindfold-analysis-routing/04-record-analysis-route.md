# 04 · Record `analysis_route` on each saved narrative

Track: server
Type: AFK

## Parent

[Opt-in Blindfold Analysis Routing PRD](../../prd/blindfold-analysis-routing.md)

## What to build

Each saved narrative records which route produced its analysis (`local` or `blindfold`) in the stored document metadata, so the operator can tell which days egressed. The narrative text is unchanged. There is no schema change: it is a new key in the existing metadata, and a row without it is `local` by definition. A retry or sweep run records the route in force when it ran; an ingest-only retry re-sends a saved narrative to LightRAG without analysis and keeps the route already recorded.

## Acceptance criteria

- [ ] A narrative saved on the default route has `analysis_route` `local`; a routed one has `blindfold`.
- [ ] A session pending under `local` and retried after the route was switched to `blindfold` is saved as `blindfold`; the reverse records `local`.
- [ ] An ingest-only retry leaves the recorded route unchanged and makes no analysis call.
- [ ] Rows from before this change still load and read as `local`; no migration.
- [ ] The narrative markdown is identical to what it was before for the same analysis.
- [ ] Server test suite passes.

## Blocked by

- [01 · Analysis route switch](./01-route-switch-default-local.md)
