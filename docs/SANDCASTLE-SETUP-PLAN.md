# Sandcastle Setup Plan

**Status: proposal — not yet implemented.**
Target: run AI coding agents against this repo in isolated sandboxes, so review findings
(see `docs/REVIEW-2026-07-04.md`) can be worked in parallel without touching the working tree.

Sandcastle (<https://github.com/mattpocock/sandcastle>, `@ai-hero/sandcastle`) is a TypeScript
library that runs coding agents (Claude Code among others) inside Docker/Podman sandboxes on
git worktrees, with a configurable **branch strategy** that merges the agent's commits back.
One `run()` call = one sandboxed agent task.

---

## 1. Why it fits this repo

- **Monorepo with two very different toolchains.** Server tasks are fully sandboxable
  (Python 3.12 + Docker). iOS tasks are *editable* in a Linux sandbox but only *verifiable*
  on the macOS host (`xcodebuild` does not run in Linux containers). Sandcastle's split
  between sandboxed editing (`branchStrategy: branch`) and host-side hooks handles exactly this.
- **A queue of independent findings.** The review produced many self-contained items
  (see the findings doc). `branch`-strategy runs on `agent/<finding-id>` branches let several
  agents work concurrently, each reviewable as a normal branch/PR.
- **Secrets hygiene.** Agents never see `server/.env`, `data/msal_cache.bin`, or Keychain
  material — the sandbox gets a worktree copy plus only what `copyToWorktree` explicitly allows.

## 2. Prerequisites (verified on this machine 2026-07-04)

| Requirement | Status |
|---|---|
| Node.js ≥ 22 | ✅ v22.17.0 |
| Docker | ✅ 29.4.1 (Podman optional alternative) |
| Git worktree support | ✅ standard git |
| Claude Code auth | `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN` (one-time) |

The repo currently has **no `package.json`** — sandcastle will introduce the first Node
tooling. Keep it minimal and private (never published).

## 3. Installation steps

```bash
cd ~/Documents/GitHub/voice-diary

# 1. Minimal private package.json at repo root
npm init -y && npm pkg set private=true

# 2. Install sandcastle as a dev dependency
npm install --save-dev @ai-hero/sandcastle tsx zod

# 3. Scaffold .sandcastle/ (choose: Docker provider, template "simple-loop" to start,
#    issue tracker "Custom" — we drive from the findings doc, not GitHub Issues, initially)
npx @ai-hero/sandcastle init

# 4. Auth
claude setup-token          # then put CLAUDE_CODE_OAUTH_TOKEN into .sandcastle/.env
```

`.gitignore` additions: `node_modules/`, `.sandcastle/.env`, `.sandcastle/logs/`
(the `init` scaffold ships a local `.gitignore` for the last two — verify it).

## 4. Sandbox image (`.sandcastle/Dockerfile`)

One image serving both tracks. Base = the scaffolded default (Node 22, git, curl, jq,
GitHub CLI, Claude Code CLI, non-root `agent` user), extended with:

```dockerfile
# --- server track: run unit tests inside the sandbox ---
RUN apt-get update && apt-get install -y python3.12 python3.12-venv ffmpeg
COPY server/webapp/requirements.txt /tmp/requirements.txt
RUN python3.12 -m venv /opt/venv && /opt/venv/bin/pip install -r /tmp/requirements.txt pytest
ENV PATH="/opt/venv/bin:$PATH"

# --- iOS track: lint/format only; building happens on the host ---
# swift-format via the official Swift Linux toolchain is optional; start without it.
```

Notes:

- **Server unit tests** (`webapp/tests/`, mocked MSAL/LightRAG/Ollama/Whisper) run fine
  inside the sandbox with the venv above. **Integration tests** (real `docker compose up`)
  need Docker-in-Docker — deliberately out of scope; they stay a host-side gate.
- Rebuild after Dockerfile changes: `npx sandcastle docker build-image`.

## 5. Branch strategy

Use `{ type: "branch", branch: "agent/<finding-id>" }` for everything.

- Parallel-safe: each run gets its own worktree; re-running the same branch resumes it.
- Nothing merges automatically — you review `agent/*` branches and merge manually
  (matches the repo's convention of short imperative commits, no auto-merge surprises).
- Avoid `head` and `merge-to-head` strategies: this repo's owner works on `main` directly;
  agents must never write to the host working tree.

## 6. Runner scripts (`.sandcastle/`)

### 6.1 `server-task.ts` — server-side findings (fully sandboxed)

```typescript
import { run } from "@ai-hero/sandcastle";
import { claudeCode } from "@ai-hero/sandcastle/agents/claude-code";
import { docker } from "@ai-hero/sandcastle/sandboxes/docker";

const findingId = process.argv[2]; // e.g. SRV-A1

await run({
  agent: claudeCode("claude-opus-4-8", { effort: "high" }),
  sandbox: docker(),
  branchStrategy: { type: "branch", branch: `agent/${findingId.toLowerCase()}` },
  promptFile: ".sandcastle/prompts/server-finding.md",
  promptArgs: { FINDING_ID: findingId },
  maxIterations: 5,
  name: `finding-${findingId}`,
  hooks: {
    sandbox: {
      // venv is baked into the image; just prove the suite is green before starting
      onSandboxReady: [{ command: "cd server/webapp && python -m pytest tests/ -q" }],
    },
  },
  logging: { type: "file", path: `.sandcastle/logs/${findingId}.log` },
});
```

`prompts/server-finding.md` instructs the agent to: read `CLAUDE.md`, `SPEC.md`,
`docs/REVIEW-2026-07-04.md` finding `{{FINDING_ID}}`; implement it; run
`pytest webapp/tests/`; commit in the repo's style. It must state explicitly that
`.env` does not exist in the sandbox and integration tests are skipped.

### 6.2 `ios-task.ts` — iOS findings (sandboxed edit, host-verified build)

```typescript
await run({
  agent: claudeCode("claude-opus-4-8", { effort: "high" }),
  sandbox: docker(),
  branchStrategy: { type: "branch", branch: `agent/${findingId.toLowerCase()}` },
  promptFile: ".sandcastle/prompts/ios-finding.md",
  promptArgs: { FINDING_ID: findingId },
  maxIterations: 5,
  hooks: {
    host: {
      // XcodeGen regeneration + build gate run on the macOS host against the worktree
      onWorktreeReady: [{ command: "cd ios && xcodegen generate 2>/dev/null || true" }],
    },
  },
});
// After the run: host-side gate before considering the branch reviewable
// git worktree add /tmp/vd-verify agent/<id>
// cd /tmp/vd-verify/ios && xcodegen generate && xcodebuild test -scheme VoiceDiary \
//   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The iOS prompt must say: **you cannot build or run tests in this sandbox** — write code,
keep diffs small, note in the commit message which manual scenario (DEVELOPMENT.md §7)
must be run on-device. The host build gate (wrap it as `scripts/verify_agent_branch.sh`)
is the real acceptance step; a branch that fails it goes back into the same worktree for
another `run()` on the same branch.

### 6.3 `review-pipeline.ts` — implement-then-review (later phase)

Sandcastle's `createSandbox` keeps one branch/worktree across steps:

```typescript
await using sandbox = await createSandbox({ branch: `agent/${id}`, sandbox: docker() });
await sandbox.run({ agent: claudeCode("claude-opus-4-8"), promptFile: ".sandcastle/prompts/server-finding.md", promptArgs: { FINDING_ID: id } });
await sandbox.run({ agent: claudeCode("claude-sonnet-5"), prompt: "Review the diff on this branch against SPEC.md and CLAUDE.md hard rules. Fix violations. Run pytest." });
```

## 7. Secrets & safety rules

1. **Never `copyToWorktree` real secrets.** Allowed: `server/.env.example` only. The sandbox
   must work without `server/.env`, `server/data/**`, or any token.
2. `.sandcastle/.env` holds only `CLAUDE_CODE_OAUTH_TOKEN`; it is gitignored.
3. Sandbox network: default Docker network is fine for npm/pip; agents must not be pointed
   at the Tailscale server. Do not pass `IOS_BEARER_TOKEN` or tailnet hostnames into prompts.
4. Agents never touch `main` (branch strategy enforces this); merging is always manual.

## 8. Phased rollout

| Phase | What | Exit criterion |
|---|---|---|
| 0 | Install + `init`, build image, commit `.sandcastle/` scaffold + root `package.json` | `npx tsx .sandcastle/main.ts` runs the demo prompt in a sandbox |
| 1 | Pilot: one small **server** finding via `server-task.ts` | Branch `agent/<id>` builds, pytest green, manually merged |
| 2 | Parallel server runs (2–3 findings concurrently) | No worktree collisions; all branches reviewable |
| 3 | iOS pilot with host build gate (`verify_agent_branch.sh`) | One iOS finding lands via agent branch + on-device manual scenario |
| 4 | `review-pipeline.ts` (implement → review on same branch) | Reviewer step catches at least the hard-rule violations |
| 5 | Optional: switch issue source from findings doc to GitHub Issues (`simple-loop` template) once findings are triaged into issues (e.g. via `/to-issues`) | Agent picks issues unattended |

## 9. Known limitations / decisions to revisit

- **No `xcodebuild` in sandbox** — iOS verification is host-only. If this becomes the
  bottleneck, alternatives are `noSandbox()` runs on the host (loses isolation) or a
  self-hosted macOS runner; both are explicitly deferred.
- **No Docker-in-Docker** — server integration tests and `docker compose` smoke tests stay
  on the host, post-merge.
- **On-device voice testing cannot be delegated.** CLAUDE.md's "test before claiming done"
  for voice features remains a human step; agent commits should say so.
- Model choices in the examples (`claude-opus-4-8` implement, `claude-sonnet-5` review)
  are starting points — tune per task size.
