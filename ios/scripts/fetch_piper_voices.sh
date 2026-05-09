#!/usr/bin/env bash
#
# One-time bootstrap for M9 Piper TTS test area.
#
# Downloads three things into ignored locations under ios/:
#   1. sherpa-onnx + onnxruntime iOS xcframeworks (binary, ~60 MB extracted)
#      → ios/Frameworks/{sherpa-onnx,onnxruntime}.xcframework/
#   2. Swift bindings (SherpaOnnx.swift + bridging header)
#      → ios/Sources/TTS/Vendor/
#   3. Piper voice model files for thorsten-high (de) + lessac-high (en)
#      → ios/Resources/Models/Voices/{de_DE-thorsten-high,en_US-lessac-high}/
#
# After this runs once, regenerate the Xcode project:
#     cd ios && xcodegen generate
#
# Re-running is safe — existing files are kept; only missing pieces are fetched.

set -euo pipefail

SHERPA_VERSION="v1.13.0"
SHERPA_IOS_TARBALL="sherpa-onnx-${SHERPA_VERSION}-ios.tar.bz2"
SHERPA_IOS_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${SHERPA_IOS_TARBALL}"

# Piper voices repackaged by sherpa-onnx. Critically these embed the
# `sample_rate` (and other VITS hyperparameters) into the ONNX metadata,
# whereas the originals on rhasspy/piper-voices keep them in a sidecar
# `.onnx.json` config that sherpa-onnx does not read — loading those
# crashes inside `offline-tts-vits-model.cc:Init` with
# "'sample_rate' does not exist in the metadata".
SHERPA_TTS_BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
DE_TARBALL="vits-piper-de_DE-thorsten-high.tar.bz2"
EN_US_TARBALL="vits-piper-en_US-lessac-high.tar.bz2"
EN_GB_TARBALL="vits-piper-en_GB-cori-high.tar.bz2"

# Each tarball is self-contained: <stem>.onnx, tokens.txt and a full
# espeak-ng-data tree. We extract espeak-ng-data once into a shared dir
# (both voices use the identical phonemizer assets, ~30 MB).

cd "$(dirname "$0")/.."  # → ios/

mkdir -p Frameworks Sources/TTS/Vendor \
    Resources/Models/Voices/de_DE-thorsten-high \
    Resources/Models/Voices/en_US-lessac-high \
    Resources/Models/Voices/en_GB-cori-high \
    Resources/Models/Voices/espeak-ng-data \
    .cache

# 1. Sherpa-onnx iOS xcframeworks
if [[ ! -d Frameworks/sherpa-onnx.xcframework || ! -d Frameworks/onnxruntime.xcframework ]]; then
    if [[ ! -f ".cache/${SHERPA_IOS_TARBALL}" ]]; then
        echo "→ Downloading sherpa-onnx iOS xcframeworks (${SHERPA_VERSION})…"
        curl -L --fail "${SHERPA_IOS_URL}" -o ".cache/${SHERPA_IOS_TARBALL}"
    fi
    # Re-extract idempotently — older releases used a top-level
    # `sherpa-onnx-${SHERPA_VERSION}-ios/` folder; v1.13.0 ships a
    # `build-ios/` folder with `sherpa-onnx.xcframework` and
    # `ios-onnxruntime/onnxruntime.xcframework` inside. Locate by glob.
    tar -xjf ".cache/${SHERPA_IOS_TARBALL}" -C .cache
    sherpa_src=$(find .cache -maxdepth 4 -type d -name "sherpa-onnx.xcframework" | head -n1)
    onnx_src=$(find .cache -maxdepth 5 -type d -name "onnxruntime.xcframework" | head -n1)
    if [[ -z "${sherpa_src}" || -z "${onnx_src}" ]]; then
        echo "✗ Could not locate xcframeworks inside extracted tarball:"
        find .cache -maxdepth 4 -type d -name "*.xcframework"
        exit 1
    fi
    rsync -a "${sherpa_src}/" "Frameworks/sherpa-onnx.xcframework/"
    rsync -a "${onnx_src}/"   "Frameworks/onnxruntime.xcframework/"
    echo "  ✓ Frameworks/sherpa-onnx.xcframework + Frameworks/onnxruntime.xcframework"
else
    echo "✓ xcframeworks already present"
fi

# 2. Swift bindings (single-file wrapper + bridging header from the upstream repo)
if [[ ! -f Sources/TTS/Vendor/SherpaOnnx.swift ]]; then
    echo "→ Fetching SherpaOnnx.swift bindings…"
    curl -L --fail "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/swift-api-examples/SherpaOnnx.swift" \
        -o Sources/TTS/Vendor/SherpaOnnx.swift
    curl -L --fail "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/swift-api-examples/SherpaOnnx-Bridging-Header.h" \
        -o Sources/TTS/Vendor/SherpaOnnx-Bridging-Header.h
    echo "  ✓ Sources/TTS/Vendor/{SherpaOnnx.swift,SherpaOnnx-Bridging-Header.h}"
else
    echo "✓ Swift bindings already present"
fi

# Sentinel marking that the voice dir was populated from sherpa-onnx
# tts-models (with embedded VITS metadata). If absent or stale, the
# voice is re-fetched even when an .onnx already exists — this catches
# checkouts that ran an older revision of this script and ended up with
# rhasspy-format .onnx files that crash sherpa-onnx at runtime.
SOURCE_TAG="sherpa-onnx-tts-models"

fetch_voice() {
    # `stem` is the bundle-side voice ID (matches PiperTTS.voiceStems and
    # the actual .onnx filename inside the sherpa-onnx tarball).
    # `cache_dir` is the top-level directory the tarball extracts into,
    # which sherpa-onnx prefixes with `vits-piper-`.
    local dest=$1 stem=$2 tarball=$3
    local cache_dir="vits-piper-${stem}"
    local sentinel="${dest}/.source"

    if [[ -f "${dest}/${stem}.onnx" && -f "${sentinel}" && "$(cat "${sentinel}")" == "${SOURCE_TAG}" ]]; then
        echo "✓ ${stem} already present (sherpa-onnx source)"
        return
    fi

    if [[ -f "${dest}/${stem}.onnx" ]]; then
        echo "→ Replacing ${stem} (existing copy is from a non-sherpa-onnx source)…"
        rm -f "${dest}"/* "${dest}"/.source
    else
        echo "→ Downloading ${stem} (~120 MB)…"
    fi

    if [[ ! -f ".cache/${tarball}" ]]; then
        curl -L --fail "${SHERPA_TTS_BASE}/${tarball}" -o ".cache/${tarball}"
    fi
    rm -rf ".cache/${cache_dir}"
    tar -xjf ".cache/${tarball}" -C .cache
    cp -f ".cache/${cache_dir}/${stem}.onnx"  "${dest}/${stem}.onnx"
    cp -f ".cache/${cache_dir}/tokens.txt"    "${dest}/tokens.txt"
    if [[ -f ".cache/${cache_dir}/MODEL_CARD" ]]; then
        cp -f ".cache/${cache_dir}/MODEL_CARD" "${dest}/MODEL_CARD"
    fi
    echo "${SOURCE_TAG}" > "${sentinel}"
    echo "  ✓ ${dest}/"
}

# 3a. German voice — thorsten-high (from sherpa-onnx with embedded metadata)
fetch_voice "Resources/Models/Voices/de_DE-thorsten-high" "de_DE-thorsten-high" "${DE_TARBALL}"

# 3b. American English voice — lessac-high
fetch_voice "Resources/Models/Voices/en_US-lessac-high" "en_US-lessac-high" "${EN_US_TARBALL}"

# 3c. British English voice — cori-high
fetch_voice "Resources/Models/Voices/en_GB-cori-high" "en_GB-cori-high" "${EN_GB_TARBALL}"

# 4. Shared espeak-ng-data — extracted from one of the voice tarballs
#    (both ship identical phonemizer assets, ~30 MB).
espeak_sentinel="Resources/Models/Voices/espeak-ng-data/.source"
if [[ ! -d Resources/Models/Voices/espeak-ng-data/voices \
      || ! -f "${espeak_sentinel}" \
      || "$(cat "${espeak_sentinel}" 2>/dev/null)" != "${SOURCE_TAG}" ]]; then
    echo "→ Extracting shared espeak-ng-data…"
    src=".cache/vits-piper-de_DE-thorsten-high"
    if [[ ! -d "${src}/espeak-ng-data" ]]; then
        # Tarball was fully consumed and tidied — re-extract just for espeak.
        tar -xjf ".cache/${DE_TARBALL}" -C .cache
    fi
    rm -rf Resources/Models/Voices/espeak-ng-data
    rsync -a "${src}/espeak-ng-data/" "Resources/Models/Voices/espeak-ng-data/"
    echo "${SOURCE_TAG}" > "${espeak_sentinel}"
    echo "  ✓ Resources/Models/Voices/espeak-ng-data/"
else
    echo "✓ espeak-ng-data already present"
fi

# 5. Sidecar XcodeGen overlay that wires the framework deps + bridging
#    header + PIPER_TTS compilation flag. Without this overlay, the main
#    project.yml stays clean and the app builds without Piper.
cat > project-piper.yml <<'YAML'
# Auto-generated by ios/scripts/fetch_piper_voices.sh — DO NOT HAND-EDIT.
# Layered on top of project.yml via:
#     xcodegen --spec project.yml,project-piper.yml
targets:
  VoiceDiary:
    settings:
      base:
        SWIFT_OBJC_BRIDGING_HEADER: Sources/TTS/Vendor/SherpaOnnx-Bridging-Header.h
        FRAMEWORK_SEARCH_PATHS: $(inherited) $(SRCROOT)/Frameworks
        SWIFT_ACTIVE_COMPILATION_CONDITIONS: $(inherited) PIPER_TTS
    dependencies:
      - framework: Frameworks/sherpa-onnx.xcframework
        embed: true
        codeSign: true
      - framework: Frameworks/onnxruntime.xcframework
        embed: true
        codeSign: true
YAML
echo "✓ project-piper.yml"

if command -v xcodegen >/dev/null 2>&1; then
    echo "→ Regenerating Xcode project with Piper overlay…"
    # `project.yml` pulls in `project-piper.yml` via its `include:` directive,
    # so a plain `xcodegen generate` is enough — no `--spec a,b` needed.
    xcodegen generate
else
    echo "⚠ xcodegen not found in PATH. Install with: brew install xcodegen"
    echo "  Then run: cd ios && xcodegen generate"
fi

echo
echo "All set. Next steps:"
echo "  1. open VoiceDiary.xcodeproj and build → run"
echo "  2. Settings → Stimmen → tap any Piper voice (Thorsten / Lessac / Cori) to select"
echo "     it for that language; the walkthrough will use it on the next session"
echo "  3. Use the play button next to each voice to A/B against Apple Premium"
echo
echo "Disk used by .cache (safe to delete after first build): $(du -sh .cache 2>/dev/null | cut -f1)"
