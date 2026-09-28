# ISSUES

Here are the open Sandcastle issues in the repo, already filtered to work that is ready
and NOT already parked awaiting host verification:

<issues-json>

!`gh issue list --state open --label Sandcastle --limit 100 --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}] | map(select((.labels | index("sandcastle:needs-host-verify")) | not))'`

</issues-json>

# CONTEXT

This is the **voice-diary** monorepo — two independently-deployable tracks:

- **server** (`server/`): FastAPI + Python 3.12, fully sandboxable, unit tests run in-sandbox.
- **ios** (`ios/`): Swift 6 / SwiftUI. Editable in the sandbox but **only verifiable on the
  macOS host** (`xcodebuild` does not run in Linux). iOS branches never auto-merge.

Most issues carry a `track:server` or `track:ios` label and reference a stable finding ID
(e.g. `SRV-A1`, `SEC-2`, `IOS-A3`) from `docs/REVIEW-2026-07-04.md`.

# TASK

Analyze the open issues and build a dependency graph. For each issue, determine whether it
**blocks** or **is blocked by** any other open issue.

An issue B is **blocked by** issue A if:

- B requires code or infrastructure that A introduces
- B and A modify overlapping files or modules, making concurrent work likely to produce merge
  conflicts (e.g. two issues both rewriting `WalkthroughCoordinator.swift`, or both touching
  `main.py` route registration — schedule these in separate rounds)
- B's requirements depend on a decision or API shape that A will establish (e.g. the shared
  Ollama/Whisper adapter in SRV-A1/A2 unblocks the callers that depend on it)

An issue is **unblocked** if it has zero blocking dependencies on other open issues.

For each unblocked issue, assign a branch name using the exact format `sandcastle/issue-{id}`
(no slug or other suffix). This must be deterministic so re-planning the same issue always
produces the same branch name and accumulated progress is preserved.

Determine each issue's **track**: `server` if it only touches `server/`, `ios` if it only
touches `ios/`, from the `track:*` label (fall back to the file paths named in the issue). If a
single issue would touch both trees, keep it and set track `ios` (the stricter, host-verified
gate) — but prefer NOT to select such cross-cutting issues concurrently with others touching the
same files.

# OUTPUT

Output your plan as a JSON object wrapped in `<plan>` tags:

<plan>
{"issues": [{"id": "42", "title": "Bind port 8000 to the tailnet IP", "branch": "sandcastle/issue-42", "track": "server"}]}
</plan>

Include only unblocked issues. If every issue is blocked, include the single highest-priority
candidate (the one with the fewest or weakest dependencies).

Always emit the `<plan>` tags, even when there is nothing to do. If there are no issues to work
on at all, output `<plan>{"issues": []}</plan>` so the run can exit cleanly.
