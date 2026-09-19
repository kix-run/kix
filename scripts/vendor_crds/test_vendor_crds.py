"""Offline tests for the vendoring routines and the driver's reconcile step.

uv run python -m unittest scripts/vendor_crds/test_vendor_crds.py
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock

import vendor_crds as v

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent


def load_driver():
    spec = importlib.util.spec_from_file_location(
        "vendor_crds_driver", SCRIPTS / "vendor-crds.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def crd(name: str, **spec) -> dict:
    plural, group = name.split(".", 1)
    return {
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {"name": name},
        "spec": {
            "group": group,
            "names": {"plural": plural, "kind": plural.title()},
            **spec,
        },
    }


class ParseSources(unittest.TestCase):
    def test_urls_comments_and_names(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "sources.txt"
            p.write_text(
                "# a comment\n\n"
                "https://x/a.yaml\n"
                "https://x/bundle.yaml  one.g two.g # trailing comment\n"
            )
            self.assertEqual(
                v.parse_sources(p),
                [
                    ("https://x/a.yaml", set()),
                    ("https://x/bundle.yaml", {"one.g", "two.g"}),
                ],
            )

    def test_not_a_url(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "sources.txt"
            p.write_text("deploy/crds/thing.yaml\n")
            with self.assertRaisesRegex(v.VendorError, "not a URL"):
                v.parse_sources(p)

    def test_empty(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "sources.txt"
            p.write_text("# nothing here\n")
            with self.assertRaisesRegex(v.VendorError, "no sources"):
                v.parse_sources(p)


class CrdsIn(unittest.TestCase):
    def test_keeps_only_crds_from_a_bundle(self):
        text = (
            "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: x\n"
            "---\n"
            "apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\n"
            "metadata:\n  name: widgets.example.io\nspec:\n  group: example.io\n"
            "---\n"
            "---\n"
            "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: op\n"
        )
        found = v.crds_in(text)
        self.assertEqual([c["metadata"]["name"] for c in found], ["widgets.example.io"])

    def test_refuses_conversion_webhook(self):
        doc = crd("widgets.example.io", conversion={"strategy": "Webhook"})
        with self.assertRaisesRegex(v.VendorError, "conversion webhook"):
            v.crds_in(json.dumps(doc), source="s")

    def test_accepts_conversion_none(self):
        doc = crd("widgets.example.io", conversion={"strategy": "None"})
        self.assertEqual(len(v.crds_in(json.dumps(doc))), 1)

    def test_nameless_crd(self):
        with self.assertRaisesRegex(v.VendorError, "no metadata.name"):
            v.crds_in("kind: CustomResourceDefinition\nmetadata: {}\n")

    def test_not_yaml(self):
        with self.assertRaisesRegex(v.VendorError, "not YAML"):
            v.crds_in("kind: [unterminated\n")


class FetchCrds(unittest.TestCase):
    def test_only_filters_and_sorts(self):
        bundle = "\n---\n".join(
            json.dumps(c) for c in [crd("b.g"), crd("a.g"), crd("c.g")]
        )
        with mock.patch.object(v, "fetch", return_value=bundle.encode()):
            names = [
                c["metadata"]["name"] for c in v.fetch_crds("https://x", {"c.g", "a.g"})
            ]
        self.assertEqual(names, ["a.g", "c.g"])

    def test_only_missing_is_an_error(self):
        with (
            mock.patch.object(v, "fetch", return_value=json.dumps(crd("a.g")).encode()),
            self.assertRaisesRegex(v.VendorError, "does not contain b.g"),
        ):
            v.fetch_crds("https://x", {"a.g", "b.g"})


class Render(unittest.TestCase):
    def test_sorted_and_newline_terminated(self):
        out = v.render(
            {
                "kind": "CustomResourceDefinition",
                "apiVersion": "v1",
                "metadata": {"name": "x"},
            }
        )
        self.assertTrue(out.endswith("}\n"))
        self.assertLess(out.index('"apiVersion"'), out.index('"kind"'))
        self.assertEqual(
            v.file_name({"metadata": {"name": "widgets.example.io"}}),
            "widgets.example.io.json",
        )


class Reconcile(unittest.TestCase):
    def setUp(self):
        self.driver = load_driver()
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = pathlib.Path(self.tmp.name) / "crds"
        self.dir.mkdir()
        self.driver.REPO = pathlib.Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_write_then_check_then_drift(self):
        files = {"a.g.json": "A\n", "b.g.json": "B\n"}
        lines = self.driver.reconcile(self.dir, files, check=False)
        self.assertEqual([l.split()[0] for l in lines], ["written", "written"])
        lines = self.driver.reconcile(self.dir, files, check=True)
        self.assertEqual([l.split()[0] for l in lines], ["ok", "ok"])
        (self.dir / "a.g.json").write_text("edited\n")
        (self.dir / "stray.json").write_text("{}\n")
        lines = self.driver.reconcile(self.dir, files, check=True)
        self.assertEqual([l.split()[0] for l in lines], ["STALE", "ok", "ORPHAN"])
        lines = self.driver.reconcile(self.dir, files, check=False)
        self.assertEqual([l.split()[0] for l in lines], ["written", "ok", "removed"])
        self.assertFalse((self.dir / "stray.json").exists())

    def test_process_reports_errors_without_raising(self):
        (self.dir / "sources.txt").write_text("not-a-url\n")
        _package, lines, ok = self.driver.process(self.dir, check=True)
        self.assertFalse(ok)
        self.assertTrue(lines[0].lstrip().startswith("ERROR"))

    def test_update_py_escape_hatch(self):
        (self.dir / "update.py").write_text(
            "def crds():\n"
            "    return [{'kind': 'CustomResourceDefinition', 'metadata': {'name': 'w.example.io'}, 'spec': {}}]\n"
        )
        _package, _lines, ok = self.driver.process(self.dir, check=False)
        self.assertTrue(ok)
        self.assertTrue((self.dir / "w.example.io.json").exists())


if __name__ == "__main__":
    unittest.main()
