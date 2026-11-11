"""Tests for the change-record parser and command line.

cd scripts && python3 -m unittest -v change_records.test_change_records
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

import change_records as cr

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent


def load_driver():
    spec = importlib.util.spec_from_file_location(
        "change_records_driver", SCRIPTS / "change-records.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


DRIVER = load_driver()


def record(header: str, body: str = "Something changed.") -> str:
    return f"+++\n{textwrap.dedent(header).strip()}\n+++\n{body}\n"


class Repo:
    """A temporary project root with a `changes/` folder and a CHANGELOG.md."""

    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self._tmp.name)
        (self.root / "changes").mkdir()
        (self.root / "changes" / "README.md").write_text("# Change records\n")
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\nIntro.\n\n## 0.9.0 - 2026-11-10\n\n### Fixed\n\n- Old fix.\n"
        )

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = DRIVER.main(["--root", str(self.root), *args])
        return code, out.getvalue(), err.getvalue()

    def git(self, *args: str) -> str:
        return subprocess.run(
            [
                "git",
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
                *args,
            ],
            cwd=self.root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def close(self) -> None:
        self._tmp.cleanup()


class RepoTest(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = Repo()
        self.addCleanup(self.repo.close)

    def problems(self) -> list[str]:
        return cr.load(self.repo.root)[1]

    def assertProblem(self, text: str, needle: str) -> None:
        self.repo.write("changes/x.md", text)
        problems = self.problems()
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(needle, problems[0])


class ValidationTest(RepoTest):
    def test_valid_records_pass(self):
        self.repo.write("changes/a.md", record('kind = "fixed"\npackages = ["caddy"]'))
        self.repo.write(
            "changes/b.md",
            record(
                """
                kind = "security"
                cve = ["CVE-2026-1"]
                workaround = "Pin the image."
                """
            ),
        )
        self.repo.write("changes/c.md", record('kind = "silent"\ntouches-data = true'))
        self.repo.write(
            "changes/d.md", record('kind = "note"\nstate = true\nrequired-stop = true')
        )
        self.repo.write("changes/0.9.0/e.md", record('kind = "error"\nid = "K0001"'))
        code, out, err = self.repo.run("check")
        self.assertEqual(code, 0, err)
        self.assertIn("5 change records, 4 unreleased", out)

    def test_readme_is_not_a_record(self):
        self.assertEqual(self.problems(), [])

    def test_missing_header(self):
        self.assertProblem("kind = 'fixed'\n", "must start with a `+++` line")

    def test_unclosed_header(self):
        self.assertProblem('+++\nkind = "fixed"\nbody\n', "no closing `+++`")

    def test_bad_toml(self):
        self.assertProblem("+++\nkind = fixed\n+++\nbody\n", "not valid TOML")

    def test_missing_kind(self):
        self.assertProblem(record('packages = ["caddy"]'), "`kind` is required")

    def test_unknown_kind(self):
        self.assertProblem(record('kind = "fix"'), '`kind = "fix"` is unknown')

    def test_unknown_field(self):
        self.assertProblem(
            record('kind = "fixed"\ntouchesData = true'), "unknown field `touchesData`"
        )

    def test_wrong_types(self):
        self.repo.write(
            "changes/x.md", record('kind = "fixed"\npackages = "caddy"\nstate = "yes"')
        )
        (problem,) = self.problems()
        self.assertIn("`packages` must be a list of strings", problem)
        self.assertIn("`state` must be true or false", problem)

    def test_error_needs_id(self):
        self.assertProblem(record('kind = "error"'), '`kind = "error"` needs an `id`')

    def test_id_shape(self):
        self.assertProblem(
            record('kind = "added"\nid = "K12"'), "must be K and four digits"
        )

    def test_touches_data_only_with_silent(self):
        self.assertProblem(
            record('kind = "changed"\ntouches-data = true'),
            "`touches-data` is only for",
        )

    def test_required_stop_needs_state(self):
        self.assertProblem(
            record('kind = "note"\nrequired-stop = true'),
            "`required-stop` needs `state = true`",
        )

    def test_cve_only_with_security(self):
        self.assertProblem(
            record('kind = "fixed"\ncve = ["CVE-1"]'), "`cve` is only for"
        )

    def test_security_needs_workaround(self):
        self.assertProblem(record('kind = "security"'), "needs a `workaround`")

    def test_workaround_only_with_security(self):
        self.assertProblem(
            record('kind = "fixed"\nworkaround = "x"'), "`workaround` is only for"
        )

    def test_empty_body(self):
        self.assertProblem(
            record('kind = "fixed"', body="  \n"), "text below the header is empty"
        )

    def test_duplicate_id(self):
        self.repo.write("changes/0.9.0/a.md", record('kind = "error"\nid = "K0007"'))
        self.repo.write("changes/b.md", record('kind = "added"\nid = "K0007"'))
        (problem,) = self.problems()
        self.assertIn("id K0007 is also used by changes/0.9.0/a.md", problem)

    def test_check_command_fails(self):
        self.repo.write("changes/x.md", record('kind = "nope"'))
        code, _, err = self.repo.run("check")
        self.assertEqual(code, 1)
        self.assertIn("changes/x.md:", err)

    def test_a_folder_that_is_no_version_is_refused(self):
        self.repo.write("changes/fix/branch.md", record('kind = "fixed"'))
        code, _, err = self.repo.run("check")
        self.assertEqual(code, 1)
        self.assertIn("must be a released version", err)

    def test_a_list_or_code_block_in_the_text_is_refused(self):
        for body in ("Intro:\n- one\n- two", "See:\n```\ncode\n```"):
            self.repo.write("changes/x.md", record('kind = "fixed"', body))
            code, _, err = self.repo.run("check")
            self.assertEqual(code, 1)
            self.assertIn("no list or code block", err)

    def test_release_refuses_a_version_that_is_not_x_y_z(self):
        self.repo.write("changes/x.md", record('kind = "fixed"'))
        for version in ("v0.10.0", "0.10.0-rc.1"):
            code, _, err = self.repo.run("release", version)
            self.assertEqual(code, 1)
            self.assertIn("is not a release version", err)
        self.assertTrue((self.repo.root / "changes/x.md").exists())

    def test_other_commands_refuse_invalid_records(self):
        self.repo.write("changes/x.md", record('kind = "nope"'))
        code, _, err = self.repo.run("changelog")
        self.assertEqual(code, 1)
        self.assertIn("is unknown", err)


class OutputTest(RepoTest):
    def setUp(self) -> None:
        super().setUp()
        self.repo.write(
            "changes/b-fix.md",
            record('kind = "fixed"', "Fixed a\nthing.\n\nSecond paragraph."),
        )
        self.repo.write(
            "changes/a-break.md",
            record('kind = "error"\nid = "K0003"\npackages = ["caddy"]', "Renamed."),
        )
        self.repo.write("changes/c-add.md", record('kind = "added"', "New."))
        self.repo.write(
            "changes/0.9.0/old.md", record('kind = "fixed"\nid = "K0001"', "Old.")
        )

    def test_changelog(self):
        code, out, _ = self.repo.run("changelog")
        self.assertEqual(code, 0)
        self.assertEqual(
            out,
            "### Breaking (shows an error)\n\n- Renamed. [K0003]\n\n"
            "### Added\n\n- New.\n\n"
            "### Fixed\n\n- Fixed a thing. Second paragraph.\n",
        )

    def test_changelog_with_heading(self):
        _, out, _ = self.repo.run(
            "changelog", "--version", "0.10.0", "--date", "2026-11-11"
        )
        self.assertTrue(
            out.startswith("## 0.10.0 - 2026-11-11\n\n### Breaking (shows an error)\n")
        )

    def test_changelog_for_a_released_version(self):
        _, out, _ = self.repo.run("changelog", "--version", "0.9.0")
        self.assertEqual(out, "### Fixed\n\n- Old. [K0001]\n")

    def test_json(self):
        code, out, _ = self.repo.run("json", "--version", "0.10.0")
        self.assertEqual(code, 0)
        doc = json.loads(out)
        self.assertEqual(doc["schema"], "kix.run/changes/v1")
        self.assertEqual(doc["version"], "0.10.0")
        self.assertEqual(
            [r["name"] for r in doc["records"]], ["a-break", "b-fix", "c-add"]
        )
        self.assertEqual(
            doc["records"][0],
            {
                "name": "a-break",
                "kind": "error",
                "packages": ["caddy"],
                "library": [],
                "cli": [],
                "state": False,
                "touchesData": False,
                "requiredStop": False,
                "id": "K0003",
                "cve": [],
                "workaround": None,
                "body": "Renamed.\n",
            },
        )

    def test_json_for_a_released_version(self):
        doc = json.loads(self.repo.run("json", "--version", "0.9.0")[1])
        self.assertEqual([r["name"] for r in doc["records"]], ["old"])

    def test_next_id(self):
        picked = self.repo.run("next-id")[1].strip()
        self.assertRegex(picked, r"^K\d{4}$")
        self.assertNotIn(picked, {"K0001", "K0003"})

    def test_next_id_with_no_ids(self):
        empty = Repo()
        self.addCleanup(empty.close)
        self.assertRegex(empty.run("next-id")[1], r"^K\d{4}\n$")

    def test_bump(self):
        self.assertEqual(self.repo.run("bump")[1], "minor\n")
        (self.repo.root / "changes/a-break.md").unlink()
        self.assertEqual(self.repo.run("bump")[1], "patch\n")
        for name in ("b-fix", "c-add"):
            (self.repo.root / f"changes/{name}.md").unlink()
        self.assertEqual(self.repo.run("bump")[1], "none\n")

    def test_bump_silent_is_minor(self):
        (self.repo.root / "changes/a-break.md").unlink()
        self.repo.write("changes/d.md", record('kind = "silent"'))
        self.assertEqual(self.repo.run("bump")[1], "minor\n")


class ReleaseTest(RepoTest):
    def test_release(self):
        self.repo.write("changes/a.md", record('kind = "added"', "New thing."))
        self.repo.write("changes/b.md", record('kind = "fixed"', "Fixed thing."))
        code, _, err = self.repo.run("release", "0.10.0", "--date", "2026-11-11")
        self.assertEqual(code, 0, err)
        self.assertTrue((self.repo.root / "changes/0.10.0/a.md").exists())
        self.assertTrue((self.repo.root / "changes/0.10.0/b.md").exists())
        self.assertFalse((self.repo.root / "changes/a.md").exists())
        self.assertTrue((self.repo.root / "changes/README.md").exists())
        self.assertEqual(
            (self.repo.root / "CHANGELOG.md").read_text(),
            "# Changelog\n\nIntro.\n\n"
            "## 0.10.0 - 2026-11-11\n\n### Added\n\n- New thing.\n\n### Fixed\n\n- Fixed thing.\n\n"
            "## 0.9.0 - 2026-11-10\n\n### Fixed\n\n- Old fix.\n",
        )
        self.assertEqual(self.repo.run("bump")[1], "none\n")
        self.assertIn(
            "New thing.", self.repo.run("changelog", "--version", "0.10.0")[1]
        )

    def test_release_refuses_with_no_records(self):
        code, _, err = self.repo.run("release", "0.10.0")
        self.assertEqual(code, 1)
        self.assertIn("nothing to release", err)

    def test_release_refuses_an_existing_version(self):
        self.repo.write("changes/a.md", record('kind = "added"'))
        self.repo.write("changes/0.10.0/b.md", record('kind = "added"'))
        code, _, err = self.repo.run("release", "0.10.0")
        self.assertEqual(code, 1)
        self.assertIn("already exists", err)


class PullRequestTest(RepoTest):
    def setUp(self) -> None:
        super().setUp()
        self.repo.git("init", "-q", "-b", "main")
        self.repo.write("cli/main.rs", "fn main() {}\n")
        self.base = self.repo.commit("base")

    def check(self, *extra: str) -> tuple[int, str]:
        head = self.repo.commit("head")
        code, _, err = self.repo.run(
            "check", "--base", self.base, "--head", head, *extra
        )
        return code, err

    def test_code_change_without_record_fails(self):
        self.repo.write("cli/main.rs", "fn main() { 1; }\n")
        code, err = self.check()
        self.assertEqual(code, 1)
        self.assertIn("adds no change record", err)
        self.assertIn("changes/<name>.md", err)
        self.assertIn("no-changelog", err)

    def test_code_change_with_record_passes(self):
        self.repo.write("cli/main.rs", "fn main() { 1; }\n")
        self.repo.write("changes/thing.md", record('kind = "fixed"'))
        self.assertEqual(self.check(), (0, ""))

    def test_label_skips_the_record_rule(self):
        self.repo.write("cli/main.rs", "fn main() { 1; }\n")
        self.assertEqual(self.check("--no-record-required")[0], 0)

    def test_label_still_checks_format(self):
        self.repo.write("changes/thing.md", record('kind = "nope"'))
        code, err = self.check("--no-record-required")
        self.assertEqual(code, 1)
        self.assertIn("is unknown", err)

    def test_readme_does_not_count_as_a_record(self):
        self.repo.write("cli/main.rs", "fn main() { 1; }\n")
        self.repo.write("changes/README.md", "# Changed\n")
        self.assertEqual(self.check()[0], 1)

    def test_other_paths_need_no_record(self):
        self.repo.write("docs/page.md", "text\n")
        self.assertEqual(self.check()[0], 0)

    def test_changelog_entry_fails(self):
        self.repo.write("changes/thing.md", record('kind = "fixed"'))
        text = (self.repo.root / "CHANGELOG.md").read_text()
        self.repo.write(
            "CHANGELOG.md", text.replace("- Old fix.\n", "- Old fix.\n- New fix.\n")
        )
        code, err = self.check()
        self.assertEqual(code, 1)
        self.assertIn("adds lines to the release sections of CHANGELOG.md", err)

    def test_changelog_intro_edit_passes(self):
        text = (self.repo.root / "CHANGELOG.md").read_text()
        self.repo.write(
            "CHANGELOG.md", text.replace("Intro.", "A new intro.\n\n- with a list")
        )
        self.assertEqual(self.check()[0], 0)

    def test_release_passes(self):
        self.repo.write("changes/thing.md", record('kind = "fixed"', "A fix."))
        self.base = self.repo.commit("record")
        self.repo.write("cli/Cargo.toml", 'version = "0.10.0"\n')
        self.repo.run("release", "0.10.0", "--date", "2026-11-11")
        self.assertEqual(self.check(), (0, ""))

    def test_a_record_added_to_a_shipped_release_fails(self):
        self.repo.write("changes/0.9.0/old.md", record('kind = "fixed"', "Old."))
        self.base = self.repo.commit("shipped")
        self.repo.write("cli/main.rs", "fn main() { 1; }\n")
        self.repo.write("changes/0.9.0/sneaked.md", record('kind = "fixed"'))
        code, err = self.check()
        self.assertEqual(code, 1)
        self.assertIn("a release that has shipped", err)
        self.assertIn("adds no change record", err)

    def test_editing_a_shipped_record_fails(self):
        self.repo.write("changes/0.9.0/old.md", record('kind = "fixed"', "Old."))
        self.base = self.repo.commit("shipped")
        self.repo.write("changes/0.9.0/old.md", record('kind = "added"', "Old."))
        code, err = self.check()
        self.assertEqual(code, 1)
        self.assertIn("changes/0.9.0/, a release that has shipped", err)

    def test_a_package_that_does_not_exist_is_refused(self):
        self.repo.write("kix/packages/stable/caddy/default.nix", "{}\n")
        self.repo.write(
            "changes/x.md", record('kind = "fixed"\npackages = ["caddy", "cady"]')
        )
        code, _, err = self.repo.run("check")
        self.assertEqual(code, 1)
        self.assertIn("`cady` in `packages` is not a folder", err)
        self.assertNotIn("`caddy` in", err)

    def test_an_error_record_needs_its_id_in_an_error_message(self):
        self.repo.write("kix/packages/stable/caddy/default.nix", "{}\n")
        self.repo.write(
            "changes/x.md", record('kind = "error"\nid = "K0007"\npackages = ["caddy"]')
        )
        code, _, err = self.repo.run("check")
        self.assertEqual(code, 1)
        self.assertIn("prints [K0007]", err)
        self.repo.write(
            "kix/packages/stable/caddy/default.nix",
            '{ x = throw "[K0007] caddy: gone"; }\n',
        )
        self.assertEqual(self.repo.run("check")[0], 0)

    def test_a_security_bullet_carries_the_workaround(self):
        self.repo.write(
            "changes/x.md",
            record(
                'kind = "security"\nworkaround = "Pin the image to 1.2.3."', "Fixed."
            ),
        )
        out = self.repo.run("changelog")[1]
        self.assertIn(
            "- Fixed. To get the fix without upgrading: Pin the image to 1.2.3.", out
        )


if __name__ == "__main__":
    unittest.main()
