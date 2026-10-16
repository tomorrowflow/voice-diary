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
| `retryable-{en,de}-{light,dark}.png` | Coded retryable card: **Try again** is the filled (primary) button, **Start without calendar** is the outlined secondary one; the hint wraps. |
| `not-bootstrapped-{en,de}-{light,dark}.png` | Coded not-bootstrapped card: **Start without calendar** is the filled (primary) button, **Try again** is the outlined secondary one; the hint says once that the sign-in has to be completed on the server, and wraps in English and German. |
| `spinner-{en,de}-{light,dark}.png` | **Try again** pressed while the fetch is pending: the button shows a spinner and "Loading…" / "Lade …", and **Start without calendar** is disabled. Retryable card, where **Try again** is the primary button. |
| `spinner-not-bootstrapped-{en,de}-{light,dark}.png` | The same retry on the not-bootstrapped card, where **Try again** is the outlined secondary button: it shows the spinner with "Loading…" / "Lade …" while **Start without calendar** stays the filled primary button (disabled while the retry runs). Captured against the slow stub (15 s) straight after the tap. |
| `resume-card-{en,de}-{light,dark}.png` | *Pick up* on an unfinished session with the calendar down: the same diagnosis with only **Try again** (primary) and "This session needs the calendar to continue. Your recordings stay saved." (DE: *Zum Fortsetzen braucht diese Sitzung den Kalender. Deine Aufnahmen bleiben gespeichert.*). See the fixture note below. |
| `card-{en,de}-{light,dark}.png` | The uncoded `notConfigured` card (no server set): its title and hint are German in both languages. |
| `walkthrough-{en,de}-{light,dark}.png` | The walkthrough running after **Start without calendar**: no calendar events, then the voice-note closing section "Day close" (DE: *Tagesabschluss*). |
| `done-de-{light,dark}.png` | The calendar-free session finishing: "Session saved." The bundle is built; with no server configured it stays queued and does not upload. |
| `resume-calendar-free-en-{light,dark}.png` | *Pick up* on an unfinished session that was started without the calendar: it goes straight back into the walkthrough, with no calendar fetch and no card. |

## Fixture for the resume card

The stub never answers 200, so a session cannot be started *with* the calendar. The
`resume-card-*` captures use this equivalent state instead: a session was started with
**Start without calendar** and finished with **Next** (real audio, recorded by the app), then
`manifest.json` and `calendar_free` were deleted from that session folder in the throwaway
simulator's app container. The app therefore sees an unfinished session with a recorded segment
and no marker. At the point the card appears the app cannot tell that apart from a session that
was started with the calendar (*Pick up* fetches the calendar before it rebuilds the plan), so
the captures show that an unfinished session with a segment and no marker reaches the retry-only
card when the fetch fails (retryable stub, port 8781). They do not show a genuine calendar
session resuming after a successful retry. Nothing outside that simulator was touched.

## Not captured

- **The spinner on the retry-only resume card.** It uses the same primary-button spinner as the
  retryable card (`retryIsPrimary` is true there), so it is not captured separately.
- **A genuine calendar session resuming after a successful retry**: the stub never answers 200
  (see the fixture note).
- **PRD scenario 3 on a physical device** is left for the operator.
