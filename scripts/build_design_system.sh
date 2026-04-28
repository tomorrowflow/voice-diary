#!/usr/bin/env bash
# Rebuild the design-system tokens and copy generated outputs into the
# iOS and server source trees. Run after editing anything under
# docs/design-system/tokens/.
#
# Usage:
#     bash scripts/build_design_system.sh
#
# Prereq: `npm install` once inside docs/design-system/.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DS_DIR="$ROOT/docs/design-system"
IOS_DEST="$ROOT/ios/Sources/DesignSystem"
SERVER_DEST="$ROOT/server/webapp/static"

if [ ! -d "$DS_DIR/node_modules" ]; then
  echo "→ Installing design-system dependencies (one-time)…"
  ( cd "$DS_DIR" && npm install --silent )
fi

echo "→ Building tokens…"
( cd "$DS_DIR" && npm run --silent build:clean )

mkdir -p "$IOS_DEST" "$SERVER_DEST"

echo "→ Copying SwiftUI outputs to $IOS_DEST/"
cp "$DS_DIR/build/ios/DSColor.swift"    "$IOS_DEST/"
cp "$DS_DIR/build/ios/DSMetrics.swift"  "$IOS_DEST/"
cp "$DS_DIR/build/ios/DSSemantic.swift" "$IOS_DEST/"

echo "→ Copying CSS outputs to $SERVER_DEST/"
cp "$DS_DIR/build/css/tokens.css"          "$SERVER_DEST/"
cp "$DS_DIR/build/css/tokens-semantic.css" "$SERVER_DEST/"

echo "✓ Design-system build complete."
