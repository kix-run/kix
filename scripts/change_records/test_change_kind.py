"""Tests for the pull request kind check.

cd scripts && python3 -m unittest -v change_records.test_change_kind
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

import change_records as cr

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent


def load_driver():
    spec = importlib.util.spec_from_file_location(
        "change_kind", SCRIPTS / "change-kind.py"
    )
    module = importlib.util.module_from_spec(spec)
    # dataclasses looks the module up in sys.modules.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


CK = load_driver()


def record(kind: str, id: str | None = None, cli: list[str] | None = None) -> cr.Record:
    return cr.Record(
        name=f"a-{kind}",
        path=pathlib.Path(f"changes/a-{kind}.md"),
        version=None,
        kind=kind,
        packages=[],
        library=[],
        cli=cli or [],
        state=False,
        touches_data=False,
        required_stop=False,
        id=id,
        cve=[],
        workaround=None,
        body="Something changed.\n",
    )


def deployment(image: str = "nginx:1.27") -> dict:
    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": "web", "namespace": "shop"},
        "spec": {"template": {"spec": {"containers": [{"image": image}]}}},
    }


def built(*manifests: dict) -> object:
    return CK.Render(CK.index(list(manifests)))


def failed(text: str) -> object:
    return CK.Render(None, text)


class Decide(unittest.TestCase):
    def test_same_manifests_need_nothing(self):
        o = CK.decide("c", built(deployment()), built(deployment()), [])
        self.assertEqual((o.status, o.problems), ("same", []))

    def test_a_cluster_that_fails_at_the_base_is_reported_and_skipped(self):
        o = CK.decide("c", failed("boom"), failed("boom"), [])
        self.assertEqual((o.status, o.problems), ("fails-at-base", []))

    def test_a_new_failure_needs_an_error_record(self):
        o = CK.decide(
            "c", built(deployment()), failed("error: replicaCount is gone"), []
        )
        self.assertEqual(o.status, "fails-at-head")
        self.assertEqual(len(o.problems), 1)
        self.assertIn('kind = "error"', o.problems[0])

    def test_a_new_failure_needs_the_id_in_the_message(self):
        records = [record("error", id="K0007")]
        o = CK.decide(
            "c",
            built(deployment()),
            failed("error: replicaCount is gone"),
            records,
        )
        self.assertEqual(len(o.problems), 1)
        self.assertIn("K0007", o.problems[0])
        self.assertIn("does not contain the id", o.problems[0])

    def test_a_new_failure_that_names_the_id_passes(self):
        records = [record("error", id="K0007")]
        text = "error: replicaCount is gone. Set replicas instead [K0007]"
        o = CK.decide("c", built(deployment()), failed(text), records)
        self.assertEqual((o.status, o.problems), ("fails-at-head", []))

    def test_a_non_error_record_does_not_cover_a_new_failure(self):
        o = CK.decide(
            "c",
            built(deployment()),
            failed("K0007"),
            [record("silent", id="K0007")],
        )
        self.assertIn('kind = "error"', o.problems[0])

    def test_changed_manifests_need_a_record(self):
        o = CK.decide("c", built(deployment()), built(deployment("nginx:1.28")), [])
        self.assertEqual(o.status, "changed")
        self.assertEqual(len(o.problems), 1)
        self.assertIn("change record", o.problems[0])
        self.assertIn("    changed Deployment shop/web", o.details)

    def test_changed_manifests_with_a_record_pass(self):
        o = CK.decide(
            "c",
            built(deployment()),
            built(deployment("nginx:1.28")),
            [record("fixed")],
        )
        self.assertEqual((o.status, o.problems), ("changed", []))

    def test_the_object_list_is_capped(self):
        many = [
            {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {"name": f"cm{i:02d}", "namespace": "a"},
            }
            for i in range(CK.MAX_LISTED + 5)
        ]
        o = CK.decide("c", built(), built(*many), [])
        self.assertIn(f"{CK.MAX_LISTED + 5} objects differ:", o.details)
        self.assertIn("    and 5 more", o.details)
        self.assertIn("    added ConfigMap a/cm00", o.details)


class Surface(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self._tmp.name)
        self.base, self.head = root / "base", root / "head"
        for side in (self.base, self.head):
            (side / CK.SCHEMA_DIR).mkdir(parents=True)
            (side / CK.SURFACE_SNAPSHOT).parent.mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, side: pathlib.Path, help_text: str, schema: dict) -> None:
        (side / CK.SURFACE_SNAPSHOT).write_text(help_text)
        (side / CK.SCHEMA_DIR / "plan.schema.json").write_text(json.dumps(schema))

    def test_added_lines_and_fields_are_not_removals(self):
        self.write(
            self.base, "## kix\n  --a\n", {"properties": {"a": {"type": "string"}}}
        )
        self.write(
            self.head,
            "## kix\n      --a\n  --b\n",
            {"properties": {"a": {"type": "string"}, "b": {"type": "string"}}},
        )
        self.assertEqual(CK.surface_removals(self.base, self.head), [])

    def test_removed_help_lines_and_schema_fields_are_found(self):
        self.write(
            self.base,
            "## kix\n  --a\n  --b\n",
            {"properties": {"a": {"type": "string"}}},
        )
        self.write(
            self.head, "## kix\n  --a\n", {"properties": {"a": {"type": "integer"}}}
        )
        removals = CK.surface_removals(self.base, self.head)
        self.assertEqual(
            removals,
            [
                f"{CK.SURFACE_SNAPSHOT}: --b",
                f"{CK.SCHEMA_DIR}/plan.schema.json: changed /properties/a/type",
            ],
        )
        self.assertEqual(len(CK.surface_problems(removals, [record("changed")])), 1)
        self.assertEqual(
            CK.surface_problems(removals, [record("error", "K0001", cli=["--b"])]), []
        )

    def test_a_base_without_the_snapshot_is_skipped(self):
        (self.head / CK.SURFACE_SNAPSHOT).write_text("## kix\n")
        self.assertEqual(CK.surface_removals(self.base, self.head), [])


class AddedRecords(unittest.TestCase):
    def test_new_and_changed_records_count_and_unchanged_ones_do_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            base, head = root / "base", root / "head"
            for side in (base, head):
                (side / "changes").mkdir(parents=True)
                (side / "changes" / "old.md").write_text(
                    '+++\nkind = "fixed"\n+++\nOld.\n'
                )
                (side / "changes" / "edited.md").write_text(
                    '+++\nkind = "fixed"\n+++\nFirst.\n'
                )
            (head / "changes" / "edited.md").write_text(
                '+++\nkind = "changed"\n+++\nSecond.\n'
            )
            (head / "changes" / "new.md").write_text('+++\nkind = "added"\n+++\nNew.\n')
            names = sorted(r.name for r in CK.added_records(base, head))
            self.assertEqual(names, ["edited", "new"])


class Main(unittest.TestCase):
    def test_main_writes_the_summary_and_fails_on_a_problem(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            base, head = root / "base", root / "head"
            for side in (base, head):
                (side / "changes").mkdir(parents=True)
            renders = {
                str(base): built(deployment()),
                str(head): built(deployment("nginx:1.28")),
            }
            summary_file = root / "summary.md"
            out = io.StringIO()
            with (
                mock.patch.object(
                    CK, "render", lambda kix, checkout, cluster: renders[str(checkout)]
                ),
                mock.patch.dict(
                    "os.environ", {"GITHUB_STEP_SUMMARY": str(summary_file)}
                ),
                contextlib.redirect_stdout(out),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                code = CK.main(
                    [
                        "--base",
                        str(base),
                        "--head",
                        str(head),
                        "--cluster",
                        "minimal",
                    ]
                )
            self.assertEqual(code, 1)
            self.assertIn("| `minimal` | changed (needs action) |", out.getvalue())
            self.assertEqual(summary_file.read_text(), out.getvalue())

    def test_clusters_build_from_head_build_and_records_come_from_head(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            base, head, build = root / "base", root / "head", root / "build"
            for side in (base, head, build):
                (side / "changes").mkdir(parents=True)
            (head / "changes" / "gone.md").write_text(
                '+++\nkind = "error"\nid = "K0042"\n+++\nThe option is gone.\n'
            )
            renders = {
                str(base): built(deployment()),
                str(build): failed("error: option `x` was removed [K0042]"),
            }
            out = io.StringIO()
            with (
                mock.patch.object(
                    CK, "render", lambda kix, checkout, cluster: renders[str(checkout)]
                ),
                mock.patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": ""}),
                contextlib.redirect_stdout(out),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                code = CK.main(
                    [
                        "--base",
                        str(base),
                        "--head",
                        str(head),
                        "--head-build",
                        str(build),
                    ]
                    + ["--cluster", "minimal"]
                )
            self.assertEqual(code, 0, out.getvalue())
            self.assertIn("| `minimal` | fails-at-head |", out.getvalue())


if __name__ == "__main__":
    unittest.main()
