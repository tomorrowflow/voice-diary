#!/usr/bin/env bash
#
# Build, install, and launch Voice Diary on the connected iPhone in one
# go. Combines:
#   1. `xcodegen generate`   — regenerate VoiceDiary.xcodeproj from
#                              project.yml (incl. the Piper overlay
#                              written by fetch_piper_voices.sh).
#   2. `xcodebuild build`    — compile for the connected device.
#   3. `xcrun devicectl
#         device install app` — push the .app over USB/Wi-Fi.
#   4. `xcrun devicectl
#         device process launch` — auto-launch on the phone.
#
# Override the target phone with `DEVICE=...` (matched by name as shown
# in `xcrun devicectl list devices`, or by UDID).
#
# Override the build config with `CONFIG=Release`.
#
# Pass `--no-launch` to install but skip the auto-launch step.
# Pass `--no-logs`   to skip streaming the device syslog after launch.
#
# Log streaming uses `idevicesyslog` from libimobiledevice. Install it
# once with `brew install libimobiledevice`. Without it the script just
# prints a Console.app fallback hint.

set -euo pipefail

DEVICE="${DEVICE:-iPhone von Florian}"
CONFIG="${CONFIG:-Debug}"
SCHEME="VoiceDiary"
BUNDLE_ID="com.tomorrowflow.voice-diary"
LAUNCH=1
STREAM_LOGS=1

for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        --no-logs)   STREAM_LOGS=0 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."  # → ios/

echo "→ xcodegen generate"
xcodegen generate

echo "→ xcodebuild ${CONFIG} for device '${DEVICE}'"
xcodebuild \
    -scheme "${SCHEME}" \
    -destination "platform=iOS,name=${DEVICE}" \
    -configuration "${CONFIG}" \
    build

# Locate the just-built .app — `xcodebuild -showBuildSettings` reports
# the BUILT_PRODUCTS_DIR for the matching destination, which is what
# `devicectl install app` needs.
echo "→ resolving build products dir"
PRODUCTS_DIR=$(xcodebuild \
    -scheme "${SCHEME}" \
    -destination "platform=iOS,name=${DEVICE}" \
    -configuration "${CONFIG}" \
    -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/ BUILT_PRODUCTS_DIR / {print $2; exit}')

if [[ -z "${PRODUCTS_DIR}" || ! -d "${PRODUCTS_DIR}/${SCHEME}.app" ]]; then
    echo "✗ Could not locate built ${SCHEME}.app under ${PRODUCTS_DIR:-?}" >&2
    exit 1
fi
APP_PATH="${PRODUCTS_DIR}/${SCHEME}.app"
echo "  ${APP_PATH}"

echo "→ devicectl install app on '${DEVICE}'"
xcrun devicectl device install app --device "${DEVICE}" "${APP_PATH}"

if [[ "${LAUNCH}" -eq 1 ]]; then
    echo "→ devicectl launch ${BUNDLE_ID}"
    xcrun devicectl device process launch --device "${DEVICE}" "${BUNDLE_ID}"
fi

echo
echo "✓ ${SCHEME} (${CONFIG}) deployed to '${DEVICE}'"

if [[ "${STREAM_LOGS}" -eq 1 ]]; then
    if ! command -v idevicesyslog >/dev/null 2>&1; then
        echo
        echo "  idevicesyslog not installed:  brew install libimobiledevice"
        echo "  Or use Console.app → select '${DEVICE}' → filter subsystem com.tomorrowflow.voice-diary"
        exit 0
    fi

    # Look up the UDID by display name. devicectl's JSON output is the
    # canonical map from name → hardware UDID.
    UDID=$(xcrun devicectl list devices --json-output - 2>/dev/null \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '${DEVICE}'
for dev in data.get('result', {}).get('devices', []):
    name = dev.get('deviceProperties', {}).get('name', '')
    if name == target:
        print(dev.get('hardwareProperties', {}).get('udid', ''))
        break
" 2>/dev/null || true)

    if [[ -z "${UDID}" ]]; then
        echo "✗ Could not resolve UDID for '${DEVICE}'." >&2
        echo "  devicectl sees these devices:" >&2
        xcrun devicectl list devices 2>&1 | sed 's/^/    /' >&2
        exit 1
    fi

    echo
    echo "→ Streaming device syslog (Ctrl+C to stop)"
    echo "  device: ${DEVICE} (${UDID})"
    echo "  filter: VoiceDiary | voice-diary | com.tomorrowflow"
    echo

    # Important on iOS 17+:
    #   `os.Logger` calls (Log.audio.notice / Log.app.notice) write to
    #   the *unified log*. idevicesyslog reads the *legacy syslog
    #   stream*, which only receives a subset of unified-log messages.
    #   `print()` / `NSLog()` / lower-priority entries reliably appear;
    #   `notice` / `info` may not. If you don't see expected logs,
    #   open Console.app, select '${DEVICE}' in the sidebar, and
    #   filter by subsystem com.tomorrowflow.voice-diary — that view
    #   sees the full unified log.
    #
    # We don't redirect stderr — if idevicesyslog can't pair, can't
    # connect, or the device is locked, we want to see the error.
    # `-p PROCESS` filters by process name — much more reliable than
    # piping to grep (which has line-buffering quirks and only sees
    # post-format strings). The VoiceDiary app's process name on iOS
    # is just "VoiceDiary".
    exec idevicesyslog -u "${UDID}" -p "VoiceDiary"
fi
