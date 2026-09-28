# TASK

Independently review the changes on branch `{{BRANCH}}` (**{{TRACK}}** track). Confirm the
change is correct and honours the project's hard rules, then improve clarity/consistency
without altering behaviour.

# CONTEXT

## Branch diff

!`git diff {{TARGET_BRANCH}}...{{BRANCH}}`

## Commits on this branch

!`git log {{TARGET_BRANCH}}..{{BRANCH}} --oneline`

# REVIEW PROCESS

1. **Understand the change**: read the diff and commits; open the referenced finding in
   `docs/REVIEW-2026-07-04.md` to confirm the change actually addresses it.

2. **Check the hard rules** (from `@.sandcastle/CODING_STANDARDS.md` — these are blocking, not
   nits):
   - No hard-coded colours/spacing/radius/font sizes; iOS style via `Theme.*` / `DSButtonStyle`,
     server CSS via `var(--*)`; no hand-edited generated token files.
   - No n8n. No telemetry / outbound traffic beyond the user's own server.
   - No committed or assumed secrets; no hard-coded bearer token or tailnet hostname.
   - No new audio-chopping path (only the documented SPEC §7.4 trim is allowed).
   - Graph access stays server-side; ingest stays segmented.
   - Commit style: short imperative subject, no `RALPH:` / AI attribution.
   - SPEC.md updated if a manifest field or endpoint shape changed.

3. **Check correctness**:
   - Does the implementation match the finding's intent? Are edge cases handled?
   - Are new/changed behaviours covered by tests?
   - Unsafe casts, unchecked assumptions, injection, credential leaks?

4. **Improve without changing behaviour**: reduce needless complexity/nesting, remove redundant
   abstractions, clarify names, drop obvious comments — but keep helpful abstractions and don't
   over-compress. Never change what the code does, only how.

# VERIFY

**If TRACK is `server`:** run `python -m pytest server/webapp/tests/ -q` and confirm green
before attesting. If it fails, fix trivial breakage or, if the change is substantively wrong,
withhold the completion signal (see below).

**If TRACK is `ios`:** you cannot build or run `xcodebuild` here. Review the diff statically
against the hard rules and the finding; the host build gate (`scripts/verify_agent_branch.sh`)
is the real acceptance step and runs after this review.

# EXECUTION

- If you find clarity improvements, make them on this branch, keep tests green, and commit.
- If the code is already clean, make no changes.

# COMPLETION SIGNAL — this is a gate

Output <promise>COMPLETE</promise> **only if** the change is correct, honours every hard rule,
and (for server) the tests are green. If it violates a hard rule or is substantively wrong,
do **not** output the signal — instead leave a comment on the issue explaining precisely what
fails, so the branch is blocked from merge and routed back for repair.
