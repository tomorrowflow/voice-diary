# Architecture handoffs: 2026-09-25

One handoff per deepening candidate from the 2026-09-23 architecture review. Each one is
written so a fresh session can **grill the candidate with the docs** (design tree first,
decisions with the user, then issues). None of these has been grilled yet.

| # | Candidate | Handoff | Existing issues that overlap |
|---|---|---|---|
| 01 | Server diary pipeline | [01-server-diary-pipeline.md](01-server-diary-pipeline.md) | #11, #12, #14, #15, #18, #43, #44 |
| 02 | Opener prefetch | [02-opener-prefetch.md](02-opener-prefetch.md) | #5 (implemented, awaiting host verify) |
| 03 | Walkthrough transitions + lull policy | [03-walkthrough-transitions.md](03-walkthrough-transitions.md) | #1 (closed umbrella) |
| 04 | Wake-word listener | [04-wake-word-listener.md](04-wake-word-listener.md) | #10 (test seams, awaiting host verify) |
| 05 | Implicit-todo confirmation as its own step | [05-implicit-todo-confirmation.md](05-implicit-todo-confirmation.md) | #7 (implemented, awaiting host verify) |
| 06 | Speaker module for TTS | [06-speaker-module.md](06-speaker-module.md) | #41 |

## Shared context (read once, applies to all six)

**Where this came from.** The 2026-09-23 review (`/mattpocock-skills:improve-codebase-architecture`)
scoped itself by commit hot spots. `ios/Sources/Dialog/WalkthroughCoordinator.swift` was 4,859
lines, changed in 21 recent commits and had 0 tests; the server session pipeline was the second
area. It produced seven candidates. The top one, **Session bundle**, was grilled to completion and
filed as #45–#48. These six are the rest. The review's HTML report lived in a temp dir and is gone;
each handoff below carries what it needs.

**Already decided: do not re-litigate.**
- **Session bundle** (#45–#48): one `SessionBundle` module owns the walkthrough on disk: segment
  IDs, chunk suffixes, paths, the `bundle.json` journal (absorbs `pause_state.json`), manifest
  building, voice-note attachment, pickup reconstruction. Candidates 02, 03 and 04 all read
  `currentRecordingSegmentID` / paths today; after #46 they get those from the bundle instead.
  Design each of them *assuming #46 has landed*.
- `docs/adr/0001-blindfolded-cloud-egress-opt-in.md`: cloud egress for narrative analysis is an
  explicit opt-in, default local (relevant to 01).
- `docs/REVIEW-2026-07-04.md` §6 "Notable positives": modules the review says not to "fix".
  `AudioEngine`, `M4AWriter`, `SessionUploader`, `OpenerTemplates`, `TTSFallbackPolicy`,
  `ParakeetManager` and the server `VoxtralClient` also passed the deletion test on 2026-09-23.
- IOS-A11 in the 2026-07-04 review was a false finding (TTS fallback *is* wired). Don't re-raise it.

**Vocabulary.**
- Domain terms: `CONTEXT.md` (session bundle, segment, chunk, voice note, pickup). Add new terms
  there as they are resolved; the old names "drive-by" and "seed" are to be avoided.
- Architecture terms come from the `codebase-design` skill: module, interface, depth, seam,
  adapter, leverage, locality. Don't use component, service, API or boundary.

**Line numbers** in the handoffs are as of `7ad3de1` (2026-09-23). Since then `main` has moved
(Sandcastle merged server fixes), and parked Sandcastle branches rewrite parts of
`WalkthroughCoordinator.swift`. Re-locate by symbol name, not line.

**Sandcastle is live on this repo.** A run may be implementing overlapping issues while you grill.
Before grilling a candidate, check its overlapping issues (`gh issue view <n> --comments`) and
their branches (`git log main..sandcastle/issue-<n>`). An issue labelled
`sandcastle:needs-host-verify` has code on a branch that hasn't been built on the Mac yet
(`scripts/verify_agent_branch.sh sandcastle/issue-<n>`).

**Process rule (user preference).** Grill first, file issues only for what survives the grill; no
mass issue creation from a review. iOS work is host-verified: agents edit in the Linux sandbox,
builds and on-device checks happen on the Mac/iPhone.

## Suggested skills for each session

- `mattpocock-skills:grilling`: walk the design tree with the user (the "grill with docs" step).
- `mattpocock-skills:codebase-design`: vocabulary; `DESIGN-IT-TWICE.md` if the interface shape
  is contested; `DEEPENING.md` for dependency categories.
- `mattpocock-skills:domain-modeling`: update `CONTEXT.md` inline; offer an ADR only if a
  rejection reason is hard to reverse, surprising, and a real trade-off.
- `mattpocock-skills:to-issues`: once the user confirms the grill is done. Label `Sandcastle` plus
  `track:ios` / `track:server` (see `docs/agents/triage-labels.md`), and link blockers with
  GitHub's native issue dependencies.
