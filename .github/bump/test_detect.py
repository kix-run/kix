"""Tests for detect.py and readiness.py. They ask no registry and no upstream.

Run from the repository root:
    python3 -m unittest discover -s .github/bump -p 'test_*.py'
"""

import json
import subprocess
import unittest

import detect
import readiness

INDEX = "application/vnd.oci.image.index.v1+json"


def index(*platforms):
    return {
        "mediaType": INDEX,
        "manifests": [
            {"platform": dict(zip(("os", "architecture"), p.split("/")))}
            for p in platforms
        ]
        # An attestation entry, which names no real platform.
        + [{"platform": {"os": "unknown", "architecture": "unknown"}}],
    }


class Registry:
    """Stand in for `crane`, answering from a table of references."""

    def __init__(self, images, broken=()):
        self.images = images
        self.broken = set(broken)
        self.gets = []

    def __call__(self, command, ref):
        if ref in self.broken:
            return subprocess.CompletedProcess(
                [], 1, "", "Error: 429 Too Many Requests"
            )
        if ref not in self.images:
            return subprocess.CompletedProcess(
                [], 1, "", "Error: MANIFEST_UNKNOWN: manifest unknown"
            )
        found = self.images[ref]
        if command == "digest":
            return subprocess.CompletedProcess([], 0, "sha256:0\n", "")
        self.gets.append(ref)
        if command == "manifest":
            body = found if "manifests" in found else {"mediaType": "manifest"}
        else:
            body = found
        return subprocess.CompletedProcess([], 0, json.dumps(body), "")


class ReadinessTest(unittest.TestCase):
    def use(self, images, broken=()):
        registry = Registry(images, broken)
        original = readiness.crane
        readiness.crane = registry
        self.addCleanup(setattr, readiness, "crane", original)
        return registry

    def test_an_image_on_both_platforms_is_ready(self):
        self.use({"r:1": index("linux/amd64", "linux/arm64")})
        self.assertIsNone(readiness.problem("r:1", {"linux/amd64", "linux/arm64"}))

    def test_a_tag_the_registry_lacks_is_not_published(self):
        registry = self.use({})
        self.assertEqual(readiness.problem("r:2", {"linux/amd64"}), "not published")
        self.assertEqual(
            registry.gets, [], "a missing tag is asked about with HEAD only"
        )

    def test_a_missing_platform_is_named(self):
        self.use({"r:1": index("linux/amd64")})
        self.assertEqual(
            readiness.problem("r:1", {"linux/amd64", "linux/arm64"}),
            "no linux/arm64 build",
        )

    def test_a_single_platform_manifest_is_read_from_its_config(self):
        self.use({"r:1": {"os": "linux", "architecture": "amd64"}})
        self.assertIsNone(readiness.problem("r:1", {"linux/amd64"}))
        self.assertEqual(
            readiness.problem("r:1", {"linux/amd64", "linux/arm64"}),
            "no linux/arm64 build",
        )

    def test_a_registry_error_is_not_an_answer(self):
        self.use({}, broken={"r:1"})
        with self.assertRaises(readiness.CouldNotCheck):
            readiness.problem("r:1", {"linux/amd64"})

    def test_an_image_needs_the_platforms_of_the_one_it_replaces(self):
        self.use(
            {
                "both@old": index("linux/amd64", "linux/arm64", "linux/s390x"),
                "amd@old": index("linux/amd64"),
            }
        )
        self.assertEqual(readiness.needed("both@old"), {"linux/amd64", "linux/arm64"})
        self.assertEqual(readiness.needed("amd@old"), {"linux/amd64"})
        self.assertEqual(readiness.needed(None), {"linux/amd64"})
        self.assertEqual(readiness.needed("gone@old"), {"linux/amd64"})


class CandidatesTest(unittest.TestCase):
    def test_tags_are_filtered_and_ordered_newest_first(self):
        tags = ["v1.2.0", "v1.10.0", "v1.9.3", "v1.11.0-rc.1", "nightly", "v2.0.0"]
        self.assertEqual(
            detect.matching(tags, {}, "1.9.0"),
            [
                ("2.0.0", "v2.0.0"),
                ("1.10.0", "v1.10.0"),
                ("1.9.3", "v1.9.3"),
                ("1.2.0", "v1.2.0"),
            ],
        )

    def test_track_and_skip_and_a_tag_pattern(self):
        entry = {
            "tags": r"^REL_(\d+_\d+)$",
            "track": "major",
            "skip": {"18.8": "broken"},
        }
        tags = ["REL_18_7", "REL_18_8", "REL_18_9", "REL_19_0", "REL_17_9"]
        self.assertEqual(
            detect.matching(tags, entry, "18.6"),
            [("18.9", "REL_18_9"), ("18.7", "REL_18_7")],
        )

    def test_through_minor_finishes_the_pinned_minor_first(self):
        newer = [("1.11.2", "a"), ("1.10.4", "b"), ("1.10.0", "c"), ("1.9.3", "d")]
        self.assertEqual(detect.in_reach(newer, "1.9.1", "minor"), [("1.9.3", "d")])

    def test_through_minor_then_takes_the_next_minor(self):
        newer = [("2.0.0", "z"), ("1.11.2", "a"), ("1.10.4", "b"), ("1.10.0", "c")]
        self.assertEqual(
            detect.in_reach(newer, "1.9.3", "minor"), [("1.10.4", "b"), ("1.10.0", "c")]
        )

    def test_without_through_every_newer_version_is_in_reach(self):
        newer = [("1.11.2", "a"), ("1.9.3", "d")]
        self.assertEqual(detect.in_reach(newer, "1.9.1", None), newer)

    def test_an_unknown_through_is_refused(self):
        with self.assertRaises(RuntimeError):
            detect.in_reach([("1.1.0", "a")], "1.0.0", "patch")


def image(ref, replaces="pinned"):
    return {"path": "image", "ref": ref, "replaces": replaces}


class PickTest(unittest.TestCase):
    def pick(self, newer, images, published, broken=()):
        def look(ref, need):
            if ref in broken:
                raise readiness.CouldNotCheck("429")
            return None if ref in published else "not published"

        return detect.pick(newer, images, look=look, need=lambda _: {"linux/amd64"})

    # ClickHouse on 23 Nov 2026: 26.8.45.6 was tagged an hour before its
    # image was pushed, and 26.8.44.3 had been published the day before.
    def test_an_older_published_release_is_taken_while_the_newest_waits(self):
        newer = [("26.8.45.6", "v26.8.45.6-lts"), ("26.8.44.3", "v26.8.44.3-lts")]
        images = {v: [image(f"clickhouse:{v}")] for v, _ in newer}
        found, not_ready = self.pick(newer, images, {"clickhouse:26.8.44.3"})
        self.assertEqual(found, ("26.8.44.3", "v26.8.44.3-lts"))
        self.assertEqual(
            not_ready, [("26.8.45.6", "`clickhouse:26.8.45.6`: not published")]
        )

    # echo-server on the same day: neither newer nginx release had an image.
    def test_no_target_when_no_newer_release_is_published(self):
        newer = [("1.30.8", "release-1.30.8"), ("1.30.7", "release-1.30.7")]
        images = {v: [image(f"nginx:{v}-alpine")] for v, _ in newer}
        found, not_ready = self.pick(newer, images, set())
        self.assertIsNone(found)
        self.assertEqual([v for v, _ in not_ready], ["1.30.8", "1.30.7"])

    def test_every_image_of_a_release_must_be_published(self):
        newer = [("2.0.0", "v2.0.0"), ("1.9.0", "v1.9.0")]
        images = {
            v: [image(f"operator:v{v}", "a"), image(f"operand:v{v}", "b")]
            for v, _ in newer
        }
        published = {"operator:v2.0.0", "operator:v1.9.0", "operand:v1.9.0"}
        found, not_ready = self.pick(newer, images, published)
        self.assertEqual(found, ("1.9.0", "v1.9.0"))
        self.assertEqual(not_ready, [("2.0.0", "`operand:v2.0.0`: not published")])

    def test_a_release_with_no_image_to_check_is_taken(self):
        found, not_ready = self.pick([("1.19.0", "v1.19.0")], {"1.19.0": []}, set())
        self.assertEqual(found, ("1.19.0", "v1.19.0"))
        self.assertEqual(not_ready, [])

    def test_an_unanswered_newer_release_stops_the_choice(self):
        newer = [("2.0.0", "v2.0.0"), ("1.9.0", "v1.9.0")]
        images = {v: [image(f"app:v{v}")] for v, _ in newer}
        with self.assertRaises(readiness.CouldNotCheck):
            self.pick(newer, images, {"app:v1.9.0"}, broken={"app:v2.0.0"})


if __name__ == "__main__":
    unittest.main()
