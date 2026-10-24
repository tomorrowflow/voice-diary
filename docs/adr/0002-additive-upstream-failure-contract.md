# Upstream failures use an additive, machine-readable error contract

**Status:** accepted (2026-10-14). Amended 2026-10-24: the sentence below saying `failed`
segments "need a re-upload" is superseded by ADR 0005; they are recovered on request from
retained server audio. The rest stands.

The server calls five upstreams (Whisper, Ollama, LightRAG, Microsoft Graph, Voxtral).
Today each router reports their failures differently: free-form strings such as
`ollama_unavailable: <reason>`, a dict `{error, detail}` on the TTS route, raw `str(exc)` on
the Graph routes, and a legacy `{status, message}` shape on the manual-ingest routes. The iOS
app only reads a string `detail`, so it can only classify by HTTP status.

Decision: every upstream failure goes through one shared server helper and is reported as

- `detail` — still a string (`"<code>"` or `"<code>: <message>"`), so installed apps keep working;
- `code` — stable snake_case (e.g. `whisper_unavailable`, `ollama_timeout`, `msgraph_rate_limited`);
- `upstream` — `whisper | ollama | lightrag | msgraph | voxtral`, plus `blindfold` when the analysis route is Blindfold (ADR 0004);
- `retryable` — whether trying again later can succeed without operator action;
- a `Retry-After` header where a wait is known.

Status mapping: **503** upstream down or timed out; **502** upstream answered with an error
(any unwrapped Graph/MSAL error is wrapped into this rather than becoming a bare 500);
**429** + `Retry-After` for Graph rate limiting. `msgraph_not_bootstrapped` stays 503 with
`retryable: false` — the operator has to run the bootstrap on the server.

The app calls `retry-analysis` for `pending_analysis` sessions once per foreground, and only
while `/health` reports Ollama and LightRAG ok. It shows no retry button; `failed` segments
(no transcript) are never retried that way, they need a re-upload.

## Considered options

- **Replace `detail` with an object** — rejected: breaks every installed app build, whose
  `assertOK` only extracts string details.
- **Status codes only (status quo)** — rejected: Ollama timeout, LightRAG down and Graph
  rate-limited are indistinguishable to the app, so it cannot explain the impact.

## Consequences

- `routers/tts.py`'s dict `detail` is aligned to the new shape; the TTS `error` field becomes `code`.
- The legacy `main.py` manual-ingest routes keep their own response shape (review-UI only, not iOS).
- Structured logging, correlation IDs, `server/scripts/backup.sh` and the README log/backup
  sections already exist and are out of scope for this work.
