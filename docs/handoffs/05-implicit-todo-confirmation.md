# Handoff 05: Implicit-todo confirmation as its own step

Read [README.md](README.md) first (shared context, vocabulary, process rules).

**2026-09-23 strength:** Speculative (clean seam depends on 03 and 04 landing first).
**Dependency category:** in-process plus the audio engine.

## The candidate in one line

Turn the CLOSING-phase implicit-todo confirmation into a sub-flow module with one entry and one
result, `run(candidates) async -> (confirmed, rejected)`, and move transcript-excerpt matching out
of the SwiftUI view.

## Friction found (as of `7ad3de1`)

- **The coordinator half.** `WalkthroughCoordinator.swift` ~3145-3600, ~455 lines, has its own
  recorder, its own `LullDetector` (declared ~154, thresholds `[3,12]`), its own `engine.start`,
  Parakeet transcription and `TodoAnswerParser`. It keeps separate state: `pendingImplicitTodos`,
  `confirmedImplicit`, `rejectedImplicit`, `todoAnswerTask`, `isAwaitingTodoAnswer`.
- **The view half.** `TodoConfirmationCard` (`UI/Walkthrough/WalkthroughView.swift`
  ~1447-1561, ~115 lines) does sentence splitting, token-overlap fuzzy matching and a 5-line
  excerpt window. That domain logic can't be tested where it sits, and it overlaps the
  coordinator's static `isGroundedInTranscript` (~3575), which is also untested.
- **Shared dependencies:** the engine, TTS, and the wake-word window (see handoffs 03/04/06).
  That's why the seam is only clean after those.
- **Behaviour that must hold:** SPEC §8 and CLAUDE.md constraint 4. Todos are detected implicitly
  on-device but confirmed **only at CLOSING**, never mid-flow. Explicit todos come from regex, and
  implicit ones carry a verbatim `source_quote` (`Models/Manifest.swift` `Todo`).
- **Where verdicts go:** after #46, verdicts go to `SessionBundle` (todo verdicts are part of the
  manifest and the journal), not to coordinator arrays.

## Overlapping issue: start here

**#7 (IOS-A8) "Extract TranscriptExcerpt + TodoConfirmationFlow from god file and view"** is
**already implemented** on `sandcastle/issue-7` (2 commits as of 2026-09-25) and parked with
`sandcastle:needs-host-verify`. It proposed a pure `TranscriptExcerpt` (transcript + needle →
text + highlight range) plus a `TodoConfirmationFlow` for the coordinator half.

This grill is therefore mostly **reviewing #7**: `git diff main...sandcastle/issue-7`, host gate
`scripts/verify_agent_branch.sh sandcastle/issue-7`. Check whether it:
- really hides the recorder and second lull loop behind `TodoConfirmationFlow`, or only moved code
- merged `isGroundedInTranscript` with `TranscriptExcerpt`'s matching, or left two matchers

## Open questions for the grill (not decided)

1. Is #7's `TodoConfirmationFlow` interface `run(candidates) -> (confirmed, rejected)`, or does
   the coordinator still drive it step by step?
2. One transcript matcher (grounding check + excerpt highlight) or two?
3. Should the todo-answer lull loop use handoff 03's pure lull policy (thresholds `[3,12]` as a
   second table)?
4. Where does the flow get audio from: the shared engine via #10's `AudioCapturing`, or its own?
5. Does the flow write verdicts to `SessionBundle` directly, or return them for the coordinator
   to record?

## Suggested skills

`mattpocock-skills:grilling`, `mattpocock-skills:code-review` against `sandcastle/issue-7`,
`mattpocock-skills:codebase-design`, `mattpocock-skills:tdd` for the pure `TranscriptExcerpt`
cases (off-by-one excerpt windows), then `mattpocock-skills:to-issues` for follow-ups
(`track:ios`).
