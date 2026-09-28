# Handoff 04: Wake-word listener

Read [README.md](README.md) first (shared context, vocabulary, process rules).

**2026-09-23 strength:** Worth exploring. **Dependency category:** true external (SFSpeech,
FluidAudio Parakeet, both on-device) behind the existing `StreamingASR` protocol (2 adapters).

## The candidate in one line

Extract the wake-word listen window into a **WakeWordListener** module:
`listen(language:phrases:timeout:) async -> (Action, trimSpan)?`. The coordinator keeps ~30 lines
that only dispatch the Action.

## Friction found (as of `7ad3de1`)

- `runWakeWordWindow` (`WalkthroughCoordinator.swift` ~4562-4806, ~250 lines; the whole
  wake-word section spans ~4516-4845). It mixes pure listening with coordinator concerns:
  - it picks `AppleStreamingRecognizer` vs `FluidAudioStreaming` by language (~4617-4637)
  - it wires the detector and audio sink
  - it races the 8 s / 15 s timeouts
  - it plays the ping and haptic
  - it keeps trim bookkeeping (~4770-4780) and dispatches actions (~4781)
- **Sink leak:** `AudioEngine.setWakeWordSink` is a third audio channel that the coordinator
  wires directly.
- **Shared state:** trim uses `silenceRunStartedAt` / `segmentRecordingStartedAt`, which are
  shared with the lull logic (handoff 03). `wakeWordTask` is cancelled from 6+ places.
- `WakeWordDetector` (`Capture/WakeWordDetector.swift`, 223 lines) is pure
  (`consume(partial:)` plus a callback), well shaped, and **untested**.
- **The trim rule is load-bearing.** SPEC §7 and §7.4, plus CLAUDE.md constraint 1: audio is
  never chopped *except* the advance/finish command word at a lull. Memory:
  "walkthrough wake-word trim & silent path". The listener must return the span; it must not
  decide the trim policy on its own. That is a question below.

## Overlapping issues

- #10 (IOS-A14) introduces an `AudioCapturing` protocol for test seams. It's implemented on
  `sandcastle/issue-10` and awaiting host verify. How the listener gets audio frames depends on
  that seam, so review #10's shape first.
- #25 (SEC-7): log the spoken command token as `.private`. It touches the same code; check
  whether it has landed.
- #46 (SessionBundle) takes `currentRecordingSegmentID` out of the coordinator. Trim bookkeeping
  references it.

## Open questions for the grill (not decided)

1. Interface: does it return `(Action, trimSpan)`, or apply the trim itself? SPEC §7.4 suggests
   the coordinator (or SessionBundle) owns the policy.
2. Does ASR backend choice by language live inside the listener, or is it injected?
3. Ping and haptic: inside the listener (part of "listening") or a caller callback?
4. How does it receive frames: via #10's `AudioCapturing`, or a dedicated sink parameter?
5. Test surface: scripted partial transcripts through a fake `StreamingASR`, plus the untested
   `WakeWordDetector`?
6. Does enrichment's wake path ("hey voice diary", SPEC §7) use the same listener as the
   advance/finish commands?

## Suggested skills

`mattpocock-skills:grilling`, `mattpocock-skills:codebase-design`,
`mattpocock-skills:domain-modeling` ("command word" vs "wake word" vs "enrichment trigger" need
precise `CONTEXT.md` terms), then `mattpocock-skills:to-issues` (`track:ios`).
