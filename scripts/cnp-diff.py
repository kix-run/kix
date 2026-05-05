#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "click"]
# ///
"""Compare CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy between
kix output and a cluster dump *semantically*, ignoring per-policy naming.

The main diff (compare-cluster-dump.py) is configured to suppress CNPs
because kix generates one policy per workload while the dump groups them
differently — names rarely line up. This tool answers the question that
suppression makes risky to leave unanswered: **does the union of allow
rules on each side actually grant the same network access?**

Strategy:

1. Load all CNP/CCNP from both sides (multi-doc safe).
2. For each policy, expand into individual *allow tuples*:
       (direction, target-namespace, target-selector, peer-spec)
   where ``peer-spec`` is the per-rule from/to clause + ports rendered
   into a stable canonical string.
3. Bucket by (target-namespace, target-selector) and compare the set of
   allow tuples per bucket.

Output (text) shows:
- A summary line: total allow tuples per side + per-direction match/diff
- Per-bucket mismatches: what kix allows that dump doesn't, and vice-versa.

For a CCNP, the target namespace is "_cluster".
"""

import json
import sys
from collections import defaultdict
from pathlib import Path

import click
import yaml

_YAMLLoader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)

_CNP_KINDS = {"CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"}


# ── ANSI helpers ──────────────────────────────────────────────────────

_BOLD = "\033[1m"
_DIM = "\033[2m"
_RED = "\033[31m"
_GREEN = "\033[32m"
_YELLOW = "\033[33m"
_CYAN = "\033[36m"
_RESET = "\033[0m"


def _c(code: str, text: str, color: bool) -> str:
    return f"{code}{text}{_RESET}" if color else text


# ── Loading ───────────────────────────────────────────────────────────


def _iter_yaml_docs(path: Path):
    """Yield every YAML doc under *path* (recursive)."""
    for f in sorted(path.rglob("*.yaml")):
        try:
            with open(f) as fh:
                for doc in yaml.load_all(fh, Loader=_YAMLLoader):
                    if isinstance(doc, dict):
                        yield doc
        except yaml.YAMLError:
            continue


def _canon(value) -> str:
    """Stable JSON for a Python value (sort keys, sort lists of dicts)."""
    return json.dumps(value, sort_keys=True, default=str)


def _extract_allows(doc: dict) -> list[tuple]:
    """Expand a CNP/CCNP into individual allow tuples.

    Each tuple has the shape:
        (target_ns, target_selector_canon, direction, peer_canon)

    `direction` is one of: "ingress", "egress", "ingressDeny", "egressDeny".
    `target_selector_canon` mixes endpointSelector / nodeSelector — whichever
    the policy uses — so two policies that target the same workload bucket
    together regardless of which selector they use.
    """
    kind = doc.get("kind")
    if kind not in _CNP_KINDS:
        return []
    meta = doc.get("metadata") or {}
    ns = meta.get("namespace") or "_cluster"

    spec = doc.get("spec") or {}
    specs = doc.get("specs") or [spec]  # CCNP can use either field

    allows = []
    for s in specs:
        if not isinstance(s, dict):
            continue
        sel = s.get("endpointSelector") or s.get("nodeSelector") or {}
        sel_canon = _canon(sel)
        for direction in ("ingress", "egress", "ingressDeny", "egressDeny"):
            for rule in s.get(direction, []) or []:
                allows.append((ns, sel_canon, direction, _canon(rule)))
    return allows


def load_allows(directories: list[Path]) -> list[tuple]:
    out: list[tuple] = []
    for d in directories:
        for doc in _iter_yaml_docs(d):
            out.extend(_extract_allows(doc))
    return out


# ── Diff ──────────────────────────────────────────────────────────────


def bucket(allows: list[tuple]) -> dict[tuple, set[tuple[str, str]]]:
    """Group allow tuples by (ns, target_selector).

    Value is a set of (direction, peer_canon) pairs — duplicates collapse,
    so two policies granting the same access count once.
    """
    out: dict[tuple, set[tuple[str, str]]] = defaultdict(set)
    for ns, sel, direction, peer in allows:
        out[(ns, sel)].add((direction, peer))
    return out


def _summary_counts(allows: list[tuple]) -> dict[str, int]:
    c = defaultdict(int)
    for _, _, direction, _ in allows:
        c[direction] += 1
    c["total"] = sum(c.values())
    return dict(c)


def _short_selector(sel_canon: str) -> str:
    """Compact one-line rendering of a selector for log output."""
    sel = json.loads(sel_canon)
    match = sel.get("matchLabels") or sel
    if not match:
        return "<all>"
    return ",".join(f"{k}={v}" for k, v in sorted(match.items()))


def _short_peer(direction: str, peer_canon: str) -> str:
    """Compact one-line rendering of an ingress/egress rule."""
    rule = json.loads(peer_canon)
    parts = []
    if direction.startswith("ingress"):
        for src in rule.get("fromEndpoints", []) or []:
            parts.append(f"from={_short_selector(_canon(src))}")
        for cidr in rule.get("fromCIDR", []) or []:
            parts.append(f"fromCIDR={cidr}")
        for cidr_set in rule.get("fromCIDRSet", []) or []:
            parts.append(f"fromCIDR={cidr_set.get('cidr', '?')}")
        for src in rule.get("fromEntities", []) or []:
            parts.append(f"fromEntity={src}")
    else:
        for dst in rule.get("toEndpoints", []) or []:
            parts.append(f"to={_short_selector(_canon(dst))}")
        for cidr in rule.get("toCIDR", []) or []:
            parts.append(f"toCIDR={cidr}")
        for cidr_set in rule.get("toCIDRSet", []) or []:
            parts.append(f"toCIDR={cidr_set.get('cidr', '?')}")
        for dst in rule.get("toEntities", []) or []:
            parts.append(f"toEntity={dst}")
        for fqdn in rule.get("toFQDNs", []) or []:
            parts.append(f"toFQDN={fqdn.get('matchName') or fqdn.get('matchPattern')}")
    ports = []
    for port_block in rule.get("toPorts", []) or rule.get("fromPorts", []) or []:
        for p in port_block.get("ports", []) or []:
            ports.append(f"{p.get('port', '?')}/{p.get('protocol', 'TCP')}")
    if ports:
        parts.append(f"ports={','.join(sorted(set(ports)))}")
    return "; ".join(parts) or "<empty>"


# ── CLI ───────────────────────────────────────────────────────────────


@click.command()
@click.argument("kix_dir", type=click.Path(exists=True, file_okay=False))
@click.argument(
    "cluster_dirs",
    nargs=-1,
    required=True,
    type=click.Path(exists=True, file_okay=False),
)
@click.option(
    "--color/--no-color",
    default=None,
    help="Colorize output (default: auto-detect TTY)",
)
@click.option(
    "--show-matched",
    is_flag=True,
    default=False,
    help="Also print buckets where both sides agree (otherwise hidden)",
)
def main(
    kix_dir: str,
    cluster_dirs: tuple[str, ...],
    color: bool | None,
    show_matched: bool,
):
    """Semantically compare CNPs between KIX_DIR and one or more CLUSTER_DIRS."""
    use_color = color if color is not None else sys.stdout.isatty()

    def C(code, text):
        return _c(code, text, use_color)

    kix_allows = load_allows([Path(kix_dir)])
    cluster_allows = load_allows([Path(d) for d in cluster_dirs])

    kix_counts = _summary_counts(kix_allows)
    cluster_counts = _summary_counts(cluster_allows)

    print(C(_BOLD, "CNP semantic diff"))
    print()
    print(f"  kix:     {kix_dir}")
    print(f"  cluster: {', '.join(cluster_dirs)}")
    print()

    # Top-level summary
    print(C(_BOLD, "Total allow rules per direction"))
    directions = ("ingress", "egress", "ingressDeny", "egressDeny")
    width = max(len(d) for d in directions) + 2
    print(f"  {'direction':<{width}}  {'kix':>6}  {'cluster':>8}  delta")
    for d in directions:
        k = kix_counts.get(d, 0)
        c = cluster_counts.get(d, 0)
        delta = k - c
        d_str = (
            C(_GREEN, f"+{delta}")
            if delta > 0
            else C(_RED, str(delta))
            if delta < 0
            else C(_DIM, "0")
        )
        print(f"  {d:<{width}}  {k:>6}  {c:>8}  {d_str}")
    print(
        f"  {'total':<{width}}  {kix_counts.get('total', 0):>6}  {cluster_counts.get('total', 0):>8}"
    )
    print()

    # Bucket-level diff
    kix_b = bucket(kix_allows)
    cluster_b = bucket(cluster_allows)
    all_keys = set(kix_b) | set(cluster_b)

    n_match = 0
    mismatch_buckets = []
    only_kix = []
    only_cluster = []

    for key in sorted(all_keys):
        k_set = kix_b.get(key, set())
        c_set = cluster_b.get(key, set())
        if k_set == c_set and k_set:
            n_match += 1
            continue
        if not c_set:
            only_kix.append((key, k_set))
        elif not k_set:
            only_cluster.append((key, c_set))
        else:
            mismatch_buckets.append((key, k_set, c_set))

    print(C(_BOLD, "Buckets (target namespace × selector)"))
    print(f"  matched:        {C(_DIM, str(n_match))}")
    print(f"  mismatched:     {C(_YELLOW, str(len(mismatch_buckets)))}")
    print(f"  only-in-kix:    {C(_GREEN, str(len(only_kix)))}")
    print(f"  only-in-cluster: {C(_RED, str(len(only_cluster)))}")
    print()

    # Detail: mismatched buckets — most actionable
    if mismatch_buckets:
        print(C(_BOLD, "Mismatched buckets"))
        print()
        for (ns, sel_canon), k_set, c_set in mismatch_buckets:
            extra_in_kix = k_set - c_set
            missing_in_kix = c_set - k_set
            print(
                f"  {C(_CYAN, ns + '/')}{C(_BOLD, _short_selector(sel_canon))}  "
                f"{C(_GREEN, '+' + str(len(extra_in_kix)))} "
                f"{C(_RED, '-' + str(len(missing_in_kix)))}"
            )
            for direction, peer in sorted(extra_in_kix):
                print(
                    f"    {C(_GREEN, '+')} {direction:<7} {_short_peer(direction, peer)}"
                )
            for direction, peer in sorted(missing_in_kix):
                print(
                    f"    {C(_RED, '-')} {direction:<7} {_short_peer(direction, peer)}"
                )
            print()

    if only_kix:
        print(C(_BOLD, "Only kix grants (no matching dump bucket)"))
        for (ns, sel_canon), allows in only_kix:
            print(
                f"  {C(_GREEN, '+')} {ns}/{_short_selector(sel_canon)}  ({len(allows)} rules)"
            )
        print()

    if only_cluster:
        print(C(_BOLD, "Only cluster grants (no matching kix bucket)"))
        for (ns, sel_canon), allows in only_cluster:
            print(
                f"  {C(_RED, '-')} {ns}/{_short_selector(sel_canon)}  ({len(allows)} rules)"
            )
        print()

    if show_matched and n_match:
        print(C(_BOLD, "Matched buckets"))
        for key in sorted(all_keys):
            if kix_b.get(key) == cluster_b.get(key) and kix_b.get(key):
                ns, sel_canon = key
                print(f"  {C(_DIM, ns + '/' + _short_selector(sel_canon))}")
        print()


if __name__ == "__main__":
    main()
