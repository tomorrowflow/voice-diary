# UFH-10 proof screenshots

Real screenshots of the running app (`xcrun simctl io … screenshot`) on a throwaway iPhone 17
simulator (iOS 27), light and dark, English. Full size 1206 × 2622. Driven with `idb` against
`features/verify-ios/stub_server.py`, following `.claude/skills/verify-ios/SKILL.md`. The app was
built ad hoc signed so the Keychain keeps the server URL.

| File | Screen | What it shows |
|---|---|---|
| `verlauf-pending-en-{light,dark}.png` | History → session | The stub's `pending` scenario: a `pending_analysis` segment with code `blindfold_unavailable` (upstream `blindfold`) shows "Private analysis isn't available" in the amber warning colour, then the impact line "Analysis is delayed; your texts are saved." in the subdued text colour, next to the amber "Processing" pill |
| `verlauf-failed-en-{light,dark}.png` | History → session | The stub's default scenario: a `failed` segment with code `whisper_timeout` shows "Transcription is taking too long" in red, title only, no impact line, next to the red "Failed" pill |

## What the fixtures are

- The status comes from the stub's `GET /api/sessions/<id>/status`: the `pending` scenario for the
  first pair, the `ok` scenario (`s01` failed with `whisper_timeout`) for the second. `s03` is
  processed in both.
- The Verlauf session is a seeded `sessions/<id>/manifest.json` with three free-reflection segments
  and tiny placeholder audio files, the same fixture kind as UFH-08 and UFH-09.
- No real Blindfold or server produced this: it proves how the app colours and words a segment's
  `code`, not the server's classification (BAR-02).
- The rows below the first are cut off by the fold; segments without a code (`s02`) and processed
  ones (`s03`) show no explanation, which `FailureCatalogTests.segmentExplanationRule` covers and
  the accessibility tree confirmed.

This replaces the caption-colour note of `docs/screenshots/UFH-09/README.md`: the explanation is now
amber on a pending row, not red.
