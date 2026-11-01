# Feature: history

Source: `ios/Sources/UI/Verlauf/VerlaufView.swift` (History tab, `AppTab.verlauf`).

## Drive

Not reachable with `simctl`; opening the tab needs a tap (manual).

## Expected (fresh install, manual)

- Tab **History** selected, header "History".
- Empty state: **No sessions yet** with "Walkthrough and note recordings show up here."
- With recordings: rows per session; delete asks "Delete recording?" ("Audio and transcript
  are removed from this phone. This cannot be undone.") with *Delete permanently* / *Cancel*.

## Failed-transcription recovery (FTR-05)

Source: `VerlaufDetailView`, `SegmentRecoveryPresentation`, `TranscriptionRecoveryModel`.

Reached with the stub and `idb`: seed a session folder (SKILL.md → Seed) whose `manifest.json`
has segments `s01` and `s02` with a `segments/s01.m4a` and `s02.m4a`. The checked-in recipe
SKILL.md → Seed → "Retained audio (History segment + note, walkthrough note review)" does this:
`features/verify-ios/fixtures/retained-audio/sessions/2026-10-30T18-15-00Z/` has that manifest and
two tone files (9 s and 10 s), so no audio has to be made by hand. Point the status route at
`recoverable`, `sibling` or `audio-gone`, open History → the session and scroll to the
segment. `/health=unhealthy` disables the button. A tap on the button reaches the in-flight row
through the stub's `retry-transcription` route. Foreground changes (HOME, then `simctl launch`)
re-read `/health` and the status without a relaunch. A status without `recoverable` (the
stub's `ok`) shows the row as before, without a button.

The stub's `--check` now prints 42 `PASS` lines, not the 33 the verify-ios skill lists.

Device-only: the real Whisper going down mid-attempt, leaving and returning during an attempt,
and recording while an attempt runs.

## Side effects

Viewing is read-only. Delete removes local files only.

## Playback UI (retained audio) — seed and `idb`

Reached with the same recipe (SKILL.md → Seed → "Retained audio (History segment + note,
walkthrough note review)"): History lists the seeded session and a loose note under *Friday,
October 30*; the session's detail has segment rows (*Fixture standup*, *Free reflection*) and a
**NOTES** row (17:40), each with a play/pause disc and, while active, a scrubber. `idb` taps
drive play and pause (KA-12 captures: `docs/screenshots/KA-12/`).

The fixture proves the rows, the glyph and the scrubber for audio that is already on the phone,
in both appearances. It does not prove a real recording, upload or transcription: the files are
synthetic tones (no speech), the transcripts are canned text, and the session was not written by
the app.

## Device-only

Playback of real recordings (`SegmentPlayer`) as the app writes them: the audio content, a
recording made on the phone, transcripts from the server, upload status pills after a real
session.
