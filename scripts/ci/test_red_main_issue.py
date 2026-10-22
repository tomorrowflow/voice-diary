"""Run with: python3 -m unittest discover -s scripts/ci (works on Linux, no extra deps)."""

import unittest

import red_main_issue as red


def needs(**results):
    return {name.replace("_", "-"): {"result": result, "outputs": {}} for name, result in results.items()}


class DecideTests(unittest.TestCase):
    def test_failure_opens_an_issue(self):
        self.assertEqual(red.decide(needs(ruff="success", server_tests="failure"), ""), "open")

    def test_failure_comments_on_the_open_issue(self):
        self.assertEqual(red.decide(needs(ruff="failure", ios_tests="success"), "12"), "comment")

    def test_green_closes_the_open_issue(self):
        self.assertEqual(red.decide(needs(ruff="success", ios_tests="success"), "12"), "close")

    def test_green_without_issue_does_nothing(self):
        self.assertIsNone(red.decide(needs(ruff="success"), ""))

    def test_cancelled_run_keeps_the_issue_open(self):
        self.assertIsNone(red.decide(needs(ruff="success", ios_tests="cancelled"), "12"))

    def test_failure_wins_over_cancelled(self):
        self.assertEqual(red.decide(needs(ruff="failure", ios_tests="cancelled"), ""), "open")


class ReportTests(unittest.TestCase):
    def test_lists_failed_jobs_commits_and_logs(self):
        body = red.report(
            "abcdef1234", "https://example.test/run/1", ["server-tests"],
            [("Server pytest (Compose)", "E assert 2 == 1")],
            ["14286b0 Merge pull request #148 from tomorrowflow/factory/41012fb4"],
        )
        self.assertIn("failed at abcdef1: https://example.test/run/1", body)
        self.assertIn("**Failing jobs:** server-tests", body)
        self.assertIn("- 14286b0 Merge pull request #148", body)
        self.assertIn("```\nE assert 2 == 1\n```", body)

    def test_says_when_no_green_run_exists(self):
        body = red.report("abcdef1", "u", ["ruff"], [], [])
        self.assertIn("(no green run found to compare with)", body)

    def test_log_tail_keeps_last_lines_without_timestamps(self):
        log = "\n".join(f"2026-10-19T06:11:0{i}.1234567Z line {i}" for i in range(5))
        self.assertEqual(red.log_tail(log, lines=2), "line 3\nline 4")

    def test_log_tail_ends_at_the_first_error(self):
        log = "line 0\nE assert 2 == 1\n##[error]Process completed with exit code 1.\nCleaning up orphan processes"
        self.assertEqual(red.log_tail(log, lines=2), "E assert 2 == 1\n##[error]Process completed with exit code 1.")


if __name__ == "__main__":
    unittest.main()
