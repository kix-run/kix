#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "click"]
# ///
"""
Compare kix-generated manifests against a cluster dump directory.

Produces a structured markdown report with:
- Summary counts (identical, modified, missing, extra)
- Fuzzy name matching for unmatched resources
- Structural diffs (JSON-path-based) for modified resources

Output is designed for both human reading and LLM consumption.
"""

import sys
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

import click
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parity.normalize import normalize_kix, normalize_cluster, resource_key
from parity.structural_diff import structural_diff, format_diffs, DiffKind


# --- Resource loading ---


def load_resources(directory: Path, normalizer) -> dict[str, dict]:
    """Load and normalize all YAML files from a directory.

    Supports both layouts:
    - Nested: {namespace}/{name}-{kind}.yaml  (dump output)
    - Flat:   {namespace}--{name}-{kind}.yaml  (kix nix build output)

    Returns dict mapping "{namespace}/{name}-{kind}" -> normalized doc.
    """
    resources = {}

    # Try nested layout first (subdirectories = namespaces)
    subdirs = [d for d in sorted(directory.iterdir()) if d.is_dir()]
    if subdirs:
        for ns_dir in subdirs:
            ns = ns_dir.name
            for f in sorted(ns_dir.glob("*.yaml")):
                if f.name == "_meta.yaml" or f.name == "README.md":
                    continue
                if "-packageinstance.yaml" in f.name:
                    continue
                with open(f) as fh:
                    doc = yaml.safe_load(fh)
                if doc is None:
                    continue
                doc = normalizer(doc)
                resources[f"{ns}/{f.stem}"] = doc
    else:
        # Flat layout: {namespace}--{name}-{kind}.yaml
        for f in sorted(directory.glob("*.yaml")):
            if f.name == "_meta.yaml":
                continue
            if "-packageinstance.yaml" in f.name:
                continue
            stem = f.stem
            if "--" not in stem:
                continue
            ns, rest = stem.split("--", 1)
            with open(f) as fh:
                doc = yaml.safe_load(fh)
            if doc is None:
                continue
            doc = normalizer(doc)
            resources[f"{ns}/{rest}"] = doc

    return resources


def parse_resource_id(key: str) -> tuple[str, str, str]:
    """Parse '{namespace}/{name}-{kind}' into (kind, namespace, name)."""
    if "/" not in key:
        return ("Unknown", "_cluster", key)
    ns, rest = key.split("/", 1)
    parts = rest.rsplit("-", 1)
    if len(parts) != 2:
        return ("Unknown", ns, rest)
    name, kind = parts
    return (kind, ns, name)


def format_resource(key: str) -> str:
    """Format a resource key as a human-readable identifier."""
    kind, ns, name = parse_resource_id(key)
    if ns == "_cluster":
        return f"{name} ({kind})"
    return f"{ns}/{name} ({kind})"


# --- Fuzzy matching ---


def find_best_match(
    key: str,
    candidates_by_kind: dict[str, list[str]],
    threshold: float = 0.7,
) -> tuple[str, float] | None:
    """Find the single best fuzzy match for a resource key among candidates.

    Only matches against the same kind. Returns (candidate_key, ratio) or None.
    """
    kind, ns, name = parse_resource_id(key)
    same_kind = candidates_by_kind.get(kind, [])
    if not same_kind:
        return None

    ns_name = f"{ns}/{name}"
    best_key = None
    best_ratio = 0.0
    for candidate in same_kind:
        _, c_ns, c_name = parse_resource_id(candidate)
        c_ns_name = f"{c_ns}/{c_name}"
        ratio = SequenceMatcher(None, ns_name, c_ns_name).ratio()
        if ratio > best_ratio:
            best_ratio = ratio
            best_key = candidate

    if best_key and best_ratio >= threshold:
        return (best_key, best_ratio)
    return None


def find_rename_pairs(
    kix_only: list[str],
    cluster_only: list[str],
    kix_resources: dict[str, dict],
    cluster_resources: dict[str, dict],
    ignore_paths: set[str] | None,
    max_structural_diffs: int = 5,
) -> list[tuple[str, str, float, list]]:
    """Find probable renames between kix-only and cluster-only resources.

    Uses three filters to avoid false positives:
    1. Name similarity (SequenceMatcher ratio >= 0.6)
    2. Strict mutual best match (A's best = B AND B's best = A)
    3. Structural similarity (diff count <= max_structural_diffs)

    Returns list of (kix_key, cluster_key, name_ratio, diffs).
    """
    # Index by kind
    kix_by_kind: dict[str, list[str]] = {}
    for key in kix_only:
        kind, _, _ = parse_resource_id(key)
        kix_by_kind.setdefault(kind, []).append(key)

    cluster_by_kind: dict[str, list[str]] = {}
    for key in cluster_only:
        kind, _, _ = parse_resource_id(key)
        cluster_by_kind.setdefault(kind, []).append(key)

    # Find mutual best matches
    pairs = []
    used_cluster = set()

    for kix_key in kix_only:
        # A's best match in cluster
        match = find_best_match(kix_key, cluster_by_kind)
        if not match:
            continue
        cluster_key, ratio = match
        if cluster_key in used_cluster:
            continue

        # B's best match in kix (mutual check)
        reverse = find_best_match(cluster_key, kix_by_kind)
        if not reverse or reverse[0] != kix_key:
            continue

        # Structural similarity filter
        diffs = structural_diff(
            kix_resources[kix_key],
            cluster_resources[cluster_key],
            "$",
            ignore_paths,
            a_label="kix",
            b_label="cluster",
        )
        # Exclude the name diff itself from the count
        non_name_diffs = [d for d in diffs if d.path != "$.metadata.name"]
        if len(non_name_diffs) > max_structural_diffs:
            continue

        used_cluster.add(cluster_key)
        pairs.append((kix_key, cluster_key, ratio, diffs))

    return pairs


# --- Report generation ---


def generate_report(
    kix_dir: Path,
    cluster_dir: Path,
    kix_resources: dict[str, dict],
    cluster_resources: dict[str, dict],
    ignore_paths: set[str] | None,
) -> str:
    """Generate a structured markdown diff report."""
    lines: list[str] = []

    # Categorize
    kix_keys = set(kix_resources.keys())
    cluster_keys = set(cluster_resources.keys())

    common = kix_keys & cluster_keys
    kix_only = sorted(kix_keys - cluster_keys)
    cluster_only = sorted(cluster_keys - kix_keys)

    identical = []
    modified = []

    for key in sorted(common):
        diffs = structural_diff(
            kix_resources[key],
            cluster_resources[key],
            "$",
            ignore_paths,
            a_label="kix",
            b_label="cluster",
        )
        if diffs:
            modified.append((key, diffs))
        else:
            identical.append(key)

    # Find probable renames (mutual best match + structural similarity)
    rename_pairs = find_rename_pairs(
        kix_only, cluster_only,
        kix_resources, cluster_resources,
        ignore_paths,
    )
    renamed_kix = {kix_key for kix_key, _, _, _ in rename_pairs}
    renamed_cluster = {cluster_key for _, cluster_key, _, _ in rename_pairs}

    # Header
    lines.append("# kix diff report")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    lines.append(f"**kix:** `{kix_dir}` ({len(kix_resources)} resources)")
    lines.append(f"**cluster:** `{cluster_dir}` ({len(cluster_resources)} resources)")
    lines.append("")

    # Summary table
    lines.append("## Summary")
    lines.append("")
    lines.append("| Category | Count |")
    lines.append("|----------|-------|")
    lines.append(f"| Identical | {len(identical)} |")
    lines.append(f"| Modified | {len(modified)} |")
    lines.append(f"| kix-only | {len(kix_only)} |")
    lines.append(f"| Cluster-only | {len(cluster_only)} |")
    lines.append("")

    # Probable renames section (before kix-only/cluster-only so context is clear)
    if rename_pairs:
        lines.append("## Probable renames / moves")
        lines.append("")
        for kix_key, cluster_key, ratio, diffs in rename_pairs:
            pct = int(ratio * 100)
            lines.append(f"### `{format_resource(kix_key)}` <-> `{format_resource(cluster_key)}` ({pct}% match)")
            lines.append("")
            if diffs:
                lines.append("```")
                lines.append(format_diffs(diffs))
                lines.append("```")
            else:
                lines.append("*Structurally identical (only name/namespace differs)*")
            lines.append("")

    # kix-only section (excluding resources that were matched as renames)
    unmatched_kix = [k for k in kix_only if k not in renamed_kix]
    if unmatched_kix:
        lines.append("## kix-only (not in cluster)")
        lines.append("")
        for key in unmatched_kix:
            lines.append(f"- `{format_resource(key)}`")
        lines.append("")

    # Cluster-only section (excluding resources that were matched as renames)
    unmatched_cluster = [k for k in cluster_only if k not in renamed_cluster]
    if unmatched_cluster:
        lines.append("## Cluster-only (not in kix)")
        lines.append("")
        for key in unmatched_cluster:
            lines.append(f"- `{format_resource(key)}`")
        lines.append("")

    # Modified section
    if modified:
        lines.append("## Modified")
        lines.append("")
        for key, diffs in modified:
            kind, ns, name = parse_resource_id(key)
            if ns == "_cluster":
                lines.append(f"### {kind} {name}")
            else:
                lines.append(f"### {kind} {ns}/{name}")
            lines.append("")

            # Diff summary
            n_missing = sum(1 for d in diffs if d.kind == DiffKind.MISSING_IN_B)
            n_extra = sum(1 for d in diffs if d.kind == DiffKind.EXTRA_IN_B)
            n_changed = sum(1 for d in diffs
                            if d.kind in (DiffKind.VALUE_MISMATCH, DiffKind.TYPE_MISMATCH))
            summary_parts = []
            if n_missing:
                summary_parts.append(f"{n_missing} in kix only")
            if n_extra:
                summary_parts.append(f"{n_extra} in cluster only")
            if n_changed:
                summary_parts.append(f"{n_changed} changed")
            lines.append(f"_{', '.join(summary_parts)}_")
            lines.append("")

            lines.append("```")
            lines.append(format_diffs(diffs))
            lines.append("```")
            lines.append("")

    # Identical list (collapsed)
    if identical:
        lines.append("## Identical")
        lines.append("")
        lines.append(f"{len(identical)} resources match exactly.")
        lines.append("")
        lines.append("<details>")
        lines.append("<summary>Show all identical resources</summary>")
        lines.append("")
        for key in identical:
            lines.append(f"- `{format_resource(key)}`")
        lines.append("")
        lines.append("</details>")
        lines.append("")

    return "\n".join(lines)


# --- Main ---


@click.command()
@click.argument("kix_dir", type=click.Path(exists=True, file_okay=False))
@click.argument("cluster_dir", type=click.Path(exists=True, file_okay=False))
@click.option("--ignore-path", multiple=True,
              help="JSON paths to ignore (e.g. '*.annotations', '$.spec.strategy')")
def main(kix_dir: str, cluster_dir: str, ignore_path: tuple[str, ...]):
    """Compare kix manifests against a cluster dump.

    KIX_DIR is the kix output directory (e.g. ./result from nix build).
    CLUSTER_DIR is the dump directory (from kix-dump.py).

    Output is a structured markdown report written to stdout.
    """
    kix_path = Path(kix_dir)
    cluster_path = Path(cluster_dir)

    ignore_paths = set(ignore_path) if ignore_path else None

    click.echo("Loading kix manifests...", err=True)
    kix_resources = load_resources(kix_path, normalize_kix)
    click.echo(f"  {len(kix_resources)} resources", err=True)

    click.echo("Loading cluster dump...", err=True)
    cluster_resources = load_resources(cluster_path, normalize_cluster)
    click.echo(f"  {len(cluster_resources)} resources", err=True)

    report = generate_report(
        kix_path, cluster_path,
        kix_resources, cluster_resources,
        ignore_paths,
    )

    # Write report to stdout (progress messages go to stderr)
    click.echo(report)


if __name__ == "__main__":
    main()
