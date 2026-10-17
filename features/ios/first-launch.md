# Feature: first-launch

Source: `ios/Sources/UI/Onboarding/OnboardingFlowView.swift` (`PermissionPrimingView`),
`ios/Sources/UI/Onboarding/OnboardingGate.swift`, `ios/Sources/App/Permissions.swift`,
`RootView` in `ios/Sources/App/VoiceDiaryApp.swift`.

Nothing asks for permissions at launch. A fresh install shows the Server step first, then a
Permissions screen that explains microphone, speech recognition and notifications. The system
dialogs appear one after the other only when the user taps **Continue** there
(`Permissions.requestUndecided`). A returning user whose permissions are all answered never sees
the screen; a reinstall that kept the Keychain (server already set up) sees the Permissions
screen alone.

## Drive

Install and launch steps from SKILL.md, then:

1. Launch: the Server screen shows with no system alert over it.
2. Save a URL and token against the stub, tap **Continue**: the Permissions screen shows.
   (iOS may raise a "Save Password?" sheet over it from the token field: tap **Not Now**.)
3. Tap **Continue**: the microphone, speech recognition and notification alerts follow;
   answer each with `idb` (`simctl privacy … grant microphone` skips the first).
4. `simctl terminate` + `simctl launch`: the app opens on the Evening tab with no alert.

## Expected

- No system alert before the tap on the Permissions screen's **Continue**.
- Three cards (Microphone, Speech recognition, Notifications), light and dark.
- After the last alert the Evening tab shows, and stays the first screen on relaunch.

## Side effects

The permission answers live in the simulator, not the repo. Deleting the throwaway simulator
(Cleanup) removes them, so every run starts at the first-run flow again. Do not reuse a shared
simulator: SpringBoard alerts survive `simctl uninstall`.

## Evidence

`docs/screenshots/UX-6a/` holds the retained captures; `launch.txt`, `xcodebuild-test.log`.

## Device-only

Microphone and speech prompts on a real device; the German permission strings
(`Resources/InfoPlist.xcstrings`) follow the device language, check them on a German device.
