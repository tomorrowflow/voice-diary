# 07 · Operator-run: first-enable verification

Track: server
Type: Operator-run

## Parent

[Opt-in Blindfold Analysis Routing PRD](../../prd/blindfold-analysis-routing.md)

## What to build

Nothing is built. This ticket is the operator's checklist before `ANALYSIS_ROUTE=blindfold` is first switched on. A factory node cannot do any of it: it needs the operator's deployed Blindfold, a cloud model account, a phone and the operator's own hands, and the node has no GitHub access. Merging tickets 01 to 06 is safe on its own, because the default sends nothing. Do these **at merge, with the flag still off**, and leave it off until all three pass. A passing automated suite says nothing about any of them.

**Operator-run: 1 · Blindfold fixes deployed (at merge).** Confirm the Blindfold build in use includes #69 (non-blocking L3 and adjudicator timeout), #76 (dedicated OpenAI upstream base URL) and #79 (surrogate collision fix).

**Operator-run: 2 · Redaction end to end (at merge).** With the route on and a synthetic session of fake persons, a fake organization, an email address and a phone number, capture the request body that reaches the cloud upstream (a stand-in upstream, or Blindfold's own request log). None of the seeded strings, and not the author's name, role and company, may appear in it. The saved narrative must show the real names restored and no surrogates. Read the capture for dates and journal content too: they are expected to be there, and the limits section from ticket 05 must match what actually left. Use nothing real.

**Operator-run: 3 · Outage and recovery (at merge).** With the route on, stop Blindfold and upload a synthetic session: it lands `pending_analysis` with `blindfold_unavailable`, `/health` shows `blindfold` down and overall `degraded`, and the app shows the Blindfold copy. Start Blindfold and foreground the app (or call `retry-analysis`): the session becomes processed. No analysis request reached Ollama during the outage. Then set `ANALYSIS_ROUTE=local`, retry a pending session, and confirm a local analysis recorded as `local`.

## Acceptance criteria

- [ ] Operator-run, at merge: check 1 passed and the deployed Blindfold version noted in the card.
- [ ] Operator-run, at merge: check 2 passed; the capture shows no seeded string and no author field, and the saved narrative has no surrogates.
- [ ] Operator-run, at merge: check 3 passed in both directions (Blindfold down and back, and the local switch).
- [ ] Route left at `local` until all three are ticked.

## Blocked by

- [05 · Disclosure docs](./05-disclosure-docs.md)
- [06 · iOS Blindfold copy and retry](./06-ios-blindfold-copy-and-retry.md)
