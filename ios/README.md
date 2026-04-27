# Voice Diary — iOS app

This directory will contain the Swift 6 / SwiftUI app for iPhone 17 Pro on iOS 26.

**Status:** not yet populated. Implementation starts with milestone M1 in [../DEVELOPMENT.md](../DEVELOPMENT.md#m1--xcode-foundation).

## What lives here (after M1)

- `VoiceDiary.xcodeproj` — Xcode project.
- `Sources/` — Swift sources organised by feature area (Capture, TTS, Dialog, Backend, Models, UI, Storage, Widget).
- `Resources/Models/` — bundled Parakeet v3 STT model + Piper voice models (German + English) + espeak-ng data.
- `Tests/` — unit and integration test targets.

## What to read before editing anything here

1. [../SPEC.md](../SPEC.md) — full spec including state machine, manifest schema, opener templates.
2. [../DEVELOPMENT.md §5](../DEVELOPMENT.md#5-ios-track-ios) — project layout and milestone plan.
3. [../CLAUDE.md](../CLAUDE.md) — agent guidance and load-bearing constraints.

## Build & run

After M1 is complete, see DEVELOPMENT.md §5.3.

## Dependencies

Planned (resolved via SwiftPM or binary xcframework):

- `FluidInference/FluidAudio` — Parakeet v3 STT.
- `k2-fsa/sherpa-onnx` — Piper TTS (xcframework).
- Apple Foundation Models (system framework, iOS 26+).
- No MSAL on the phone; all Microsoft Graph access is in `../server/`.
