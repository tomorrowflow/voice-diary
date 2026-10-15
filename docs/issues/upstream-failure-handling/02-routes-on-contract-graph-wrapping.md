# 02 · Enrichment, Graph and TTS routes on the contract

Track: server
Type: AFK

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md)

## What to build

Move the remaining upstream-facing routes onto the helper from slice 01: `routers/lightrag.py` (`/lightrag/query`, `/yesterday/open-todos`), `routers/email.py`, `routers/calendar.py` and `routers/tts.py`. Split the Ollama summariser failure into `ollama_unavailable`, `ollama_timeout`, `ollama_engine_error` by reason; LightRAG timeouts become `lightrag_timeout` instead of being folded into unavailable; `lightrag_status_N` / `lightrag_bad_response` become `lightrag_engine_error`. In `routers/tts.py` the dict `detail` is replaced by the shared shape (`error` becomes `code`; `voxtral_timeout` becomes 503 instead of 504).

In `msgraph_client.py`, wrap every transport exception and MSAL failure into `MSGraphError` / `MSGraphNotBootstrapped` so none becomes a bare 500, and expose the 429 `Retry-After` on the exception: exhausted backoff yields 429 `msgraph_rate_limited` with the `Retry-After` header; network errors and timeouts yield 503 `msgraph_unavailable`; 5xx/`graph_error` yield 502 `msgraph_engine_error`; `msgraph_not_bootstrapped` stays 503 with `retryable: false`.

Update SPEC §10.7 (error shape of the read endpoints) and the README code table.

## Acceptance criteria

- [ ] With each upstream mocked down, slow and erroring, each of the five routers returns the documented code, status, `upstream` and `retryable` (new test files for lightrag, email, calendar and tts; none exist today).
- [ ] Graph: 429 exhaustion returns 429 with `Retry-After`; an `httpx.RemoteProtocolError` and an MSAL exception return a coded 502/503, not 500 (tests).
- [ ] `msgraph_not_bootstrapped` returns 503 with `retryable: false`.
- [ ] The TTS error body follows the shared shape and `unknown_voice` keeps 400 with `retryable: false`; `test_voxtral_client.py` still passes.
- [ ] No router builds an upstream `HTTPException` by hand any more (grep check in the PR description).
- [ ] SPEC §10.7 and the README table updated; `server` tests and ruff pass.

## Blocked by

- [01 · Failure contract: helper, Whisper preflight, segment codes](./01-failure-contract-whisper-sessions.md)
