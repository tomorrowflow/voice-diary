# BAR-06 proof screenshots

Real screenshots of the running app (`xcrun simctl io … screenshot`) on a throwaway iPhone 17
simulator (iOS 27), light and dark, English. Full size 1206 × 2622. Driven with `idb` against
`features/verify-ios/stub_server.py`, following `features/verify-ios/SKILL.md`. The app was built
ad hoc signed so the Keychain keeps the server URL.

| File | Screen | What it shows |
|---|---|---|
| `verlauf-blindfold-en-{light,dark}.png` | History → session | A `failed` segment with code `blindfold_timeout` (upstream `blindfold`) shows "Private analysis is taking too long" under its details, next to the "Failed" pill; a `failed` segment without a code shows only the pill; a processed segment is unchanged |

## What the fixtures are

- The status comes from the stub's new `blindfold` scenario on `GET /api/sessions/<id>/status`:
  `s01` failed `blindfold_timeout`, `s02` failed without a code, `s03` processed. The scenario is
  new in this ticket and is part of the stub's `--check` run.
- The Verlauf session is a seeded `sessions/<id>/manifest.json` with three free-reflection segments
  and tiny placeholder audio files, the same fixture kind as UFH-08.
- No real Blindfold or server produced this: it proves how the app words the failure code, not the
  server's classification (BAR-02).

German copy ("Geschützte Auswertung dauert zu lange") is covered by `FailureCatalogTests`; it was
not captured here.
