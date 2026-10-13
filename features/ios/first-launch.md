# Feature: first-launch

Source: `ios/Sources/App/Permissions.swift`, `ios/Sources/Capture/CaptureNotifications.swift`,
`.task` in `ios/Sources/App/VoiceDiaryApp.swift`.

On a fresh install the app asks for permissions at launch, up front: notifications first
(`requestAuthorisationIfNeeded`), then microphone, then speech recognition
(`requestStartupPermissions`).

## Drive

Install and launch steps from SKILL.md. Reached with `simctl` only as far as the first prompt:

1. `simctl privacy … grant microphone` skips the microphone prompt.
2. Notifications and speech recognition cannot be pre-granted from the CLI, and answering them
   needs a tap (manual). Until answered, the notification prompt stays on screen.

## Expected

- The system alert `"Voice Diary" Would Like to Send You Notifications` with *Don't Allow* /
  *Allow*, over the app: the bottom tab bar (Evening selected, Recording, History, More) is
  visible behind it.
- Light and dark appearance both render the alert and tab bar in matching colors.
- No crash dialog; the process stays running (`simctl launch` printed a pid).

## Side effects

The permission answers live in the simulator, not the repo. Deleting the throwaway simulator
(Cleanup) removes them, so every run starts at this prompt again. Do not reuse a shared
simulator: SpringBoard alerts survive `simctl uninstall`.

## Evidence

`evening-first-launch-light.png` and `evening-first-launch-dark.png` (KA-9 retained them in
`docs/screenshots/KA-9/`), `launch.txt`, `xcodebuild-test.log`.

## Device-only

Microphone and speech prompts on a real device; the German permission strings
(`Resources/InfoPlist.xcstrings`) follow the device language, check them on a German device.
