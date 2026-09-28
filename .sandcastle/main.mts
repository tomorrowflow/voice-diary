// Voice Diary — parallel planner with review, track-aware merge gate.
//
// Four-phase loop, adapted from the sandcastle "parallel planner with review"
// template for this two-track monorepo:
//
//   Phase 1 (Plan):    An agent reads open `Sandcastle` issues, builds a
//                      dependency graph, and emits a <plan> JSON of the unblocked
//                      issues with a deterministic branch AND a `track`
//                      (server | ios) each.
//   Phase 2 (Execute + Review): Per issue, a sandbox is created on its branch.
//                      The implementer runs (100 iters); if it produced work the
//                      independent reviewer runs in the same sandbox (1 iter).
//                      Issue pipelines run concurrently, capped at MAX_PARALLEL.
//   Phase 3 (Gate):    server branches that cleared implementer + reviewer
//                      auto-merge. ios branches NEVER auto-merge — they are parked
//                      with `sandcastle:needs-host-verify` for the macOS host gate
//                      (`scripts/verify_agent_branch.sh`), because `xcodebuild`
//                      cannot run in the Linux sandbox.
//   Phase 4 (Merge):   One agent merges the cleared server branches in a
//                      STAGING worktree (MERGE_STAGING_BRANCH, cut fresh from the
//                      target). Only after it attests COMPLETE does the host
//                      fast-forward the target to the staging tip and close the
//                      issues. The live checkout is never written by an agent.
//
// The outer loop repeats up to MAX_ITERATIONS so newly-unblocked issues are
// picked up after each round of merges. Parked ios issues are excluded by the
// planner filter, so they don't loop forever.
//
// SAFETY: running on `main` is fine — the target only moves by a host-side
// `git merge --ff-only` of an attested staging result (same model as blindfold).
// See docs/SANDCASTLE-RUNBOOK.md.
//
// Usage (from inside .sandcastle/, where package.json lives):
//   npm run sandcastle            (== npx tsx main.mts)
// `tsx .sandcastle/main.mts` from the repo root works too — see REPO_ROOT below.

import * as sandcastle from "@ai-hero/sandcastle";
import { podman } from "@ai-hero/sandcastle/sandboxes/podman";
import { z } from "zod";
import { execSync, execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

// The planner emits its plan as JSON inside <plan> tags; Output.object extracts
// and validates it against this schema.
const planSchema = z.object({
  issues: z.array(
    z.object({
      id: z.string(),
      title: z.string(),
      branch: z.string(),
      track: z.enum(["server", "ios"]),
    }),
  ),
});

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Maximum number of plan→execute→merge cycles before stopping.
const MAX_ITERATIONS = 8;

// How many issue sandboxes run at once. Every sandbox is a Podman container
// running Claude Code (plus pytest on the server track), and they all share the
// podman machine's RAM. Launching the whole plan at once (24 issues) exhausted a
// 3.7 GiB machine: "cannot allocate memory", a dead Podman socket, and every
// sandbox crashing with git/idle timeouts. Budget roughly 1 GiB per sandbox: the
// default 5 fits the 8 GiB machine with headroom for the blindfold infra
// containers that share it. Raise only together with `podman machine set
// --memory`. Override per run with SANDCASTLE_MAX_PARALLEL=<n>.
const MAX_PARALLEL = Math.max(1, Number(process.env.SANDCASTLE_MAX_PARALLEL) || 5);

// Run `fn` over `items` with at most `limit` in flight; results keep input order,
// same shape as Promise.allSettled.
async function settledWithLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<PromiseSettledResult<R>[]> {
  const results: PromiseSettledResult<R>[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      try {
        results[i] = { status: "fulfilled", value: await fn(items[i]!) };
      } catch (reason) {
        results[i] = { status: "rejected", reason };
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

// Built-in model per role when .sandcastle/.env doesn't choose one: the latest
// Sonnet. The actual per-role choice (e.g. Opus for the planner and the
// fail-closed reviewer, an Ollama model for implementers) lives in .env as
// SANDCASTLE_MODEL_<ROLE> — see "Per-role model settings" below.
const DEFAULT_MODELS = {
  PLAN: "claude-sonnet-5",
  IMPLEMENT: "claude-sonnet-5",
  REVIEW: "claude-sonnet-5",
  MERGE: "claude-sonnet-5",
} as const;

// The server venv + tools are baked into the image; nothing to install per run.
// A trivial hook keeps the shape and gives an early failure if the image is wrong.
const hooks = {
  sandbox: { onSandboxReady: [{ command: "python --version" }] },
};

// Never drag host tooling or secrets into the worktree. The sandbox must work
// without server/.env, server/data/**, or any token (SANDCASTLE-SETUP-PLAN §7).
const copyToWorktree: string[] = [];

// The branch completed work merges into (current HEAD) — also the diff base.
const TARGET_BRANCH = execSync("git rev-parse --abbrev-ref HEAD", {
  encoding: "utf8",
}).trim();

// The repo root — resolved from git rather than assumed to be process.cwd(), so
// the Supacode worktree-surface path below is correct however the orchestrator
// is launched. Falls back to cwd if git can't answer.
const REPO_ROOT = (() => {
  try {
    return execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim();
  } catch {
    return process.cwd();
  }
})();

// Where sandcastle lays out its per-issue worktrees. This MUST match the
// library's own layout (`<repo>/.sandcastle/worktrees/<name>`) exactly, because
// the Supacode-surface pre-creation below relies on sandcastle finding — and
// adopting — the worktree it expects to create there.
const SANDCASTLE_WORKTREES_DIR = join(REPO_ROOT, ".sandcastle", "worktrees");

// Normalize the process working directory to the git root. The sandcastle library
// resolves git mounts and its worktree layout from process.cwd() (`<cwd>/.git`,
// `<cwd>/.sandcastle/worktrees`), so launching via `npm run sandcastle` — which runs
// from `.sandcastle/`, where package.json lives — would otherwise make it stat
// `.sandcastle/.git` and throw WorktreeError. Env is read from the process
// environment (not a cwd-relative .env), so this does not affect auth.
if (process.cwd() !== REPO_ROOT) process.chdir(REPO_ROOT);

// Prompt files live under .sandcastle/. Resolve them against REPO_ROOT (from git),
// not process.cwd(), so both launches work: `npm run sandcastle` (cwd =
// .sandcastle/) and `tsx .sandcastle/main.mts` (cwd = repo root).
const promptPath = (name: string) => join(REPO_ROOT, ".sandcastle", name);

// .sandcastle/.env, parsed once. Sandcastle itself forwards into the sandbox ONLY
// the keys listed there (a listed key with an empty value falls back to the host
// environment; an unlisted key never reaches the container). The orchestrator
// reads it too, for the model-provider switch below. Commented lines are ignored,
// so switching providers is a matter of (un)commenting a block in .env.
const dotenv = new Map<string, string>();
{
  const envFile = join(REPO_ROOT, ".sandcastle", ".env");
  if (existsSync(envFile)) {
    for (const line of readFileSync(envFile, "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
      if (m) dotenv.set(m[1]!, m[2]!.trim().replace(/^(["'])(.*)\1$/, "$2"));
    }
  }
}
const envVar = (k: string): string =>
  dotenv.has(k) ? dotenv.get(k) || process.env[k] || "" : "";

// ── Per-role model settings (Anthropic or Ollama) ────────────────────────────
// Kept IDENTICAL across the blindfold and voice-diary harnesses — only
// DEFAULT_MODELS (the role set and each role's built-in model) is per repo.
//
// Each role's model is set in .env as SANDCASTLE_MODEL_<ROLE>, where ROLE is a
// key of DEFAULT_MODELS. The value is `<provider>:<model>` or a bare `<model>`
// for the default provider:
//   SANDCASTLE_MODEL_IMPLEMENT=ollama:glm-5.3
//   SANDCASTLE_MODEL_REVIEW=anthropic:claude-opus-5-5
//   SANDCASTLE_MODEL_MERGE=glm-5.3            (default provider)
// Unset roles use DEFAULT_MODELS, unless OLLAMA_MODEL is set — then every unset
// role runs on Ollama with OLLAMA_MODEL (the "switch everything to Ollama"
// lever). A bare `<model>` means the default provider: `ollama` when
// OLLAMA_MODEL is set, else `anthropic`. `ollama:` / `anthropic:` with no model
// means that provider's default (OLLAMA_MODEL / the role's DEFAULT_MODELS entry).
//
// Ollama speaks the Anthropic Messages API, so Claude Code runs unchanged against
// it: point ANTHROPIC_BASE_URL at Ollama and authenticate with ANTHROPIC_AUTH_TOKEN
// (the same variables `ollama launch claude` sets). ANTHROPIC_AUTH_TOKEN outranks
// CLAUDE_CODE_OAUTH_TOKEN in Claude Code's auth precedence, so the Anthropic token
// can stay in .env while a role runs on Ollama.
//   OLLAMA_API_KEY    required for Ollama Cloud (https://ollama.com/settings/keys)
//   OLLAMA_BASE_URL   default https://ollama.com; a host-local Ollama is
//                     http://host.containers.internal:11434 (no key needed)
// Every Claude Code model alias (haiku/sonnet/opus, subagents, background tasks)
// is pinned to the role's Ollama model — the Anthropic model IDs don't exist there.
type Role = keyof typeof DEFAULT_MODELS;
type Provider = "anthropic" | "ollama";
const ROLES = Object.keys(DEFAULT_MODELS) as Role[];
const OLLAMA_MODEL = envVar("OLLAMA_MODEL");
const OLLAMA_BASE_URL = envVar("OLLAMA_BASE_URL") || "https://ollama.com";
const OLLAMA_API_KEY = envVar("OLLAMA_API_KEY");
const OLLAMA_IS_CLOUD = /^https:\/\/(www\.)?ollama\.com/.test(OLLAMA_BASE_URL);
const DEFAULT_PROVIDER: Provider = OLLAMA_MODEL ? "ollama" : "anthropic";

function resolveRole(role: Role): { provider: Provider; model: string } {
  const spec = envVar(`SANDCASTLE_MODEL_${role}`);
  const m = spec.match(/^(anthropic|ollama):(.*)$/);
  const provider: Provider = m ? (m[1] as Provider) : DEFAULT_PROVIDER;
  // `ollama:` / `anthropic:` with no model = that provider's default model.
  const model =
    (m ? m[2]!.trim() : spec) ||
    (provider === "ollama" ? OLLAMA_MODEL : DEFAULT_MODELS[role]);
  if (!model) {
    console.error(
      `\n✗ ${role} is set to Ollama but has no model: set SANDCASTLE_MODEL_${role}=ollama:<model> ` +
        `or OLLAMA_MODEL in .sandcastle/.env.\n`,
    );
    process.exit(1);
  }
  return { provider, model };
}
const ROLE_MODELS = Object.fromEntries(ROLES.map((r) => [r, resolveRole(r)])) as Record<
  Role,
  { provider: Provider; model: string }
>;

function agentFor(role: Role) {
  const { provider, model } = ROLE_MODELS[role];
  if (provider === "anthropic") return sandcastle.claudeCode(model);
  const routing = {
    ANTHROPIC_BASE_URL: OLLAMA_BASE_URL,
    ANTHROPIC_DEFAULT_HAIKU_MODEL: model,
    ANTHROPIC_DEFAULT_SONNET_MODEL: model,
    ANTHROPIC_DEFAULT_OPUS_MODEL: model,
    CLAUDE_CODE_SUBAGENT_MODEL: model,
  };
  const base = sandcastle.claudeCode(model, {
    // Local Ollama accepts any bearer token; the docs use the literal "ollama".
    env: { ...routing, ANTHROPIC_AUTH_TOKEN: OLLAMA_API_KEY || "ollama" },
  });
  // The provider `env` above only reaches the agent via sandcastle.run().
  // createSandbox() starts the container with an EMPTY agent env and
  // sandbox.run() execs without it (sandcastle 0.12), so branch-scoped runs
  // would silently drop the redirect and send the Ollama model id to Anthropic
  // ("There's an issue with the selected model"). Prefix the assignments onto
  // the command itself: per-command, so an Anthropic role in the SAME sandbox
  // (e.g. an Opus reviewer) is unaffected. The key is referenced as
  // $OLLAMA_API_KEY (already in the container env from .env) so its value
  // never appears in the command string or the logs.
  const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
  const prefix =
    Object.entries(routing)
      .map(([k, v]) => `${k}=${shq(v)}`)
      .join(" ") +
    ` ANTHROPIC_AUTH_TOKEN=${OLLAMA_API_KEY ? '"$OLLAMA_API_KEY"' : "ollama"} `;
  return {
    ...base,
    buildPrintCommand(opts: Parameters<typeof base.buildPrintCommand>[0]) {
      const cmd = base.buildPrintCommand(opts);
      return { ...cmd, command: prefix + cmd.command };
    },
  };
}

// Fail fast on missing credentials, and print what each role runs on so a
// misconfigured .env is visible at startup rather than as a failed agent. A
// missing GH_TOKEN otherwise surfaces as an opaque PromptError from the
// planner's `gh issue list` preprocessing step.
{
  const used = new Set(ROLES.map((r) => ROLE_MODELS[r].provider));
  const missing: string[] = [];
  if (!envVar("GH_TOKEN")) missing.push("GH_TOKEN");
  if (used.has("anthropic") && !envVar("CLAUDE_CODE_OAUTH_TOKEN")) {
    missing.push("CLAUDE_CODE_OAUTH_TOKEN");
  }
  if (used.has("ollama") && OLLAMA_IS_CLOUD && !OLLAMA_API_KEY) {
    missing.push("OLLAMA_API_KEY (Ollama Cloud)");
  }
  if (missing.length > 0) {
    console.error(
      `\n✗ Missing sandbox credential(s): ${missing.join(", ")}.\n` +
        `  Add them to .sandcastle/.env (see .sandcastle/.env.example).\n`,
    );
    process.exit(1);
  }
  console.log("\nAgent models:");
  for (const r of ROLES) {
    const { provider, model } = ROLE_MODELS[r];
    const where = provider === "ollama" ? `ollama @ ${OLLAMA_BASE_URL}` : "anthropic";
    console.log(`  ${r.toLowerCase().padEnd(12)} ${model}  (${where})`);
  }
}

// The staging branch the merger operates on. The merge lands here first, in its
// own worktree, and the target is only fast-forwarded AFTER the merger attests
// COMPLETE. The merger never writes to the live target checkout, so a failed or
// half-finished merge can't leave unverified code on the target.
const MERGE_STAGING_BRANCH = "sandcastle/merge-staging";

// ---------------------------------------------------------------------------
// GitHub issue lifecycle (host-side, best-effort, fail-OPEN)
//
// The orchestrator runs on the HOST, where `gh` is authenticated. Issue updates
// happen here, not inside sandboxes. Every call is swallowed on error so an
// issue-tracker hiccup can never throw into the gate below.
// ---------------------------------------------------------------------------

const REPO = (() => {
  try {
    return execFileSync(
      "gh",
      ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
      { encoding: "utf8" },
    ).trim();
  } catch {
    return "";
  }
})();

// Mutually-exclusive state labels: exactly one reflects where an issue is now.
const SANDCASTLE_LABELS = [
  ["running", "FBCA04", "A Sandcastle agent is working this issue now"],
  ["needs-host-verify", "1D76DB", "iOS branch implemented — awaiting macOS host xcodebuild gate"],
  ["blocked", "B60205", "Sandcastle gate withheld — needs a human"],
  ["merged", "0E8A16", "Sandcastle merged this branch into the target branch"],
] as const;
type SandcastleState = (typeof SANDCASTLE_LABELS)[number][0];

function ensureSandcastleLabels(): void {
  if (!REPO) return;
  for (const [name, color, description] of SANDCASTLE_LABELS) {
    try {
      execFileSync(
        "gh",
        ["label", "create", `sandcastle:${name}`, "--repo", REPO, "--color", color, "--description", description, "--force"],
        { stdio: "ignore" },
      );
    } catch {
      /* label tooling is non-critical */
    }
  }
}

// Post a timeline comment at most once, keyed by an invisible marker.
function postOnce(id: string, marker: string, body: string): void {
  if (!REPO) return;
  try {
    const existing = execFileSync(
      "gh",
      ["issue", "view", id, "--repo", REPO, "--json", "comments", "-q", "[.comments[].body]"],
      { encoding: "utf8" },
    );
    if (existing.includes(marker)) return;
    execFileSync(
      "gh",
      ["issue", "comment", id, "--repo", REPO, "--body", `${body}\n\n<!-- ${marker} -->`],
      { stdio: "ignore" },
    );
  } catch (err) {
    console.warn(`  (issue #${id} comment "${marker}" failed, continuing: ${err})`);
  }
}

// Swap the issue to a single sandcastle:* state label.
function setStateLabel(id: string, state: SandcastleState): void {
  if (!REPO) return;
  const args = ["issue", "edit", id, "--repo", REPO, "--add-label", `sandcastle:${state}`];
  for (const [other] of SANDCASTLE_LABELS) {
    if (other !== state) args.push("--remove-label", `sandcastle:${other}`);
  }
  try {
    execFileSync("gh", args, { stdio: "ignore" });
  } catch {
    /* label swap is non-critical */
  }
}

function closeIssue(id: string, comment: string): void {
  if (!REPO) return;
  try {
    execFileSync("gh", ["issue", "close", id, "--repo", REPO, "--comment", comment], {
      stdio: "ignore",
    });
  } catch (err) {
    console.warn(`  (issue #${id} close failed, continuing: ${err})`);
  }
}

// How many commits `branch` is ahead of the target — the true "is there work?"
// signal, counting work a prior run already left on the branch. 0 on any error.
function commitsAhead(branch: string): number {
  try {
    const out = execFileSync("git", ["rev-list", "--count", `${TARGET_BRANCH}..${branch}`], {
      encoding: "utf8",
    });
    return parseInt(out.trim(), 10) || 0;
  } catch {
    return 0;
  }
}

// Are we running inside a live Supacode session? True only when the CLI is on
// PATH AND the app socket is reachable (SUPACODE_SOCKET_PATH is exported inside
// Supacode terminals; `supacode socket` confirms the app is actually up). When
// true, the per-issue worktrees are registered Supacode *surfaces*, so teardown
// must go THROUGH Supacode — a raw `git worktree remove` would orphan the surface
// in Supacode's registry. Probed once and memoised; fail-OPEN to the git path.
let _supacodeSession: boolean | null = null;
function supacodeSession(): boolean {
  if (_supacodeSession !== null) return _supacodeSession;
  try {
    if (!process.env.SUPACODE_SOCKET_PATH) return (_supacodeSession = false);
    execFileSync("supacode", ["socket"], { stdio: "ignore" });
    // The app is up, but this repo must also be open in Supacode — otherwise
    // every worktree/tab call fails with "No worktree matching the deeplink".
    const repoId = encodeURIComponent(REPO_ROOT.endsWith("/") ? REPO_ROOT : REPO_ROOT + "/");
    const repos = execFileSync("supacode", ["repo", "list"], { encoding: "utf8" });
    if (!repos.split("\n").some((l) => l.trim() === repoId)) {
      console.warn(
        `  (Supacode is running but this repo isn't open in it — no worktree surfaces or trace panes.\n` +
          `   Run \`supacode repo open ${REPO_ROOT}\` once to enable them.)`,
      );
      return (_supacodeSession = false);
    }
    return (_supacodeSession = true);
  } catch {
    return (_supacodeSession = false);
  }
}

// Reap a merged branch's worktree + branch so they don't accrete across runs.
function worktreePathForBranch(branch: string): string | null {
  try {
    const out = execFileSync("git", ["worktree", "list", "--porcelain"], { encoding: "utf8" });
    let cur: string | null = null;
    for (const line of out.split("\n")) {
      if (line.startsWith("worktree ")) cur = line.slice("worktree ".length).trim();
      else if (line.startsWith("branch ") && line.slice("branch ".length).trim() === `refs/heads/${branch}`)
        return cur;
    }
  } catch {
    /* treated as no worktree */
  }
  return null;
}

function localBranchExists(branch: string): boolean {
  try {
    execFileSync("git", ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

// Prefer Supacode-native deletion when in a Supacode session — one call unlocks,
// removes the git worktree, deletes the branch, AND deregisters the surface;
// outside Supacode, force-remove via git then delete the branch. Best-effort +
// fail-OPEN. Never touches the target's own worktree.
function reapBranch(branch: string): void {
  if (branch === TARGET_BRANCH) return;
  const path = worktreePathForBranch(branch);
  try {
    if (supacodeSession() && path) {
      // Supacode keys worktrees by the percent-encoded absolute path (trailing slash).
      const id = encodeURIComponent(path.endsWith("/") ? path : path + "/");
      execFileSync("supacode", ["worktree", "delete", "-w", id], { stdio: "ignore" });
      // Supacode also drops the branch, but be explicit in case a version doesn't.
      try {
        execFileSync("git", ["branch", "-D", branch], { stdio: "ignore" });
      } catch {
        /* already removed by Supacode */
      }
      console.log(`  🧹 reaped worktree + branch for ${branch} (via Supacode)`);
    } else {
      if (path) execFileSync("git", ["worktree", "remove", "--force", path], { stdio: "ignore" });
      execFileSync("git", ["branch", "-D", branch], { stdio: "ignore" });
      console.log(`  🧹 reaped worktree + branch for ${branch} (via git)`);
    }
  } catch (err) {
    console.warn(`  (cleanup for ${branch} failed, continuing: ${err})`);
  }
}

// ── Supacode trace panes ─────────────────────────────────────────────────────
// Open a live `tail -F` pane for each agent's log, pinned to that agent's own
// worktree — the same worktree ensureSupacodeWorktreeSurface() registered. One
// "traces" tab per worktree; each role becomes a vertical split within it
// (implementer/reviewer for an issue; planner/merger on the target). `tail -F`
// follows by name, so opening the pane BEFORE the agent creates its log is fine.
// Because the panes live IN the worktree, reapBranch()'s Supacode teardown
// removes them too. Best-effort + fail-OPEN: a display glitch never breaks a run.
const _traceTab = new Map<string, string>(); // branch -> traces tab UUID
const _tracePrev = new Map<string, string>(); // branch -> last surface UUID in that tab
const _traceOpened = new Set<string>(); // "branch|role" -> pane already opened

function worktreeIdForBranch(branch: string): string | null {
  // The target's panes live in the invoking terminal's tab (see openTracePane),
  // so address that terminal's own worktree.
  if (branch === TARGET_BRANCH && process.env.SUPACODE_WORKTREE_ID) {
    return process.env.SUPACODE_WORKTREE_ID;
  }
  const path = branch === TARGET_BRANCH ? REPO_ROOT : worktreePathForBranch(branch);
  if (!path) return null;
  return encodeURIComponent(path.endsWith("/") ? path : path + "/");
}

// Sandcastle writes each run's log to `.sandcastle/logs/<branch-slug>-<name>.log`.
function traceLogPath(branch: string, role: string): string {
  const slug = branch.replace(/\//g, "-");
  return join(REPO_ROOT, ".sandcastle", "logs", `${slug}-${role}.log`);
}

function openTracePane(branch: string, role: string): void {
  if (!supacodeSession()) return;
  const key = `${branch}|${role}`;
  if (_traceOpened.has(key)) return;

  const wid = worktreeIdForBranch(branch);
  if (!wid) return; // worktree not registered (yet) — skip rather than guess

  const slug = branch.replace(/\//g, "-");
  const title = `${role} @ ${slug}`;
  const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
  // OSC-2 tab title via printf at runtime (no raw control bytes through -i);
  // `exec tail` replaces the shell so the title persists.
  const cmd =
    `printf '\\033]2;%s\\007' ${shq(title)}; ` +
    `printf '=== %s ===\\n' ${shq(title)}; ` +
    `exec tail -F ${shq(traceLogPath(branch, role))}`;

  const openFreshTab = (): void => {
    const newTab = execFileSync("supacode", ["tab", "new", "-w", wid, "-i", cmd], {
      encoding: "utf8",
    }).trim();
    _traceTab.set(branch, newTab);
    _tracePrev.set(branch, newTab);
  };

  // Roles on the target (the planner) split BELOW the terminal running this
  // orchestrator instead of opening a separate tab: seed the target's traces tab
  // with the invoking surface, whose IDs Supacode exports into its terminals.
  if (
    branch === TARGET_BRANCH &&
    !_traceTab.has(branch) &&
    process.env.SUPACODE_TAB_ID &&
    process.env.SUPACODE_SURFACE_ID
  ) {
    _traceTab.set(branch, process.env.SUPACODE_TAB_ID);
    _tracePrev.set(branch, process.env.SUPACODE_SURFACE_ID);
  }

  try {
    const tab = _traceTab.get(branch);
    if (!tab) {
      openFreshTab();
    } else {
      // Split within the worktree's traces tab; if it was closed mid-run, reopen.
      const prev = _tracePrev.get(branch)!;
      try {
        const sid = execFileSync(
          "supacode",
          ["surface", "split", "-w", wid, "-t", tab, "-s", prev, "-d", "v", "-i", cmd],
          { encoding: "utf8" },
        ).trim();
        _tracePrev.set(branch, sid);
      } catch {
        _traceTab.delete(branch);
        _tracePrev.delete(branch);
        openFreshTab();
      }
    }
    _traceOpened.add(key);
    console.log(`  🪟 trace pane for ${role} @ ${slug}`);
  } catch (err) {
    console.warn(`  (couldn't open Supacode trace pane for ${role} @ ${slug}: ${err})`);
  }
}

// Pre-create a per-issue worktree THROUGH Supacode so it registers as a managed
// surface — a tab the human can open and watch the agent work in. This is the
// creation-side mirror of reapBranch()'s Supacode-aware teardown, and it closes
// the asymmetry that made sandcastle's worktrees invisible in Supacode: the
// library creates them with a raw `git worktree add`, which Supacode never sees.
//
// It works by exploiting sandcastle's own worktree `create`: when a worktree is
// already checked out on the branch AND lives under `.sandcastle/worktrees/`,
// sandcastle ADOPTS it instead of erroring or making its own. So we create it
// there first, via Supacode, and sandcastle bind-mounts the surface we made. We
// match the library's layout exactly — `<repo>/.sandcastle/worktrees/<branch
// with '/'→'-'>` — so the adoption fires.
//
// Best-effort + fail-OPEN, and deliberately conservative:
//   - No Supacode session, or a worktree already on the branch → do nothing;
//     sandcastle's existing raw-git path runs unchanged. Pure upgrade: only ever
//     ADDS a surface.
//   - If Supacode places the worktree OUTSIDE the managed dir (which would turn
//     sandcastle's adopt into a hard collision error), we tear that stray
//     worktree back down so sandcastle falls back to its own git creation — a
//     lost surface, never a broken run.
// Never touches the target's own worktree.
function ensureSupacodeWorktreeSurface(branch: string): void {
  if (branch === TARGET_BRANCH) return;
  if (!supacodeSession()) return; // non-Supacode: raw-git path is unchanged
  if (worktreePathForBranch(branch)) return; // already has a worktree — adopted as-is
  // `supacode repo worktree-new --branch` only creates NEW branches; for one that
  // already exists (a re-picked issue, merge-staging) it refuses with "Choose a
  // different branch name". Skip quietly: sandcastle's raw `git worktree add`
  // lands in the same managed dir, and Supacode lists git-created worktrees too.
  if (localBranchExists(branch)) return;

  // Match sandcastle's naming EXACTLY (branch.replace(/\//g, "-")) and location
  // so its collision check treats the surface we make as its own managed worktree.
  const worktreeName = branch.replace(/\//g, "-");
  try {
    execFileSync(
      "supacode",
      [
        "repo",
        "worktree-new",
        // Explicit repo: the default ($SUPACODE_REPO_ID) is whichever repo the
        // invoking terminal belongs to, which silently registered another
        // project's issue worktrees under that repo when the loop was launched
        // from a terminal outside this checkout.
        "--repo",
        encodeURIComponent(REPO_ROOT.endsWith("/") ? REPO_ROOT : REPO_ROOT + "/"),
        "--branch",
        branch,
        "--base",
        TARGET_BRANCH,
        "--location",
        SANDCASTLE_WORKTREES_DIR,
        "--name",
        worktreeName,
      ],
      { stdio: "ignore" },
    );
  } catch (err) {
    // Couldn't create it — sandcastle will make its own via git (no surface).
    console.warn(
      `  (Supacode worktree surface for ${branch} not created; sandcastle will make one via git: ${err})`,
    );
    return;
  }

  // Verify it landed UNDER the managed dir. If Supacode ignored --location and
  // put it elsewhere, sandcastle's adopt-or-fail check would hard-fail on the
  // collision — so reap the stray worktree and let sandcastle create its own.
  const created = worktreePathForBranch(branch);
  if (created && resolve(created).startsWith(resolve(SANDCASTLE_WORKTREES_DIR))) {
    console.log(
      `  🏗️ registered Supacode worktree surface for ${branch} (.sandcastle/worktrees/${worktreeName})`,
    );
    return;
  }
  if (created) {
    console.warn(
      `  (Supacode created ${branch}'s worktree at '${created}', outside ${SANDCASTLE_WORKTREES_DIR}; ` +
        `removing it so sandcastle can create its own — no surface this run)`,
    );
    try {
      execFileSync("git", ["worktree", "remove", "--force", created], { stdio: "ignore" });
    } catch (err) {
      console.warn(`  (couldn't reap stray worktree for ${branch}, continuing: ${err})`);
    }
  }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

ensureSandcastleLabels();

for (let iteration = 1; iteration <= MAX_ITERATIONS; iteration++) {
  console.log(`\n=== Iteration ${iteration}/${MAX_ITERATIONS} ===\n`);

  // ---- Phase 1: Plan ----
  openTracePane(TARGET_BRANCH, "planner");
  const plan = await sandcastle.run({
    hooks,
    sandbox: podman(),
    name: "planner",
    maxIterations: 1,
    agent: agentFor("PLAN"),
    promptFile: promptPath("plan-prompt.md"),
    output: sandcastle.Output.object({ tag: "plan", schema: planSchema }),
  });

  const issues = plan.output.issues;
  if (issues.length === 0) {
    console.log("No unblocked issues to work on. Exiting.");
    break;
  }

  console.log(
    `Planning complete. ${issues.length} issue(s), at most ${MAX_PARALLEL} sandbox(es) at a time:`,
  );
  for (const issue of issues) {
    console.log(`  ${issue.id} [${issue.track}]: ${issue.title} → ${issue.branch}`);
  }

  // ---- Phase 2: Execute + Review (per issue, at most MAX_PARALLEL at once) ----
  const settled = await settledWithLimit(issues, MAX_PARALLEL, async (issue: (typeof issues)[number]) => {
      // Register the per-issue worktree as a Supacode surface FIRST (when in a
      // Supacode session), so sandcastle adopts it as its bind-mount target and
      // the human gets a tab to watch. No-op / fail-OPEN otherwise — see the
      // helper. Must run before createSandbox, which is what triggers adoption.
      ensureSupacodeWorktreeSurface(issue.branch);

      const sandbox = await sandcastle.createSandbox({
        branch: issue.branch,
        sandbox: podman(),
        hooks,
        copyToWorktree,
      });

      setStateLabel(issue.id, "running");
      postOnce(
        issue.id,
        "sandcastle:picked-up",
        `🏗️ **sandcastle** picked up this issue on \`${issue.branch}\` (**${issue.track}** track).\n\n` +
          `🎯 ${issue.title}\n\n▶️ Implementer is now operating (red-green-refactor).`,
      );

      try {
        openTracePane(issue.branch, "implementer");
        const implement = await sandbox.run({
          name: "implementer",
          maxIterations: 100,
          agent: agentFor("IMPLEMENT"),
          promptFile: promptPath("implement-prompt.md"),
          promptArgs: {
            TASK_ID: issue.id,
            ISSUE_TITLE: issue.title,
            BRANCH: issue.branch,
            TRACK: issue.track,
          },
        });

        const implementerComplete = implement.completionSignal !== undefined;
        const ahead = commitsAhead(issue.branch);

        // No work at all → nothing to review, gate, or merge.
        if (ahead === 0) {
          return { issue, hasWork: false, implementerComplete, reviewerComplete: false };
        }

        setStateLabel(issue.id, "running");
        openTracePane(issue.branch, "reviewer");
        const review = await sandbox.run({
          name: "reviewer",
          maxIterations: 1,
          agent: agentFor("REVIEW"),
          promptFile: promptPath("review-prompt.md"),
          // TARGET_BRANCH is injected automatically by sandcastle.
          promptArgs: { BRANCH: issue.branch, TRACK: issue.track },
        });

        const reviewerComplete = review.completionSignal !== undefined;
        return { issue, hasWork: true, implementerComplete, reviewerComplete };
      } finally {
        await sandbox.close();
      }
  });

  // ---- Phase 3: Gate ----
  const serverToMerge: { id: string; title: string; branch: string }[] = [];

  for (const [i, outcome] of settled.entries()) {
    const issue = issues[i]!;
    if (outcome.status === "rejected") {
      console.error(`  ✗ ${issue.id} (${issue.branch}) crashed: ${outcome.reason}`);
      continue;
    }
    const r = outcome.value;
    if (!r.hasWork) {
      console.log(`  · ${issue.id} produced no commits — nothing to gate.`);
      continue;
    }

    const cleared = r.implementerComplete && r.reviewerComplete;

    if (!cleared) {
      const why = !r.implementerComplete
        ? "implementer did not finish (no COMPLETE)"
        : "reviewer withheld attestation (correctness / hard-rule FAIL)";
      console.warn(`  ⊘ ${issue.id} (${issue.branch}) BLOCKED: ${why} — commits kept for next cycle / a human.`);
      setStateLabel(issue.id, "blocked");
      postOnce(
        issue.id,
        `sandcastle:blocked:${r.implementerComplete ? "reviewer" : "implementer"}`,
        `⛔ **Gate blocked** \`${issue.branch}\`: ${why}.\n\nCommits stay on the branch — sandcastle never merges by default.`,
      );
      continue;
    }

    if (issue.track === "ios") {
      // iOS is EDIT-ONLY in the sandbox. Never auto-merge — park for the host gate.
      console.log(`  ⏸ ${issue.id} (${issue.branch}) iOS — parked for host xcodebuild gate.`);
      setStateLabel(issue.id, "needs-host-verify");
      postOnce(
        issue.id,
        "sandcastle:needs-host-verify",
        `🍎 iOS branch \`${issue.branch}\` implemented + reviewed in-sandbox, but iOS cannot be built here.\n\n` +
          `**Host gate (run on the Mac):** \`scripts/verify_agent_branch.sh ${issue.branch}\`\n\n` +
          `Then run the on-device manual scenario named in the commit before merging. This issue is parked ` +
          `(the planner skips it) until a human verifies and merges it.`,
      );
      continue;
    }

    // server + cleared → eligible for the merge phase.
    serverToMerge.push({ id: issue.id, title: issue.title, branch: issue.branch });
  }

  if (serverToMerge.length === 0) {
    console.log("\nNo server branch cleared the gate this cycle. Nothing to merge.");
    continue;
  }

  console.log(`\n${serverToMerge.length} server branch(es) cleared the gate:`);
  for (const m of serverToMerge) console.log(`  ${m.branch}`);

  // ---- Phase 4: Merge (server branches only, in a staging worktree) ----
  // Reap leftover staging state from a prior blocked cycle so staging is always
  // recreated fresh from the target's current HEAD. Worktrees share refs, so the
  // issue branches are reachable from inside the staging worktree.
  const preMergeSha = (() => {
    try {
      return execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
    } catch {
      return "";
    }
  })();
  reapBranch(MERGE_STAGING_BRANCH);
  ensureSupacodeWorktreeSurface(MERGE_STAGING_BRANCH);
  const mergeSandbox = await sandcastle.createSandbox({
    branch: MERGE_STAGING_BRANCH,
    sandbox: podman(),
    hooks,
    copyToWorktree,
  });

  let mergerComplete = false;
  try {
    openTracePane(MERGE_STAGING_BRANCH, "merger");
    const merge = await mergeSandbox.run({
      name: "merger",
      maxIterations: 1,
      agent: agentFor("MERGE"),
      promptFile: promptPath("merge-prompt.md"),
      promptArgs: {
        BRANCHES: serverToMerge.map((m) => `- ${m.branch}`).join("\n"),
        ISSUES: serverToMerge.map((m) => `- ${m.id}: ${m.title}`).join("\n"),
      },
    });
    mergerComplete = merge.completionSignal !== undefined;
  } finally {
    await mergeSandbox.close();
  }

  const postMergeSha = (() => {
    try {
      return execFileSync("git", ["rev-parse", MERGE_STAGING_BRANCH], { encoding: "utf8" }).trim();
    } catch {
      return "";
    }
  })();

  // Advance the target ONLY after attestation, and only by fast-forward — fail
  // closed, never force. A failed ff has two common causes, reported separately
  // because they need different fixes: the target moved mid-merge (e.g. a human
  // committed), or the host checkout has local changes/untracked files that the
  // merge would overwrite. The latter is surfaced with git's own message.
  let mergeBlessed =
    mergerComplete && !!preMergeSha && !!postMergeSha && postMergeSha !== preMergeSha;
  let ffFailure: string | null = null;
  if (mergeBlessed) {
    try {
      execFileSync("git", ["merge", "--ff-only", MERGE_STAGING_BRANCH], {
        stdio: ["ignore", "ignore", "pipe"],
        encoding: "utf8",
      });
    } catch (err) {
      mergeBlessed = false;
      const headNow = (() => {
        try {
          return execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
        } catch {
          return "";
        }
      })();
      const stderr = String((err as { stderr?: unknown }).stderr ?? "").trim();
      ffFailure =
        headNow && headNow !== preMergeSha
          ? `the target moved during the merge (\`${TARGET_BRANCH}\` is now ${headNow.slice(0, 7)}, staging was cut from ${preMergeSha.slice(0, 7)})`
          : `git refused the fast-forward in the host checkout — usually local changes or untracked files the merge would overwrite: ${stderr.split("\n").slice(0, 6).join(" | ") || String(err)}`;
    }
  }

  if (!mergeBlessed) {
    const why = !mergerComplete
      ? "merger did not signal COMPLETE (merge or tests unfinished)"
      : ffFailure
        ? `the staging result could not fast-forward \`${TARGET_BRANCH}\`: ${ffFailure}`
        : "merger signalled COMPLETE but the staging tip did not advance";
    console.warn(
      `  ⊘ Merge WITHHELD: ${why}. ${TARGET_BRANCH} not advanced; result parked on ` +
        `${MERGE_STAGING_BRANCH}; branch commits kept; nothing closed or reaped.`,
    );
    for (const m of serverToMerge) {
      setStateLabel(m.id, "blocked");
      postOnce(
        m.id,
        `sandcastle:merge-blocked:${mergerComplete ? "ff" : "merger"}`,
        `⛔ **Merge blocked** for \`${m.branch}\`: ${why}.\n\n` +
          `\`${TARGET_BRANCH}\` was **not** advanced. The merge result is parked on ` +
          `\`${MERGE_STAGING_BRANCH}\` for inspection and the branch commits are kept.`,
      );
    }
    continue;
  }

  console.log(`\nBranches merged on staging and ${TARGET_BRANCH} fast-forwarded.`);
  reapBranch(MERGE_STAGING_BRANCH);
  for (const m of serverToMerge) {
    setStateLabel(m.id, "merged");
    postOnce(
      m.id,
      "sandcastle:merged",
      `🎉 Merged \`${m.branch}\` into \`${TARGET_BRANCH}\` — cleared the implementer + reviewer gate.`,
    );
    closeIssue(m.id, `Completed by Sandcastle — merged into ${TARGET_BRANCH}.`);
    reapBranch(m.branch);
  }
}

console.log("\nAll done.");
