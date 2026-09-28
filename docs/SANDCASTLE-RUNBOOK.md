# Sandcastle Runbook

Operational guide for the sandcastle agent environment set up per `docs/SANDCASTLE-SETUP-PLAN.md`.
Two ways to work the `Sandcastle`-labelled issues (both consume the same prompts + standards):

- **Interactive, human-gated:** the `/phase <issue>` skill — one issue in a worktree, you review
  each step. Best for the first pilot and anything subtle.
- **Autonomous, parallel:** `npm run sandcastle` (from `.sandcastle/`) — plans, implements, reviews, and merges many
  issues per round in Podman sandboxes (rootless, on the `podman machine`).

## One-time setup

```bash
cd ~/Documents/GitHub/voice-diary/.sandcastle   # package.json lives here

# 1. Install deps (@ai-hero/sandcastle, tsx, zod).
npm install

# 2. Auth token for the sandboxed agents (uses your Claude subscription).
claude setup-token
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' '<paste-token>' > .env
# The sandbox also needs GitHub access to read/comment issues. Add a fine-grained
# PAT (Issues: read/write, Contents: read) as GH_TOKEN in the same file:
printf 'GH_TOKEN=%s\n'                 '<paste-pat>'   >> .env
# .sandcastle/.env is gitignored. NEVER put IOS_BEARER_TOKEN or a tailnet host here.

# 3. Podman machine must be running (sandcastle checks this before every sandbox).
podman machine start   # no-op if already running

# 4. Build the sandbox image (Node + gh + Claude + Python 3.12 venv + ffmpeg) from
#    .sandcastle/Containerfile with the repo root as build context (it COPYs
#    server/webapp/requirements.txt). Heavy the first time. Rerun after any
#    Containerfile or requirements.txt change.
npm run build-image
```

## Autonomous run

```bash
# Runs against the CURRENT branch (usually `main`). Agents never write to it: the
# merger works in a staging worktree and the host fast-forwards the target only
# after the merger signals COMPLETE.
cd .sandcastle && npm run sandcastle
```

At most 5 issue sandboxes run at once (about 1 GiB each on the 8 GiB podman machine, which
also hosts blindfold's containers). Override for one run with
`SANDCASTLE_MAX_PARALLEL=3 npm run sandcastle`; raise the default only together with
`podman machine set --memory`.

Launch it from a Supacode terminal to get the Supacode extras. Each is skipped
automatically outside Supacode.
- **Worktrees you can open:** each issue's worktree is created through Supacode under
  `.sandcastle/worktrees/`, so you can open it and watch the agent work.
- **Live traces:** a "traces" tab per worktree tails each agent's log (planner and merger
  on the target and staging branches, implementer and reviewer per issue).
- **Clean teardown:** merged branches are reaped through Supacode, so no stale worktrees
  are left behind.

## Agent models and providers

Every role (planner, implementer, reviewer, merger) runs Claude Code. What you can change
per role is the model and the provider behind it: Anthropic, or Ollama, which serves the
Anthropic Messages API (the same mechanism `ollama launch claude` uses). The settings live
in `.sandcastle/.env`, and the run prints the resolved table at startup.

```bash
# Per role: <provider>:<model>, or a bare <model> for the default provider
SANDCASTLE_MODEL_IMPLEMENT=ollama:kimi-k2.7-code
SANDCASTLE_MODEL_REVIEW=anthropic:claude-opus-4-8
# SANDCASTLE_MODEL_PLAN=   SANDCASTLE_MODEL_MERGE=   (unset = default)

# Ollama as the default provider for every role you don't override
OLLAMA_MODEL=kimi-k2.7-code          # list: curl -s https://ollama.com/api/tags
OLLAMA_API_KEY=<key>                 # https://ollama.com/settings/keys (Ollama Cloud)
# local Ollama instead: OLLAMA_BASE_URL=http://host.containers.internal:11434 (no key)
```

Rules:
- The per-role choice lives in `.env`. The current setup: plan and review on
  `anthropic:claude-opus-5-5`, implement on `ollama:glm-5.3` (Ollama Cloud, so `OLLAMA_API_KEY`
  must be set), merge on `anthropic:claude-sonnet-5`.
- A role left unset runs on `claude-sonnet-5`, the single built-in default in `main.mts`.
- Setting `OLLAMA_MODEL` moves every role you don't override onto Ollama with that model.
- `ollama:` or `anthropic:` with no model name means that provider's default model.
- The run stops at startup if a provider you picked is missing its credential: the Claude
  token for Anthropic roles, `OLLAMA_API_KEY` for Ollama Cloud roles.
- The reviewer is the merge gate. When you move roles to Ollama, consider keeping it on
  `anthropic:claude-opus-4-8`.

While a role runs on Ollama:
- every Claude Code model alias (haiku/sonnet/opus, subagents) is pinned to that model
- the Anthropic token in `.env` isn't used, because `ANTHROPIC_AUTH_TOKEN` outranks it
- local models need at least 64k context (`OLLAMA_CONTEXT_LENGTH=65536` on the Ollama
  server) and can be slow enough to hit sandcastle's 600 s idle timeout

What happens each round (`.sandcastle/main.mts`):
1. **Plan** — reads open `Sandcastle` issues (excluding those parked `needs-host-verify`), builds
   a dependency graph, emits unblocked issues with a `track` (server / ios) each.
2. **Execute + Review** — per issue, a sandbox on `sandcastle/issue-<n>`: implementer
   (red-green-refactor, 100 iters) → independent reviewer (hard-rule + correctness gate, 1 iter).
3. **Gate** —
   - **server** cleared (implementer + reviewer signalled COMPLETE, pytest green) → auto-merged.
   - **ios** cleared → **never auto-merged**. Parked with `sandcastle:needs-host-verify` + a
     comment telling you to run the host gate. iOS can't be built in Linux.
   - anything that failed a gate → `sandcastle:blocked` with the reason; commits kept on the branch.
4. **Merge**: one agent merges the cleared server branches on `sandcastle/merge-staging` (its
   own worktree, recreated from the target each round) and runs pytest. If it signals COMPLETE,
   the host runs `git merge --ff-only` to move the target forward, then closes the issues and
   reaps the branches. If anything fails, the target stays untouched, the result stays parked
   on the staging branch, and the issues get `sandcastle:blocked`.

Issue state is visible at a glance via `sandcastle:*` labels: `running`, `needs-host-verify`,
`blocked`, `merged`.

## iOS host gate

For any branch parked `sandcastle:needs-host-verify`, on the Mac:

```bash
scripts/verify_agent_branch.sh sandcastle/issue-<n>   # xcodegen + xcodebuild test on iPhone 17 Pro sim
```

Green build + sim tests is necessary but **not sufficient**: run the on-device manual scenario
named in the commit (DEVELOPMENT.md §7) before merging by hand. Voice/hardware paths are never
delegated to an agent.

## Scope, secrets, safety

- Agents only ever see a worktree copy — no `server/.env`, no `server/data/**`, no tokens
  (`copyToWorktree = []`). The sandbox is built to work without them; integration tests that need
  a live `docker compose up` are out of scope and stay a host step.
- Sandbox network reaches npm/pip/GitHub only — never point an agent at the Tailscale server.
- Server branches reach the target (the branch you launched from) only by a host-side
  `git merge --ff-only` of the attested staging result; no agent writes to the target checkout.
  iOS never merges without the host gate + on-device scenario.

## Tuning

- Models per role in `main.mts`: work roles (`MODEL_PLAN/IMPLEMENT/MERGE`) run on
  `claude-sonnet-5`; `MODEL_REVIEW` stays on `claude-opus-4-8` (the fail-closed merge
  gate — don't downgrade it). Tune cost by moving the Sonnet roles, not the reviewer.
- `MAX_ITERATIONS` — plan→merge cycles per invocation.
- Prompts: `.sandcastle/{plan,implement,review,merge}-prompt.md`; standards enforced by the
  reviewer: `.sandcastle/CODING_STANDARDS.md`.
