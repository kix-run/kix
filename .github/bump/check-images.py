#!/usr/bin/env python3
"""Check that every default image of the given package folders runs on amd64.

Usage: check-images.py <package folder>...

The bump agent tests on arm64, so an image that upstream publishes for arm64
only passes its tests and fails on most clusters. This reads each package's
default images from `kix/packages/default-images.nix` and asks the registry
for the platforms of each one. It needs `nix` and `crane` on the PATH.
"""

import json
import subprocess
import sys
from pathlib import Path

EXPR = """
let
  lib = (builtins.getFlake (toString ./.)).inputs.nixpkgs.lib;
in
import ./kix/packages/default-images.nix { inherit lib; }
"""

INDEX_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


def crane(*args: str) -> dict:
    out = subprocess.run(["crane", *args], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def platforms(ref: str) -> set[str]:
    manifest = crane("manifest", ref)
    if manifest.get("mediaType") in INDEX_TYPES or "manifests" in manifest:
        return {
            f"{m['platform']['os']}/{m['platform']['architecture']}"
            for m in manifest.get("manifests", [])
            if "platform" in m
        }
    config = crane("config", ref)
    return {f"{config.get('os')}/{config.get('architecture')}"}


def main() -> int:
    dirs = sys.argv[1:]
    if not dirs:
        print(__doc__, file=sys.stderr)
        return 2
    images = json.loads(
        subprocess.run(
            ["nix", "eval", "--json", "--impure", "--expr", EXPR],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )
    fail = 0
    for d in dirs:
        level, name = Path(d).parts[-2:]
        found = [
            i
            for i in images.get(level, {}).get(name, [])
            if i["repository"] and i["tag"]
        ]
        if not found:
            print(f"skip   {d}: no default image")
        for i in found:
            ref = f"{i['repository']}:{i['tag']}"
            if i["digest"]:
                ref = f"{i['repository']}@{i['digest']}"
            label = f"{name}.{i['path']} ({i['repository']}:{i['tag']})"
            try:
                found_platforms = platforms(ref)
            except subprocess.CalledProcessError as e:
                print(
                    f"FAIL   {label}: the registry did not answer: {e.stderr.strip()}"
                )
                fail = 1
                continue
            if "linux/amd64" in found_platforms:
                print(f"ok     {label}")
            else:
                shown = ", ".join(sorted(found_platforms)) or "none"
                print(f"FAIL   {label}: no linux/amd64 build (has {shown})")
                fail = 1
    return fail


if __name__ == "__main__":
    sys.exit(main())
