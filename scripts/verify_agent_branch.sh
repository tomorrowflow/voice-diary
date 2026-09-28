#!/usr/bin/env bash
# verify_agent_branch.sh — host-side iOS build/test gate for a sandcastle agent branch.
#
# iOS branches are EDITED in the Linux sandbox but cannot be BUILT there (xcodebuild is
# macOS-only). This script is the real acceptance step: it checks out the agent branch in a
# throwaway git worktree, regenerates the Xcode project with XcodeGen, and runs the unit
# tests on the iPhone 17 Pro simulator. Run it on the Mac before merging an iOS branch that
# main.mts parked with the `sandcastle:needs-host-verify` label.
#
# It does NOT run on-device manual scenarios or voice tests — those remain a human step
# (CLAUDE.md "test before claiming done"). The agent's commit names which DEVELOPMENT.md §7
# scenario to run by hand.
#
# Usage:   scripts/verify_agent_branch.sh sandcastle/issue-<n>
# Exit 0 = build + simulator unit tests green; nonzero = gate failed (do not merge).

set -euo pipefail

BRANCH="${1:-}"
if [[ -z "$BRANCH" ]]; then
  echo "usage: $0 <agent-branch>   (e.g. $0 sandcastle/issue-42)" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR="${VD_SIMULATOR:-iPhone 17 Pro}"
WORKTREE="$(mktemp -d /tmp/vd-verify.XXXXXX)"

cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Preconditions"
command -v xcodebuild >/dev/null || { echo "xcodebuild not found — run on macOS with Xcode." >&2; exit 1; }
command -v xcodegen  >/dev/null || { echo "xcodegen not found — 'brew install xcodegen'." >&2; exit 1; }
git -C "$REPO_ROOT" rev-parse --verify "$BRANCH" >/dev/null 2>&1 \
  || { echo "branch '$BRANCH' not found (fetch it or check the name)." >&2; exit 1; }

echo "==> Checking out $BRANCH in a throwaway worktree: $WORKTREE"
git -C "$REPO_ROOT" worktree add --force "$WORKTREE" "$BRANCH"

echo "==> Regenerating the Xcode project (XcodeGen)"
( cd "$WORKTREE/ios" && xcodegen generate )

echo "==> Building + running unit tests on '$SIMULATOR'"
( cd "$WORKTREE/ios" && xcodebuild test \
    -scheme VoiceDiary \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -configuration Debug \
    -quiet )

echo
echo "✅ $BRANCH: build + simulator unit tests PASSED."
echo "   Reminder: run the on-device manual scenario named in the commit (DEVELOPMENT.md §7)"
echo "   before merging. This script does not exercise voice/hardware paths."
