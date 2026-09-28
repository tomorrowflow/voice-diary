# TASK

Implement issue **{{TASK_ID}}: {{ISSUE_TITLE}}** on the **{{TRACK}}** track.

Pull the issue with `gh issue view {{TASK_ID}} --comments`. It references a stable finding ID
(e.g. `SRV-A1`, `IOS-A3`, `SEC-2`) in `docs/REVIEW-2026-07-04.md` — read that finding: it names
the exact files, line ranges, and the intended solution. Only work on this one issue.

Work on branch **{{BRANCH}}**. Make small, focused commits.

# ORIENTATION — read before touching code

- `CLAUDE.md` — the hard rules (design tokens, no n8n, secrets, DE/EN, commit style).
- `SPEC.md` — single source of truth for behaviour. Consult the relevant section for any
  state-machine, manifest, endpoint, or UX question. If you change a manifest field or endpoint
  shape, update `SPEC.md` in the same commit.
- `@.sandcastle/CODING_STANDARDS.md` — the distilled standards the reviewer will hold you to.
- The finding in `docs/REVIEW-2026-07-04.md`.

Sandbox facts you must respect:
- **There is no `server/.env` and no secrets here.** Code must not assume one exists; never
  hard-code the bearer token or a tailnet hostname. Integration tests that need a live
  `docker compose up` cannot run here — do not attempt them.

<recent-commits>

!`git log -n 10 --format="%H%n%ad%n%B---" --date=short`

</recent-commits>

# EXPLORATION

Explore the repo and load the relevant code and tests into context before writing anything.
Read the existing code before changing it — `server/webapp/` and `ios/` are working codebases;
understand a module before modifying it. Pay extra attention to test files near the change.

# EXECUTION — red-green-refactor, one tracer bullet at a time

1. **RED:** write ONE failing test for ONE behavior; confirm it fails for the right reason.
2. **GREEN:** minimum code to pass it.
3. **REPEAT** until the finding's acceptance is met.
4. **REFACTOR** while green — prefer deep modules over shallow pass-throughs.

Never bulk-write tests. One test → one implementation → repeat.

# FEEDBACK LOOP — track-specific

**If TRACK is `server`:** before every commit, run the server unit tests and keep them green:

!`echo "run: python -m pytest server/webapp/tests/ -q"`

Mock MSAL, LightRAG, Ollama, Whisper — follow the pattern in `tests/test_voxtral_client.py`.

**If TRACK is `ios`:** you **cannot build or run tests in this sandbox** — there is no Swift
toolchain and `xcodebuild` does not run on Linux. Write the code, keep diffs small and
surgical, and add/adjust pure-logic unit tests where they exist (they run on the host). In your
commit message, name the manual scenario from `DEVELOPMENT.md §7` (and any on-device voice step)
that a human must run on the iPhone before this is truly done.

# COMMIT

Commit in the repo's style: a short, imperative subject line. **No `RALPH:` prefix, no Claude/AI
attribution.** If helpful, add a brief body with key decisions and any notes for the next
iteration. Reference the finding ID in the body (e.g. `SRV-A1`).

# THE ISSUE

If the task is not complete when you stop, leave a comment on the issue describing what was done
and what remains. Do **not** close the issue — that happens later.

Once the work is complete and (for server) the tests are green, output <promise>COMPLETE</promise>.

# FINAL RULES

ONLY WORK ON THIS SINGLE ISSUE. Respect every hard rule in CODING_STANDARDS.md — a design-token
violation, a new audio-chop path, or an assumed secret is a blocking defect, not a nit.
