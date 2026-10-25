# UFH-09 proof screenshots

Real screenshots of the running app (`xcrun simctl io … screenshot`) on a throwaway iPhone 17
simulator (iOS 27), light and dark, English. Full size 1206 × 2622. Driven with `idb` against
`features/verify-ios/stub_server.py`, following `.claude/skills/verify-ios/SKILL.md`. The app was
built ad hoc signed so the Keychain keeps the server URL.

| File | Screen | What it shows |
|---|---|---|
| `verlauf-pending-en-{light,dark}.png` | History → session | A `pending_analysis` segment with code `blindfold_unavailable` (upstream `blindfold`) shows "Private analysis isn't available" under its details, next to the amber "Processing" pill; a `pending_analysis` segment without a code shows only the plain pill |

## What the fixtures are

- The status comes from the stub's new `pending` scenario on `GET /api/sessions/<id>/status`: `s01`
  and `s02` `pending_analysis` (`s01` with `blindfold_unavailable` / `blindfold`, `s02` without a
  code), `s03` processed. The scenario is part of the stub's `--check` run.
- The Verlauf session is a seeded `sessions/<id>/manifest.json` with three free-reflection segments
  and tiny placeholder audio files, the same fixture kind as UFH-08 and BAR-06.
- No real Blindfold or server produced this: it proves how the app words a `pending_analysis`
  segment's `code`, not the server's classification (BAR-02).
- The processed `s03` row sits below the fold in the capture; its absence of an explanation is
  covered by `FailureCatalogTests.segmentExplanationRule` and was read from the accessibility tree
  (label "Processed", no explanation line).

The explanation keeps the destructive (red) caption colour used for failed segments, next to the
unchanged amber "Processing" pill, as the ticket specifies.
