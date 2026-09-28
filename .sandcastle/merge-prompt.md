# TASK

Merge the following **server-track** branches into the current branch. (iOS branches are never
merged here — they wait for the host build gate, `scripts/verify_agent_branch.sh`.)

{{BRANCHES}}

For each branch:

1. Run `git merge <branch> --no-edit`.
2. If there are merge conflicts, resolve them by reading both sides and choosing the correct
   resolution — respect the hard rules in `@.sandcastle/CODING_STANDARDS.md` (no n8n, design
   tokens, no assumed secrets).
3. After resolving, run `python -m pytest server/webapp/tests/ -q` to confirm everything works.
4. If tests fail, fix the breakage before moving to the next branch.

After all branches are merged, make a single commit summarizing the merge (short imperative
subject, no `RALPH:` / AI attribution).

# DO NOT CLOSE ISSUES

Do **not** run `gh issue close` or any other `gh issue` mutation. You are merging on a
staging branch; the host fast-forwards the target and handles the issue lifecycle (labels,
comments, closing) only after you signal completion. For context, these are the issues
whose branches you are merging:

{{ISSUES}}

Output <promise>COMPLETE</promise> **only** if every branch merged and the test suite is green.
If anything is left unmerged or failing, stop without the signal: the host then keeps the
target unchanged.
