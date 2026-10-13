# iOS feature map

User-facing maps for the `verify-ios` skill (`.claude/skills/verify-ios/SKILL.md`). Each file says how a state is
reached on a throwaway iPhone 17 simulator (`vd-verify-ios`), what proves it, and what only a device can check.

| Feature | Where in the app | Reached with `simctl` | Mapped from |
|---|---|---|---|
| [first-launch](first-launch.md) | system prompts over the Evening tab | yes (launch) | `Permissions.swift`, `CaptureNotifications.swift` |
| [evening-walkthrough](evening-walkthrough.md) | Evening tab (default) | launch only | `Walkthrough/WalkthroughView.swift` |
| [recording](recording.md) | Recording tab | no (tap) | `DriveBy/CaptureView.swift` |
| [history](history.md) | History tab | no (tap) | `Verlauf/VerlaufView.swift` |
| [more-settings](more-settings.md) | More tab, appearance, language | appearance only | `VoiceDiaryApp.swift` (`MehrView`), `Settings/` |

## Ground rules

- The real app runs; nothing in `ios/Sources/` is changed, mocked or launched with a debug flag.
- `simctl` cannot tap, type or swipe. A "(tap)" state is documented so a person (or a future UI
  test) can reach it, but this skill never claims it as verified.
- Evidence for a run lives in `features/evidence/ios-<run>/` (git-ignored). Screenshots worth
  keeping are copied to `docs/screenshots/<KEY>/` and committed on purpose.
- A state that is not in the table is not verified by this skill.

## Device-only (not covered here)

These need a real iPhone 17 Pro and are checked from the manual plan in `ios/README.md` and
SPEC §15, not by this skill:

- microphone capture, AAC file output, background audio and interruptions;
- wake-word listening ("weiter / nächstes / fertig") and the speech recognizer;
- on-device models: Parakeet (~1.2 GB download), Apple Foundation Models, Gemma 4 E4B;
- Piper voices (the simulator build has the `PIPER_TTS` stub, `project-piper.yml` is `{}`);
- Action Button, lock-screen widget, Live Activity, haptics;
- upload to the real server over Tailscale (see `features/verify-server/` for the server side).
