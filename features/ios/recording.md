# Feature: recording

Source: `ios/Sources/UI/DriveBy/CaptureView.swift`; deep link `voicediary://capture/start|stop|toggle`
handled in `IntentRouter` (`VoiceDiaryApp.swift`), which also switches to this tab.

## Drive

- Not reachable with `simctl`: opening the tab and the record button need taps (manual).
- `xcrun simctl openurl vd-verify-ios "voicediary://capture/start"` is not usable: iOS shows an
  "Open in Voice Diary?" confirmation first (needs a tap) that then stays on that device, seen
  in a KA-9 run.

## Expected (manual)

- Tab **Recording** selected; heading **Quick capture** with "Catch a thought now. It
  resurfaces during this evening's walkthrough."
- A start button (accessibility label "Start recording"); while the speech model is loading the
  screen says "Preparing speech model…" / "Loading speech model — ~1.2 GB". The model download
  needs network and does not work offline.

## Side effects

A recording writes an `.m4a` and metadata into the app container and queues an upload. Cleanup
(deleting the simulator) removes the container.

## Device-only

Everything audio: microphone capture, the live waveform, interruptions, background audio,
Action Button / lock-screen widget starting a capture.
