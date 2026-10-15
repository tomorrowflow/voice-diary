# Upstream outages degrade the app but never block or lose capture

**Status:** accepted (2026-10-14)

Builds on ADR 0002 (the error contract). It fixes what the app does when an upstream is down,
in line with SPEC §15.2: capture and upload data are never lost.

- **Walkthrough start without calendar.** If the calendar fetch fails (Graph down,
  rate-limited, not bootstrapped), the app shows the diagnosis with two actions: retry, or
  start without the calendar (general sections, free reflection, voice notes only). It never
  starts silently without the calendar, and a calendar failure no longer puts the walkthrough
  in `.failed` with a raw error string.
- **Enrichment copy per upstream.** Spoken failure lines are chosen by `code` / `upstream`
  (Ollama, LightRAG, Graph), German and English, each ending "Anreicherung übersprungen" /
  "Enrichment skipped". With no `code` (old server, no network) the existing
  connectivity-vs-generic split stays.
- **Health semantics.** Overall `down` stays Postgres or Whisper only. Ollama, LightRAG and
  Graph (down or `not_bootstrapped`) give `degraded`. Voxtral and `skipped` never change the
  overall status; Voxtral is an **optional upstream**, read by the app only when a Voxtral
  voice is selected. The Voxtral probe is accurate because the voxtral-gate answers it
  without waking the engine.
- **Upload retry.** `SessionUploader` keeps its backoff, honours `Retry-After` when longer,
  treats `retryable: false` as non-automatic (waits for the user or a config change), and
  shows the last failure's explanation on the pending-upload row. Audio is never deleted on
  failure.

## Consequences

- The server must ship before the app (ADR 0002); a new app on an old server falls back to
  status-based classification.
- Copy lives in the app's string catalog, not on the server.
