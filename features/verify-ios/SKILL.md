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

Must run (the file may be empty before the simulator exists). It only proves `idb` works:
it also lists simulators deleted while their idb companion kept running, under their old
names (`vd-verify-ios`, `verify-*`). Those are not devices. Whether a `vd-verify-ios` exists
is decided by the `simctl list devices` check below only.

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
simulator reaches the host loopback) answers `GET /health`, `GET /today/calendar`,
`GET /api/sessions/dates` and `GET /api/sessions/<id>/status` with the shapes of `server/webapp/routers/` and, per route and
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
| `unhealthy` | `/health` only (`ok` elsewhere): 200, `status: down`, Whisper, Ollama and Voxtral `down`, Graph `not_bootstrapped`, LightRAG `ok` (UFH-08) |

It also answers `GET /api/sessions/<id>/status` for any id (route key `/api/sessions/{id}/status`)
with one segment failed with code `whisper_timeout`, one failed without a code and one processed
(UFH-08, Verlauf).

On `/health`, `retryable` and `not-bootstrapped` answer like the real server: 200,
`status: degraded`, `msgraph` `down` / `not_bootstrapped`.

A route takes a comma-separated list (`--route /today/calendar=retryable,ok`: the first request
fails, every later one succeeds). The authed routes answer 401 `missing_bearer_token` without a
bearer header and accept any token unless `--token` is given.

**Node permission.** The Mac node must allow exactly two commands, both from the worktree root:
`python3 features/verify-ios/stub_server.py <args>` and
`pkill -f features/verify-ios/stub_server.py`. No other `python3` command is needed or allowed,
and no background mode, `&`, `nohup` or wrapper script.

Start it **detached, in the foreground**. The Bash tool's background mode is not available on the
node, so the stub daemonizes itself: `--daemon` forks twice with `setsid`, points stdin, stdout
and stderr at `/dev/null` (or at `--log <file>`, which then holds the request log), prints one
line and returns at once. `--ttl <seconds>` (1 to 7200) is required with it: the stub exits on
its own when the time is up, so a forgotten run cannot listen forever. The port is bound before
the fork, so a busy port is an error here, not a silent failure later. One command:

```bash
python3 features/verify-ios/stub_server.py --daemon --ttl 3000 --port 8791 --log features/evidence/ios-<run>/stub.log --route /today/calendar=retryable
```

It prints `stub listening on http://127.0.0.1:8791 {…} ttl=3000s log=…` and the stub survives
the next commands. Check every route and scenario through the same file (`curl` is denied); it
prints one `PASS`/`FAIL` line per request (33 lines, the last `routes restored`), exits non-zero on a
failure, and restores the routes it changed. Without a listener it prints
`no stub answering on …` and exits 2:

```bash
python3 features/verify-ios/stub_server.py --port 8791 --check > features/evidence/ios-<run>/stub-check.txt 2>&1
```

Change what a route answers while the app is running, without restarting (the next request
uses it):

```bash
python3 features/verify-ios/stub_server.py --port 8791 --set /today/calendar=not-bootstrapped
```

Without `--daemon` the stub runs in the foreground until killed; do not do that from a Bash call
that has to return. The app's server URL for the stub is `http://127.0.0.1:8791`. The stub is
stopped in Cleanup; never leave it running.

## Drive

Map of what is reachable, per feature file. `idb` drives the taps; the stub supplies the server
states:

| Feature | Reachable | Needs |
|---|---|---|
| [first-launch](../ios/first-launch.md) | launch, prompts, light/dark; answering the prompts | `idb` tap |
| [evening-walkthrough](../ios/evening-walkthrough.md) | Evening tab, day overview, walkthrough steps with the progress header, calendar failure cards, retry spinner, note review with playable note (Seed → Retained audio) | stub, `idb`, seed |
| [recording](../ios/recording.md) | nothing | tab, record button (microphone) |
| [history](../ios/history.md) | tab (tap); session with playable segment and note rows (Seed → Retained audio) | `idb` tap, seed |
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

### Reaching the walkthrough progress header (`FlowHeader`)

`FlowHeader` draws the progress capsules (one per walkthrough step, filled up to the current
one) above the title, and keeps the same 32 pt row empty on screens without progress. Both
states are reachable with the stub's default `ok` calendar; no fixture or seed is needed:

1. **No progress:** on first launch, answer both prompts; the Server screen is a `FlowHeader`
   with the row empty. Take its screenshots before typing anything.
2. Set up the server as in step 1 of "Reaching the calendar failure states" below, with the stub
   left on `ok` (start it without `--route`): `/today/calendar` then answers two events.
3. Wait for the speech model (step 2 below): **Start session** must be in the tree and enabled.
4. **Progress:** tap **Start session**. The first event step opens (title `1:1 mit …`, the
   stub's first event) with the first capsule filled. Screenshot once `Next` is in the tree.
5. Tap **Next** for the following step; one more capsule is filled.

*Start session* records from the simulator's microphone and writes a session into this
simulator's app container; Cleanup deletes the simulator with it. Do not open a walkthrough on
any other simulator.

### Reaching the calendar failure states (UFH-06)

1. First launch: answer both prompts (`Allow`, `Allow`), then on the Server screen tap the URL
   field and type `127.0.0.1:8791` after the prefilled `http://`, tap the token field and type a
   dummy token, tap the keyboard's return key, tap **Save**. The Connection row turns **OK**
   (the stub's `/health`), then tap **Continue**. They must persist: `simctl terminate`,
   `simctl launch`; the app must open on the Evening tab, not the Server screen (an unsigned
   build forgets them, see "Why ad-hoc signing"). The stub log then shows the app's
   `/today/calendar` and `/api/sessions/dates` requests.
2. Wait for the on-device speech model (Parakeet, about 1.2 GB from Hugging Face, then a first
   CoreML compile of a few minutes; every new simulator repeats it). **Start session** is
   missing from the tree or disabled ("Preparing speech model…") until it is ready.
3. **Retryable card:** stub on `/today/calendar=retryable`, tap **Start session**. The card
   shows the diagnosis with **Try again** (primary) and **Start without calendar**.
4. **Retry spinner:** `--set /today/calendar=slow:30`, tap **Try again**, screenshot straight
   away: the button reads **Loading…** with a spinner. Both appearances fit in the 30 s. The card
   only returns once the request has failed, so wait for `Try again` in the tree before the next
   tap.
5. **Not-bootstrapped card:** `--set /today/calendar=not-bootstrapped`, tap **Try again**:
   **Start without calendar** is now the primary button and the hint says the sign-in has to be
   completed on the server.
6. **Retry-only resume card:** needs an unfinished session with a recorded segment and no
   marker. Tap **Start without calendar**, wait until the Day close step records (the timer
   runs), tap **Next** (this writes `segments/s01.m4a`), then use the Seed step below. After the
   relaunch the Evening tab shows *Unfinished session — pick it up below*; with the stub on
   `retryable`, tap **Pick up**: the card shows only **Try again** and "This session needs the
   calendar to continue. Your recordings stay saved."

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

For the UFH-06 resume card also remove the session's `manifest.json` (a session with a
manifest counts as finished), leaving `segments/` in place:

```bash
rm "<data container>/Library/Application Support/VoiceDiary/sessions/<session>/manifest.json"
```

Only the paths of this simulator's container. Say in the evidence what the fixture does and does
not prove: the app cannot tell this session from one that was started *with* the calendar, so the
capture shows the card for "unfinished session, a segment, no marker", not a genuine calendar
session. Launch the app again afterwards.

#### Retained audio (History segment + note, walkthrough note review)

Playback UI needs audio the app has already kept: a History session with segment rows, a note
row, and a note in the walkthrough's note review. The simulator has no microphone worth using,
so this recipe seeds synthetic tones (no speech, no recording) from
`features/verify-ios/fixtures/retained-audio/`, which mirrors the data container:

| File | What |
|---|---|
| `sessions/2026-10-30T18-15-00Z/manifest.json` | finalized session: `s01` calendar event "Fixture standup", `s02` free reflection, note `note-2026-10-30T16:40:00Z` listed as surfaced |
| `sessions/2026-10-30T18-15-00Z/segments/s01.m4a` | 9 s, 440 Hz tone, 31 KB |
| `sessions/2026-10-30T18-15-00Z/segments/s02.m4a` | 10 s, 330 Hz tone, 32 KB |
| `driveby_seeds/2026-10-30T16-40-00Z/audio.m4a` | 8 s, 523 Hz tone, 28 KB |
| `driveby_seeds/2026-10-30T16-40-00Z/metadata.json.template` | the note's `metadata.json`; the `printf` below writes it with the container path |

All three tones are AAC-LC, mono, 16 kHz `.m4a`, the app's container and codec (`M4AWriter`),
at 32 kbps instead of 64 to stay small. One command makes the `.m4a` files (host Swift; a run
does not need it. It only regenerates the tones; the JSON is maintained by hand and must stay
decodable by `Manifest` and `VoiceNote`):

```bash
swift features/verify-ios/fixtures/make_fixtures.swift features/verify-ios/fixtures/retained-audio
```

Seed after the first launch has answered the prompts and saved the server, so the container
exists. The node asks for approval on `cp -R` and `sed`, so every file is its own `cp`. Stop the
app and get the data container (`<data container>` below, no trailing slash):

```bash
xcrun simctl terminate vd-verify-ios com.tomorrowflow.voice-diary
```

```bash
xcrun simctl get_app_container vd-verify-ios com.tomorrowflow.voice-diary data
```

The session:

```bash
mkdir -p "<data container>/Library/Application Support/VoiceDiary/sessions/2026-10-30T18-15-00Z/segments"
```

```bash
cp features/verify-ios/fixtures/retained-audio/sessions/2026-10-30T18-15-00Z/manifest.json "<data container>/Library/Application Support/VoiceDiary/sessions/2026-10-30T18-15-00Z/manifest.json"
```

```bash
cp features/verify-ios/fixtures/retained-audio/sessions/2026-10-30T18-15-00Z/segments/s01.m4a "<data container>/Library/Application Support/VoiceDiary/sessions/2026-10-30T18-15-00Z/segments/s01.m4a"
```

```bash
cp features/verify-ios/fixtures/retained-audio/sessions/2026-10-30T18-15-00Z/segments/s02.m4a "<data container>/Library/Application Support/VoiceDiary/sessions/2026-10-30T18-15-00Z/segments/s02.m4a"
```

The note (`driveby_seeds` does not exist until a note is made, hence the `mkdir`):

```bash
mkdir -p "<data container>/Library/Application Support/VoiceDiary/driveby_seeds/2026-10-30T16-40-00Z"
```

```bash
cp features/verify-ios/fixtures/retained-audio/driveby_seeds/2026-10-30T16-40-00Z/audio.m4a "<data container>/Library/Application Support/VoiceDiary/driveby_seeds/2026-10-30T16-40-00Z/audio.m4a"
```

The note's `metadata.json` holds `audio_file_url`, an absolute file URL that the walkthrough's
note review plays from directly, so it cannot be copied: write it with the data container typed
into the URL (`file://` + `<data container>` gives `file:///Users/…`; keep
`Application%20Support`). History does not need the URL (it plays the `audio.m4a` beside the
file), the walkthrough does. The text is `metadata.json.template` on one line:

```bash
printf '%s\n' '{"audio_file_url":"file://<data container>/Library/Application%20Support/VoiceDiary/driveby_seeds/2026-10-30T16-40-00Z/audio.m4a","captured_at":"2026-10-30T16:40:00Z","duration_seconds":8,"language":"en","seed_id":"note-2026-10-30T16:40:00Z","transcript":"Synthetic tone fixture, no speech."}' > "<data container>/Library/Application Support/VoiceDiary/driveby_seeds/2026-10-30T16-40-00Z/metadata.json"
```

Launch again (`simctl launch`, as in Launch); wait until `describe-all` shows the app's labels.

Two things from KA-12 that look like faults and are not:

- A tree with only `Voice Diary` and no labels, after the Server screen, is a system sheet over
  the app: *Save Password?* (from the token field). Screenshot it, tap **Not Now**
  (about (127, 546)).
- Taps sent while a screen is changing land on the next screen. Taps sent together during
  onboarding started two real sessions in the container (audio in `s01.m4a`), so the Evening tab
  showed *Unfinished session — pick it up below* with **Pick up** / **Start fresh**, and History
  listed them under **TODAY**. Send one tap per call and read the tree between screens; the
  extra sessions are harmless for this recipe (use **Start fresh**).

**History segment row, History note row.** The tab bar's items are not in the `idb` tree: tap
by position at y 815 (Evening x 67, Recording x 157, History x 244, More x 329).

1. Tap History (244, 815). Under **FRIDAY, OCTOBER 30** are two rows: the session (label
   `Evening session · 1 event, For Friday, October 30, 2026`) and the voice note on its own (label
   `Synthetic tone fixture, no speech., For …`). Tap the session row (centre of its frame in
   the tree; rows under **TODAY** are not the fixture).
2. The detail lists **SECTIONS** (*Fixture standup*, *Free reflection*) and **NOTES** (17:40).
   The notes are below the tab bar until you scroll:
   `idb ui swipe 200 700 200 200 --duration 0.5 --udid <udid>`, then `describe-all` for the frames.
3. Segment row: tap the **Play** disc of *Fixture standup*. The label turns into **Pause**
   and a scrubber `0:00 … 0:09` appears: playing. Screenshot, then tap the same disc again:
   the label is **Play** again and the scrubber stays at the stopped time: paused. Screenshot.
   The 9 s tone leaves room for both shots; if it ran out, the disc shows **Play** with no
   scrubber: tap and repeat.
4. Note row: tap the **Play** disc beside `17:40` (orange) and repeat. The segment row's
   scrubber closes when another row starts, so the layout shifts: read the tree again before
   the pause tap.

**Walkthrough note review.** Needs the server saved ("Reaching the calendar failure states",
step 1) and the stub started with `--route /today/calendar=retryable`. *Start session* stays
disabled until the speech model has loaded (step 2); in KA-12 **Start fresh** on the
*Unfinished session* card was enabled straight after onboarding, with no model wait, so the
extra sessions above are also the quick way in:

1. Tap Evening (67, 815). If the tab shows *Unfinished session — pick it up below*, tap **Start
   fresh**; otherwise **Start session**. The card *Calendar and mail aren't available* appears.
2. Tap **Start without calendar**. The only step left is the notes step, which opens directly
   on the review: title **Notes**, the 17:40 card with the orange **Older — 30. Oct** badge (the
   fixed date is a past day, so the note is always older than today), `0:08` and the
   transcript. A spoken intro runs first; the tree shows `Play`, `17:40` and `Older — 30. Oct`
   when it is ready.
3. Tap the **Play** disc (about (50, 222)): the pause glyph, the scrubber and the elapsed time
   show; a second tap pauses. Screenshot each, one call per step: the 8 s tone ends after about
   six calls, and a tap on the disc after the end plays it again from 0:00, so a "pause" shot
   there shows the pause glyph at 0:02, not a paused note. The wake-word window ("Listening
   for “Next”…") times out a few seconds after the spoken summary and moves on to **Day close**
   (a timer, **Next**, **Pause**); if the card is gone, tap **Close** (about (378, 90)) and
   start again with **Start fresh**: the card is back about 20 s later.

**What it proves.** The rows, the play/pause glyph and the scrubber for retained audio in
History and in the note review, in both appearances. **What it does not.** A real recording
(the files are tones, the transcripts canned, the language `EN`), upload, transcription, the
note's pause/resume chunks, or a session the app wrote itself (the manifest carries no
`drive_by` segment for the note, so History shows it only under NOTES). With the stub running,
History's status route marks both segments **Failed** (UFH-08, "Transcription is taking too
long"): that is the stub, not the fixture. The walkthrough also writes a session of its own
into the container; Cleanup deletes the simulator with it. Finishing a walkthrough past the note
step marks the note surfaced (`surfaced_seed_ids.json`), and later walkthroughs skip it:
**Close** instead of finishing, or seed a new simulator.

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
next to it and open the copy. How depends on who runs this skill:

- A Claude Code session downscales with `sips -Z 1200 ... --out <state>-light-small.png` and
  opens both copies with the Read tool:

  ```bash
  sips -Z 1200 features/evidence/ios-<run>/<state>-light.png --out features/evidence/ios-<run>/<state>-light-small.png
  ```

- The Workboard verifier (Code Mode, no Read tool) downscales each copy to a JPEG no wider
  than 800 px, base64-encodes it, and calls Code Mode's `image()` helper on it inside one
  `exec` script, which adds the picture to its context:

  ```bash
  sips -Z 800 -s format jpeg -s formatOptions 65 features/evidence/ios-<run>/<state>-light.png --out features/evidence/ios-<run>/<state>-light-small.jpg
  ```

  ```javascript
  // inside exec, per copy: run sips and `base64 -i <copy>.jpg` through the node exec tool, then
  image("data:image/jpeg;base64," + base64Output);
  ```

  It then records what it saw in the `visual` part of its `workboard-verification` block,
  one entry per screenshot (`path`, `shows`, `looks_right|problem`) and an overall visual
  verdict. That visual check is operator-run: it never makes the verification `fail` or
  `error`. A session that cannot show itself an image records `not_checked`, not `error`.

**Open both copies** and write down what each shows: which tab is selected, which text, which
button is filled, which alert, and whether dark mode really changed the colors. A file that
exists is not proof; a wrong state (blank launch screen, stale alert, crash dialog) means the
step failed. Commit the original full-size images, not the `-small` copies.

The app log (os.Logger) can be read with `xcrun simctl spawn vd-verify-ios log show --last 5m
--predicate 'process == "VoiceDiary"' --style compact`; it is noisy (CoreML, network), so
filter on the message you expect, e.g. `eventMessage CONTAINS "Voice Diary ready"`. The
stub also logs every request it answers (method, path, status) to its `--log` file.

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

Stop the stub first (matches only this file's process, which `pkill` ends even though it was
detached; a non-zero exit with no output just means none was running). Confirm nothing is left:

```bash
pkill -f features/verify-ios/stub_server.py
```

```bash
pgrep -fl stub_server
```

Must print nothing (exit 1).

```bash
python3 features/verify-ios/stub_server.py --port 8791 --check
```

Must print `no stub answering on http://127.0.0.1:8791` (port closed).

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
