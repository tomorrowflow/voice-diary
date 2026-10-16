---
name: verify-ios
description: Build, test and launch the real Voice Diary iOS app on a throwaway iPhone 17 simulator (launch, doctor, stub server, drive with idb, evidence, cleanup) and capture light/dark screenshots of the real app screen. Use when an iOS change must be shown working in the running app on a Mac, not just reviewed statically.
---

# verify-ios

Generates the Xcode project with XcodeGen, creates a dedicated **iPhone 17** simulator
(`vd-verify-ios`), runs the unit tests on it, installs and launches the real app, starts a
stub server for the server states a real server cannot produce on demand, drives the app with
`idb`, records evidence under `features/evidence/ios-<run>/`, and cleans up only what this run
created.

The feature map is `features/ios/README.md`; one file per user-facing feature in `features/ios/`.
The stub is `features/verify-ios/stub_server.py`.

Needs macOS with Xcode 26+ (the app targets iOS 26), XcodeGen, `idb` and an iOS 26+ simulator
runtime (`DEVELOPMENT.md` §7.4/§7.5). `xcodebuild` does not run on Linux; there, report the
iOS part as not run.

> **Staged file.** This copy lives in `features/verify-ios/` because the Mac node cannot edit
> `.claude/`. The operator moves it to `.claude/skills/verify-ios/SKILL.md` on the PR branch.

## Why a dedicated simulator

System alerts live in SpringBoard, not in the app, and they outlive `simctl uninstall`. A shared
`iPhone 17` that someone already used can show a stale alert (an "Open in Voice Diary?" from an
earlier `openurl`, say) over every screenshot, and `simctl` cannot dismiss it. A device created
for the run starts clean, is not shared with other sessions, and is deleted at the end.
Its type is `iPhone 17`, the same as the tests in `DEVELOPMENT.md` §7.4.

## Rules

- **No app behavior change.** Never edit `ios/Sources/` to make a run pass or to get a cleaner
  screenshot. The real prompts, empty states and errors are the evidence.
- **Real screen only.** Screenshots come from `xcrun simctl io <device> screenshot` of the
  running app. SwiftUI previews and `ImageRenderer` renders are not evidence.
- **Only what you started.** Only the artifacts listed in Cleanup are removed. Never run
  `simctl erase`, `simctl delete all`/`unavailable`, `shutdown all`, or touch any other
  simulator or `~/Library/Developer/CoreSimulator`. Do not run `openurl` against a simulator
  you do not intend to delete: the confirmation alert it raises cannot be dismissed. Never
  `pkill` anything but the stub (`pkill -f features/verify-ios/stub_server.py`): another run's
  stub, or a stub from an earlier ticket, may be listening elsewhere.
- **Every command runs from the worktree root**, without `cd` and without `$(...)`/`$?`
  (agent sandboxes reject them). Paths are relative to the root. Chained commands (`&&`, `;`,
  pipes) can need approval; run one command per call and redirect output to a file.
- **Signing.** Release signing is unchanged. The simulator build for this skill is signed
  locally (ad hoc), see "Why ad-hoc signing" below. No real secret is needed: the stub accepts
  any bearer token, so type a dummy one.
- **Drive with `idb`.** `simctl` cannot tap, type or swipe; `idb ui` can (Drive). A state that
  needs a tap is driven with `idb`, not claimed from reading code. Physical-device checks
  stay out of this skill.
- Host-only and device-only checks (microphone capture, wake word, Action Button, lock
  screen, Live Activity, on-device models, real server over Tailscale) stay out of this skill.
  They are listed under "Device-only" in `features/ios/README.md`.

## Why ad-hoc signing

An unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`) carries no entitlements, so the
Keychain refuses every write: `SecItemAdd` returns `-34018` (`errSecMissingEntitlement`).
`KeychainStore.write` ignores that status, so Settings → Server (and the first-launch Server
screen) appear to accept the URL and token and then forget them at the next launch. Without a
server URL the app cannot reach any stub. Signing with the ad-hoc identity embeds the
entitlements and `SecItemAdd` returns `0`. KA-11 reproduced both on the iOS 27 simulator (log
line `add server_url status=-34018` unsigned, `status=0` ad hoc; the URL survived a relaunch only
ad hoc). The flags below change only how this skill builds the app; `project.yml` and the
release signing stay as they are.

```
CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
```

## Variables

Pick a run name first and reuse it: `features/evidence/ios-<run>/` (e.g. `ios-run-1`).
The simulator is `vd-verify-ios` (addressed by name; `idb` needs its UDID, which Launch writes
to `device-udid.txt`: use it as `<udid>` below). Bundle id: `com.tomorrowflow.voice-diary`.
The stub port is `8791` (choose another if `pgrep -fl stub` shows a listener on yours).

```bash
mkdir -p features/evidence/ios-<run>
```

## Doctor

Run first; stop and report if any check fails. Nothing here changes state.

```bash
xcodebuild -version > features/evidence/ios-<run>/doctor-xcode.txt 2>&1
```

Must show Xcode 26 or newer.

```bash
xcodegen --version > features/evidence/ios-<run>/doctor-xcodegen.txt 2>&1
```

```bash
idb list-targets > features/evidence/ios-<run>/doctor-idb.txt 2>&1
```

Must run (the file may be empty before the simulator exists).

```bash
xcrun simctl list runtimes available > features/evidence/ios-<run>/doctor-runtimes.txt 2>&1
```

Must list an iOS 26+ runtime; note its identifier (`com.apple.CoreSimulator.SimRuntime.iOS-<major>-<minor>`).

```bash
xcrun simctl list devicetypes iPhone > features/evidence/ios-<run>/doctor-devicetypes.txt 2>&1
```

Must list `iPhone 17 (com.apple.CoreSimulator.SimDeviceType.iPhone-17)`.

```bash
xcrun simctl list devices vd-verify-ios > features/evidence/ios-<run>/doctor-existing-device.txt 2>&1
```

Must list no `vd-verify-ios` device. If one exists, an earlier run did not clean up: do not
reuse or delete it blindly; report it.

```bash
pgrep -fl stub
```

Lists stub processes already running. A `features/verify-ios/stub_server.py` here is an earlier
run of this skill that did not clean up; stop it with the Cleanup `pkill`. Anything else
(`calendar_stub.py` from an earlier ticket, say) is not yours: leave it and pick another port.

Check that no stub of yours will be overwritten. Both commands must fail with `No such file`;
if either exists, a real Piper bootstrap is in place: skip the stub in Launch and do not
delete it in Cleanup.

```bash
ls ios/project-piper.yml
```

```bash
ls ios/Resources/Models
```

## Launch

The Xcode project is generated and `ios/project.yml` includes the gitignored
`project-piper.yml` (normally written by `ios/scripts/fetch_piper_voices.sh`), and
references the gitignored `Resources/Models` folder. Stub both (the node-proven way):

```bash
printf '{}\n' > ios/project-piper.yml
```

```bash
mkdir -p ios/Resources/Models
```

```bash
xcodegen generate --spec ios/project.yml --project ios > features/evidence/ios-<run>/xcodegen.log 2>&1
```

Last line must be `Created project at …/ios/VoiceDiary.xcodeproj`. Create the simulator
(prints its UDID; use the runtime identifier from Doctor), boot it and wait:

```bash
xcrun simctl create vd-verify-ios com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-<major>-<minor> > features/evidence/ios-<run>/device-udid.txt 2>&1
```

```bash
xcrun simctl boot vd-verify-ios
```

```bash
xcrun simctl bootstatus vd-verify-ios -b > features/evidence/ios-<run>/boot.log 2>&1
```

`boot.log` ends with `Finished` (about 30 s for a new device).

Build and run the unit tests. `-skipMacroValidation` is for the MLXHuggingFace package macro;
the signing flags are "Why ad-hoc signing" above (and clear the personal team `project.yml`
pins); derived data stays in the git-ignored `ios/DerivedData` so the next run is incremental.
The first run resolves Swift packages and takes several minutes (needs network):

```bash
xcodebuild test -project ios/VoiceDiary.xcodeproj -scheme VoiceDiary -destination 'platform=iOS Simulator,name=vd-verify-ios' -skipMacroValidation -derivedDataPath ios/DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= > features/evidence/ios-<run>/xcodebuild-test.log 2>&1
```

```bash
tail -n 12 features/evidence/ios-<run>/xcodebuild-test.log
```

Must end with `** TEST SUCCEEDED **`; the Swift Testing line reads
`Test run with <n> tests in <m> suites passed`. On failure read the log; do not edit the app.
(An "ad-hoc codesigning" note about the hardened runtime is expected.)

Install and launch the real app (the test build is already the simulator app):

```bash
xcrun simctl install vd-verify-ios ios/DerivedData/Build/Products/Debug-iphonesimulator/VoiceDiary.app
```

Pre-grant what `simctl` can (microphone only; it terminates the app if running, and it may
fail once right after install: repeat it). Notifications and speech recognition **cannot** be
pre-granted from the CLI; Drive taps their prompts with `idb`:

```bash
xcrun simctl privacy vd-verify-ios grant microphone com.tomorrowflow.voice-diary
```

```bash
xcrun simctl launch vd-verify-ios com.tomorrowflow.voice-diary > features/evidence/ios-<run>/launch.txt 2>&1
```

Prints `com.tomorrowflow.voice-diary: <pid>`. Within about a second the fresh install shows the
system notification prompt (then the speech-recognition prompt) over the first screen
(`features/ios/first-launch.md`). It stays until someone taps it, and every screenshot taken
meanwhile includes it. Taking the shot faster does not help: the prompt appears before the
first app frame.

## Stub server

`features/verify-ios/stub_server.py` (Python 3 standard library only, binds `127.0.0.1`; the
simulator reaches the host loopback) answers `GET /health`, `GET /today/calendar` and
`GET /api/sessions/dates` with the shapes of `server/webapp/routers/` and, per route and
scenario, the SPEC §10.6.1 failure contract (`detail`, `code`, `upstream`, `retryable`, and
`Retry-After` where the server sends one):

| Scenario | Response |
|---|---|
| `ok` | 200, normal body (two events on the requested `date` for the calendar) |
| `retryable` | 503 `msgraph_unavailable`, `retryable: true` |
| `not-bootstrapped` | 503 `msgraph_not_bootstrapped`, `retryable: false` |
| `rate-limited` | 429 `msgraph_rate_limited`, `Retry-After: 5` |
| `engine-error` | 502 `msgraph_engine_error` |
| `slow` / `slow:<s>` | the `retryable` 503 after 15 s (or `<s>`): the retry spinner stays visible |
| `slow-ok` | the 200 after 15 s |

A route takes a comma-separated list (`--route /today/calendar=retryable,ok`: the first request
fails, every later one succeeds). The authed routes answer 401 `missing_bearer_token` without a
bearer header and accept any token unless `--token` is given.

**Node permission.** The Mac node must allow exactly two commands, both from the worktree root:
`python3 features/verify-ios/stub_server.py <args>` and
`pkill -f features/verify-ios/stub_server.py`. No other `python3` command is needed or allowed.

Start it with the Bash tool in **background mode** (no `&`, `nohup` or wrapper script), as one
command:

```bash
python3 features/verify-ios/stub_server.py --port 8791 --route /today/calendar=retryable
```

Its first output line is `stub listening on http://127.0.0.1:8791 {…}`. Check every route and
scenario through the same file (`curl` is denied); it prints one `PASS`/`FAIL` line per request,
exits non-zero on a failure, and restores the routes it changed:

```bash
python3 features/verify-ios/stub_server.py --port 8791 --check > features/evidence/ios-<run>/stub-check.txt 2>&1
```

Change what a route answers while the app is running, without restarting (the next request
uses it):

```bash
python3 features/verify-ios/stub_server.py --port 8791 --set /today/calendar=not-bootstrapped
```

The app's server URL for the stub is `http://127.0.0.1:8791`. The stub is stopped in Cleanup;
never leave it running.

## Drive

Map of what is reachable, per feature file. `idb` drives the taps; the stub supplies the server
states:

| Feature | Reachable | Needs |
|---|---|---|
| [first-launch](../ios/first-launch.md) | launch, prompts, light/dark; answering the prompts | `idb` tap |
| [evening-walkthrough](../ios/evening-walkthrough.md) | Evening tab, day overview, calendar failure cards, retry spinner | stub, `idb` |
| [recording](../ios/recording.md) | nothing | tab, record button (microphone) |
| [history](../ios/history.md) | tab (tap) | `idb` tap |
| [more-settings](../ios/more-settings.md) | appearance (system-wide), rows, language toggle, Server | `idb` tap/text |

`simctl openurl voicediary://capture/start` does **not** help: iOS asks "Open in Voice
Diary?" first, and the alert then stays on that device. Appearance is set from the CLI:

```bash
xcrun simctl ui vd-verify-ios appearance dark
```

(`light` to restore.) `xcrun simctl ui vd-verify-ios appearance` with no value prints the
current one; record it before and after.

### Finding elements and tapping (`idb`)

`idb` needs the simulator UDID (`device-udid.txt`). List what is on screen, with each element's
label, value and frame in points (the iPhone 17 screen is 402 × 874):

```bash
idb ui describe-all --udid <udid> > features/evidence/ios-<run>/ui.json
```

```bash
grep -o -E '"(AXLabel|AXValue|AXFrame)":"[^"]*"' features/evidence/ios-<run>/ui.json
```

Read the elements in order: a label is followed by its frame. Tap the **centre** of the frame
(`x + width/2`, `y + height/2`), type into the focused field, press the keyboard's return key
to dismiss it:

```bash
idb ui tap <x> <y> --udid <udid>
```

```bash
idb ui text "<text>" --udid <udid>
```

Things learned in KA-11:

- `describe-all` shows only a status-bar fragment while the app is launching or animating. Run it
  again until the app's labels appear; a screenshot taken then is blank.
- The tree is the state check: the UI lists labels such as `Start session`, `Try again`
  (DE: `Erneut versuchen`), `Start without calendar` (DE: `Ohne Kalender starten`). Take a
  screenshot only once the label you expect is in the tree.
- A system prompt covers the app; its buttons are in the same tree. Answer them first:
  notifications (`Allow`), then speech recognition (`Allow`).
- The soft keyboard hides the Save button; tap the keyboard's return key (bottom right), then
  re-read the tree, then tap Save.
- `idb ui text` types after the existing text, so `http://` in the Server URL field stays: type
  `127.0.0.1:8791`. A field showing a placeholder is empty.
- A tap that changes nothing was probably outside the frame; read the tree again, do not repeat
  it blindly.

### Reaching the calendar failure states (UFH-06)

1. First launch: answer the prompts, then enter the server URL `http://127.0.0.1:8791` and any
   dummy token on the Server screen (or More → Server) and tap **Save**. They must persist: quit
   and relaunch the app (`simctl terminate`, `simctl launch`); the Server screen must not come
   back (an unsigned build forgets them, see "Why ad-hoc signing").
2. Wait for the Parakeet model (about 1.2 GB, needs network) to finish loading; **Start
   session** stays disabled until then. Check the tree for the button being enabled.
3. With the stub on `/today/calendar=retryable`, tap **Start session**: the card with
   **Try again** and **Start without calendar** appears. Switch the stub (`--set …=not-bootstrapped`)
   and tap **Try again** for the not-bootstrapped card. With `slow` the card shows the retry
   spinner right after the tap: screenshot within the delay.
4. The retry-only resume card needs an unfinished session: use the Seed step below.

### Seed (states the UI cannot reach)

Some states need a file the UI never produces, for example removing the `calendar_free`
marker from a session folder so *Pick up* sees an unfinished session without one (UFH-06).
Stop the app first, then work inside its data container; `simctl spawn … rm` does **not** work,
use the host `ls`/`rm` on the path the next command prints:

```bash
xcrun simctl terminate vd-verify-ios com.tomorrowflow.voice-diary
```

```bash
xcrun simctl get_app_container vd-verify-ios com.tomorrowflow.voice-diary data
```

Sessions are under `<data container>/Library/Application Support/VoiceDiary/sessions/<session>/`:

```bash
ls "<data container>/Library/Application Support/VoiceDiary/sessions"
```

```bash
rm "<data container>/Library/Application Support/VoiceDiary/sessions/<session>/calendar_free"
```

Only the paths of this simulator's container. Say in the evidence what the fixture does and does
not prove (a seeded state is not the real flow that normally leads to it). Launch the app again
afterwards.

## Evidence

Screenshots of the real screen, one per appearance, after the state you are mapping is on
screen (the expected label is in the `idb` tree; wait a moment after switching appearance):

```bash
xcrun simctl io vd-verify-ios screenshot features/evidence/ios-<run>/<state>-light.png
```

```bash
xcrun simctl ui vd-verify-ios appearance dark
```

```bash
xcrun simctl io vd-verify-ios screenshot features/evidence/ios-<run>/<state>-dark.png
```

```bash
xcrun simctl ui vd-verify-ios appearance light
```

Full-size screenshots are 1206 × 2622 px. **Never open the original.** Make a downscaled copy
next to it and open the copy:

```bash
sips -Z 1200 features/evidence/ios-<run>/<state>-light.png --out features/evidence/ios-<run>/<state>-light-small.png
```

**Open both copies** (Read tool) and write down what each shows: which tab is selected, which
text, which button is filled, which alert, and whether dark mode really changed the colors. A
file that exists is not proof; a wrong state (blank launch screen, stale alert, crash dialog)
means the step failed. Commit the original full-size images, not the `-small` copies.

The app log (os.Logger) can be read with `xcrun simctl spawn vd-verify-ios log show --last 5m
--predicate 'process == "VoiceDiary"' --style compact`; it is noisy (CoreML, network), so
filter on the message you expect, e.g. `eventMessage CONTAINS "Voice Diary ready"`. The
stub also logs every request it answers on its stderr (the background task's output).

Retain proof you want in git by copying it out of the git-ignored evidence directory into
`docs/screenshots/<KEY>/` and committing it as the last commit (`<KEY>: proof screenshots`):

```bash
mkdir -p docs/screenshots/<KEY>
```

```bash
cp features/evidence/ios-<run>/<state>-light.png features/evidence/ios-<run>/<state>-dark.png docs/screenshots/<KEY>/
```

Raw logs stay in `features/evidence/` (git-ignored; `git add -f` only on purpose). The test
log contains absolute local paths; do not commit it.

## Cleanup

Always run it, also after a failed Launch or Drive. It removes only what this run made and
never touches `features/evidence/` or `docs/screenshots/`. Deleting the device also removes
the installed app, its container and every permission answer.

Stop the stub first (matches only this file's process; `no process found` is fine). Then end
the background Bash task if it is still listed, and confirm nothing is left:

```bash
pkill -f features/verify-ios/stub_server.py
```

```bash
pgrep -fl stub_server
```

Must print nothing.

```bash
xcrun simctl terminate vd-verify-ios com.tomorrowflow.voice-diary
```

(`found nothing to terminate` is fine.)

```bash
xcrun simctl shutdown vd-verify-ios
```

```bash
xcrun simctl delete vd-verify-ios
```

Remove the generated project and the stubs (skip the stub lines if Doctor found a real
bootstrap). `rmdir` refuses a non-empty `Models` folder, which is the safety check:

```bash
rm -r ios/VoiceDiary.xcodeproj
```

```bash
rm ios/project-piper.yml
```

```bash
rmdir ios/Resources/Models
```

`ios/DerivedData` (git-ignored, several GB) is kept so the next run is fast; delete it with
`rm -r ios/DerivedData` when the worktree is finished. Then confirm:

```bash
xcrun simctl list devices vd-verify-ios > features/evidence/ios-<run>/post-cleanup-devices.txt 2>&1
```

It must list no `vd-verify-ios`. `git status --short` must show no stub or `ios/` change, and
`ls features/evidence/ios-<run> docs/screenshots/<KEY>` must still list the proof files.

## Adding a feature

Copy a file in `features/ios/`, say how the state is reached (stub scenario, `idb` taps, seed),
what proves it, and what is device-only; list it in `features/ios/README.md` and in the Drive
table above. A server state the stub cannot produce yet is a new scenario in
`features/verify-ios/stub_server.py`. If a UI-test target ever lands, update the Drive section.
