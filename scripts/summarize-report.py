#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["click"]
# ///
"""Summarize a JSON report from compare-cluster-dump.py.

Usage:
    ./scripts/summarize-report.py report.json
    ./scripts/summarize-report.py report.json --diffs           # show per-resource diffs
    ./scripts/summarize-report.py report.json --diffs --filter valkey  # filter by keyword
"""

import json
from collections import Counter

import click


def _format_counts(counts: dict) -> str:
    return f"(+{counts['extra']} -{counts['missing']} ~{counts['changed']})"


def _classify(key: str) -> str:
    """Classify a resource key into a pattern group."""
    if "sgcluster" in key and "sgpostgresconfig" not in key:
        return "sgcluster"
    if "sgpostgresconfig" in key:
        return "sgpostgresconfig"
    if "sginstanceprofile" in key:
        return "sginstanceprofile"
    if "valkey" in key and "health" in key:
        return "valkey-health"
    if "valkey" in key and "service" in key:
        return "valkey-service"
    if "valkey" in key:
        return "valkey-other"
    if "clusterrole" in key:
        return "clusterrole"
    if "customresourcedefinition" in key:
        return "crd"
    if "ciliumclusterwide" in key:
        return "cilium-policy"
    if "prometheusrule" in key:
        return "prometheusrule"
    if "deployment" in key:
        return "deployment"
    if "daemonset" in key:
        return "daemonset"
    if "statefulset" in key:
        return "statefulset"
    if "nginx" in key:
        return "nginx"
    if "configmap" in key:
        return "configmap"
    if "ingress" in key and "class" not in key:
        return "ingress"
    return "other"


@click.command()
@click.argument("report_file", type=click.Path(exists=True))
@click.option("--diffs", is_flag=True, default=False, help="Show per-resource diffs")
@click.option(
    "--filter", "filter_keyword", default=None, help="Filter resources by keyword"
)
@click.option(
    "--group", is_flag=True, default=False, help="Group modified resources by type"
)
def main(report_file: str, diffs: bool, filter_keyword: str | None, group: bool):
    """Summarize a JSON report from compare-cluster-dump.py."""
    with open(report_file) as f:
        r = json.load(f)

    s = r["summary"]

    # --- Summary ---
    click.echo("# Summary\n")
    click.echo(f"  Identical:    {s['identical']}")
    click.echo(
        f"  Modified:     {s['modified']}  (+{s['diff_totals']['extra']} -{s['diff_totals']['missing']} ~{s['diff_totals']['changed']})"
    )
    click.echo(f"  kix-only:     {s['kix_only']}")
    click.echo(f"  Cluster-only: {s['cluster_only']}")
    click.echo(f"  Total:        {s['total']}")
    click.echo()

    # --- Renames ---
    renames = r.get("renames", [])
    if renames:
        click.echo(f"# Probable renames ({len(renames)})\n")
        for rn in renames:
            kix_key = rn["kix"]["key"]
            cluster_key = rn["cluster"]["key"]
            ratio = rn["match_ratio"]
            n_diffs = len(rn.get("diffs", []))
            suffix = f"  ({n_diffs} diffs)" if n_diffs else "  (identical)"
            click.echo(f"  {kix_key}")
            click.echo(f"    <-> {cluster_key}  ({ratio:.0%} match){suffix}")
        click.echo()

    # --- Modified ---
    modified = r.get("modified", [])
    if filter_keyword:
        modified = [m for m in modified if filter_keyword.lower() in m["key"].lower()]

    if group:
        click.echo(f"# Modified by type ({len(modified)} resources)\n")
        patterns = Counter()
        for m in modified:
            patterns[_classify(m["key"])] += 1
        for pattern, count in sorted(patterns.items(), key=lambda x: -x[1]):
            click.echo(f"  {count:3d}  {pattern}")
        click.echo()

    click.echo(f"# Modified resources ({len(modified)})\n")
    for m in modified:
        counts = m["counts"]
        click.echo(f"  {m['key']}  {_format_counts(counts)}")
        if diffs:
            for d in m["diffs"]:
                kind = d["kind"]
                path = d["path"]
                if kind == "value_mismatch" or kind == "type_mismatch":
                    kix_val = str(d.get("kix", ""))[:100]
                    cluster_val = str(d.get("cluster", ""))[:100]
                    click.echo(f"    ~ {path}")
                    click.echo(f"      kix:     {kix_val}")
                    click.echo(f"      cluster: {cluster_val}")
                elif kind == "missing_in_b":
                    kix_val = str(d.get("kix", ""))[:120]
                    click.echo(f"    - {path}")
                    click.echo(f"      kix: {kix_val}")
                elif kind == "extra_in_b":
                    cluster_val = str(d.get("cluster", ""))[:120]
                    click.echo(f"    + {path}")
                    click.echo(f"      cluster: {cluster_val}")
            click.echo()


if __name__ == "__main__":
    main()
