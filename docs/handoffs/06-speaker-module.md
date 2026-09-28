# Handoff 06: Speaker module for TTS

Read [README.md](README.md) first (shared context, vocabulary, process rules).

**2026-09-23 strength:** Speculative. The review recommended doing it **as part of 02 (opener
prefetch)** rather than alone. **Dependency category:** local-substitutable (`TTSEngine`,
3 adapters).

## The candidate in one line

Add a **Speaker** module on top of the existing `TTSEngine` seam that owns *which engine is
active* and *the speaking state*: `speak(script)`, `play(prefetched)`, `cancelAll()`, and an
`isSpeaking` stream.

## Friction found (as of `7ad3de1`)

- The `TTSEngine` seam is real, with 3 adapters: `AppleSpeechTTS`, `PiperTTS`, `VoxtralTTS`.
  Selection goes through `VoiceRegistry.engine(for:)` (`TTS/VoiceRegistry.swift` ~25-34).
  Fallback policy is centralised and pure (`TTSFallbackPolicy.decide`) and **wired**; IOS-A11 in
  the 2026-07-04 review was false.
- **The top of the seam is shallow.**
  - The coordinator's `cancelTTS` (~4508) must name all three concrete singletons
    (`AppleSpeechTTS/PiperTTS/VoxtralTTS.shared`, cancelled at ~4509-4511), because nothing tracks
    which engine is speaking.
  - `speak(_:language:)` (~3982), `speak(script:)` (~4002) and `speakOpenerScript` (~4124) each
    re-implement the `isSpeaking` / `silenceLevel` / `interruptInFlight` span loop.
- **Bypasses:** `VoiceSettingsView` (~395, ~403) skips the registry for previews. `WakePing` and
  `SegmentPlayer` are further audio outputs outside the seam.
- **Size:** ~150 lines would leave the coordinator.
- `VoxtralTTS` has a pre-flight warning path (`voxtralPreflightWarning`) and applies the fallback
  itself (~174-182, calling `PiperTTS.shared` / `AppleSpeechTTS.shared` directly).

## Overlapping issues

- #41 (DOC-7): remove the stale Slice-05 `TTSFallbackPolicy` comment in `VoiceRegistry`. Trivial;
  check whether it has landed.
- #5 (opener prefetch, on `sandcastle/issue-5`) owns `TTSEngine.prefetch` calls. If Speaker
  owns `play(prefetched)`, the two modules meet exactly there.

## Open questions for the grill (not decided)

1. Fold into 02/#5 (one module that prepares *and* plays openers), or a separate Speaker module
   that 02 uses?
2. Does Speaker own fallback (move it out of `VoxtralTTS`), or keep fallback per adapter?
3. Are `WakePing` / `SegmentPlayer` / settings previews in scope ("all audio output goes through
   Speaker") or not?
4. How is state exposed: `isSpeaking` / `silenceLevel` as an observable stream the coordinator
   and UI subscribe to, or callbacks?
5. Interrupt semantics: the coordinator today doesn't cut the AI off mid-word when the user
   resumes speaking. Does `cancelAll()` keep that behaviour, or is it a separate call?

## Suggested skills

`mattpocock-skills:grilling` (probably in the same session as handoff 02),
`mattpocock-skills:codebase-design` ("one adapter = hypothetical seam, two = real" applies to the
fallback question), then `mattpocock-skills:to-issues` (`track:ios`).
