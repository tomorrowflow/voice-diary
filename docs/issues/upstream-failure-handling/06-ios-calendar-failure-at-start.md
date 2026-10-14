# 06 · iOS: calendar failure at walkthrough start offers retry or start without

Track: ios
Type: HITL

## Parent

[Upstream Failure Handling PRD](../../prd/upstream-failure-handling.md) · [ADR 0003](../../adr/0003-upstream-outages-never-block-capture.md)

## What to build

Today `WalkthroughCoordinator.fetchCalendar` runs inside the start `do/catch`, so any calendar failure (Graph down, rate-limited, not bootstrapped) puts the walkthrough in `.failed` with a raw error string. Replace that with a state that shows the `ConnectionDiagnosis` for the failure and two actions: "Erneut versuchen" and "Ohne Kalender starten" (general sections, free reflection and voice notes only). Starting without the calendar is always an explicit choice; nothing starts silently without it. For `msgraph_not_bootstrapped` the copy says the operator has to set it up, and retrying is offered but not emphasised.

Human review: German and English copy, and the manual scenario below on a device.

## Acceptance criteria

- [ ] With Graph unreachable, starting a walkthrough shows the diagnosis with both actions; no raw error string appears.
- [ ] "Erneut versuchen" re-runs the fetch and continues the normal walkthrough when it succeeds.
- [ ] "Ohne Kalender starten" completes a walkthrough with no calendar events, produces a normal session bundle, and uploads it.
- [ ] Failures other than the calendar fetch still end in `.failed` as before.
- [ ] Copy is in the string catalog (DE+EN); the screen uses `Theme.*` and `DSButtonStyle` only.
- [ ] Manual scenario 3 in the PRD passes; `ios` build and tests pass.

## Blocked by

- [02 · Enrichment, Graph and TTS routes on the contract](./02-routes-on-contract-graph-wrapping.md)
- [04 · iOS: parse the contract, failure copy, spoken enrichment lines](./04-ios-parse-contract-and-copy.md)
