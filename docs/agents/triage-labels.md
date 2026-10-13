# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

Agent work is queued as Workboard cards, not by labels: a card carries the issue's scope, and the agent follows `CLAUDE.md` and `CODING_STANDARDS.md`. The legacy `Sandcastle` label (retired with the Sandcastle loop, KA-10) remains on old public issues for history only; do not apply it to new issues. The `track:server` / `track:ios` and `priority:high` labels are orthogonal to triage state: keep applying them alongside the role label.
