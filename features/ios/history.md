# Feature: history

Source: `ios/Sources/UI/Verlauf/VerlaufView.swift` (History tab, `AppTab.verlauf`).

## Drive

Not reachable with `simctl`; opening the tab needs a tap (manual).

## Expected (fresh install, manual)

- Tab **History** selected, header "History".
- Empty state: **No sessions yet** with "Walkthrough and note recordings show up here."
- With recordings: rows per session; delete asks "Delete recording?" ("Audio and transcript
  are removed from this phone. This cannot be undone.") with *Delete permanently* / *Cancel*.

## Side effects

Viewing is read-only. Delete removes local files only.

## Device-only

Playback of real recordings (`SegmentPlayer`), transcripts from the server, upload status
pills after a real session.
