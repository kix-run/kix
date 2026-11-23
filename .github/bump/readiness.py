#!/usr/bin/env python3
"""Say whether container images can be pulled on the platforms Kix needs.

Usage: readiness.py [--base <commit>] <package folder>...

An image is ready when its registry has it for linux/amd64, which most
clusters run, and for every other platform in PLATFORMS that the image it
replaces has. The bump agent tests on linux/arm64, so a release whose
arm64 build is late is not ready. A project that publishes for amd64 only
stays ready, and its package keeps the limit it already has.

`detect.py` imports this module and asks about the images of a release
before it starts a bump. Run as a script, it checks every default image of
the given package folders, which the bump workflow does after the agent has
finished. With `--base`, each image is compared with the image the same
option held at that commit. Without it, each image needs linux/amd64 only.
Both callers read the images from the packages themselves.

It needs `crane` on the PATH, and `nix` and `git` when run as a script.

Exit status: 0 when every image is ready, 1 when one is not or a registry
could not be asked.
"""

import json
import subprocess
import sys
from pathlib import Path

ALWAYS = "linux/amd64"
PLATFORMS = (ALWAYS, "linux/arm64")

# `%s` is the tree to read the packages from.
EXPR = """
let
  lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib;
in
import (%s + "/kix/packages/default-images.nix") { inherit lib; }
"""

INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}

# The error codes a registry gives for a tag or a repository it does not
# have (OCI distribution specification, "Error Codes").
ABSENT = ("MANIFEST_UNKNOWN", "NAME_UNKNOWN")


class CouldNotCheck(Exception):
    """A registry gave no answer about an image, so nothing is known about it."""


def crane(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["crane", *args], capture_output=True, text=True, timeout=120)


def crane_json(*args: str) -> dict:
    got = crane(*args)
    if got.returncode != 0:
        raise CouldNotCheck(got.stderr.strip()[-300:])
    return json.loads(got.stdout)


def exists(ref: str) -> bool:
    """Return whether the registry has `ref`.

    `crane digest` asks with a HEAD request, which Docker Hub does not
    count against its pull limit, so a tag that is not published yet costs
    nothing to ask about.
    """
    got = crane("digest", ref)
    if got.returncode == 0:
        return True
    if any(code in got.stderr for code in ABSENT):
        return False
    raise CouldNotCheck(got.stderr.strip()[-300:])


def platforms(ref: str) -> set[str]:
    """Return the platforms `ref` is published for, as `os/architecture`."""
    manifest = crane_json("manifest", ref)
    if manifest.get("mediaType") in INDEX_TYPES or "manifests" in manifest:
        return {
            f"{m['platform']['os']}/{m['platform']['architecture']}"
            for m in manifest.get("manifests", [])
            if "platform" in m
        }
    config = crane_json("config", ref)
    return {f"{config.get('os')}/{config.get('architecture')}"}


def needed(replaces: str | None) -> set[str]:
    """Return the platforms an image must have to replace `replaces`.

    `replaces` is the reference pinned now, or None for an image the
    package did not have before.
    """
    if replaces is None or not exists(replaces):
        return {ALWAYS}
    return {ALWAYS} | (set(PLATFORMS) & platforms(replaces))


def problem(ref: str, need: set[str]) -> str | None:
    """Return what keeps `ref` from being ready, or None when it is ready.

    Raises CouldNotCheck when the registry did not answer.
    """
    if not exists(ref):
        return "not published"
    lacking = sorted(need - platforms(ref))
    if lacking:
        return f"no {' or '.join(lacking)} build"
    return None


def reference(image: dict) -> str:
    if image["digest"]:
        return f"{image['repository']}@{image['digest']}"
    return f"{image['repository']}:{image['tag']}"


def default_images(tree: str) -> dict:
    return json.loads(
        subprocess.run(
            ["nix", "eval", "--json", "--impure", "--expr", EXPR % tree],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )


def main() -> int:
    dirs = sys.argv[1:]
    base = None
    if dirs[:1] == ["--base"]:
        base, dirs = dirs[1], dirs[2:]
    if not dirs:
        print(__doc__, file=sys.stderr)
        return 2
    images = default_images("./.")
    before = {}
    if base:
        root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        before = default_images(
            f'(builtins.fetchGit {{ url = "{root}"; rev = "{base}"; }})'
        )
    fail = 0
    for d in dirs:
        level, name = Path(d).parts[-2:]
        found = [
            i
            for i in images.get(level, {}).get(name, [])
            if i["repository"] and i["tag"]
        ]
        old = {
            i["path"]: reference(i)
            for i in before.get(level, {}).get(name, [])
            if i["repository"] and i["tag"]
        }
        if not found:
            print(f"skip   {d}: no default image")
        for i in found:
            label = f"{name}.{i['path']} ({i['repository']}:{i['tag']})"
            try:
                found_problem = problem(reference(i), needed(old.get(i["path"])))
            except CouldNotCheck as e:
                print(f"FAIL   {label}: the registry did not answer: {e}")
                fail = 1
                continue
            if found_problem:
                print(f"FAIL   {label}: {found_problem}")
                fail = 1
            else:
                print(f"ok     {label}")
    return fail


if __name__ == "__main__":
    sys.exit(main())
