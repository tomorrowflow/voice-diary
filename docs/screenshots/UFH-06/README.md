# UFH-06 proof screenshots: not captured on the node

No screenshots are committed for UFH-06. The five states below can only be reached by
tapping, and the node that runs `verify-ios` cannot tap. This file says exactly why and what a
person or device run has to capture.

## Why the node cannot drive them

- **No tap input.** `xcrun simctl` has no tap, type or swipe command. `idb` and `cliclick` are not
  installed, AppleScript is not allowed in the agent sandbox (`.claude/skills/verify-ios/SKILL.md`,
  Rules), and the project has no UI-test target.
- **"Start session" is disabled until the speech model has loaded.** The calendar fetch only runs
  after the tap. The button stays disabled while `ParakeetManager` (`ios/Sources/Capture/ParakeetManager.swift`)
  downloads and loads its ~1.2 GB model (`WalkthroughView.isModelReady`).
- **The server comes from the Keychain.** `ServerClient.config()` reads URL and bearer token from
  `KeychainStore`; they cannot be passed as a launch argument, so the app needs the Settings screen
  (taps and typing) and a server whose `/today/calendar` answers 503.
- **A real launch only shows the first-launch Server screen** under the system notification
  prompt (`features/ios/first-launch.md`), not any state this ticket changed.

`ImageRenderer` renders are not evidence (board reference), so none are committed.

## What to capture (device or simulator, with a person tapping)

Point the app at a server whose `GET /today/calendar` returns 503 with `code: msgraph_unavailable`
(retryable), then with `code: msgraph_not_bootstrapped` (`retryable: false`). Take real screenshots
(`xcrun simctl io <device> screenshot`, or the device screenshot), light and dark, German and English:

1. Calendar card, retryable: **Try again** is the dark button, **Start without calendar** is secondary.
2. Calendar card, not bootstrapped: **Start without calendar** is the dark button; the text says once
   that the server has to be set up. Check that the English hint wraps and nothing is cut off.
3. Retry spinner: tap **Try again** while the server is slow; both buttons are disabled.
4. After **Start without calendar**: the walkthrough opens on a general section (no calendar events).
5. Resume with Graph down (*Pick up where you left off*): the card shows **Try again** only.

Then run PRD manual scenario 3 on the iPhone 17 Pro: start without the calendar, finish, and
confirm the session uploads with no calendar segment. Commit the images here as the last commit,
`UFH-06: proof screenshots`, and delete this README.
