#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "click"]
# ///
"""
Source-level structural diff between two directories of K8s manifests.

Walks two directory trees, loads every *.yaml/*.yml (multi-doc aware), and
indexes each document by (apiVersion, kind, namespace or "_cluster", name).
Reports per-resource buckets and JSON-path-keyed structural diffs using the
shared parity.structural_diff engine.

Unlike scripts/kix-dump.py + parity diff, both inputs are on-disk manifest
dumps (no live cluster), so we apply the same `normalize_kix` rules to each
side before comparing.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import click
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parity.normalize import normalize_kix
from parity.structural_diff import format_diffs, structural_diff


def _load_dir(root: Path) -> dict[tuple, dict]:
    """Return {(apiVersion, kind, ns, name): doc} for all YAML under root."""
    index: dict[tuple, dict] = {}
    if not root.exists():
        raise click.ClickException(f"directory does not exist: {root}")
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix not in (".yaml", ".yml"):
            continue
        # Walk doc-by-doc so a single malformed doc inside a multi-doc
        # file (e.g. helm chart NOTES.txt fragments) doesn't drop the
        # rest of the file.
        docs: list = []
        try:
            text = path.read_text()
        except OSError as e:
            click.echo(f"warning: failed to read {path}: {e}", err=True)
            continue
        gen = yaml.safe_load_all(text)
        while True:
            try:
                doc = next(gen)
            except StopIteration:
                break
            except yaml.YAMLError as e:
                click.echo(
                    f"warning: skipping malformed doc in {path}: {str(e)[:80]}",
                    err=True,
                )
                # Re-init generator past the failure point — yaml-py
                # can't recover so we abort the rest of this file.
                break
            docs.append(doc)
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            kind = doc.get("kind")
            api = doc.get("apiVersion")
            md = doc.get("metadata") or {}
            name = md.get("name")
            if not (kind and api and name):
                continue
            ns = md.get("namespace") or "_cluster"
            key = (api, kind, ns, name)
            if key in index:
                click.echo(f"warning: duplicate {key} in {root} ({path})", err=True)
            index[key] = doc
    return index


def _load_ignore_paths(file: Path | None) -> tuple[set[str], set[str]]:
    """Return (path_patterns, resource_keys).

    Lines beginning with `resource:` skip the entire matching resource
    (key form: `<ns>/<kind>/<name>`). Everything else is a JSON-path pattern.
    """
    if not file or not file.exists():
        return set(), set()
    paths: set[str] = set()
    resources: set[str] = set()
    for raw in file.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("resource:"):
            resources.add(line[len("resource:") :].strip())
        else:
            paths.add(line)
    return paths, resources


def _bucket_key(k: tuple) -> str:
    _api, kind, ns, name = k
    return f"{ns}/{kind}/{name}"


@click.command()
@click.argument(
    "left_dir", type=click.Path(exists=True, file_okay=False, path_type=Path)
)
@click.argument(
    "right_dirs",
    nargs=-1,
    type=click.Path(exists=True, file_okay=False, path_type=Path),
    required=True,
)
@click.option(
    "--summary",
    is_flag=True,
    help="Bucket counts + per-resource bucket list (default).",
)
@click.option(
    "--detail", metavar="NS/KIND/NAME", help="Full structural diff for one resource."
)
@click.option(
    "--ns", "namespace", help="Filter to a namespace (use _cluster for cluster-scoped)."
)
@click.option("--json", "as_json", is_flag=True, help="Emit machine-readable JSON.")
@click.option(
    "--ignore-paths",
    "ignore_paths_file",
    type=click.Path(dir_okay=False, path_type=Path),
    help="File of JSON-path patterns to ignore (one per line, # comments ok).",
)
@click.option(
    "--left-label",
    default="left",
    help="Label for left side in output (default: left).",
)
@click.option(
    "--right-label",
    default="right",
    help="Label for right side in output (default: right).",
)
@click.option(
    "--color/--no-color", default=sys.stdout.isatty(), help="Colorize output."
)
def main(
    left_dir: Path,
    right_dirs: tuple[Path, ...],
    summary: bool,
    detail: str | None,
    namespace: str | None,
    as_json: bool,
    ignore_paths_file: Path | None,
    left_label: str,
    right_label: str,
    color: bool,
) -> None:
    """Diff two directories of K8s manifests at the resource level.

    LEFT_DIR is conventionally the kix build output (./result). One or more
    RIGHT_DIRS are merged into a single right-side index — pass both
    `nw1/migration/k8s/` and `nw1/migration/helm-rendered/` to compare
    against the full Ansible deployment. Resources are matched on
    (apiVersion, kind, namespace or "_cluster", name).
    """
    left = _load_dir(left_dir)
    right: dict[tuple, dict] = {}
    for d in right_dirs:
        for k, v in _load_dir(d).items():
            right[k] = v
    ignore_paths, ignore_resources = _load_ignore_paths(ignore_paths_file)

    if ignore_resources:
        left = {k: v for k, v in left.items() if _bucket_key(k) not in ignore_resources}
        right = {
            k: v for k, v in right.items() if _bucket_key(k) not in ignore_resources
        }

    if namespace:
        left = {k: v for k, v in left.items() if k[2] == namespace}
        right = {k: v for k, v in right.items() if k[2] == namespace}

    only_left = sorted(left.keys() - right.keys())
    only_right = sorted(right.keys() - left.keys())
    both = sorted(left.keys() & right.keys())

    equal: list[tuple] = []
    different: list[tuple] = []
    diffs_by_key: dict[tuple, list] = {}
    for k in both:
        a = normalize_kix(left[k])
        b = normalize_kix(right[k])
        d = structural_diff(
            a, b, ignore_paths=ignore_paths, a_label=left_label, b_label=right_label
        )
        if d:
            different.append(k)
            diffs_by_key[k] = d
        else:
            equal.append(k)

    if detail:
        try:
            ns, kind, name = detail.split("/", 2)
        except ValueError:
            raise click.ClickException("--detail must be NS/KIND/NAME")
        match = next(
            (k for k in both if k[1] == kind and k[2] == ns and k[3] == name),
            None,
        )
        if match is None:
            raise click.ClickException(f"no resource matches {detail} in both dirs")
        click.echo(
            format_diffs(diffs_by_key.get(match, []), color=color, full_diff=True)
        )
        return

    if as_json:
        out = {
            "only_left": [_bucket_key(k) for k in only_left],
            "only_right": [_bucket_key(k) for k in only_right],
            "equal": [_bucket_key(k) for k in equal],
            "different": [
                {
                    "key": _bucket_key(k),
                    "diffs": [
                        {"path": d.path, "kind": d.kind.value} for d in diffs_by_key[k]
                    ],
                }
                for k in different
            ],
        }
        click.echo(json.dumps(out, indent=2))
        return

    # summary (default)
    click.echo(f"left  ({left_label}): {left_dir}  [{len(left)} resources]")
    rds = ", ".join(str(d) for d in right_dirs)
    click.echo(f"right ({right_label}): {rds}  [{len(right)} resources]")
    click.echo("")
    click.echo(f"  only-in-left  : {len(only_left)}")
    click.echo(f"  only-in-right : {len(only_right)}")
    click.echo(f"  equal         : {len(equal)}")
    click.echo(f"  different     : {len(different)}")
    click.echo("")

    if only_left:
        click.echo("== only in left ==")
        for k in only_left:
            click.echo(f"  - {_bucket_key(k)}")
        click.echo("")
    if only_right:
        click.echo("== only in right ==")
        for k in only_right:
            click.echo(f"  + {_bucket_key(k)}")
        click.echo("")
    if different:
        click.echo("== different ==")
        for k in different:
            click.echo(f"  ~ {_bucket_key(k)}  ({len(diffs_by_key[k])} diffs)")


if __name__ == "__main__":
    main()
