# Feature: evening-walkthrough

Source: `ios/Sources/UI/Walkthrough/WalkthroughView.swift`, `RootView` in
`ios/Sources/App/VoiceDiaryApp.swift` (the Evening tab is the default, `AppRouter.selectedTab = .abend`).

## Drive

- Launch (SKILL.md → Launch): the app opens on the Evening tab. Reached with `simctl`.
- Not reachable without a tap (manual): *Start session*, the day picker (`<`, `Today`, `>`),
  *Open settings* in the error card.

On a fresh install the first-run Server and Permissions screens come first (`first-launch.md`).

## Expected (once the prompt is answered)

- Large title **Evening**; card "Ready for the evening reflection?" / "We'll walk through the
  day's accepted events in order."; day picker showing **Today**; a *Day overview* section; the
  black **Start session** button above the tab bar.
- With no server configured the day overview shows the app's own error card with an
  *Open settings* button (seen behind the alert in a KA-9 run); that is the real no-server
  state, not a fault.
- Light and dark: backgrounds and text invert through the design tokens, no hard-coded colors.

## Calendar failure at start (UFH-06) — stub and `idb`

Not reachable with `simctl` alone: it needs *Start session* (tap), which stays disabled until the
Parakeet model has loaded (~1.2 GB), and a server URL and bearer token in the Keychain (the
ad-hoc signed build keeps them; SKILL.md → "Why ad-hoc signing"). SKILL.md → Drive → "Reaching
the calendar failure states" does it with `features/verify-ios/stub_server.py` answering
`/today/calendar` and `idb` taps (KA-11 captures: `docs/screenshots/KA-11/`).

The stub answers 503 `msgraph_unavailable` or 503 `msgraph_not_bootstrapped`; wait for the model,
tap *Start session*:

- a card with the diagnosis, **Try again** and **Start without calendar** (DE: *Erneut versuchen*,
  *Ohne Kalender starten*); for not bootstrapped, *Start without calendar* is the dark button;
- **Try again** shows a spinner and disables both buttons while it fetches;
- **Start without calendar** runs general sections and voice notes only, and uploads as usual;
- *Pick up where you left off* with Graph down shows the same card with **Try again** only.

## Side effects

None from viewing. *Start session* starts a recording and talks to the server: drive it only
against the stub on the run's own simulator (SKILL.md → Drive → "Reaching the walkthrough
progress header").

## Evidence

Screenshots in light and dark with the prompt answered (manual), plus `xcodebuild-test.log`
showing the unit suites that cover the walkthrough logic.

## Device-only

Spoken prompts (Piper/AVSpeech), wake-word advance, live transcript, the real calendar from the
server, Live Activity during a session.
