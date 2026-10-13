---
name: verify-ios
description: Build, test and launch the real Voice Diary iOS app on a throwaway iPhone 17 simulator (launch, doctor, drive, evidence, cleanup) and capture light/dark screenshots of the real app screen. Use when an iOS change must be shown working in the running app on a Mac, not just reviewed statically.
---

# verify-ios

Generates the Xcode project with XcodeGen, creates a dedicated **iPhone 17** simulator
(`vd-verify-ios`), runs the unit tests on it, installs and launches the real app, drives what
`simctl` can drive, records evidence under `features/evidence/ios-<run>/`, and cleans up only
what this run created.

The feature map is `features/ios/README.md`; one file per user-facing feature in `features/ios/`.

Needs macOS with Xcode 26+ (the app targets iOS 26), XcodeGen and an iOS 26+ simulator runtime
(`DEVELOPMENT.md` §7.4/§7.5). `xcodebuild` does not run on Linux; there, report the iOS part
as not run.

## Why a dedicated simulator

System alerts live in SpringBoard, not in the app, and they outlive `simctl uninstall`. A shared
`iPhone 17` that someone already used can show a stale alert (an "Open in Voice Diary?" from an
earlier `openurl`, say) over every screenshot, and `simctl` cannot dismiss it. A device created
for the run starts clean, is not shared with other sessions, and is deleted at the end.
Its type is `iPhone 17`, the same as the tests in `DEVELOPMENT.md` §7.4.

## Rules

- **No app behavior change.** Never edit `ios/Sources/` to make a run pass or to get a cleaner
  screenshot. The real prompts, empty states and errors are the evidence.
- **Real screen only.** Screenshots come from `xcrun simctl io <device> screenshot` of the
  running app. SwiftUI previews and `ImageRenderer` renders are not evidence.
- **Only what you started.** Only the artifacts listed in Cleanup are removed. Never run
  `simctl erase`, `simctl delete all`/`unavailable`, `shutdown all`, or touch any other
  simulator or `~/Library/Developer/CoreSimulator`. Do not run `openurl` against a simulator
  you do not intend to delete: the confirmation alert it raises cannot be dismissed.
- **Every command runs from the worktree root**, without `cd` and without `$(...)`/`$?`
  (agent sandboxes reject them). Paths are relative to the root.
- **No secrets.** The app is built unsigned (`CODE_SIGNING_ALLOWED=NO`); no server URL,
  bearer token or Keychain entry is needed or touched.
- `simctl` cannot tap, type or swipe, and nothing on the node can (no `idb`, AppleScript is
  not allowed). A state that needs a tap is *not driven*; it is listed in its feature file as
  manual or device-only. Never claim it as verified.
- Host-only and device-only checks (microphone capture, wake word, Action Button, lock
  screen, Live Activity, on-device models, real server over Tailscale) stay out of this skill.
  They are listed under "Device-only" in `features/ios/README.md`.

## Variables

Pick a run name first and reuse it: `features/evidence/ios-<run>/` (e.g. `ios-run-1`).
The simulator is `vd-verify-ios` (addressed by name). Bundle id: `com.tomorrowflow.voice-diary`.

```bash
mkdir -p features/evidence/ios-<run>
```

## Doctor

Run first; stop and report if any check fails. Nothing here changes state.

```bash
xcodebuild -version > features/evidence/ios-<run>/doctor-xcode.txt 2>&1
```

Must show Xcode 26 or newer.

```bash
xcodegen --version > features/evidence/ios-<run>/doctor-xcodegen.txt 2>&1
```

```bash
xcrun simctl list runtimes available > features/evidence/ios-<run>/doctor-runtimes.txt 2>&1
```

Must list an iOS 26+ runtime; note its identifier (`com.apple.CoreSimulator.SimRuntime.iOS-<major>-<minor>`).

```bash
xcrun simctl list devicetypes iPhone > features/evidence/ios-<run>/doctor-devicetypes.txt 2>&1
```

Must list `iPhone 17 (com.apple.CoreSimulator.SimDeviceType.iPhone-17)`.

```bash
xcrun simctl list devices vd-verify-ios > features/evidence/ios-<run>/doctor-existing-device.txt 2>&1
```

Must list no `vd-verify-ios` device. If one exists, an earlier run did not clean up: do not
reuse or delete it blindly; report it.

Check that no stub of yours will be overwritten. Both commands must fail with `No such file`;
if either exists, a real Piper bootstrap is in place: skip the stub in Launch and do not
delete it in Cleanup.

```bash
ls ios/project-piper.yml
```

```bash
ls ios/Resources/Models
```

## Launch

The Xcode project is generated and `ios/project.yml` includes the gitignored
`project-piper.yml` (normally written by `ios/scripts/fetch_piper_voices.sh`), and
references the gitignored `Resources/Models` folder. Stub both (the node-proven way):

```bash
printf '{}\n' > ios/project-piper.yml
```

```bash
mkdir -p ios/Resources/Models
```

```bash
xcodegen generate --spec ios/project.yml --project ios > features/evidence/ios-<run>/xcodegen.log 2>&1
```

Last line must be `Created project at …/ios/VoiceDiary.xcodeproj`. Create the simulator
(prints its UDID; use the runtime identifier from Doctor), boot it and wait:

```bash
xcrun simctl create vd-verify-ios com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-<major>-<minor> > features/evidence/ios-<run>/device-udid.txt 2>&1
```

```bash
xcrun simctl boot vd-verify-ios
```

```bash
xcrun simctl bootstatus vd-verify-ios -b > features/evidence/ios-<run>/boot.log 2>&1
```

`boot.log` ends with `Finished` (about 30 s for a new device).

Build and run the unit tests. `-skipMacroValidation` is for the MLXHuggingFace package macro;
`CODE_SIGNING_ALLOWED=NO` because `project.yml` pins a personal team; derived data stays in the
git-ignored `ios/DerivedData` so the next run is incremental. The first run resolves Swift
packages and takes several minutes (needs network):

```bash
xcodebuild test -project ios/VoiceDiary.xcodeproj -scheme VoiceDiary -destination 'platform=iOS Simulator,name=vd-verify-ios' -skipMacroValidation -derivedDataPath ios/DerivedData CODE_SIGNING_ALLOWED=NO > features/evidence/ios-<run>/xcodebuild-test.log 2>&1
```

```bash
tail -n 12 features/evidence/ios-<run>/xcodebuild-test.log
```

Must end with `** TEST SUCCEEDED **`; the Swift Testing line reads
`Test run with <n> tests in <m> suites passed`. On failure read the log; do not edit the app.

Install and launch the real app (the test build is already the simulator app):

```bash
xcrun simctl install vd-verify-ios ios/DerivedData/Build/Products/Debug-iphonesimulator/VoiceDiary.app
```

Pre-grant what `simctl` can (microphone only; it terminates the app if running, and it may
fail once right after install: repeat it). Notifications and speech recognition **cannot** be
pre-granted from the CLI:

```bash
xcrun simctl privacy vd-verify-ios grant microphone com.tomorrowflow.voice-diary
```

```bash
xcrun simctl launch vd-verify-ios com.tomorrowflow.voice-diary > features/evidence/ios-<run>/launch.txt 2>&1
```

Prints `com.tomorrowflow.voice-diary: <pid>`. Within about a second the fresh install shows the
system notification prompt over the Evening tab (`features/ios/first-launch.md`). It stays
until someone taps it, and every screenshot taken meanwhile includes it. Taking the shot
faster does not help: the prompt appears before the first app frame.

## Drive

Map of what is reachable, per feature file:

| Feature | Reachable with `simctl` | Needs a tap (manual) |
|---|---|---|
| [first-launch](../ios/first-launch.md) | launch, prompt visible, light/dark | answering the prompts |
| [evening-walkthrough](../ios/evening-walkthrough.md) | default tab on launch | Start session, day picker |
| [recording](../ios/recording.md) | nothing | tab, record button |
| [history](../ios/history.md) | nothing | tab |
| [more-settings](../ios/more-settings.md) | appearance (system-wide) | every row, language toggle |

`simctl openurl voicediary://capture/start` does **not** help: iOS asks "Open in Voice
Diary?" first, which also needs a tap, and the alert then stays on that device. Appearance is
set from the CLI:

```bash
xcrun simctl ui vd-verify-ios appearance dark
```

(`light` to restore.) `xcrun simctl ui vd-verify-ios appearance` with no value prints the
current one; record it before and after.

## Evidence

Screenshots of the real screen, one per appearance, after the state you are mapping is on
screen (wait a few seconds after launch and after switching appearance):

```bash
xcrun simctl io vd-verify-ios screenshot features/evidence/ios-<run>/<state>-light.png
```

```bash
xcrun simctl ui vd-verify-ios appearance dark
```

```bash
xcrun simctl io vd-verify-ios screenshot features/evidence/ios-<run>/<state>-dark.png
```

```bash
xcrun simctl ui vd-verify-ios appearance light
```

**Open both images** (Read tool) and write down what each shows: which tab is selected,
which text, which alert, and whether dark mode really changed the colors. A file that exists
is not proof; a wrong state (blank launch screen, stale alert, crash dialog) means the step
failed.

The app log (os.Logger) can be read with `xcrun simctl spawn vd-verify-ios log show --last 5m
--predicate 'process == "VoiceDiary"' --style compact`; it is noisy (CoreML, network), so
filter on the message you expect, e.g. `eventMessage CONTAINS "Voice Diary ready"`.

Retain proof you want in git by copying it out of the git-ignored evidence directory into
`docs/screenshots/<KEY>/` and committing it as the last commit (`<KEY>: proof screenshots`):

```bash
mkdir -p docs/screenshots/<KEY>
```

```bash
cp features/evidence/ios-<run>/<state>-light.png features/evidence/ios-<run>/<state>-dark.png docs/screenshots/<KEY>/
```

Raw logs stay in `features/evidence/` (git-ignored; `git add -f` only on purpose). The test
log contains absolute local paths; do not commit it.

## Cleanup

Always run it, also after a failed Launch or Drive. It removes only what this run made and
never touches `features/evidence/` or `docs/screenshots/`. Deleting the device also removes
the installed app, its container and every permission answer.

```bash
xcrun simctl terminate vd-verify-ios com.tomorrowflow.voice-diary
```

(`found nothing to terminate` is fine.)

```bash
xcrun simctl shutdown vd-verify-ios
```

```bash
xcrun simctl delete vd-verify-ios
```

Remove the generated project and the stubs (skip the stub lines if Doctor found a real
bootstrap). `rmdir` refuses a non-empty `Models` folder, which is the safety check:

```bash
rm -r ios/VoiceDiary.xcodeproj
```

```bash
rm ios/project-piper.yml
```

```bash
rmdir ios/Resources/Models
```

`ios/DerivedData` (git-ignored, several GB) is kept so the next run is fast; delete it with
`rm -r ios/DerivedData` when the worktree is finished. Then confirm:

```bash
xcrun simctl list devices vd-verify-ios > features/evidence/ios-<run>/post-cleanup-devices.txt 2>&1
```

It must list no `vd-verify-ios`. `git status --short` must show no stub or `ios/` change, and
`ls features/evidence/ios-<run> docs/screenshots/<KEY>` must still list the proof files.

## Adding a feature

Copy a file in `features/ios/`, say how the state is reached (CLI vs tap), what proves it,
and what is device-only; list it in `features/ios/README.md` and in the Drive table above.
If a UI-test target ever lands, it can answer the system prompts and unlock the tap-only
states; update the Drive table then.
