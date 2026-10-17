# UX-13a proof screenshots

Real screenshots of the running app (`xcrun simctl io … screenshot`) on a throwaway iPhone 17
simulator (iOS 27), light and dark. Full size 1206 × 2622. Driven with `idb` against
`features/verify-ios/stub_server.py`, following `.claude/skills/verify-ios/SKILL.md`. The app was
built ad hoc signed so the Keychain keeps the server URL.

Screen: More → Language (DE: Mehr → Sprache). "top" is the screen as opened, "bottom" is the same
screen scrolled down so the response-language picker clears the tab bar.

| File | State | What it shows |
|---|---|---|
| `language-{top,bottom}-default-{light,dark}.png` | fresh install | App language `System` checked; Recording language `Auto (recommended)` / `Deutsch` / `English` with Auto checked; Response language `Match (recommended)` / `Deutsch` / `English` with Match checked |
| `language-{top,bottom}-changed-{light,dark}.png` | after changing both pickers, app terminated and relaunched | Recording language `English` and Response language `Deutsch` still checked (the choice was saved); App language unchanged |
| `language-{top,bottom}-de-{light,dark}.png` | App language set to `Deutsch` | The same screen in German: `Aufnahmesprache` (`Automatisch (empfohlen)` / `Deutsch` / `Englisch`) and `Antwortsprache` (`Angleichen (empfohlen)` / `Deutsch` / `Englisch`), with the saved selection still shown |

## What this does not show

The effect of the two choices on a live recording (wake-word listening language, spoken response
language) needs the microphone and the on-device speech models, so it is not run in the simulator.
It is covered by `LanguagePreferencesTests` (resolution, defaults, persistence, and that
`OpenerLanguage.current` follows the response override).
