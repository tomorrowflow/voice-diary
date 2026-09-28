# Handoff 03: Walkthrough transitions + lull policy

Read [README.md](README.md) first (shared context, vocabulary, process rules).

**2026-09-23 strength:** Worth exploring. **Dependency category:** in-process.

## The candidate in one line

Give the walkthrough state machine **one transition module**, where teardown-per-state is written
once, and make **lull policy a pure decision function**,
`decide(threshold, heardSpeech, headphones, followUpUsed, …) -> [Effect]`, shared by both lull loops.

## Friction found (as of `7ad3de1`, `ios/Sources/Dialog/`)

- `WalkthroughState.swift` is a data enum only. Its own comment says the transition logic lives
  in the coordinator.
- The coordinator has **29 direct `state =` writes**. Each `run*` method re-checks state after
  every `await` (e.g. `runEvent` ~1818/1834/1845).
- **Teardown is repeated per entry point.** Four `switch state` blocks, in `advance` (~1342),
  `skip` (~1441), `finishCurrentSection` (~1490) and `resume` (~1675), repeat the same
  "opener → `cancelTTS`; listening → `stopSegmentCapture`" preamble.
- `withTransition` (~1331) only centralises the re-entrancy guard. `cancel()` (~1536) and
  `pause()` (~1610) bypass it and hand-roll teardown: wake task, follow-up task, note playback,
  timer, lull detector, todo capture, TTS.
- Pause is an orthogonal flag (`isPaused`, `pausedAtState`) rather than a state.
- **Lull policy is tangled with side effects.** `handleLull` (~2777-3060) encodes a timing table:
  thresholds `[3,6,15,24]` s, pre- vs post-speech, headphones vs speaker, `followUpUsed`. It also
  spawns Tasks and calls `advance()`, so it can't be unit-tested. The todo-answer loop (~3312+)
  re-implements a variant with `[3,12]` on a second `LullDetector`.
- The view pattern-matches raw state in ~8 places (IOS-A10 in `docs/REVIEW-2026-07-04.md`).
- **Suspected race (reported by the explorer, NOT reproduced).** `runEvent` ~1845 does `guard …
  else { return }` *after* `startEventCapture` succeeded. If another chain already moved on, this
  leaves the engine capturing and a staged segment behind, and the next `engine.start` throws
  `alreadyRunning` (`AudioEngine.swift:274`). Verify before designing around it.
- Related memory: the 15 s silent-user lull path and the deliberate command-word trim (SPEC §7.4)
  are intentional behaviour, not bugs.

## Overlapping issues

- #1 (IOS-A1, closed): the god-module umbrella, dropped in the 2026-07-04 grill as too big for one
  slice. This candidate is one of the "sub-machines" it pointed at, alongside FollowUpEngine.
- #46 (SessionBundle) takes `currentRecordingSegmentID` and segment staging out of the
  coordinator. #5 and #7 (branches awaiting host verify) also rewrite this file. Transitions touch
  every one of those paths, so **this candidate should come after them**. Confirm that ordering in
  the grill.

## Open questions for the grill (not decided)

1. Shape: an explicit transition table / reducer, or keep imperative `run*` methods but route
   every state change through one `transition(to:)` that runs `teardown(from:)`?
2. Should pause become a real state (`paused(from:)`) instead of a flag?
3. Lull policy: one pure function for both loops (walkthrough `[3,6,15,24]` and todo-answer
   `[3,12]`), or two tables behind one decision interface?
4. Which effects exist (speak follow-up, offer continue, advance, stop capture…), and who executes
   them?
5. Reproduce the ~1845 race first? It decides whether this is a bug fix or a refactor.
6. Test surface: the lull table as unit tests; transitions via a fake engine/TTS (#10's
   `AudioCapturing` seam)?

## Suggested skills

`mattpocock-skills:grilling`, `mattpocock-skills:prototype` (a throwaway state-model prototype is
a good fit for Q1/Q2), `mattpocock-skills:diagnosing-bugs` for the suspected race,
`mattpocock-skills:codebase-design`, then `mattpocock-skills:to-issues` (`track:ios`).
