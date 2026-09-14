#!/usr/bin/env python3
"""Vendor the VictoriaMetrics operator CRD schemas into the kix package.

The operator's CRDs are generated from Go types upstream. Kix ships slim
stubs for most kinds, which accept any spec: enough to register the kind,
useless for catching a mistyped field. For the kinds a consumer actually
writes a spec into (`consumer = true` in kinds.nix) we vendor the real
upstream schema instead, so the apiserver rejects a bad spec at apply time
and `kix deploy --dry-run` sees it.

That only holds while the vendored files match the pinned operator version,
so this script is the single way to produce them, and `--check` fails when
they have drifted.

    scripts/vendor-vm-crd-schemas.py            # write the files
    scripts/vendor-vm-crd-schemas.py --check    # fail if they are stale

The version comes from the package itself, so the two cannot disagree.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
PKG = REPO / "kix" / "packages" / "victoria-metrics-operator"
SCHEMAS = PKG / "schemas"
BUNDLE = (
    "https://raw.githubusercontent.com/VictoriaMetrics/operator/{tag}"
    "/config/crd/overlay/crd.yaml"
)


def pinned_tag() -> str:
    """The operator image tag the package pins, e.g. v0.74.1."""
    text = (PKG / "default.nix").read_text()
    match = re.search(r'repository = "victoriametrics/operator";\s*\n\s*tag = "([^"]+)"', text)
    if not match:
        sys.exit("could not find the operator image tag in default.nix")
    return match.group(1)


def consumer_kinds() -> dict:
    """The kinds.nix entries that have a kix consumer surface."""
    out = subprocess.run(
        ["nix", "eval", "--file", str(PKG / "kinds.nix"), "vmCrdDefs", "--json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return {k: v for k, v in json.loads(out.stdout).items() if v.get("consumer")}


def upstream_crds(tag: str) -> dict:
    """Every CRD in the upstream bundle, keyed by `<plural>.<group>`."""
    import yaml  # only needed here; the bundle is YAML, the vendored files are JSON

    url = BUNDLE.format(tag=tag)
    with urllib.request.urlopen(url) as response:
        docs = yaml.safe_load_all(response.read().decode())
        return {d["metadata"]["name"]: d for d in docs if d}


def render(crd: dict) -> str:
    """What we commit: the upstream document, sorted, one key per line.

    Sorted and indented so a drift diff is readable. crds.nix reads only
    `.spec.versions[0].schema.openAPIV3Schema.properties.spec` out of it;
    the rest is kept so the diff shows everything that moved upstream.
    """
    return json.dumps(crd, indent=1, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if any vendored file differs from upstream",
    )
    args = parser.parse_args()

    tag = pinned_tag()
    kinds = consumer_kinds()
    crds = upstream_crds(tag)

    SCHEMAS.mkdir(exist_ok=True)
    stale = []
    for entry in sorted(kinds.values(), key=lambda e: e["plural"]):
        name = f"{entry['plural']}.operator.victoriametrics.com"
        if name not in crds:
            sys.exit(f"{name} is not in the {tag} bundle; check kinds.nix against upstream")
        target = SCHEMAS / f"{entry['plural']}.json"
        wanted = render(crds[name])
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
            f"\n{len(stale)} vendored schema(s) do not match operator {tag}."
            "\nRun scripts/vendor-vm-crd-schemas.py to refresh them.",
            file=sys.stderr,
        )
        return 1
    print(f"\nAll {len(kinds)} consumer schemas match operator {tag}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
