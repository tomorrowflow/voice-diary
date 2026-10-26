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
has segments `s01` and `s02` with a `segments/s01.m4a` and `s02.m4a`, point the status route at
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

## Device-only

Playback of real recordings (`SegmentPlayer`), transcripts from the server, upload status
pills after a real session.
