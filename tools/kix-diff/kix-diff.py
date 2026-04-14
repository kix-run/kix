#!/usr/bin/env python3
"""Compare two kix activations and show what changed.

Sections:
  1. Package changes (nom-style) — added, removed, version changes
  2. Edge changes — dependency graph diff (new/removed/moved edges)
  3. Manifest diffs grouped by package

Usage: kix-diff.py <old-result> <new-result>
"""

import argparse
import os
import sys

# Allow imports from tools/lib/ and scripts/parity/
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))

from lib.kix_model import KixModel, read_store_json  # noqa: E402
from parity.structural_diff import structural_diff, format_diffs  # noqa: E402


# ── ANSI helpers ──────────────────────────────────────────────────────

_COLOR = sys.stdout.isatty()


def _c(code, text):
    return f"\033[{code}m{text}\033[0m" if _COLOR else text


def _bold(t):
    return _c("1", t)


def _dim(t):
    return _c("2", t)


def _green(t):
    return _c("32", t)


def _red(t):
    return _c("31", t)


def _yellow(t):
    return _c("33", t)


def _cyan(t):
    return _c("36", t)


def _magenta(t):
    return _c("35", t)


# ── Package diff ──────────────────────────────────────────────────────


def diff_packages(old_model, new_model):
    """Compare package sets. Returns (added, removed, changed, unchanged) lists.

    Each entry is a dict with keys: key, name, ns, old_version, new_version,
    old_hash, new_hash, resource_count_delta.
    """
    old_pkgs = old_model.packages_by_key()
    new_pkgs = new_model.packages_by_key()
    old_keys = set(old_pkgs)
    new_keys = set(new_pkgs)

    added = []
    for k in sorted(new_keys - old_keys):
        p = new_model.packages[new_pkgs[k]]
        added.append(
            {
                "key": k,
                "name": p["name"],
                "ns": p["ns"],
                "new_version": new_model.package_version(new_pkgs[k]),
                "resource_count": len(p["resources"]),
            }
        )

    removed = []
    for k in sorted(old_keys - new_keys):
        p = old_model.packages[old_pkgs[k]]
        removed.append(
            {
                "key": k,
                "name": p["name"],
                "ns": p["ns"],
                "old_version": old_model.package_version(old_pkgs[k]),
            }
        )

    changed = []
    unchanged = []
    for k in sorted(old_keys & new_keys):
        old_pi = old_pkgs[k]
        new_pi = new_pkgs[k]
        old_hash = old_model.package_content_hash(old_pi)
        new_hash = new_model.package_content_hash(new_pi)
        if old_hash == new_hash:
            unchanged.append({"key": k})
            continue
        old_v = old_model.package_version(old_pi)
        new_v = new_model.package_version(new_pi)
        old_res = len(old_model.packages[old_pi]["resources"])
        new_res = len(new_model.packages[new_pi]["resources"])
        changed.append(
            {
                "key": k,
                "name": old_model.packages[old_pi]["name"],
                "ns": old_model.packages[old_pi]["ns"],
                "old_version": old_v,
                "new_version": new_v,
                "resource_delta": new_res - old_res,
            }
        )

    return added, removed, changed, unchanged


def print_package_summary(added, removed, changed, unchanged):
    """Print nom-style package change summary."""
    print(_bold("Package changes"))
    print()

    if not added and not removed and not changed:
        print(_dim("  (no package changes)"))
        print()
        return

    # Compute column width for alignment
    all_names = (
        [e["name"] for e in added]
        + [e["name"] for e in removed]
        + [e["name"] for e in changed]
    )
    name_w = max((len(n) for n in all_names), default=10) + 2

    for e in added:
        v = e.get("new_version") or "?"
        res = f"({e['resource_count']} resources)" if e.get("resource_count") else ""
        print(f"  {_green('+')} {e['name']:<{name_w}} {_green(v)}  {_dim(res)}")

    for e in removed:
        v = e.get("old_version") or "?"
        print(f"  {_red('-')} {e['name']:<{name_w}} {_red(v)}")

    for e in changed:
        old_v = e.get("old_version") or "?"
        new_v = e.get("new_version") or "?"
        if old_v != new_v:
            version_str = f"{old_v} {_yellow('→')} {new_v}"
        else:
            version_str = _dim(f"{old_v} (content changed)")
        delta = e.get("resource_delta", 0)
        delta_str = ""
        if delta > 0:
            delta_str = _dim(f"(+{delta} resources)")
        elif delta < 0:
            delta_str = _dim(f"({delta} resources)")
        print(f"  {_yellow('~')} {e['name']:<{name_w}} {version_str}  {delta_str}")

    if unchanged:
        print(_dim(f"\n  {len(unchanged)} packages unchanged"))
    print()


# ── Edge diff ─────────────────────────────────────────────────────────


def _edge_set(model):
    """Build a set of (source_pkg_key, target_pkg_key) edges."""
    edges = set()
    for pi_path, deps in model.cross_deps.items():
        if pi_path not in model.packages:
            continue
        src = model.package_key(pi_path)
        for dep in deps:
            tgt_pi = dep["target_pi"]
            if tgt_pi in model.packages:
                edges.add((src, model.package_key(tgt_pi)))
    return edges


def _edge_detail(model):
    """Build edge → [resource-level detail] mapping."""
    detail = {}
    for pi_path, deps in model.cross_deps.items():
        if pi_path not in model.packages:
            continue
        src = model.package_key(pi_path)
        for dep in deps:
            tgt_pi = dep["target_pi"]
            if tgt_pi not in model.packages:
                continue
            tgt = model.package_key(tgt_pi)
            edge_key = (src, tgt)
            detail.setdefault(edge_key, []).append(f"{dep['from']} → {dep['to']}")
    return detail


def diff_edges(old_model, new_model):
    """Compare dependency edges between two models.

    Returns (new_edges, removed_edges, moved_edges) where moved_edges
    are packages whose edge set changed but the package content-hash
    didn't (i.e. same content, different position in graph).
    """
    old_edges = _edge_set(old_model)
    new_edges = _edge_set(new_model)
    _old_detail = _edge_detail(old_model)
    new_detail = _edge_detail(new_model)

    added = sorted(new_edges - old_edges)
    removed = sorted(old_edges - new_edges)

    # Detect "moved" patterns: same package exists in both, but its
    # edges changed. This happens when e.g. a dependency moves namespace
    # or a consumer switches to a different provider.
    old_by_key = old_model.packages_by_key()
    new_by_key = new_model.packages_by_key()
    common_keys = set(old_by_key) & set(new_by_key)

    # Find packages where content hash is the same but edges differ
    moved = []
    for key in sorted(common_keys):
        old_pi = old_by_key[key]
        new_pi = new_by_key[key]
        old_hash = old_model.package_content_hash(old_pi)
        new_hash = new_model.package_content_hash(new_pi)
        if old_hash != new_hash:
            continue  # content changed, not a "move"

        old_pkg_edges = {e for e in old_edges if e[0] == key or e[1] == key}
        new_pkg_edges = {e for e in new_edges if e[0] == key or e[1] == key}
        if old_pkg_edges != new_pkg_edges:
            moved.append(
                {
                    "key": key,
                    "lost": sorted(old_pkg_edges - new_pkg_edges),
                    "gained": sorted(new_pkg_edges - old_pkg_edges),
                }
            )

    return added, removed, moved, new_detail


def print_edge_changes(added, removed, moved, new_detail):
    """Print dependency edge changes."""
    print(_bold("Edge changes"))
    print()

    if not added and not removed and not moved:
        print(_dim("  (no edge changes)"))
        print()
        return

    for src, tgt in added:
        details = new_detail.get((src, tgt), [])
        via = _dim(f"  via {details[0]}") if details else ""
        print(f"  {_green('+')} {src} → {tgt}{via}")

    for src, tgt in removed:
        print(f"  {_red('-')} {src} → {tgt}")

    for m in moved:
        print(f"  {_magenta('↔')} {m['key']} {_dim('(same content, edges changed)')}")
        for src, tgt in m["lost"]:
            print(f"      {_red('-')} {src} → {tgt}")
        for src, tgt in m["gained"]:
            print(f"      {_green('+')} {src} → {tgt}")

    print()


# ── Manifest diffs grouped by package ─────────────────────────────────


def _resource_key(res):
    """Stable key for a resource: Kind/name."""
    return f"{res.get('kind', '?')}/{res.get('metadata', {}).get('name', '?')}"


def _load_resource_map(model):
    """Build pkg_key → {resource_key → manifest} for all packages."""
    pkg_resources = {}
    for pi_path, pkg in model.packages.items():
        key = model.package_key(pi_path)
        resources = {}
        for res_path in pkg["resources"]:
            manifest = read_store_json(res_path)
            if manifest:
                rk = _resource_key(manifest)
                resources[rk] = manifest
        pkg_resources[key] = resources
    return pkg_resources


def diff_manifests(old_model, new_model, changed_keys):
    """Produce per-package manifest diffs for changed packages.

    Returns dict of pkg_key → {added: [...], removed: [...], modified: [...]}.
    """
    old_res = _load_resource_map(old_model)
    new_res = _load_resource_map(new_model)

    result = {}
    for pkg_key in changed_keys:
        old_manifests = old_res.get(pkg_key, {})
        new_manifests = new_res.get(pkg_key, {})
        old_rks = set(old_manifests)
        new_rks = set(new_manifests)

        added = sorted(new_rks - old_rks)
        removed = sorted(old_rks - new_rks)

        modified = []
        for rk in sorted(old_rks & new_rks):
            diffs = structural_diff(
                old_manifests[rk], new_manifests[rk], a_label="old", b_label="new"
            )
            if diffs:
                modified.append({"key": rk, "diffs": diffs})

        if added or removed or modified:
            result[pkg_key] = {
                "added": added,
                "removed": removed,
                "modified": modified,
            }

    return result


def print_manifest_diffs(manifest_diffs, full_diff=False):
    """Print manifest diffs grouped by package."""
    print(_bold("Manifest changes"))
    print()

    if not manifest_diffs:
        print(_dim("  (no manifest changes)"))
        print()
        return

    for pkg_key in sorted(manifest_diffs):
        d = manifest_diffs[pkg_key]
        print(
            f"  {_cyan('──')} {_bold(pkg_key)} {_cyan('─' * max(1, 60 - len(pkg_key)))}"
        )

        for rk in d["added"]:
            print(f"    {_green('+ ' + rk)}")

        for rk in d["removed"]:
            print(f"    {_red('- ' + rk)}")

        for m in d["modified"]:
            diff_text = format_diffs(m["diffs"], color=_COLOR, full_diff=full_diff)
            # Count changes
            n = len(m["diffs"])
            print(f"    {_yellow('~ ' + m['key'])} {_dim(f'({n} changes)')}")
            # Indent diff output
            for line in diff_text.strip().split("\n"):
                print(f"      {line}")

        print()


# ── Stateful resource warnings ────────────────────────────────────────


def warn_stateful_changes(_old_model, new_model, changed_keys):
    """Warn about changes to stateful packages (PVCs, databases, etc.)."""
    warnings = []
    for key in changed_keys:
        new_by_key = new_model.packages_by_key()
        pi = new_by_key.get(key)
        if not pi:
            continue
        meta = new_model.packages[pi]["metadata"]
        # Check for lifecycle=stateful in annotations or labels
        _annotations = meta.get("metadata", {}).get("annotations", {})
        # Also check PI spec for well-known kinds
        name = meta.get("spec", {}).get("instanceName", "")
        # PVCs and databases are typically stateful
        is_pvc = "persistent-volume" in name.lower() or "pvc" in name.lower()
        is_db = any(x in name.lower() for x in ["postgres", "mysql", "mongo", "etcd"])
        if is_pvc or is_db:
            warnings.append(key)

    if warnings:
        print(_bold(_yellow("Stateful resource warnings")))
        print()
        for w in warnings:
            print(f"  {_yellow('⚠')} {w} — stateful resource changed, review carefully")
        print()


# ── Main ──────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Compare two kix activations and show what changed.",
    )
    parser.add_argument("old", help="Path to old result (symlink or store path)")
    parser.add_argument("new", help="Path to new result (symlink or store path)")
    parser.add_argument(
        "--full-diff", action="store_true", help="Show full multi-line string diffs"
    )
    parser.add_argument(
        "--no-manifests", action="store_true", help="Skip manifest-level diffs (faster)"
    )
    parser.add_argument("--no-color", action="store_true", help="Disable color output")
    args = parser.parse_args()

    global _COLOR
    if args.no_color:
        _COLOR = False

    old_path = os.path.realpath(args.old)
    new_path = os.path.realpath(args.new)

    if old_path == new_path:
        print("Both paths resolve to the same store path — nothing to diff.")
        sys.exit(0)

    def _status(label):
        def fn(msg):
            print(f"\r{_dim(f'[{label}] {msg}')}", end="", flush=True)

        return fn

    old_model = KixModel(old_path, status_fn=_status("old"))
    print()  # clear status line
    new_model = KixModel(new_path, status_fn=_status("new"))
    print()  # clear status line
    print()

    # Header
    print(_bold(f"kix diff: {old_model.cluster_name}"))
    print(_dim(f"  old: {args.old} → {os.path.basename(old_path)}"))
    print(_dim(f"  new: {args.new} → {os.path.basename(new_path)}"))
    print()

    # Section 1: Package changes
    added, removed, changed, unchanged = diff_packages(old_model, new_model)
    print_package_summary(added, removed, changed, unchanged)

    # Section 2: Edge changes
    edge_added, edge_removed, edge_moved, edge_detail = diff_edges(old_model, new_model)
    print_edge_changes(edge_added, edge_removed, edge_moved, edge_detail)

    # Section 3: Stateful warnings
    changed_keys = [e["key"] for e in changed]
    warn_stateful_changes(old_model, new_model, changed_keys)

    # Section 4: Manifest diffs
    if not args.no_manifests and changed_keys:
        manifest_diffs = diff_manifests(old_model, new_model, changed_keys)
        print_manifest_diffs(manifest_diffs, full_diff=args.full_diff)
    elif args.no_manifests and changed_keys:
        print(_dim(f"  (manifest diffs skipped, {len(changed_keys)} packages changed)"))

    # Summary line
    total = len(added) + len(removed) + len(changed) + len(unchanged)
    print(
        _dim(
            f"Total: {total} packages — "
            f"{_green(str(len(added)))} added, "
            f"{_red(str(len(removed)))} removed, "
            f"{_yellow(str(len(changed)))} changed, "
            f"{len(unchanged)} unchanged"
        )
    )


if __name__ == "__main__":
    main()
