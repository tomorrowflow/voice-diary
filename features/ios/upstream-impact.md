# Upstream impact and pending uploads

Where: More → Server (impact card, upload-queue card), History → a session (failed-segment
explanation), Evening → Start session (start notice).
Code: `Settings/ServerSettingsView.swift`, `Backend/UpstreamImpact.swift`,
`Backend/PendingUploadSummary.swift`, `Verlauf/VerlaufView.swift`, `Walkthrough/WalkthroughView.swift`.

## Reaching it

1. Stub on `/health=unhealthy` (`features/verify-ios/stub_server.py --route /health=unhealthy`).
   It also answers `GET /api/sessions/<id>/status` with one coded failed segment (`whisper_timeout`),
   one failed segment without a code and one processed segment.
2. Seed the queue: stop the app, write `Library/Application Support/VoiceDiary/upload_queue.json`
   in the data container with entries whose `next_attempt_at` is far in the future and one
   `last_failure_code` (`whisper_unavailable`). Seed a session: `sessions/<id>/manifest.json` plus
   `segments/s01.m4a` … placeholders. Launch the app again.
3. First launch: type `127.0.0.1:8791` after `http://` and a dummy token, press return, Save,
   dismiss the "Save Password?" prompt with "Not Now", tap Continue, then Continue on the
   Permissions screen and answer its three prompts.
4. More → Server: scroll until the Services and Upload queue cards are on screen. History → the
   session shows the failed-segment explanation.

## What proves it

The `idb` tree lists `Services` with one label per non-`ok` upstream (`Whisper, Recordings stay on
your phone and upload later.` …), `2 sessions waiting to upload` and the last failure's title; the
Verlauf row lists `Transcription is taking too long` for the coded segment only.

## Device-only / not reached

- **Start notice:** needs a walkthrough start; the simulator's host microphone can crash the audio
  engine (24 kHz input) before the banner can be captured. Check on a device (PRD scenario 5).
- A real upload that fails with `whisper_unavailable` and later succeeds (PRD scenario 1).
