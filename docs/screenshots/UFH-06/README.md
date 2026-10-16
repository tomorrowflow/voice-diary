# UFH-06 proof screenshots

Real screenshots (`xcrun simctl io <device> screenshot`) of the running app on a throwaway
iPhone 17 simulator (iOS 27). App language was switched in the app and appearance with
`simctl ui <device> appearance`.

## Captured

The coded cards were produced against a local stub that answers `GET /today/calendar` with
503 `msgraph_unavailable` (`retryable: true`), 503 `msgraph_not_bootstrapped`
(`retryable: false`), or the retryable 503 after a 15 s wait. The server URL was changed
between states in More → Server. The app was an ad-hoc signed build for the proof only
(`CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=`),
because the unsigned simulator build cannot write the Keychain (`-34018`).

| Files | State |
|---|---|
| `retryable-{en,de}-{light,dark}.png` | Coded retryable card: **Try again** is the dark (primary) button, **Start without calendar** is secondary; the hint wraps. |
| `not-bootstrapped-{en,de}-{light,dark}.png` | Coded not-bootstrapped card: **Start without calendar** is the dark (primary) button, **Try again** is secondary; the hint says once that the sign-in has to be completed on the server, and wraps in English and German. |
| `spinner-{en,de}-{light,dark}.png` | **Try again** pressed while the fetch is pending: the button shows a spinner and "Loading…" / "Lade …", and **Start without calendar** is disabled. |
| `card-{en,de}-{light,dark}.png` | The uncoded `notConfigured` card (no server set): its title and hint are German in both languages. |
| `walkthrough-{en,de}-{light,dark}.png` | The walkthrough running after **Start without calendar**: no calendar events, then the voice-note closing section "Day close" (DE: *Tagesabschluss*). |
| `done-de-{light,dark}.png` | The calendar-free session finishing: "Session saved." The bundle is built; with no server configured it stays queued and does not upload. |
| `resume-calendar-free-en-{light,dark}.png` | *Pick up* on an unfinished session that was started without the calendar: it goes straight back into the walkthrough, with no calendar fetch and no card. |

## Not captured

- **Retry-only resume card** (*Pick up* on an unfinished session started *with* the calendar,
  calendar down: the card with **Try again** only). It needs an unfinished session that has
  recorded audio but no `calendar_free` marker. The stub never answers 200, so such a session
  cannot be started; the only route is to record a calendar-free session and delete its
  `calendar_free` file from the simulator's app container, and this node's path guard blocked
  reading or deleting files in the simulator container (outside the worktree). Not worked around.
- **PRD scenario 3 on a physical device** is left for the operator.
