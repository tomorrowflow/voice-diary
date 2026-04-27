# Voice Diary — iOS

Swift 6 / SwiftUI app for iPhone 17 Pro on iOS 26. The Xcode project is **generated** from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `VoiceDiary.xcodeproj` is gitignored.

## Status

| Milestone | What's in this commit |
|---|---|
| M1 — Xcode foundation | ✅ project.yml, Package.swift, entitlements, scaffolding |
| M2 — Drive-by capture MVP | ⚪ partial: real `AudioEngine` + `M4AWriter`, in-app record button, on-device file write. `ParakeetManager` is a stub — the server's Whisper sidecar re-transcribes. |
| M3 — Backend bridge | ✅ `ServerClient` (multipart upload + bearer auth), `SessionUploader` (persistent FIFO queue, exp. backoff 1/2/4/8/30/60/600 s), `Reachability` (probes `/health`), Keychain storage, debug screens. |
| M4 — Drive-by surfaces | ⚪ parked — WidgetKit, ActivityKit, App Intents come next cycle |
| M5–M12 | ⚪ parked |

The current build supports the **dogfoodable loop**: tap *Test-Upload* → record 5 s → upload to your server over Tailscale → see the segment processed end-to-end (Whisper → entity_detector → document_processor → LightRAG).

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
xcodebuild -scheme VoiceDiary -destination 'platform=iOS,name=Florian iPhone' build
```

Or just press ▶ in Xcode. On first launch you'll get the microphone-permission prompt.

---

## Configure server access

The app stores the Tailscale URL + bearer token in Keychain. There is **no production onboarding yet** — that lands in M11. For now:

1. Launch the app → *Server* tab.
2. Paste the Tailscale URL of your `server/` deployment, e.g. `http://my-server.tailnet.ts.net:8000`.
3. Paste the value of `IOS_BEARER_TOKEN` from `server/.env` (see `server/README.md` step 5 for how to issue one).
4. Tap *Speichern*. The status row then shows `ok (6 upstream)` if `/health` reports healthy.

The bearer token is stored under service `com.tomorrowflow.voice-diary.backend` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Rotation: paste a new value and tap *Speichern* — old tokens are rejected by the server immediately.

---

## Manual test plan against a live server

Run these scenarios after every iOS or server change. They cover what M3 needs to be considered solid.

### 1. Reachability

- *Server* tab → *Server prüfen*. Expect `ok (6 upstream)`.
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

## Layout

```
ios/
├── README.md                     (this file)
├── project.yml                   XcodeGen spec
├── Package.swift                 SwiftPM (FluidAudio dep)
├── Config/
│   ├── Info.plist
│   └── VoiceDiary.entitlements
├── Sources/
│   ├── App/
│   │   └── VoiceDiaryApp.swift   App entry + RootView (TabView)
│   ├── Backend/
│   │   ├── KeychainStore.swift
│   │   ├── ServerClient.swift    multipart upload, /health, /today/calendar
│   │   ├── SessionUploader.swift persistent FIFO + exp. backoff
│   │   └── Reachability.swift    /health probe + NWPathMonitor
│   ├── Capture/
│   │   ├── AudioEngine.swift     AVAudioEngine dual sink
│   │   ├── M4AWriter.swift       AAC-LC 16 kHz mono 64 kbps CBR
│   │   └── ParakeetManager.swift FluidAudio stub (M2 final pass)
│   ├── Models/
│   │   ├── Manifest.swift        SPEC §10.3 — segments + todos + ai_prompts
│   │   └── DriveBySeed.swift
│   ├── Storage/
│   │   └── LocalStore.swift      Application Support paths
│   ├── UI/
│   │   ├── DriveBy/CaptureView.swift
│   │   └── Settings/
│   │       ├── DebugSettingsView.swift   server URL + bearer paste
│   │       └── DebugUploadView.swift     synthetic-session uploader
│   ├── TTS/                      placeholder — M5
│   ├── Dialog/                   placeholder — M5/M6/M7
│   └── Widget/                   placeholder — M4
├── Resources/
│   └── Models/                   Piper voice models go here (M5)
└── Tests/
    └── ManifestTests.swift       round-trip JSON
```

---

## Deferred bits (for future cycles)

- **FluidAudio Parakeet model bundle.** `ParakeetManager` returns placeholder text right now. The dependency is in `Package.swift`; M2's final pass downloads the model on first launch (or bundles it under `Resources/Models/`) and wires `feed(buffer:)` into `AudioEngine`'s streaming sink.
- **sherpa-onnx xcframework + Piper voices.** Deferred to M5 alongside the walkthrough state machine. Drop the xcframework into `Resources/` (or add via Xcode → *Add Files*), then place `de_DE-thorsten-high.onnx`/`.json` and `en_US-lessac-high.onnx`/`.json` plus the espeak-ng data dir under `Resources/Models/`.
- **App Intents + Action Button + WidgetKit + ActivityKit.** Deferred to M4.
- **Walkthrough state machine + Apple FM dialog + wake-word + multilingual TTS.** Deferred to M5–M9.
- **Production onboarding (Tailscale check, Action Button binding, voice preview).** Deferred to M11.
- **`URLSessionConfiguration.background`** so uploads survive app suspension. Currently using the default config — fine for foreground-only dogfooding. Switch in M11.

Each item maps 1:1 to a story in `.planning/stories/`.
