# KA-11 proof screenshots

Real screenshots (`xcrun simctl io <device> screenshot`, 1206 × 2622 px) of the running app on a
throwaway iPhone 17 simulator (iOS 27), driven with `idb` against `features/verify-ios/stub_server.py`
on `127.0.0.1:8791` (answering `/health` 200 and `/today/calendar` as named below). The app was the
ad-hoc signed proof build (`CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO
DEVELOPMENT_TEAM=`), English, appearance switched with `simctl ui <device> appearance`. The app code
is the UFH-06 branch (PR #96) unchanged. Each file was opened through a `sips -Z 1200` copy.

| Files | State | What it shows |
|---|---|---|
| `retryable-en-{light,dark}.png` | Stub `/today/calendar` = 503 `msgraph_unavailable`, `retryable: true`; **Start session** tapped | Coded card "Calendar and mail aren't available" with the diagnosis, **Try again** as the filled primary button and **Start without calendar** as the outlined one. Dark inverts the card and buttons. |
| `spinner-retryable-en-{light,dark}.png` | Stub on `slow:30` (the retryable 503 after 30 s); **Try again** tapped, captured while the request is pending | **Try again** now reads "Loading…" with a spinner; **Start without calendar** stays beside it. Same card in both appearances. |
| `not-bootstrapped-en-{light,dark}.png` | Stub = 503 `msgraph_not_bootstrapped`, `retryable: false`; **Try again** tapped on the card above | Card "Calendar and mail aren't set up" ("Microsoft sign-in has to be completed on the server. This can't be fixed on the phone."): **Start without calendar** is the filled primary button, **Try again** the outlined one. |
| `resume-card-en-{light,dark}.png` | Unfinished session picked up with the stub on the retryable 503 | Same diagnosis with only **Try again** (primary) and "This session needs the calendar to continue. Your recordings stay saved." |

## Fixture for the resume card

The stub never answers 200 here, so a session cannot be started *with* the calendar. The capture
uses the UFH-06 equivalent: a session was started with **Start without calendar** and **Next**
tapped once (the app recorded `segments/s01.m4a`), the app was stopped, and `manifest.json` and
`calendar_free` were deleted from that session folder in the simulator's data container
(`simctl get_app_container … data`). The app then sees an unfinished session with a segment and no
marker and cannot tell it from a session started with the calendar; the capture shows that this
reaches the retry-only card when the fetch fails. It does not show a genuine calendar session
resuming after a successful retry. Nothing outside that simulator was touched.

## Not captured

- German captures and the spinner on the not-bootstrapped card (UFH-06 has both under
  `docs/screenshots/UFH-06/`).
- PRD scenario 3 on a physical device, which stays with the operator.
