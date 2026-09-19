#!/usr/bin/env python3
"""Vendor upstream CRDs into the kix packages that ship them.

Every package that owns CRDs keeps them under `<pkg>/crds/`, one JSON file
per CRD named `<metadata.name>.json`, next to a `sources.txt` listing the
public URLs they come from (one per line, optionally followed by the CRD
names to take from that document). A package whose upstream is not a public
URL ships `crds/update.py` instead, exposing `crds() -> list[dict]` and
saying in a comment why the URL list did not fit.

    uv run scripts/vendor-crds.py                # refresh every package
    uv run scripts/vendor-crds.py velero arc     # just these
    uv run scripts/vendor-crds.py --check        # fail if anything drifted

`--check` runs in CI on every pull request that touches a package. The
script is deliberately dumb: fetch, keep the CustomResourceDefinition
documents, sort, write. Anything project-specific belongs in that package's
`sources.txt`. Design: v2_discussions/146_crd_vendoring_and_upgrades.md.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import importlib.util
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from vendor_crds import (
    VendorError,
    fetch_crds,
    file_name,
    parse_sources,
    render,
)

REPO = pathlib.Path(__file__).resolve().parent.parent
PACKAGES = REPO / "kix" / "packages"


def discover(names: list[str]) -> list[pathlib.Path]:
    """The `crds/` directories to process, all of them or the named packages."""
    if names:
        dirs = [PACKAGES / name / "crds" for name in names]
        for directory in dirs:
            if not directory.is_dir():
                sys.exit(f"{directory.relative_to(REPO)}: no such directory")
        return dirs
    return sorted(
        d
        for d in PACKAGES.glob("*/crds")
        if (d / "sources.txt").exists() or (d / "update.py").exists()
    )


def wanted(directory: pathlib.Path) -> dict[str, str]:
    """`file name -> rendered content` for one package, from its sources."""
    script = directory / "update.py"
    if script.exists():
        spec = importlib.util.spec_from_file_location(
            f"crds_{directory.parent.name}", script
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)  # type: ignore[union-attr]
        crds = module.crds()
    else:
        crds = []
        for url, only in parse_sources(directory / "sources.txt"):
            crds.extend(fetch_crds(url, only))
    out: dict[str, str] = {}
    for crd in crds:
        name = file_name(crd)
        if name in out:
            raise VendorError(f"{crd['metadata']['name']} is produced twice")
        out[name] = render(crd)
    return out


def reconcile(directory: pathlib.Path, files: dict[str, str], check: bool) -> list[str]:
    """Write (or, in check mode, compare) one package's files. Returns the
    lines to print; a line starting with a capital is a problem."""
    lines: list[str] = []
    rel = directory.relative_to(REPO)
    for name, content in sorted(files.items()):
        target = directory / name
        if target.exists() and target.read_text() == content:
            lines.append(f"  ok       {rel / name}")
        elif check:
            lines.append(f"  STALE    {rel / name}")
        else:
            target.write_text(content)
            lines.append(f"  written  {rel / name}")
    for stray in sorted(directory.glob("*.json")):
        if stray.name in files:
            continue
        if check:
            lines.append(f"  ORPHAN   {rel / stray.name} (no source produces it)")
        else:
            stray.unlink()
            lines.append(f"  removed  {rel / stray.name}")
    return lines


def process(directory: pathlib.Path, check: bool) -> tuple[str, list[str], bool]:
    package = directory.parent.name
    try:
        lines = reconcile(directory, wanted(directory), check)
    except VendorError as error:
        return package, [f"  ERROR    {error}"], False
    return (
        package,
        lines,
        not any(line.lstrip().startswith(("STALE", "ORPHAN")) for line in lines),
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "packages", nargs="*", help="package names; default is every package with crds/"
    )
    parser.add_argument(
        "--check", action="store_true", help="exit non-zero if any file would change"
    )
    parser.add_argument(
        "-j", "--jobs", type=int, default=8, help="packages processed in parallel"
    )
    args = parser.parse_args()

    directories = discover(args.packages)
    if not directories:
        sys.exit(
            "no package under kix/packages has a crds/sources.txt or crds/update.py"
        )

    failed: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for package, lines, ok in pool.map(
            lambda d: process(d, args.check), directories
        ):
            print(f"{package}:")
            print("\n".join(lines))
            if not ok:
                failed.append(package)

    if failed:
        verb = "do not match their sources" if args.check else "could not be vendored"
        print(
            f"\n{len(failed)} package(s) {verb}: {', '.join(failed)}", file=sys.stderr
        )
        if args.check:
            print("Run scripts/vendor-crds.py to refresh them.", file=sys.stderr)
        return 1
    print(f"\n{len(directories)} package(s) up to date.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
