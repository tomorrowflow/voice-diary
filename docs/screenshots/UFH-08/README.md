# UFH-08 proof screenshots

Real screenshots of the running app (`xcrun simctl io … screenshot`) on a throwaway iPhone 17
simulator (iOS 27), light and dark, English and German. Full size 1206 × 2622. Driven with `idb`
against `features/verify-ios/stub_server.py` (`/health=unhealthy`), following
`features/verify-ios/SKILL.md`. The app was built ad hoc signed so the Keychain keeps the server URL.

| File | Screen | What it shows |
|---|---|---|
| `server-impacts-{en,de}-{light,dark}.png` | More → Server | The "Services" / "Dienste" card with one impact sentence for each non-`ok` upstream (Whisper, Ollama, Microsoft Graph not set up, Voxtral) and none for LightRAG (`ok`); the "Upload queue" card with "2 sessions waiting to upload" / "2 Sitzungen warten auf Upload" and the explanation of the last failure (`whisper_unavailable`) |
| `verlauf-failed-{en,de}-{light,dark}.png` | History → session | A `failed` segment with code `whisper_timeout` shows "Transcription is taking too long" / "Transkription dauert zu lange" under its details; a `failed` segment without a code shows only the plain pill; a processed segment is unchanged |

## What the fixtures are

- `/health` comes from the stub's `unhealthy` scenario: Whisper `down` (so overall `down`), Ollama
  `down`, Voxtral `down`, Graph `not_bootstrapped`, LightRAG `ok`.
- The upload queue is a seeded `upload_queue.json` in the app container: two sessions, the first with
  `last_failure_code: whisper_unavailable`, both due far in the future so the uploader leaves them
  alone. It proves how the card renders a queue like that, not that a real upload produced it (that
  is PRD scenario 1, run on a device).
- The Verlauf session is a seeded `sessions/<id>/manifest.json` with three tiny placeholder audio
  files. The stub answers `GET /api/sessions/<id>/status` with `s01` failed `whisper_timeout`, `s02`
  failed without a code, `s03` processed.

## Not captured: the walkthrough start notice

The non-blocking notice at walkthrough start is not in this set. On this host the simulator's
microphone input is 24 kHz, and the app's audio engine (`AudioEngine.installNoOpTap`, unchanged by
this ticket) crashes with "Failed to create tap due to format mismatch" about 0.3 s after "Start
session", right after `/health` is requested and before a frame with the banner can be captured.
Its logic is covered by `UpstreamImpactTests` (`startNotice`), and it is part of PRD scenario 5 on a
device.

## Observed on the way (not changed here)

In German the Verlauf detail still shows some English text (the page title "Evening", the "Failed"
and "Processed" pills, "Free reflection", "SECTIONS"). Those strings use `String(localized:)`, which
does not follow the app's language setting the way the new explanation text does; they predate
UFH-08.
