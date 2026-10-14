# 04 · iOS: parse the contract, failure copy, spoken enrichment lines

Track: ios
Type: AFK

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md)

## What to build

Teach the app to read the contract and explain it. `ServerClient.assertOK` decodes `code`, `upstream`, `retryable` and `Retry-After` into `ServerClientError.http` next to the existing status and detail; missing fields are nil, which is today's behavior. Add a pure failure-copy module mapping `(code, upstream)` to title, hint and one-line impact in German and English through `Localizable.xcstrings`. `ConnectionDiagnosis.classify` consults it first and falls back to its status-based cases. `EnrichmentService.failureMessage` returns a per-upstream spoken line (Ollama, LightRAG, Graph), each ending "Anreicherung übersprungen" / "Enrichment skipped"; without a code it keeps the connectivity-versus-generic split.

Update SPEC §15.1 with the new rows.

## Acceptance criteria

- [ ] Error bodies with and without the new fields decode correctly; `Retry-After` is parsed as seconds (unit tests).
- [ ] `ConnectionDiagnosis` and `failureMessage` produce the documented copy for each code and upstream in German and English, and fall back to the old behavior with no code (extends `EnrichmentFailureCopyTests`).
- [ ] All new strings are in the string catalog with DE and EN values; no hard-coded user-facing text.
- [ ] A new app against an old server shows the previous status-based messages, never an empty message.
- [ ] SPEC §15.1 updated; `ios` build and tests pass (DEVELOPMENT.md §7.4).

## Blocked by

- [02 · Enrichment, Graph and TTS routes on the contract](./02-routes-on-contract-graph-wrapping.md)
