# 04 · Opener prefetch through Voxtral

Labels: needs-triage, type/performance, area/tts, area/ios, area/walkthrough
Type: AFK

## Parent

[Voxtral TTS Integration PRD](../../prd/voxtral-tts-integration.md)

## What to build

Hide the Tailscale round-trip and the Voxtral synthesis cost behind the user's prior turn by wiring `VoxtralTTS.prefetch()` into the existing opener prefetch path that already hides Piper's 400-800 ms synthesis cost. The walkthrough kicks off the next opener prefetch as soon as the user's current listen window closes; when the next opener actually needs to speak, `speakOpenerScript()` consumes the cached WAV identically to how it consumes a Piper prefetch today.

The goal is parity with the Piper-baseline cadence on home Wi-Fi: the user should not be able to tell from latency alone whether they are on Piper or Voxtral.

## Acceptance criteria

- [ ] `VoxtralTTS.prefetch(text, language)` performs the synthesis off the critical path, writes the WAV to `FileManager.temporaryDirectory`, and returns a `PrefetchedUtterance` with `audioURL` set.
- [ ] `speakOpenerScript()` (and the multi-span variant) consume a Voxtral `PrefetchedUtterance` via the existing `engine.play(utt)` call, with no special-casing for Voxtral.
- [ ] If a prefetch is stale (voice was changed mid-session between prefetch and play), the existing auto-promotion to a fresh `speak()` call works for Voxtral exactly as it does for Piper.
- [ ] Prefetched WAVs are deleted from `FileManager.temporaryDirectory` after playback completes or is cancelled, matching the Piper cleanup pattern.
- [ ] A three-event walkthrough with Voxtral selected for DE on home Wi-Fi has no audible stall between the end of the user's input and the start of the next opener vs. a comparison run on Piper.
- [ ] An opener triggered without a prefetch (e.g. first opener at session start before any prefetch has had time) still plays correctly — it just pays the full synthesis latency.

## Blocked by

- [03 · Voxtral in the live walkthrough](./03-walkthrough-integration.md)
