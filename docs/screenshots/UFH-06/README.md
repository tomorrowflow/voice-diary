# UFH-06 proof screenshots

Real screenshots (`xcrun simctl io <device> screenshot`) of the running app on a throwaway
iPhone 17 simulator (iOS 27). App language was switched in the app and appearance with
`simctl ui <device> appearance`.

## Captured

| File | State |
|---|---|
| `card-en-light.png`, `card-en-dark.png`, `card-de-light.png`, `card-de-dark.png` | The calendar card after "Start session" with the calendar fetch failing: diagnosis, **Try again** / **Start without calendar** (DE: *Erneut versuchen* / *Ohne Kalender starten*), and the explanation line. This is the uncoded `notConfigured` diagnosis, so its title and hint are German in both languages; it is not the coded retryable or not-bootstrapped card. |
| `walkthrough-en-light.png`, `walkthrough-en-dark.png`, `walkthrough-de-light.png`, `walkthrough-de-dark.png` | The walkthrough running after **Start without calendar**: no calendar events, then the voice-note closing section "Day close" (DE: *Tagesabschluss*). |
| `done-de-light.png`, `done-de-dark.png` | The same calendar-free session finishing: "Session saved." The bundle is built; with no server configured it stays queued and does not upload. |
| `resume-calendar-free-en-light.png`, `resume-calendar-free-en-dark.png` | *Pick up* on an unfinished session that was started without the calendar: it goes straight back into the walkthrough, with no calendar fetch and no card. |

## How the failure was produced

The app was never given a working server: with no server URL and token the calendar fetch
fails at start (`ServerClientError.notConfigured`). That is a real calendar failure, but an
uncoded one, so the card shows the German status-based text "Server noch nicht eingerichtet"
in both languages (a known limit of uncoded diagnoses, out of scope for this ticket).

## Not captured, and why

- **Coded cards:** retryable (`msgraph_unavailable`) and not bootstrapped
  (`msgraph_not_bootstrapped`, where **Start without calendar** is the dark button), including
  the English hint wrap. They need a server answering 503 with the failure fields. Two things
  stand in the way:
  1. *Keychain (understood, workaround found).* In the unsigned simulator build
     (`CODE_SIGNING_ALLOWED=NO`) `SecItemAdd` fails with `-34018` (missing entitlement), so **Save**
     on the server settings silently stores nothing. An ad-hoc signed build writes it
     (`SecItemAdd` returns 0): add `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
     CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=` to the `xcodebuild` command.
  2. *Stub server (open).* Nothing on this node can keep a server running: Bash background
     processes are denied, and `python3`, `node` and `ruby` scripts need an approval nobody can give
     there. A stub only has to answer `GET /today/calendar` with 503 and the failure fields
     (`{"detail":"…","code":"msgraph_unavailable","upstream":"msgraph","retryable":true}` and the
     `msgraph_not_bootstrapped` / `retryable: false` variant), `/health` with 200, and a slow
     (about 15 s) variant for the spinner.
- **Retry spinner:** it needs a fetch that stays pending, which needs the same server setup.
- **Resume card with "Erneut versuchen" only:** it needs an unfinished session that was started
  *with* the calendar, so a working server first.
- **PRD scenario 3 on a physical device** is left for the operator.

To capture the missing states, run the app signed on a device or simulator with Keychain access,
point it at a server whose `GET /today/calendar` answers 503 with `code: msgraph_unavailable`
(retryable) and then `code: msgraph_not_bootstrapped` (`retryable: false`), and add the images here as
`card-<lang>-<light|dark>-retryable.png`, `card-<lang>-<light|dark>-not-bootstrapped.png`,
`retry-spinner-…png` and `resume-card-…png`.
