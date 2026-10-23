#!/usr/bin/env python3
"""Keep one open `ci-red` issue while `main` CI is red, for the red-main intake.

Runs as the last CI job on pushes to main. A failed job opens the issue (or
comments on the one already open) with the failing jobs, a log tail per job,
and the commits since the last green run, so the factory's review routine can
draft a fix card from it. A fully green run closes the open issue. A run with
cancelled jobs changes nothing: it proved neither red nor green. A run for a commit
that is no longer main's head changes nothing either: main runs finish out of order, and the
newer commit's run reports on main as it now is.

Usage (env from the workflow): RESULTS='${{ toJSON(needs) }}' python3 scripts/ci/red_main_issue.py
"""

import json
import os
import re
import subprocess
import sys

LABEL = "ci-red"
LOG_TAIL_LINES = 60
MAX_COMMITS = 20
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T[\d:.]+Z ")


def decide(results, open_issue, superseded=False):
    """'open', 'comment', 'close', or None for a run's `needs` results."""
    if superseded:
        return None
    outcomes = {job["result"] for job in results.values()}
    if "failure" in outcomes:
        return "comment" if open_issue else "open"
    if outcomes == {"success"} and open_issue:
        return "close"
    return None


def failed_jobs(results):
    return sorted(name for name, job in results.items() if job["result"] == "failure")


def log_tail(log, lines=LOG_TAIL_LINES):
    """The lines up to the first `##[error]`; the job's cleanup steps follow it."""
    all_lines = [TIMESTAMP.sub("", line) for line in log.splitlines()]
    end = next((i + 1 for i, line in enumerate(all_lines) if line.startswith("##[error]")), len(all_lines))
    return "\n".join(all_lines[max(0, end - lines):end])


def report(sha, run_url, failed, logs, commits):
    parts = [
        f"`main` CI failed at {sha[:7]}: {run_url}",
        "",
        f"**Failing jobs:** {', '.join(failed)}",
        "",
        "**Commits since the last green run:**",
        "",
    ]
    parts += [f"- {line}" for line in commits] or ["- (no green run found to compare with)"]
    for name, log in logs:
        parts += ["", f"**{name}** (up to {LOG_TAIL_LINES} log lines before the first error):", "", "```", log, "```"]
    return "\n".join(parts)


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def failing_job_logs(repo, run_id):
    jobs = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}/jobs", "--jq", ".jobs"))
    logs = []
    for job in jobs:
        if job.get("conclusion") == "failure":
            logs.append((job["name"], log_tail(gh("api", f"repos/{repo}/actions/jobs/{job['id']}/logs"))))
    return logs


def commits_since_green(repo, sha):
    green = gh(
        "run", "list", "--workflow", "ci.yml", "--branch", "main", "--event", "push",
        "--status", "success", "--limit", "1", "--json", "headSha", "--jq", ".[0].headSha // empty",
    ).strip()
    if not green:
        return []
    lines = gh(
        "api", f"repos/{repo}/compare/{green}...{sha}",
        "--jq", '.commits[] | .sha[0:7] + " " + (.commit.message | split("\\n")[0])',
    ).splitlines()
    return lines[-MAX_COMMITS:]


def main():
    results = json.loads(os.environ["RESULTS"])
    repo = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]
    run_id = os.environ["GITHUB_RUN_ID"]
    run_url = f"{os.environ['GITHUB_SERVER_URL']}/{repo}/actions/runs/{run_id}"
    open_issue = gh(
        "issue", "list", "--label", LABEL, "--state", "open", "--json", "number",
        "--jq", ".[0].number // empty",
    ).strip()
    head = gh("api", f"repos/{repo}/commits/main", "--jq", ".sha").strip()
    action = decide(results, open_issue, superseded=head != sha)
    print(
        f"needs: {results}; open {LABEL} issue: {open_issue or 'none'}; main head: {head[:7]}; action: {action}",
        file=sys.stderr,
    )
    if action in ("open", "comment"):
        body = report(sha, run_url, failed_jobs(results), failing_job_logs(repo, run_id), commits_since_green(repo, sha))
        if action == "open":
            gh("issue", "create", "--label", LABEL, "--title", f"main CI red since {sha[:7]}", "--body", body)
        else:
            gh("issue", "comment", open_issue, "--body", body)
    elif action == "close":
        gh("issue", "close", open_issue, "--comment", f"`main` is green again at {sha[:7]}: {run_url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
