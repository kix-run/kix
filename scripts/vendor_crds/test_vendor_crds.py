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

    def test_bare_equals_is_a_string(self):
        doc = v.documents_in("enum:\n- '!='\n- =\n- =~\n", "s")
        self.assertEqual(doc, [{"enum": ["!=", "=", "=~"]}])


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


def role(kind: str, name: str) -> dict:
    return {
        "apiVersion": "rbac.authorization.k8s.io/v1",
        "kind": kind,
        "metadata": {"name": name},
        "rules": [{"apiGroups": [""], "resources": ["pods"], "verbs": ["get"]}],
    }


BUNDLE = "\n---\n".join(
    json.dumps(d)
    for d in [
        role("ClusterRole", "op"),
        role("Role", "op"),
        role("ClusterRole", "x.io:admin"),
        {"kind": "ServiceAccount", "metadata": {"name": "op"}},
    ]
)


class RolesIn(unittest.TestCase):
    def test_selects_by_kind_and_name(self):
        found = v.roles_in(BUNDLE, {"Role/op", "ClusterRole/x.io:admin"})
        self.assertEqual(
            [(r["kind"], r["metadata"]["name"]) for r in found],
            [("ClusterRole", "x.io:admin"), ("Role", "op")],
        )

    def test_missing_selector(self):
        with self.assertRaisesRegex(v.VendorError, "does not contain Role/other"):
            v.roles_in(BUNDLE, {"Role/op", "Role/other"})

    def test_refuses_other_kinds(self):
        with self.assertRaisesRegex(v.VendorError, "not ClusterRole/name or Role/name"):
            v.roles_in(BUNDLE, {"ServiceAccount/op"})

    def test_selector_without_name(self):
        with self.assertRaisesRegex(v.VendorError, "not ClusterRole/name or Role/name"):
            v.roles_in(BUNDLE, {"ClusterRole"})

    def test_no_selectors_is_refused(self):
        with self.assertRaisesRegex(v.VendorError, "as Kind/name"):
            v.roles_in(BUNDLE, set())

    def test_file_names(self):
        self.assertEqual(
            v.file_name(role("ClusterRole", "x.io:admin")),
            "clusterrole-x.io_admin.json",
        )
        self.assertEqual(v.file_name(role("Role", "op")), "role-op.json")
        with self.assertRaisesRegex(v.VendorError, "no file name mapping"):
            v.file_name(role("Role", "Op/1"))


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
            v.file_name(
                {"kind": v.CRD_KIND, "metadata": {"name": "widgets.example.io"}}
            ),
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

    def test_rbac_directory(self):
        rbac = pathlib.Path(self.tmp.name) / "rbac"
        rbac.mkdir()
        (rbac / "sources.txt").write_text(
            "https://x/bundle.yaml ClusterRole/x.io:admin Role/op\n"
        )
        with mock.patch.object(self.driver, "fetch", return_value=BUNDLE.encode()):
            package, _lines, ok = self.driver.process(rbac, check=False)
        self.assertTrue(ok)
        self.assertEqual(package.split("/")[-1], "rbac")
        self.assertEqual(
            sorted(p.name for p in rbac.glob("*.json")),
            ["clusterrole-x.io_admin.json", "role-op.json"],
        )

    def test_discover_skips_rbac_without_sources(self):
        packages = pathlib.Path(self.tmp.name) / "packages"
        for d in ("a/crds", "a/rbac", "b/rbac"):
            (packages / d).mkdir(parents=True)
        (packages / "a/crds/update.py").write_text("")
        (packages / "a/rbac/update.py").write_text("")
        (packages / "b/rbac/sources.txt").write_text("")
        self.driver.PACKAGES = packages
        found = [str(d.relative_to(packages)) for d in self.driver.discover([])]
        self.assertEqual(found, ["a/crds", "b/rbac"])
        with self.assertRaises(SystemExit):
            self.driver.discover(["c"])

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
