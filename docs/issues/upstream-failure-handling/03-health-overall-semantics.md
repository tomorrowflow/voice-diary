# 03 · `/health` overall status rules

Track: server
Type: AFK

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md) · [ADR 0003](../../adr/0003-upstream-outages-never-block-capture.md)

## What to build

Make `/health`'s overall status rules explicit and make Voxtral an optional upstream. The response shape (`status`, `upstream{}`) and per-upstream values are unchanged. `down` only if `postgres` or `whisper` is `down`. `degraded` if any non-optional upstream other than `skipped`/`fixture` is not `ok`, including Graph `not_bootstrapped`, Ollama, LightRAG and Qdrant. Voxtral (`ok`, `down` or `skipped`) never changes the overall status. The Graph probe keeps checking the MSAL token cache, not live Graph. Voxtral's entry stays accurate because the voxtral-gate answers the probe without waking the engine.

Fix the SPEC §10.7 `/health` row, which says `ok` requires only LightRAG, Ollama, Whisper and Postgres, so it describes the real rules. Note the semantics in `server/README.md`.

## Acceptance criteria

- [ ] Table tests of the overall status for: all ok; Postgres down; Whisper down; Ollama down; LightRAG down; Graph `down` and `not_bootstrapped`; Qdrant down; `skipped`/`fixture` entries ignored; Voxtral `down` alone leaves `ok`; Voxtral `down` plus Ollama down gives `degraded` (no health tests exist today beyond bearer gating).
- [ ] `upstream.voxtral` still reports the real probe result.
- [ ] The `/health` route stays unauthenticated.
- [ ] SPEC §10.7 and the README updated; `server` tests and ruff pass.

## Blocked by

None — can start immediately.
