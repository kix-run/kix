#!/usr/bin/env python3
"""Check that a pull request's change records match what it changes for users.

    scripts/change-kind.py --base <dir> --head <dir> [--head-build <dir>]
                           [--kix <kix>] [--labels a,b] [--cluster <name> ...]

`--base` and `--head` are checkouts of the pull request's base and head
commits. The script reads the change records and the CLI surface files from
them. It builds each fixture cluster at `--base` and at `--head-build`, with
the head's `kix`. `--head-build` defaults to `--head`. The workflow passes a
checkout of the head commit whose `clusters/` comes from the base, so the
base's cluster definitions are built with the pull request's library. A pull
request that removes an option and also fixes `clusters/` then still shows
the removal as a failure.

- A cluster that builds at the base and fails at the head needs a record of
  kind `error`, and the failure message must contain that record's id.
- A cluster whose manifests change needs a record of any kind, and the
  pull request needs the label `manifest-change-reviewed`. Only the
  maintainer adds that label.
- A line removed or changed in the CLI surface needs a record whose `cli`
  field names the command or flag.

Labels come from `--labels` or the `PR_LABELS` environment variable, as a
comma-separated list. The summary goes to stdout and to
`$GITHUB_STEP_SUMMARY` when it is set. The exit code is 1 when the pull
request is missing something.

The tests: `cd scripts && python3 -m unittest -v change_records.test_change_kind`.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import json
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import change_records as cr  # noqa: E402

# Flake attributes of the root flake.nix. `homelab-kind` holds most of the
# package set. The others add what it leaves out and render in seconds.
CLUSTERS = [
    "homelab-kind",
    "minimal",
    "example",
    "full",
    "cnpg",
    "monitoring-native",
    "external-secrets",
]

REVIEWED_LABEL = "manifest-change-reviewed"
SURFACE_SNAPSHOT = "cli/kix-cli/tests/snapshots/cli_surface.snap"
SCHEMA_DIR = "cli/kix-cli/schema"
MAX_LISTED = 20


@dataclasses.dataclass
class Render:
    """One cluster built at one commit: its manifests, or the failure text."""

    manifests: dict[tuple[str, str, str, str], dict] | None
    error: str = ""

    @property
    def ok(self) -> bool:
        return self.manifests is not None


@dataclasses.dataclass
class Outcome:
    cluster: str
    status: str  # same, changed, fails-at-head, fails-at-base
    problems: list[str] = dataclasses.field(default_factory=list)
    details: list[str] = dataclasses.field(default_factory=list)


def index(manifests: list[dict]) -> dict[tuple[str, str, str, str], dict]:
    """Key each manifest by apiVersion, kind, namespace, and name."""
    out = {}
    for m in manifests:
        meta = m.get("metadata") or {}
        key = (
            m.get("apiVersion", ""),
            m.get("kind", ""),
            meta.get("namespace", ""),
            meta.get("name", ""),
        )
        out[key] = m
    return out


def render(kix: str, checkout: pathlib.Path, cluster: str) -> Render:
    result = subprocess.run(
        [kix, "--flake", str(checkout), "--quiet", "build", "-o", "json", cluster],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return Render(None, (result.stderr + result.stdout).strip())
    try:
        return Render(index(json.loads(result.stdout)))
    except json.JSONDecodeError as e:
        return Render(None, f"kix build printed output that is not JSON: {e}")


def describe(key: tuple[str, str, str, str]) -> str:
    _, kind, namespace, name = key
    return f"{kind} {namespace}/{name}" if namespace else f"{kind} {name}"


def changed_objects(base: Render, head: Render) -> list[str]:
    """List the objects added, removed, or changed between two renders, sorted."""
    b, h = base.manifests or {}, head.manifests or {}
    lines = []
    for key in sorted(set(b) | set(h)):
        if key not in b:
            lines.append(f"added {describe(key)}")
        elif key not in h:
            lines.append(f"removed {describe(key)}")
        elif b[key] != h[key]:
            lines.append(f"changed {describe(key)}")
    return lines


def decide(
    cluster: str,
    base: Render,
    head: Render,
    added: list[cr.Record],
    labels: set[str],
) -> Outcome:
    """Decide what one cluster's two renders require of the pull request."""
    if not base.ok:
        return Outcome(
            cluster,
            "fails-at-base",
            details=[
                "It does not build at the base commit, so there is nothing to compare.",
                "Failure (last lines):",
                *[f"    {line}" for line in base.error.splitlines()[-5:]],
            ],
        )

    if not head.ok:
        outcome = Outcome(cluster, "fails-at-head")
        errors = [r for r in added if r.kind == "error"]
        if not errors:
            outcome.problems.append(
                f"`{cluster}` builds at the base commit and fails at this pull request. "
                'Add a change record with `kind = "error"` and an `id`, and put the id in the '
                "error message. If the failure is a bug, fix it instead."
            )
        elif not any(r.id and r.id in head.error for r in errors):
            ids = ", ".join(r.id for r in errors if r.id)
            outcome.problems.append(
                f"`{cluster}` fails at this pull request, and the failure message does not "
                f"contain the id of the pull request's `error` record ({ids}). "
                "Put the id in the error message, so a user can look the change up."
            )
        tail = head.error.splitlines()[-5:]
        outcome.details += ["Failure (last lines):", *[f"    {line}" for line in tail]]
        return outcome

    changes = changed_objects(base, head)
    if not changes:
        return Outcome(cluster, "same")

    outcome = Outcome(cluster, "changed")
    if not added:
        outcome.problems.append(
            f"`{cluster}` builds different manifests at this pull request. "
            "Add a change record that says what changes for users (changes/README.md)."
        )
    if REVIEWED_LABEL not in labels:
        outcome.problems.append(
            f"`{cluster}` builds different manifests at this pull request. "
            f"The maintainer reviews the change and adds the label `{REVIEWED_LABEL}`. "
            "Say in the pull request description which record kind you propose, and why."
        )
    outcome.details.append(f"{len(changes)} objects differ:")
    outcome.details += [f"    {line}" for line in changes[:MAX_LISTED]]
    if len(changes) > MAX_LISTED:
        outcome.details.append(f"    and {len(changes) - MAX_LISTED} more")
    return outcome


def normalized_lines(text: str) -> collections.Counter[str]:
    return collections.Counter(
        " ".join(line.split()) for line in text.splitlines() if line.strip()
    )


def flatten(value, path: str = "") -> dict[str, object]:
    """Map each leaf of a JSON value to its path."""
    if isinstance(value, dict):
        out: dict[str, object] = {}
        for k, v in value.items():
            out.update(flatten(v, f"{path}/{k}"))
        return out
    if isinstance(value, list):
        out = {}
        for i, v in enumerate(value):
            out.update(flatten(v, f"{path}/{i}"))
        return out
    return {path: value}


def surface_removals(base: pathlib.Path, head: pathlib.Path) -> list[str]:
    """Return the CLI surface the head removes or changes, compared with the base.

    The surface snapshot is compared line by line, ignoring order and spacing.
    Each JSON schema is compared leaf by leaf, so a new field alone is no
    removal. A file the base does not have is skipped.
    """
    found: list[str] = []
    base_surface = base / SURFACE_SNAPSHOT
    if base_surface.is_file():
        head_surface = head / SURFACE_SNAPSHOT
        after = (
            normalized_lines(head_surface.read_text())
            if head_surface.is_file()
            else collections.Counter()
        )
        gone = normalized_lines(base_surface.read_text()) - after
        found += [f"{SURFACE_SNAPSHOT}: {line}" for line in sorted(gone)]
    base_schemas = base / SCHEMA_DIR
    if base_schemas.is_dir():
        for path in sorted(base_schemas.glob("*.json")):
            rel = path.relative_to(base)
            head_path = head / rel
            before = flatten(json.loads(path.read_text()))
            after = (
                flatten(json.loads(head_path.read_text()))
                if head_path.is_file()
                else {}
            )
            for leaf, value in sorted(before.items()):
                if leaf not in after:
                    found.append(f"{rel}: removed {leaf}")
                elif after[leaf] != value:
                    found.append(f"{rel}: changed {leaf}")
    return found


def surface_problems(removals: list[str], added: list[cr.Record]) -> list[str]:
    if not removals or any(r.cli for r in added):
        return []
    return [
        "This pull request removes or changes part of the CLI surface (a command, a flag, "
        "or a JSON schema field). Add a change record whose `cli` field names each command or flag that "
        'changed, such as `cli = ["--old-flag"]`.'
    ]


def added_records(base: pathlib.Path, head: pathlib.Path) -> list[cr.Record]:
    """Return the unreleased records the head adds or changes, compared with the base."""
    records, problems = cr.load(head)
    if problems:
        raise cr.RecordError("\n".join(problems))
    added = []
    for record in cr.unreleased(records):
        rel = record.path.relative_to(head)
        before = base / rel
        if not before.is_file() or before.read_text() != record.path.read_text():
            added.append(record)
    return added


def summary(
    outcomes: list[Outcome],
    removals: list[str],
    surface: list[str],
    added: list[cr.Record],
) -> str:
    out = ["## Change kind check", ""]
    kinds = ", ".join(f"`{r.name}` ({r.kind})" for r in added) or "none"
    out += [f"Change records this pull request adds: {kinds}", ""]
    out += ["| Cluster | Result |", "|---|---|"]
    for o in outcomes:
        out.append(
            f"| `{o.cluster}` | {o.status}{' (needs action)' if o.problems else ''} |"
        )
    out.append("")
    for o in outcomes:
        if o.problems or o.details:
            out += [f"### `{o.cluster}`", ""]
            out += [f"- {p}" for p in o.problems]
            if o.details:
                out += ["", "```", *o.details, "```"]
            out.append("")
    if removals:
        out += ["### CLI surface", ""]
        out += [f"- {p}" for p in surface]
        out += ["", "```", *removals[:MAX_LISTED]]
        if len(removals) > MAX_LISTED:
            out.append(f"and {len(removals) - MAX_LISTED} more")
        out += ["```", ""]
    failed = any(o.problems for o in outcomes) or surface
    out.append("Result: **fail**" if failed else "Result: pass")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--base", type=pathlib.Path, required=True, help="checkout of the base commit"
    )
    parser.add_argument(
        "--head", type=pathlib.Path, required=True, help="checkout of the head commit"
    )
    parser.add_argument(
        "--head-build",
        type=pathlib.Path,
        help="checkout to build the clusters from in place of --head",
    )
    parser.add_argument(
        "--kix",
        default=os.environ.get("KIX", "kix"),
        help="the kix to build with (default: $KIX or kix)",
    )
    parser.add_argument(
        "--labels",
        default=os.environ.get("PR_LABELS", ""),
        help="comma-separated pull request labels",
    )
    parser.add_argument(
        "--cluster", action="append", help="build only this cluster (repeatable)"
    )
    args = parser.parse_args(argv)

    labels = {label.strip() for label in args.labels.split(",") if label.strip()}
    try:
        added = added_records(args.base, args.head)
    except cr.RecordError as e:
        print(
            f"The change records do not parse. Run scripts/change-records.py check.\n{e}",
            file=sys.stderr,
        )
        return 1

    outcomes = []
    for cluster in args.cluster or CLUSTERS:
        print(f"building {cluster} at the base and the head", file=sys.stderr)
        base = render(args.kix, args.base, cluster)
        head = render(args.kix, args.head_build or args.head, cluster)
        outcomes.append(decide(cluster, base, head, added, labels))

    removals = surface_removals(args.base, args.head)
    surface = surface_problems(removals, added)

    # When nothing builds at the base, the check compared nothing. That is a
    # broken check, and it must not pass.
    if outcomes and all(o.status == "fails-at-base" for o in outcomes):
        outcomes[0].problems.append(
            "No cluster builds at the base commit, so this check compared nothing. "
            "Look at the failure below. It is likely a problem with the check's setup."
        )
    text = summary(outcomes, removals, surface, added)
    sys.stdout.write(text)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as f:
            f.write(text)
    return 1 if any(o.problems for o in outcomes) or surface else 0


if __name__ == "__main__":
    sys.exit(main())
