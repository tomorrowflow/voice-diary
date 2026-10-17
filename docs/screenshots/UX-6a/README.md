# UX-6a proof screenshots

Real-app captures from a throwaway iPhone 17 simulator (iOS 27.0), light and dark, full size.
Each state has a `-light` and a `-dark` file.

| File | Shows |
|---|---|
| `01-first-launch-server-no-prompt-*` | Fresh install, first frame: the Server step with no system alert over it. |
| `02-permissions-priming-*` | The Permissions screen after server setup: Microphone, Speech recognition and Notifications cards, no system alert yet. |
| `03-after-continue-prompt-*` | After tapping Continue on the Permissions screen: the first system prompt (microphone), the spinner on the button. Speech recognition and notifications follow it. |
| `04-after-onboarding-evening-*` | After the last prompt is answered: the Evening tab. It shows "Server noch nicht eingerichtet" because the tab loaded behind the first-run cover, before the server was saved. |
| `05-relaunch-returning-user-*` | Relaunch of the same install: opens straight on the Evening tab with the day's events loaded and no onboarding or system alert. |
| `06-reinstall-keychain-priming-only-*` | Uninstall and reinstall with the Keychain kept (server already set up): the Permissions screen alone, with no Server step and no system alert. |
