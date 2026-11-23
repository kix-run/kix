"""Tests for batch.py. They ask GitHub nothing.

Run from the repository root:
    python3 -m unittest discover -s .github/bump -p 'test_*.py'
"""

import os
import unittest

os.environ.setdefault("GH_TOKEN", "unused")
os.environ.setdefault("GITHUB_REPOSITORY", "kix-run/kix")

import batch  # noqa: E402 - batch reads the environment when it is imported


def run(name, conclusion="success", status="completed"):
    return {"name": name, "status": status, "conclusion": conclusion}


class ChecksStateTest(unittest.TestCase):
    def state(self, runs):
        original = batch.api
        batch.api = lambda method, path, body=None: {"check_runs": runs}
        self.addCleanup(setattr, batch, "api", original)
        return batch.checks_state("abc")

    # A bump changes a package folder and a change record. These are the
    # checks such a pull request gets: the CLI tests do not run for it.
    def test_a_package_only_bump_with_its_checks_green_has_passed(self):
        runs = [
            run(n)
            for n in ("changelog", "change-kind", "lib-tests", "lint", "copy-pass")
        ]
        self.assertEqual(self.state(runs), "passed")

    def test_checks_that_have_not_all_started_are_running(self):
        self.assertEqual(self.state([run("changelog"), run("lint")]), "running")

    def test_an_unfinished_check_is_running(self):
        runs = [run(n) for n in ("changelog", "change-kind")]
        runs.append(run("lib-tests", conclusion=None, status="in_progress"))
        self.assertEqual(self.state(runs), "running")

    def test_a_failed_check_fails_the_bump(self):
        runs = [run(n) for n in ("changelog", "change-kind", "lib-tests")]
        runs.append(run("test", conclusion="failure"))
        self.assertEqual(self.state(runs), "failed")

    def test_a_skipped_check_counts_as_passed(self):
        runs = [run(n) for n in ("changelog", "change-kind", "lib-tests")]
        runs.append(run("captures", conclusion="skipped"))
        self.assertEqual(self.state(runs), "passed")


if __name__ == "__main__":
    unittest.main()
