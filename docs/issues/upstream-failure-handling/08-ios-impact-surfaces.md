# 08 · iOS: impact lines, pending-upload indicator, start notice, Verlauf pill

Track: ios
Type: HITL

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md)

## What to build

Show the impact where the user looks. In `ServerSettingsView`: one impact sentence per non-`ok` upstream from `Reachability` (Whisper: recordings stay on the phone and upload later; Ollama/LightRAG: analysis is delayed, texts are saved; Graph: calendar and mail unreachable, or not set up on the server; Voxtral: server voices fall back to Piper), and a new minimal pending-upload indicator ("N Sitzungen warten auf Upload") with the last failure's explanation from slice 05. SPEC §10.6 already promises that indicator, but only the DangerZoneView count exists today. At walkthrough start, show a non-blocking notice (like the Voxtral preflight) with the same impact line for any unhealthy upstream; it never blocks starting. In Verlauf, the pill for a `failed` segment shows the explanation for its segment `code`.

Human review: German and English copy and the manual scenarios on a device.

## Acceptance criteria

- [ ] Each non-`ok` upstream shows its impact sentence in Mehr → Server; `ok` and `skipped` upstreams show none; Voxtral never makes the overall status read as degraded.
- [ ] The pending-upload indicator shows the count and last failure explanation, and disappears when the queue is empty.
- [ ] The start notice appears for an unhealthy upstream, clears itself, and never blocks or delays the walkthrough.
- [ ] A `failed` segment with a `code` shows its explanation in Verlauf; one without a code shows today's pill.
- [ ] All strings are in the string catalog (DE+EN); only `Theme.*` and `DSButtonStyle` are used.
- [ ] Manual scenarios 1, 4, 5 and 6 in the PRD pass; `ios` build and tests pass.

## Blocked by

- [03 · `/health` overall status rules](./03-health-overall-semantics.md)
- [04 · iOS: parse the contract, failure copy, spoken enrichment lines](./04-ios-parse-contract-and-copy.md)
- [05 · iOS: upload queue honours Retry-After and `retryable`, keeps the last failure](./05-ios-upload-queue-retry-and-reason.md)
