# 06 · Latency measurement & streaming decision

Labels: needs-triage, type/decision, area/tts, area/performance
Type: HITL

## Parent

[Voxtral TTS Integration PRD](../../prd/voxtral-tts-integration.md)

## What to build

Decide whether to invest in vLLM Omni streaming inference for Voxtral, based on real measurements on home Wi-Fi over Tailscale, not on Mistral's H200 benchmarks. The PRD's milestone exit criterion is "median TTFA ≤ 600 ms on home Wi-Fi for an opener of typical length." This slice instruments the iOS engine to record TTFA from the moment `speak()` is invoked to the moment `AVAudioPlayer` produces its first audio frame, runs a small batch of measurements during real walkthroughs, and produces a written decision addendum to the PRD.

HITL because the deliverable is a documented decision (and an optional follow-up issue), not a feature.

## Acceptance criteria

- [ ] `VoxtralTTS` records and logs a TTFA measurement (in milliseconds) for every utterance during this measurement window, behind a debug toggle so it does not pollute production logs by default.
- [ ] At least three full evening walkthroughs are run on home Wi-Fi over Tailscale with Voxtral selected for DE; per-walkthrough median TTFA, p90 TTFA, and total utterance count are recorded.
- [ ] The same three walkthroughs are run with prefetch disabled to isolate the prefetch contribution and quantify the worst-case opener latency.
- [ ] A "Latency & streaming decision" addendum is appended to `docs/prd/voxtral-tts-integration.md` containing: (a) the measurements, (b) a one-paragraph interpretation, (c) one of two outcomes: **(i) "Ship as-is, batch is sufficient"** with the median TTFA quoted, or **(ii) "Open follow-up issue for streaming inference"** with a one-paragraph sketch of what the streaming follow-up would entail.
- [ ] If outcome (ii) is chosen, a new issue file `07-streaming-inference.md` is drafted with a `needs-triage` label and `Blocked by: 06`.
- [ ] The debug toggle that enabled TTFA logging is left in place for future re-measurement but defaults to off.

## Blocked by

- [04 · Opener prefetch through Voxtral](./04-opener-prefetch.md)
