#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "click"]
# ///
"""
Verify behavioral parity between Helm chart output and kix module output.

Compares rendered Helm templates against built kix manifests, normalizing
cosmetic differences (labels, annotations, naming) to focus on behavioral
equivalence.
"""

import difflib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import click
import yaml

# Add scripts/ to path so we can import the parity package
sys.path.insert(0, str(Path(__file__).resolve().parent))
from parity.normalize import normalize_helm, normalize_kix, resource_key

REPO_ROOT = Path(__file__).resolve().parent.parent
CHART_CACHE = REPO_ROOT / ".cache" / "charts"


def ensure_chart(chart_ref: str, chart_name: str, chart_version: str | None = None) -> str:
    """Pull a Helm chart and cache it locally. Returns the path to the chart directory.

    chart_ref is any helm-compatible identifier: OCI ref, repo/chart, URL, local path.
    If chart_ref is already a local directory, it's used directly (no pull).
    """
    # Local directory — use as-is
    ref_path = Path(chart_ref)
    if ref_path.is_dir():
        return str(ref_path)

    # Build a cache key from the ref (and version if specified)
    # Strip protocol prefixes and slashes to make a filesystem-safe name
    cache_key = chart_ref.replace("://", "_").replace("/", "_").replace(":", "_")
    if chart_version:
        cache_key += f"__{chart_version}"
    cache_dir = CHART_CACHE / cache_key

    # Reuse cached chart if available
    if cache_dir.is_dir():
        # The chart is inside a subdirectory named after the chart
        subdirs = [d for d in cache_dir.iterdir() if d.is_dir()]
        if subdirs:
            return str(subdirs[0])

    cache_dir.mkdir(parents=True, exist_ok=True)

    cmd = ["helm", "pull", chart_ref, "--untar", "--destination", str(cache_dir)]
    if chart_version:
        cmd += ["--version", chart_version]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        # Clean up empty cache dir on failure
        cache_dir.rmdir()
        raise click.ClickException(f"helm pull failed for '{chart_ref}':\n{result.stderr}")

    subdirs = [d for d in cache_dir.iterdir() if d.is_dir()]
    if not subdirs:
        raise click.ClickException(f"helm pull produced no chart directory in {cache_dir}")

    return str(subdirs[0])


def helm_template(chart_path: str, values_file: str | None = None) -> dict[str, dict]:
    with tempfile.TemporaryDirectory() as tmpdir:
        cmd = ["helm", "template", "release-name", chart_path,
               "--output-dir", tmpdir]
        if values_file:
            cmd += ["-f", values_file]

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise click.ClickException(f"helm template failed:\n{result.stderr}")

        resources = {}
        for yaml_file in Path(tmpdir).rglob("*.yaml"):
            with open(yaml_file) as f:
                for doc in yaml.safe_load_all(f):
                    if doc is None:
                        continue
                    doc = normalize_helm(doc)
                    key = resource_key(doc)
                    if key in resources:
                        key += f"-{len(resources)}"
                    resources[key] = doc
        return resources


def nix_build(flake_pkg: str) -> dict[str, dict]:
    cmd = [
        "nix", "build", f"{REPO_ROOT}#{flake_pkg}",
        "--extra-experimental-features", "pipe-operators",
        "--no-link", "--print-out-paths",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise click.ClickException(f"nix build failed for '{flake_pkg}':\n{result.stderr}")

    out_path = Path(result.stdout.strip())
    resources = {}
    for json_file in out_path.glob("*.json"):
        with open(json_file) as f:
            doc = json.load(f)
        doc = normalize_kix(doc)
        key = resource_key(doc)
        resources[key] = doc
    return resources


def compare_resources(helm: dict[str, dict], kix: dict[str, dict],
                      diff_lines: int = 80, ignore_missing: set[str] | None = None) -> bool:
    """Compare Helm and kix resources. Returns True if parity achieved."""

    def by_kind(resources):
        index = {}
        for key, doc in resources.items():
            kind = doc.get("kind", "Unknown")
            index.setdefault(kind, {})[key] = doc
        return index

    helm_by_kind = by_kind(helm)
    kix_by_kind = by_kind(kix)
    all_kinds = sorted(set(helm_by_kind) | set(kix_by_kind))

    click.echo(f"  Helm resources: {click.style(str(len(helm)), bold=True)}")
    click.echo(f"  Kix resources:  {click.style(str(len(kix)), bold=True)}")
    click.echo()

    has_diff = False
    matched_kix_keys = set()

    for kind in all_kinds:
        helm_resources = helm_by_kind.get(kind, {})
        kix_resources = kix_by_kind.get(kind, {})

        for helm_key, helm_doc in helm_resources.items():
            if helm_key in kix_resources and helm_key not in matched_kix_keys:
                kix_key = helm_key
            else:
                kix_key = next(
                    (k for k in kix_resources if k not in matched_kix_keys), None
                )

            if kix_key is None:
                if ignore_missing and helm_key in ignore_missing:
                    click.echo(f"  {click.style('SKIPPED', fg='blue', dim=True)}  {helm_key}")
                else:
                    click.echo(f"  {click.style('MISSING', fg='red')}  {helm_key}")
                    has_diff = True
                continue

            matched_kix_keys.add(kix_key)
            kix_doc = kix_resources[kix_key]

            helm_json = json.dumps(helm_doc, sort_keys=True, indent=2)
            kix_json = json.dumps(kix_doc, sort_keys=True, indent=2)

            if helm_json == kix_json:
                click.echo(f"  {click.style('MATCH  ', fg='green')}  {helm_key}")
            else:
                label = helm_key if helm_key == kix_key else f"{helm_key} <-> {kix_key}"
                click.echo(f"  {click.style('DIFFERS', fg='yellow')}  {label}")
                diff = list(difflib.unified_diff(
                    helm_json.splitlines(),
                    kix_json.splitlines(),
                    fromfile=f"helm:{helm_key}",
                    tofile=f"kix:{kix_key}",
                    lineterm="",
                ))
                for line in diff[:diff_lines]:
                    if line.startswith("+") and not line.startswith("+++"):
                        click.echo(f"    {click.style(line, fg='green')}")
                    elif line.startswith("-") and not line.startswith("---"):
                        click.echo(f"    {click.style(line, fg='red')}")
                    elif line.startswith("@@"):
                        click.echo(f"    {click.style(line, fg='cyan')}")
                    else:
                        click.echo(f"    {line}")
                if len(diff) > diff_lines:
                    click.echo(click.style(f"    ... ({len(diff) - diff_lines} more lines)", dim=True))
                click.echo()
                has_diff = True

    for kind in all_kinds:
        for kix_key in kix_by_kind.get(kind, {}):
            if kix_key not in matched_kix_keys:
                click.echo(f"  {click.style('EXTRA  ', fg='cyan')}  {kix_key}")
                has_diff = True

    return not has_diff


def run_one(chart_path: str, flake_pkg: str, values_file: str | None,
            diff_lines: int, ignore_missing: set[str] | None = None) -> bool:
    click.echo()
    click.secho(f"  {flake_pkg}", bold=True)
    click.echo()

    helm_resources = helm_template(chart_path, values_file)
    kix_resources = nix_build(flake_pkg)
    passed = compare_resources(helm_resources, kix_resources, diff_lines, ignore_missing)

    click.echo()
    if passed:
        click.secho("  ✓ Parity achieved", fg="green", bold=True)
    else:
        click.secho("  ✗ Differences found", fg="red", bold=True)
    click.echo()
    return passed


@click.group(invoke_without_command=True)
@click.pass_context
def cli(ctx):
    """Verify behavioral parity between Helm charts and kix modules."""
    if ctx.invoked_subcommand is None:
        click.echo(ctx.get_help())


@cli.command()
@click.argument("chart_name")
@click.option("--chart", "chart_ref", required=True,
              help="Helm chart reference (OCI ref, repo/chart, URL, or local path)")
@click.option("--chart-version", default=None, help="Chart version to pull")
@click.option("-f", "--values", type=click.Path(exists=True), help="Helm values file")
@click.option("--diff-lines", default=80, show_default=True, help="Max diff lines per resource")
@click.option("--ignore-missing", multiple=True,
              help="Kind/name keys to ignore if missing from kix (e.g. Secret/valkey)")
def check(chart_name: str, chart_ref: str, chart_version: str | None,
          values: str | None, diff_lines: int, ignore_missing: tuple[str, ...]):
    """Run a single parity test with default or custom values."""
    chart_path = ensure_chart(chart_ref, chart_name, chart_version)
    ok = run_one(chart_path, chart_name, values, diff_lines, set(ignore_missing) or None)
    sys.exit(0 if ok else 1)


@cli.command("all")
@click.argument("chart_name")
@click.option("--chart", "chart_ref", default=None,
              help="Helm chart reference (overrides cases.yaml)")
@click.option("--chart-version", default=None, help="Chart version (overrides cases.yaml)")
@click.option("--diff-lines", default=80, show_default=True, help="Max diff lines per resource")
@click.option("--ignore-missing", multiple=True,
              help="Additional Kind/name keys to ignore (adds to cases.yaml)")
def check_all(chart_name: str, chart_ref: str | None, chart_version: str | None,
              diff_lines: int, ignore_missing: tuple[str, ...]):
    """Run all test cases from tests/<chart>/cases.yaml."""
    cases_file = REPO_ROOT / "tests" / chart_name / "cases.yaml"
    if not cases_file.exists():
        raise click.ClickException(f"No test cases at {cases_file}")

    with open(cases_file) as f:
        config = yaml.safe_load(f)

    # Resolve chart: CLI flags override cases.yaml
    effective_ref = chart_ref or config.get("chart")
    if not effective_ref:
        raise click.ClickException(
            "No --chart flag and no 'chart' key in cases.yaml")
    effective_version = chart_version or config.get("chart-version")

    chart_path = ensure_chart(effective_ref, chart_name, effective_version)

    # Merge ignore-missing from cases.yaml and CLI
    ignore_set = set(ignore_missing) | set(config.get("ignore-missing", []))
    ignore_set = ignore_set or None

    tests_dir = cases_file.parent
    raw_cases = config.get("cases", {})
    if not raw_cases:
        raise click.ClickException(f"No cases defined in {cases_file}")

    cases: list[tuple[str, str | None]] = []
    for pkg, opts in raw_cases.items():
        opts = opts or {}
        values = opts.get("values")
        values_path = str(tests_dir / values) if values else None
        cases.append((pkg, values_path))

    results = []
    for pkg, values_path in cases:
        click.echo("╔══════════════════════════════════════════════════════════════╗")
        click.echo(f"║ {click.style(pkg, bold=True)}")
        click.echo("╚══════════════════════════════════════════════════════════════╝")
        passed = run_one(chart_path, pkg, values_path, diff_lines, ignore_set)
        results.append((pkg, passed))

    click.echo("═══════════════════════════════════════════════════════════════")
    total = len(results)
    passed_count = sum(1 for _, p in results if p)
    failed = [name for name, p in results if not p]

    if failed:
        click.secho(f"  {passed_count}/{total} passed, {len(failed)} failed", fg="red", bold=True)
        click.echo(f"  Failed: {', '.join(failed)}")
    else:
        click.secho(f"  {passed_count}/{total} passed", fg="green", bold=True)
    click.echo("═══════════════════════════════════════════════════════════════")
    sys.exit(0 if not failed else 1)


if __name__ == "__main__":
    cli()
