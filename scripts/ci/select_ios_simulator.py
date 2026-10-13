#!/usr/bin/env python3
"""Pick an iOS simulator that is actually installed, for the macOS CI job.

Reads `xcrun simctl list devices available -j` JSON on stdin and prints the UDID
of the chosen device on stdout (diagnostics go to stderr).

Selection: newest installed iOS runtime >= MIN_IOS_MAJOR; on that runtime prefer
the device named PREFERRED_NAME, else the newest plain iPhone (no Pro/Plus/Max/
Air/SE/mini variants), else any iPhone. Exits 1 if nothing qualifies.

Usage:
    xcrun simctl list devices available -j | python3 scripts/ci/select_ios_simulator.py
"""

import json
import re
import sys

MIN_IOS_MAJOR = 26  # ios/project.yml deploymentTarget
PREFERRED_NAME = "iPhone 17"  # what DEVELOPMENT.md §7.4 uses; not assumed to exist
VARIANT_WORDS = ("Pro", "Plus", "Max", "Air", "SE", "mini")


def runtime_version(runtime_id):
    """`com.apple.CoreSimulator.SimRuntime.iOS-26-0` -> (26, 0); None if not iOS."""
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime_id)
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split("-"))


def model_number(name):
    match = re.match(r"iPhone (\d+)", name)
    return int(match.group(1)) if match else -1


def is_plain(name):
    return not any(word in name.split() for word in VARIANT_WORDS)


def select(devices_by_runtime):
    runtimes = []
    for runtime_id, devices in devices_by_runtime.items():
        version = runtime_version(runtime_id)
        if version is None or version[0] < MIN_IOS_MAJOR:
            continue
        iphones = [
            d for d in devices
            if d.get("isAvailable", True) and d.get("name", "").startswith("iPhone")
        ]
        if iphones:
            runtimes.append((version, runtime_id, iphones))
    if not runtimes:
        return None

    version, runtime_id, iphones = max(runtimes, key=lambda r: r[0])
    for device in iphones:
        if device["name"] == PREFERRED_NAME:
            return device["udid"], device["name"], runtime_id
    plain = [d for d in iphones if is_plain(d["name"])]
    device = max(plain or iphones, key=lambda d: (model_number(d["name"]), d["name"]))
    return device["udid"], device["name"], runtime_id


def main():
    chosen = select(json.load(sys.stdin).get("devices", {}))
    if chosen is None:
        print(f"No available iPhone simulator on an iOS >= {MIN_IOS_MAJOR} runtime.", file=sys.stderr)
        return 1
    udid, name, runtime_id = chosen
    print(f"Selected {name} ({runtime_id}) {udid}", file=sys.stderr)
    print(udid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
