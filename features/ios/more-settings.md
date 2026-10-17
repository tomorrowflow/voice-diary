# Feature: more-settings

Source: `MehrView` in `ios/Sources/App/VoiceDiaryApp.swift`, views in `ios/Sources/UI/Settings/`,
`ios/Sources/Localization/`.

## Drive

- Appearance is system-wide and reached with `simctl`:
  `xcrun simctl ui vd-verify-ios appearance dark` / `light`. The app follows it (verified in
  KA-9: the same screen re-rendered dark, tab bar included).
- Opening the **More** tab, each row, and the language toggle need taps (manual).

## Expected (manual)

- Tab **More**: header "More" and a list: Sections, Order, Event filter, Voices, Dialog model,
  Language, Permissions, Wake word, Lock screen, Server, Diagnostics, Danger zone.
- *Language* flips the whole UI between English and German at runtime (`AppLanguage`
  Bundle swap); German is the primary language, so check a German screenshot too. The same
  screen has the *Recording language* (Auto / Deutsch / English) and *Response language*
  (Match / Deutsch / English) pickers; the response picker sits below the fold, so scroll
  (`idb ui swipe`) to capture it. The choice is saved across a relaunch; its effect on a live
  recording is device-only (microphone, speech models).
- *Server* is where the Tailscale URL and bearer token are entered (Keychain); never enter a
  real token during a simulator run.

## Side effects

Settings are stored in the app container / Keychain of the simulator; deleting the
simulator (Cleanup) resets them.

## Device-only

Wake-word and lock-screen settings effects, Voices (Piper models), Dialog model (Gemma/Apple
FM), real Tailscale reachability from *Server*.
