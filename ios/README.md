# Voice Diary — iOS

Swift 6 / SwiftUI app for iPhone 17 Pro on iOS 26. The Xcode project is **generated** from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `VoiceDiary.xcodeproj` is gitignored.

## Status

The app and its widget extension are implemented in source. This section lists what the code
provides; it does not claim on-device validation or that every milestone is complete. Trust
`git log` and `ios/Sources/` for details.

**Implemented in source** (targets from `project.yml`: `VoiceDiary`, `VoiceDiaryWidget`,
`VoiceDiaryTests`):

- **Capture.** `AudioEngine` and `M4AWriter` record drive-by notes; `CaptureCoordinator` stores them
  and transcribes them on-device through `ParakeetManager` (FluidAudio Parakeet v3, batch
  `transcribe(audioURL:)`).
- **Backend bridge.** `ServerClient` (multipart upload with bearer auth, `/health`, calendar),
  `SessionUploader` (persistent FIFO queue, backoff 1/2/4/8/30/60/600 s), `Reachability`, and
  Keychain storage.
- **Walkthrough.** `WalkthroughCoordinator` runs the evening walkthrough from a plan of ordered
  sections, with dialog backends in `Sources/Dialog/` (Apple Foundation Models by default,
  Gemma 4 E4B opt-in) and wake-word steering through `StreamingASR`.
- **TTS.** `VoiceRegistry` picks the engine per language: `VoxtralTTS` (server-mediated), `PiperTTS`
  (on-device, when its assets are installed) or `AppleSpeechTTS` (default and fallback).
- **Drive-by surfaces.** `VoiceDiaryAppShortcuts` / `CaptureThoughtIntent` (App Shortcuts and Action
  Button), and in the `VoiceDiaryWidget` extension a lock-screen widget
  (`LockScreenCaptureWidget`) and a Live Activity (`CaptureLiveActivity`).
- **App UI.** First-run onboarding gate, Verlauf history, and settings screens; English and German
  localization.

**Still needed before these are usable or validated:**

- **Parakeet model.** `ParakeetManager` downloads the ~1.2 GB model on first use; until that
  succeeds, a note is saved without an on-device transcript and the server's Whisper sidecar
  transcribes the upload.
- **Piper voices.** `PiperTTS` is a no-op stub until `scripts/fetch_piper_voices.sh` has run and the
  project is regenerated; `VoiceRegistry` falls back to `AppleSpeechTTS` meanwhile.
- **Hardware.** Nothing here records device validation. The widget, Live Activity, Action Button
  binding, lock-screen behaviour and wake-word steering need a physical iPhone; use the manual
  test plan below.

---

## First-time setup

### 1. Tooling

```bash
brew install xcodegen
```

Xcode 16.2+ with the iOS 26 SDK is required. Sign in to Xcode with the Apple Developer account that holds the device's provisioning profile.

### 2. Generate the Xcode project

```bash
cd ios
xcodegen generate
open VoiceDiary.xcodeproj
```

`xcodegen generate` is **idempotent** — re-run it any time `project.yml` or the `Sources/` layout changes. The generated project is gitignored.

### 3. Signing

In Xcode → *VoiceDiary target* → *Signing & Capabilities*:

- Team: your Apple Developer team.
- Bundle Identifier: leave as `com.tomorrowflow.voice-diary` or change to your own — must match a provisioning profile your team owns.
- App Groups: `group.com.tomorrowflow.voice-diary` (created on first signing if it doesn't exist).
- Capabilities already set in `Config/VoiceDiary.entitlements`: App Groups. Microphone + Background Audio are picked up from `project.yml` `info` block.

### 4. Build + run on device

```bash
# from this directory
xcodebuild -scheme VoiceDiary -destination 'platform=iOS,name=Lukas iPhone' build
```

Or just press ▶ in Xcode. On first launch the onboarding gate asks for the server first; the system permission dialogs appear only after you tap Continue on the permission-priming screen.

---

## Configure server access

The app stores the Tailscale URL + bearer token in Keychain. First launch shows a reduced onboarding gate (server setup, then permission priming); the full SPEC §14 flow was intentionally dropped. To change the server later:

1. Launch the app → *More* → *Server*.
2. Paste the Tailscale URL of your `server/` deployment, e.g. `http://my-server.tailnet.ts.net:8000`.
3. Paste the value of `IOS_BEARER_TOKEN` from `server/.env` (see `server/README.md` step 5 for how to issue one).
4. Tap *Speichern*. The status row then shows `ok (6 upstream)` if `/health` reports healthy.

The bearer token is stored under service `com.tomorrowflow.voice-diary.backend` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Rotation: paste a new value and tap *Speichern* — old tokens are rejected by the server immediately.

---

## Manual test plan against a live server

Run these scenarios after every iOS or server change. They cover what M3 needs to be considered solid.

### 1. Reachability

- *More* → *Server* → *Server prüfen*. Expect `ok (6 upstream)`.
- Stop the Whisper sidecar on the host (`docker compose stop whisper`) → tap again → expect `degraded: whisper=down`.
- Bring it back up → expect `ok` again.

### 2. Synthetic upload

- *Test-Upload* tab → *Synthetik-Upload starten*.
- Speak for 5 s in German.
- Within ~10 s the status text reads `OK — <session_id>` and the response box shows `s01: processed (transcript <id>)` (or `pending_analysis` if Ollama/LightRAG is down).
- On the server, check:
  ```bash
  ls server/data/sessions/    # the session_id directory should exist
  docker compose logs webapp | jq 'select(.session_id != null)' | tail -20
  ```

### 3. Offline retry

- Turn off Tailscale on the iPhone.
- Run a synthetic upload — expect `Direkter Upload fehlgeschlagen — in der Queue.`
- Turn Tailscale back on, tap *Queue erneut versuchen* on the same screen. The queued upload completes.

### 4. Drive-by recording

- *Aufnahme* tab → tap the mic.
- Speak. Counter ticks. Tap stop.
- Use Xcode → *Window* → *Devices and Simulators* → select the iPhone → *Voice Diary* → *Download Container* to inspect `Application Support/VoiceDiary/driveby_seeds/<timestamp>/audio.m4a`.
- Open the M4A in QuickTime Player on Mac to confirm it plays at expected pitch.

---

## Linting

SwiftLint (`brew install swiftlint`; validated with 0.65.1) lints the hand-written Swift under
`ios/`. Config: `../.swiftlint.yml` (repo root). Lint-only: nothing here runs `--fix` or reformats.

```bash
# from the repo root
swiftlint lint --strict
```

- **Why SwiftLint, not swift-format:** rule-based lint can be turned on conservatively, one
  correctness rule at a time, without forcing a formatting sweep over existing code.
- **Rule choices:** `only_rules` is an explicit allowlist (20 rules). SwiftLint's default and opt-in
  sets are off. Enabled: unsafe constructs (`force_cast`, `force_try`); likely bugs
  (`duplicate_conditions`, `duplicate_enum_cases`, `duplicate_imports`, `empty_enum_arguments`,
  `no_fallthrough_only`, `unavailable_condition`, `unused_optional_binding`, `unused_setter_value`,
  `unneeded_override`, `private_unit_test`, `xctfail_message`); dead or noisy code
  (`redundant_discardable_let`, `orphaned_doc_comment`, `invalid_swiftlint_command`,
  `legacy_cggeometry_functions`, `legacy_constructor`, `trailing_semicolon`, `void_return`).
  No formatting, naming, or size rules (`line_length`, `file_length`, `identifier_name`,
  `trailing_whitespace`, ...). Add rules deliberately, one at a time.
- **Scope:** `ios/` (102 Swift files). Excluded: the three generated design-system files
  (`DSColor.swift`, `DSMetrics.swift`, `DSSemantic.swift`, written by
  `scripts/build_design_system.sh`), the gitignored `Sources/TTS/Vendor` and `Frameworks`, and
  build output.
- **Baseline:** `swiftlint lint --strict` is clean across the hand-written sources. The three
  original `force_try` violations in `Sources/Dialog/TodoExtractor.swift` were fixed in KA-6. No
  `disabled_rules` and no per-file disables hide anything.


---

## Layout

```
ios/
├── README.md                     (this file)
├── project.yml                   XcodeGen spec (VoiceDiary, VoiceDiaryWidget, VoiceDiaryTests)
├── Package.swift                 SwiftPM (FluidAudio dep)
├── Config/                       Info.plist, VoiceDiary.entitlements
├── Sources/                      app target (+ Shared and DesignSystem, also built into the widget)
│   ├── App/                      app entry, RootView, permissions
│   ├── Backend/                  ServerClient, SessionUploader, Reachability, KeychainStore, failure copy
│   ├── Capture/                  AudioEngine, M4AWriter, ParakeetManager, CaptureCoordinator, wake word, Live Activity hub
│   ├── Dialog/                   WalkthroughCoordinator, dialog LLMs (Apple FM, Gemma), todo extraction, opener prefetch
│   ├── TTS/                      TTSEngine, VoiceRegistry, AppleSpeechTTS, PiperTTS, VoxtralTTS
│   ├── Intents/                  VoiceDiaryAppShortcuts (main app only)
│   ├── Shared/                   CaptureThoughtIntent, CaptureActivityAttributes, App Group helpers
│   ├── DesignSystem/             Theme and design tokens
│   ├── Localization/             AppLanguage, language preferences
│   ├── Models/                   Manifest, DriveBySeed, CalendarEvent
│   ├── Storage/                  LocalStore, SessionHistoryStore, AudioMerger, ShareStaging
│   └── UI/                       Chrome, DriveBy, Onboarding, Settings, Verlauf, Walkthrough
├── WidgetExtension/              VoiceDiaryWidget: LockScreenCaptureWidget, CaptureLiveActivity
├── Resources/                    fonts, asset catalog, string catalogs; Models/Voices/ is created by the Piper script
├── scripts/                      fetch_piper_voices.sh, run_on_device.sh, build_app_icon.swift
└── Tests/                        VoiceDiaryTests unit tests
```

---

## Deferred bits

- **Full SPEC §14 onboarding (Tailscale check, Action Button binding, voice preview).** Intentionally dropped; the reduced first-run gate (server setup + permission priming) is what shipped. `OnboardingFlowView` contains none of those three steps.
- **`URLSessionConfiguration.background`** so uploads survive app suspension. `ServerClient` still uses `URLSessionConfiguration.default`, which is fine for foreground-only dogfooding. Not tied to a milestone.

The Parakeet model download, the Piper bootstrap and device validation are install-time and hardware prerequisites, not deferred code. They are listed under *Status*.
