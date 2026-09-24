#!/usr/bin/env python3
"""Vendor the Altinity clickhouse-operator CRD schemas into the Kix package.

The operator ships four CRDs as YAML. The Kix package builds them through the
typed CRD chain and takes the spec schema, the printer columns and a names
check from the upstream documents, which are vendored here as JSON, one file
per kind under `schemas/`. With the real schema in place the apiserver
refuses a mistyped field in a ClickHouseInstallation at apply time, and
`kix deploy --dry-run` sees it too.

That only holds while the vendored files match the pinned operator version,
so this script is the single way to produce them, and `--check` fails when
they have drifted.

    scripts/vendor-clickhouse-crd-schemas.py            # write the files
    scripts/vendor-clickhouse-crd-schemas.py --check    # fail if they are stale
    scripts/vendor-clickhouse-crd-schemas.py --source ~/src/clickhouse-operator

The version comes from the package itself, so the two cannot disagree.
`--source` reads the CRDs from a local clone checked out at that version and
skips the network.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
PKG = REPO / "kix" / "packages" / "clickhouse-operator"
SCHEMAS = PKG / "schemas"
CRD_DIR = "deploy/helm/clickhouse-operator/crds"
RAW = "https://raw.githubusercontent.com/Altinity/clickhouse-operator/release-{version}/"


def pinned_version() -> str:
    """The operator image tag the package pins, e.g. 0.27.3."""
    text = (PKG / "default.nix").read_text()
    match = re.search(
        r'repository = "docker.io/altinity/clickhouse-operator";\s*\n\s*tag = "([^"]+)"',
        text,
    )
    if not match:
        sys.exit("could not find the operator image tag in default.nix")
    return match.group(1)


def shipped_kinds() -> list:
    """Every kinds.nix entry. All of them carry a vendored document."""
    out = subprocess.run(
        ["nix", "eval", "--file", str(PKG / "kinds.nix"), "crdDefs", "--json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return sorted(json.loads(out.stdout).values(), key=lambda e: e["plural"])


def upstream_crd(entry: dict, version: str, source) -> dict:
    import yaml  # upstream is YAML, the vendored files are JSON

    name = f"{entry['plural']}.{entry['group']}"
    relative = f"{CRD_DIR}/CustomResourceDefinition-{name}.yaml"
    if source is not None:
        text = (source / relative).read_text()
    else:
        with urllib.request.urlopen(RAW.format(version=version) + relative) as response:
            text = response.read().decode()
    crd = yaml.safe_load(text)
    if crd["metadata"]["name"] != name:
        sys.exit(f"{relative} declares {crd['metadata']['name']}, expected {name}")
    stamped = crd["metadata"].get("labels", {}).get(f"{entry['group']}/chop")
    if stamped != version:
        sys.exit(
            f"{name} is stamped for operator {stamped}, but the package pins {version}"
        )
    return crd


def render(crd: dict) -> str:
    """What we commit: the upstream document, sorted, one key per line.

    Sorted and indented so a drift diff is readable. crds.nix reads the spec
    schema, the printer columns and the names out of it; the rest is kept so
    the diff shows everything that moved upstream.
    """
    return json.dumps(crd, indent=1, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if any vendored file differs from upstream",
    )
    parser.add_argument(
        "--source",
        type=pathlib.Path,
        help="a local clone of Altinity/clickhouse-operator at the pinned version",
    )
    args = parser.parse_args()

    version = pinned_version()
    kinds = shipped_kinds()

    SCHEMAS.mkdir(exist_ok=True)
    stale = []
    for entry in kinds:
        target = SCHEMAS / f"{entry['plural']}.json"
        wanted = render(upstream_crd(entry, version, args.source))
        if target.exists() and target.read_text() == wanted:
            print(f"  ok      {target.relative_to(REPO)}")
            continue
        if args.check:
            stale.append(target.relative_to(REPO))
            print(f"  STALE   {target.relative_to(REPO)}")
            continue
        target.write_text(wanted)
        print(f"  written {target.relative_to(REPO)}")

    if stale:
        print(
            f"\n{len(stale)} vendored schema(s) do not match operator {version}."
            "\nRun scripts/vendor-clickhouse-crd-schemas.py to refresh them.",
            file=sys.stderr,
        )
        return 1
    print(f"\nAll {len(kinds)} schemas match operator {version}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
