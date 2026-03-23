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
from parity.normalize import normalize_kix, normalize_cluster, resource_key, strip_port_names, normalize_dns_suffix
from parity.structural_diff import structural_diff, format_diffs, DiffKind

# Fields that Kubernetes auto-assigns at runtime — never present in kix output.
CLUSTER_DEFAULT_PATHS = {
    "$.spec.clusterIP",
    "$.spec.clusterIPs",
    "$.spec.internalTrafficPolicy",
    "$.spec.ipFamilies",
    "$.spec.ipFamilyPolicy",
    "$.spec.sessionAffinity",
    "*.configMap.defaultMode",
}

# ANSI helpers (duplicated here for section-level coloring)
_BOLD = "\033[1m"
_DIM = "\033[2m"
_RED = "\033[31m"
_GREEN = "\033[32m"
_YELLOW = "\033[33m"
_CYAN = "\033[36m"
_RESET = "\033[0m"


# --- Resource loading ---


def _is_controller_owned(doc: dict) -> bool:
    """Check if a resource is owned by a controller (auto-created, not user-deployed).

    Detects two patterns:
    - ownerReferences with controller=true (standard K8s ownership)
    - cert-manager.io annotations indicating controller management
    """
    metadata = doc.get("metadata", {})
    owner_refs = metadata.get("ownerReferences", [])
    if any(ref.get("controller") is True for ref in owner_refs if isinstance(ref, dict)):
        return True
    for field in ("annotations", "labels"):
        entries = metadata.get(field, {})
        if any(k.startswith("controller.") and v == "true" for k, v in entries.items()):
            return True
    return False


def load_resources(directory: Path, normalizer, service: str | None = None,
                   skip_controller_owned: bool = False) -> dict[str, dict]:
    """Load and normalize all YAML files from a directory.

    Supports both layouts:
    - Nested: {namespace}/{name}-{kind}.yaml  (dump output)
    - Flat:   {namespace}--{name}-{kind}.yaml  (kix nix build output)

    If *service* is given, only files whose stem starts with that name
    (before the first ``-``) are included.

    If *skip_controller_owned* is True, resources with ownerReferences
    where controller=true are excluded (they are managed by a controller,
    not deployed directly).

    Returns dict mapping "{namespace}/{name}-{kind}" -> normalized doc.
    """
    resources = {}

    def _matches_service(stem: str) -> bool:
        if service is None:
            return True
        # stem is e.g. "coredns-deployment"; extract the name part before the kind suffix
        name_part = stem.rsplit("-", 1)[0] if "-" in stem else stem
        return name_part == service or name_part.startswith(service + "-")

    def _load(f: Path, key: str):
        with open(f) as fh:
            doc = yaml.safe_load(fh)
        if doc is None:
            return
        if skip_controller_owned and _is_controller_owned(doc):
            return
        doc = normalizer(doc)
        resources[key] = doc

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
                if not _matches_service(f.stem):
                    continue
                _load(f, f"{ns}/{f.stem}")
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
            if not _matches_service(rest):
                continue
            _load(f, f"{ns}/{rest}")

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
    color: bool = False,
    full_diff: bool = False,
    files_only: bool = False,
    only_broken: bool = False,
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

    # Classify renames: those with only name/namespace diffs count as identical,
    # the rest count as modified
    _RENAME_ONLY_PATHS = {"$.metadata.name", "$.metadata.namespace"}
    for kix_key, cluster_key, ratio, diffs in rename_pairs:
        non_rename_diffs = [d for d in diffs if d.path not in _RENAME_ONLY_PATHS]
        if non_rename_diffs:
            modified.append((kix_key, non_rename_diffs))
        else:
            identical.append(kix_key)

    # Header
    if color:
        lines.append(f"{_BOLD}kix diff report{_RESET}")
        lines.append("")
        lines.append(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
        lines.append(f"kix:     {kix_dir} ({len(kix_resources)} resources)")
        lines.append(f"cluster: {cluster_dir} ({len(cluster_resources)} resources)")
    else:
        lines.append("# kix diff report")
        lines.append("")
        lines.append(f"**Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
        lines.append(f"**kix:** `{kix_dir}` ({len(kix_resources)} resources)")
        lines.append(f"**cluster:** `{cluster_dir}` ({len(cluster_resources)} resources)")
    lines.append("")

    # Summary (exclude renames from kix-only / cluster-only counts)
    n_kix_only = len(kix_only) - len(renamed_kix)
    n_cluster_only = len(cluster_only) - len(renamed_cluster)
    if color:
        lines.append(f"{_BOLD}Summary{_RESET}")
        lines.append(f"  Identical:    {_DIM}{len(identical)}{_RESET}")
        lines.append(f"  Modified:     {_YELLOW}{len(modified)}{_RESET}")
        lines.append(f"  kix-only:     {_RED}{n_kix_only}{_RESET}")
        lines.append(f"  Cluster-only: {_GREEN}{n_cluster_only}{_RESET}")
    else:
        lines.append("## Summary")
        lines.append("")
        lines.append("| Category | Count |")
        lines.append("|----------|-------|")
        lines.append(f"| Identical | {len(identical)} |")
        lines.append(f"| Modified | {len(modified)} |")
        lines.append(f"| kix-only | {n_kix_only} |")
        lines.append(f"| Cluster-only | {n_cluster_only} |")
    lines.append("")

    # Probable renames section (before kix-only/cluster-only so context is clear)
    if rename_pairs:
        lines.append(f"{_BOLD}Probable renames / moves{_RESET}" if color else "## Probable renames / moves")
        lines.append("")
        for kix_key, cluster_key, ratio, diffs in rename_pairs:
            non_rename_diffs = [d for d in diffs if d.path not in _RENAME_ONLY_PATHS]
            pct = int(ratio * 100)
            if color:
                lines.append(f"  {_CYAN}{_BOLD}{format_resource(kix_key)}{_RESET} <-> {_CYAN}{_BOLD}{format_resource(cluster_key)}{_RESET} {_DIM}({pct}% match){_RESET}")
            else:
                lines.append(f"### `{format_resource(kix_key)}` <-> `{format_resource(cluster_key)}` ({pct}% match)")
            lines.append("")
            if not files_only:
                if non_rename_diffs:
                    if not color:
                        lines.append("```")
                    lines.append(format_diffs(non_rename_diffs, color=color, full_diff=full_diff))
                    if not color:
                        lines.append("```")
                else:
                    if color:
                        lines.append(f"  {_DIM}(identical apart from name/namespace){_RESET}")
                    else:
                        lines.append("*Structurally identical (only name/namespace differs)*")
            lines.append("")

    # kix-only section (excluding resources that were matched as renames)
    unmatched_kix = [k for k in kix_only if k not in renamed_kix]
    if unmatched_kix:
        lines.append(f"{_BOLD}{_RED}kix-only (not in cluster){_RESET}" if color else "## kix-only (not in cluster)")
        lines.append("")
        for key in unmatched_kix:
            lines.append(f"  {_RED}- {format_resource(key)}{_RESET}" if color else f"- `{format_resource(key)}`")
        lines.append("")

    # Cluster-only section (excluding resources that were matched as renames)
    unmatched_cluster = [k for k in cluster_only if k not in renamed_cluster]
    if unmatched_cluster:
        lines.append(f"{_BOLD}{_GREEN}Cluster-only (not in kix){_RESET}" if color else "## Cluster-only (not in kix)")
        lines.append("")
        for key in unmatched_cluster:
            lines.append(f"  {_GREEN}+ {format_resource(key)}{_RESET}" if color else f"- `{format_resource(key)}`")
        lines.append("")

    # Modified section
    if modified:
        lines.append(f"{_BOLD}{_YELLOW}Modified{_RESET}" if color else "## Modified")
        lines.append("")
        for key, diffs in modified:
            kind, ns, name = parse_resource_id(key)
            if color:
                label = f"{name}" if ns == "_cluster" else f"{ns}/{name}"
                lines.append(f"  {_BOLD}{kind} {label}{_RESET}")
            else:
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
            if color:
                lines.append(f"  {_DIM}{', '.join(summary_parts)}{_RESET}")
            else:
                lines.append(f"_{', '.join(summary_parts)}_")
            lines.append("")

            if not files_only:
                if not color:
                    lines.append("```")
                lines.append(format_diffs(diffs, color=color, full_diff=full_diff))
                if not color:
                    lines.append("```")
                lines.append("")

    # Identical list (collapsed in markdown, dim in color mode)
    if identical and not only_broken:
        if color:
            lines.append(f"{_BOLD}Identical{_RESET} {_DIM}({len(identical)} resources match exactly){_RESET}")
            lines.append("")
            for key in identical:
                lines.append(f"  {_DIM}{format_resource(key)}{_RESET}")
        else:
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
@click.option("--service", default=None,
              help="Only compare resources whose name matches this service (e.g. 'coredns')")
@click.option("--color/--no-color", default=None,
              help="Colorize diff output (default: auto-detect TTY)")
@click.option("--ignore-cluster-defaults", is_flag=True, default=False,
              help="Ignore fields that K8s auto-assigns (clusterIP, ipFamilies, sessionAffinity, etc.)")
@click.option("--full-diff", is_flag=True, default=False,
              help="Show full unified diffs for multi-line string values (e.g. ConfigMaps)")
@click.option("--ignore-port-names", is_flag=True, default=False,
              help="Ignore port name differences in container ports")
@click.option("--ignore-dns-suffix", is_flag=True, default=False,
              help="Treat FQDN service DNS names (x.ns.svc.cluster.local) as equivalent to short names (x)")
@click.option("--skip-controller-owned", is_flag=True, default=False,
              help="Skip cluster resources with ownerReferences[controller=true] (auto-created by controllers)")
@click.option("--skip-all", is_flag=True, default=False,
              help="Enable all skip/ignore flags (cluster-defaults, port-names, dns-suffix, controller-owned)")
@click.option("--files-only", is_flag=True, default=False,
              help="Only show file-level info, skip detailed line-by-line diffs")
@click.option("--only-broken", is_flag=True, default=False,
              help="Hide identical resources from the output")
def main(kix_dir: str, cluster_dir: str, ignore_path: tuple[str, ...], service: str | None,
         color: bool | None, ignore_cluster_defaults: bool, full_diff: bool,
         ignore_port_names: bool, ignore_dns_suffix: bool, skip_controller_owned: bool,
         skip_all: bool, files_only: bool, only_broken: bool):
    """Compare kix manifests against a cluster dump.

    KIX_DIR is the kix output directory (e.g. ./result from nix build).
    CLUSTER_DIR is the dump directory (from kix-dump.py).

    Output is a structured markdown report written to stdout.
    """
    kix_path = Path(kix_dir)
    cluster_path = Path(cluster_dir)

    # --skip-all expands to all skip/ignore flags
    if skip_all:
        ignore_cluster_defaults = True
        ignore_port_names = True
        ignore_dns_suffix = True
        skip_controller_owned = True

    ignore_paths = set(ignore_path) if ignore_path else set()
    if ignore_cluster_defaults:
        ignore_paths |= CLUSTER_DEFAULT_PATHS
    ignore_paths = ignore_paths or None

    # Build post-normalization pipeline from flags
    post_steps = []
    if ignore_port_names:
        post_steps.append(strip_port_names)
    if ignore_dns_suffix:
        post_steps.append(normalize_dns_suffix)

    def _with_post(base_normalizer):
        def wrapped(doc):
            doc = base_normalizer(doc)
            for step in post_steps:
                doc = step(doc)
            return doc
        return wrapped

    if service:
        click.echo(f"Filtering for service: {service}", err=True)

    click.echo("Loading kix manifests...", err=True)
    kix_resources = load_resources(kix_path, _with_post(normalize_kix), service)
    click.echo(f"  {len(kix_resources)} resources", err=True)

    click.echo("Loading cluster dump...", err=True)
    cluster_resources = load_resources(cluster_path, _with_post(normalize_cluster), service,
                                       skip_controller_owned=skip_controller_owned)
    click.echo(f"  {len(cluster_resources)} resources", err=True)

    # Resolve color: explicit flag wins, otherwise auto-detect TTY on stdout
    use_color = color if color is not None else sys.stdout.isatty()

    report = generate_report(
        kix_path, cluster_path,
        kix_resources, cluster_resources,
        ignore_paths,
        color=use_color,
        full_diff=full_diff,
        files_only=files_only,
        only_broken=only_broken,
    )

    # Write report to stdout (progress messages go to stderr)
    click.echo(report)


if __name__ == "__main__":
    main()
