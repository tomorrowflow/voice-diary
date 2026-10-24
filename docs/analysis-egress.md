# Opt-in analysis egress and its limits

Voice Diary sends no diary content to a cloud AI service **by default**. The one exception is an
operator opt-in: the once-per-session narrative analysis can be routed through a
Blindfold pseudonymizing proxy to a frontier cloud model. This page
is the single place that states what that opt-in sends, what it does not protect, and what must
be true before it is switched on. README, SPEC, DEVELOPMENT, `server/README.md` and
`server/.env.example` link here instead of repeating it.

Background: [PRD](prd/blindfold-analysis-routing.md),
[ADR 0001](adr/0001-blindfolded-cloud-egress-opt-in.md) (the opt-in itself) and
[ADR 0004](adr/0004-blindfold-route-scope-config-and-failure.md) (scope, configuration, failure).

## Default: nothing goes to Blindfold or a cloud model

With `ANALYSIS_ROUTE=local` (the default, also when the variable is unset) the server makes no
request to Blindfold and sends no diary content to any cloud AI service. Transcription uses the
local Whisper sidecar; correction, analysis, narrative generation and enrichment summaries use
local Ollama. Upgrading the server does not change this.

## Settings

Environment only (`server/.env`); there is no admin-UI, app or per-session switch. The route is
read once at start-up, so changing it needs a server restart.

| Variable | Default | Required when routed | Meaning |
|---|---|---|---|
| `ANALYSIS_ROUTE` | `local` | – | `local` or `blindfold`. Any other value stops the server at start-up. |
| `BLINDFOLD_BASE_URL` | none | yes | Base of the OpenAI-shape endpoint (`/v1/chat/completions`). |
| `BLINDFOLD_ANALYSIS_MODEL` | none | yes | The cloud model id. The operator chooses it; the code has no default. |
| `BLINDFOLD_API_KEY` | none | no | Optional bearer token. Never logged. |
| `BLINDFOLD_ANALYSIS_TIMEOUT` | `OLLAMA_ANALYSIS_TIMEOUT` | no | Read timeout in seconds. |

With `blindfold`, a missing or empty base URL or model refuses to start and names the variable;
the server never quietly runs locally instead. Start-up logs one WARNING naming the route, base
URL and model (never the key).

## What the opt-in covers

Only the main analysis call (`analyze_transcript`) is routed. The context summary, transcript
correction, fluency and validation steps, and enrichment stay on local Ollama. Both callers of the
shared narrative stage follow the route: the iOS session pipeline (first run, `retry-analysis`,
start-up sweep) and the HTMX review stream. A retry reads the route in force at retry time; an
ingest-only retry re-sends a saved narrative to LightRAG, does no analysis and keeps the route
already recorded.

## No fallback

A Blindfold outage, timeout or error is never retried on local Ollama or any other provider. The
session stays `pending_analysis` with `blindfold_unavailable`, `blindfold_timeout` or
`blindfold_engine_error` (upstream `blindfold`; SPEC §10.6.1), and no diary data is lost. To get an
analysis during a long outage, set `ANALYSIS_ROUTE=local`, restart and retry. `/health` shows a
`blindfold` entry only when routed; Blindfold down makes the overall status `degraded`, never
`down` (SPEC §10.7). Each saved narrative records `analysis_route` (`local` or `blindfold`) in its
metadata, so you can tell which days left the machine.

## Limits: what still leaves the machine, or may

Blindfold pseudonymizes entities. That is **not content-level privacy**: the analysis prompt is
still the whole day, and what it says about you and other people still reaches the cloud model. With
the route on, these egress:

- **Transcript and journal content.** The full session transcript (entity names already
  normalized) goes out. Events, feelings, decisions and todos in it are not protected at all.
- **Dates.** Dates in the prompt and the diary prose are not pseudonymized: Blindfold's date shift
  is not wired (ADR-0005 / #25 in the Blindfold project, not in this repo). Dates are quasi-identifiers.
- **Relationships.** Who did what with, reports to or disagreed with whom is journal content, not
  an entity, and is sent as written.
- **The local context summary.** The context summary is produced locally from LightRAG
  retrievals, but its output is part of the analysis prompt and egresses. The raw retrievals
  behind it do not.
- **The author's name, role and company.** These are fixed values added to every analysis prompt
  and are the most identifying strings in it. Whether Blindfold treats them as entities is what the
  first-enable check below has to show.
- **Entities Blindfold does not detect.** Nicknames, unlisted companies and anything else its
  detection misses pass through unchanged. Detection on German prose is part of what the operator
  has to read for in that check.

Un-restored surrogates in Blindfold's response are not detected by this server; keeping them out of
Postgres and LightRAG is Blindfold's job, verified by the check below.

## Gate on the first enable

The server work merges with the route off, which is safe on its own. Do **not** set
`ANALYSIS_ROUTE=blindfold` until the operator-run checks in
[ticket 07](issues/blindfold-analysis-routing/07-operator-first-enable-checks.md) pass:

1. The Blindfold build you run includes #69 (non-blocking L3 and adjudicator timeout), #76
   (dedicated OpenAI upstream base URL) and #79 (surrogate collision fix).
2. A redaction end-to-end on a synthetic diary day: the request body that reaches the cloud
   upstream contains none of the seeded strings nor the author fields, the saved narrative shows
   the real names restored with no surrogates, and the dates and journal content you read in the
   capture match the limits above.
3. An outage and recovery run: Blindfold stopped gives `pending_analysis` with
   `blindfold_unavailable`, Blindfold restarted recovers by retry, and the switch back to `local`
   gives a local analysis recorded as `local`.

An automated test suite cannot establish any of these.
