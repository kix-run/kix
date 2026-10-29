#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml", "click"]
# ///
"""
Dump live Kubernetes cluster resources into a normalized YAML directory.

Output uses the same file naming convention as Kix ({namespace}--{name}-{kind}.yaml)
so it can be directly compared with `kix-diff.py` or even plain `diff -r`.

Secret resources are included, but their data/stringData fields are stripped
during normalization: only metadata and type are preserved for comparison.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import click
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parity.normalize import normalize_cluster


# Resource types to always skip: these are ephemeral, derived, or runtime-only
# and not useful for comparing declared vs actual state.
SKIP_RESOURCES = {
    # Ephemeral / runtime state
    "events",
    "events.events.k8s.io",
    "pods",
    "jobs.batch",
    "replicasets.apps",
    "controllerrevisions.apps",
    "endpointslices.discovery.k8s.io",
    "endpoints",
    "leases.coordination.k8s.io",
    "componentstatuses",
    # Node / cluster inventory (not declarative)
    "nodes",
    "nodes.metrics.k8s.io",
    "pods.metrics.k8s.io",
    "csinodes.storage.k8s.io",
    "csidrivers.storage.k8s.io",
    "csistoragecapacities.storage.k8s.io",
    "volumeattachments.storage.k8s.io",
    "runtimeclasses.node.k8s.io",
    # API machinery
    "apiservices.apiregistration.k8s.io",
    "flowschemas.flowcontrol.apiserver.k8s.io",
    "prioritylevelconfigurations.flowcontrol.apiserver.k8s.io",
    # Cilium runtime state
    "ciliumidentities.cilium.io",
    "ciliumendpoints.cilium.io",
    "ciliumnodes.cilium.io",
    # Backup runtime state (Velero)
    "backups.velero.io",
    "datadownloads.velero.io",
    "datauploads.velero.io",
    "podvolumebackups.velero.io",
    "podvolumerestores.velero.io",
    "backuprepositories.velero.io",
    # StackGres operational state
    "sgbackups.stackgres.io",
    "sgdbops.stackgres.io",
    # cert-manager transient state
    "orders.acme.cert-manager.io",
    "challenges.acme.cert-manager.io",
    "certificaterequests.cert-manager.io",
    # KubeVirt runtime
    "virtualmachineinstances.kubevirt.io",
    # Persistent volumes (dynamically provisioned, not declared)
    "persistentvolumes",
    # GitHub Actions runner ephemeral resources
    "ephemeralrunners.actions.github.com",
    "ephemeralrunnersets.actions.github.com",
    # CDI runtime
    "storageprofiles.cdi.kubevirt.io",
    # K3s/RKE2 internal
    "etcdsnapshotfiles.k3s.cattle.io",
    "addons.k3s.cattle.io",
    "helmcharts.helm.cattle.io",
    "helmchartconfigs.helm.cattle.io",
    # ZFS runtime state
    "zfsvolumes.zfs.openebs.io",
    "zfsnodes.zfs.openebs.io",
    "zfssnapshots.zfs.openebs.io",
    "volumesnapshotcontents.snapshot.storage.k8s.io",
}


def kubectl(args: list[str], context: str | None = None) -> str:
    """Run a kubectl command and return stdout."""
    cmd = ["kubectl"]
    if context:
        cmd += ["--context", context]
    cmd += args
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise click.ClickException(
            f"kubectl {' '.join(args)} failed:\n{result.stderr.strip()}"
        )
    return result.stdout


def kubectl_get_json(
    resource: str,
    args: list[str],
    context: str | None = None,
) -> list[dict]:
    """Fetch resources as JSON items list."""
    cmd = ["get", resource, "-o", "json"] + args
    try:
        raw = kubectl(cmd, context)
    except click.ClickException:
        return []
    data = json.loads(raw)
    if data.get("kind") == "List":
        return data.get("items", [])
    return [data]


def get_api_resources(context: str | None = None) -> list[tuple[str, bool]]:
    """Get all listable API resource types in the cluster.

    Returns list of (resource_name, namespaced) tuples.
    resource_name is the fully-qualified form (e.g. "deployments.apps").
    """
    results = []
    for namespaced in [True, False]:
        raw = kubectl(
            [
                "api-resources",
                "--verbs=list",
                f"--namespaced={str(namespaced).lower()}",
                "-o",
                "name",
            ],
            context,
        )
        for line in raw.strip().splitlines():
            line = line.strip()
            if line:
                results.append((line, namespaced))
    return results


def parse_kix_filename(filename: str) -> tuple[str, str, str] | None:
    """Parse a Kix filename into (namespace, name, kind).

    Format: {namespace}--{name}-{kind}.yaml
    The kind is the last hyphen-separated segment before .yaml.
    """
    stem = filename.removesuffix(".yaml")
    if "--" not in stem:
        return None
    ns, rest = stem.split("--", 1)
    parts = rest.rsplit("-", 1)
    if len(parts) != 2:
        return None
    name, kind = parts
    return (ns, name, kind)


def make_filepath(ns: str, name: str, kind: str) -> Path:
    """Build a Kix-convention file path: {namespace}/{name}-{kind}.yaml"""
    kind_lower = kind.lower()
    ns_dir = ns if ns else "_cluster"
    return Path(ns_dir) / f"{name}-{kind_lower}.yaml"


def dump_match_kix(
    kix_dir: Path,
    context: str | None,
) -> tuple[list[dict], list[str]]:
    """Fetch exactly the resources that exist in a Kix output directory.

    Uses `kubectl get <kind> <name> -n <ns>` per resource. The kind from the
    Kix filename (e.g. "deployment") works directly as a kubectl resource type.
    """
    # Group targets by (kind, namespace) for batching
    targets: dict[tuple[str, str], list[str]] = {}  # (kind, ns) -> [name, ...]
    for f in sorted(kix_dir.glob("*.yaml")):
        parsed = parse_kix_filename(f.name)
        if not parsed:
            continue
        ns, name, kind = parsed
        if kind == "packageinstance":
            continue
        targets.setdefault((kind, ns), []).append(name)

    resources = []
    skipped = []

    for (kind, ns), names in sorted(targets.items()):
        click.echo(f"  Fetching {kind} in {ns} ({len(names)} targets)...", err=True)
        for name in names:
            args = [name]
            if ns != "_cluster":
                args += ["-n", ns]
            docs = kubectl_get_json(kind, args, context)
            if docs:
                resources.extend(docs)
            else:
                skipped.append(f"Not found: {kind}/{ns}/{name}")

    return resources, skipped


def dump_managed(
    context: str | None,
) -> tuple[list[dict], list[str]]:
    """Fetch all resources with managed-by=kix label."""
    api_resources = get_api_resources(context)
    resources = []
    skipped = []
    selector = "app.kubernetes.io/managed-by=kix"

    for resource_name, namespaced in api_resources:
        if resource_name in SKIP_RESOURCES:
            continue
        args = ["-l", selector]
        if namespaced:
            args += ["-A"]

        docs = kubectl_get_json(resource_name, args, context)
        if docs:
            click.echo(f"  {resource_name}: {len(docs)} resources", err=True)
            resources.extend(docs)

    return resources, skipped


def dump_namespaces(
    namespaces: list[str],
    context: str | None,
) -> tuple[list[dict], list[str]]:
    """Fetch all resources in given namespaces."""
    api_resources = get_api_resources(context)
    resources = []
    skipped = []

    for resource_name, namespaced in api_resources:
        if not namespaced:
            continue
        if resource_name in SKIP_RESOURCES:
            continue

        for ns in namespaces:
            docs = kubectl_get_json(resource_name, ["-n", ns], context)
            if docs:
                click.echo(f"  {ns}/{resource_name}: {len(docs)} resources", err=True)
                resources.extend(docs)

    return resources, skipped


def dump_all(
    context: str | None,
) -> tuple[list[dict], list[str]]:
    """Fetch all resources across all namespaces (and cluster-scoped)."""
    api_resources = get_api_resources(context)
    resources = []
    skipped = []

    for resource_name, namespaced in api_resources:
        if resource_name in SKIP_RESOURCES:
            continue

        args = ["-A"] if namespaced else []
        docs = kubectl_get_json(resource_name, args, context)
        if docs:
            click.echo(f"  {resource_name}: {len(docs)} resources", err=True)
            resources.extend(docs)

    return resources, skipped


@click.command()
@click.argument("output_dir", type=click.Path())
@click.option("--context", default=None, help="Kubernetes context to use")
@click.option(
    "--match-kix",
    "kix_dir",
    type=click.Path(exists=True, file_okay=False),
    help="Match resources from a kix output directory",
)
@click.option(
    "--managed",
    "mode_managed",
    is_flag=True,
    help="Fetch all resources with managed-by=kix label",
)
@click.option("--namespaces", default=None, help="Comma-separated namespaces to dump")
@click.option(
    "--all", "mode_all", is_flag=True, help="Dump all resources across all namespaces"
)
def main(
    output_dir: str,
    context: str | None,
    kix_dir: str | None,
    mode_managed: bool,
    namespaces: str | None,
    mode_all: bool,
):
    """Dump live cluster resources into a normalized YAML directory.

    OUTPUT_DIR is the directory to write normalized YAML files to.
    Secrets are included, but their data is stripped: only metadata and type are kept.
    """
    out = Path(output_dir)

    # Determine mode
    modes = sum([kix_dir is not None, mode_managed, namespaces is not None, mode_all])
    if modes == 0:
        raise click.UsageError(
            "Specify one of: --match-kix, --managed, --namespaces, or --all"
        )
    if modes > 1:
        raise click.UsageError(
            "Specify only one of: --match-kix, --managed, --namespaces, or --all"
        )

    click.echo("Dumping cluster resources...", err=True)

    if kix_dir:
        resources, skipped = dump_match_kix(Path(kix_dir), context)
    elif mode_managed:
        resources, skipped = dump_managed(context)
    elif mode_all:
        resources, skipped = dump_all(context)
    else:
        ns_list = [ns.strip() for ns in namespaces.split(",")]
        resources, skipped = dump_namespaces(ns_list, context)

    # Write to a temp directory next to the target, then swap atomically
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(dir=out.parent, prefix=f".{out.name}."))

    try:
        written = 0
        for doc in resources:
            doc = normalize_cluster(doc)
            kind = doc.get("kind", "Unknown")
            name = doc.get("metadata", {}).get("name", "unknown")
            ns = doc.get("metadata", {}).get("namespace")

            filepath = tmp / make_filepath(ns or "_cluster", name, kind)
            filepath.parent.mkdir(parents=True, exist_ok=True)

            with open(filepath, "w") as f:
                yaml.dump(
                    doc, f, default_flow_style=False, sort_keys=True, allow_unicode=True
                )
            written += 1

        # Build the command string for the report
        cmd_parts = ["./scripts/kix-dump.py"]
        if context:
            cmd_parts += ["--context", context]
        if kix_dir:
            cmd_parts += ["--match-kix", kix_dir]
        elif mode_managed:
            cmd_parts.append("--managed")
        elif mode_all:
            cmd_parts.append("--all")
        elif namespaces:
            cmd_parts += ["--namespaces", namespaces]
        cmd_parts.append(output_dir)
        cmd_str = " ".join(cmd_parts)

        mode = (
            "match-kix"
            if kix_dir
            else ("managed" if mode_managed else ("all" if mode_all else "namespaces"))
        )
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Write report
        report_lines = [
            "# Cluster Dump",
            "",
            f"**Timestamp:** {timestamp}",
            f"**Context:** {context or '(current)'}",
            f"**Mode:** {mode}",
            f"**Resources written:** {written}",
            "",
            "## Command",
            "",
            "```",
            cmd_str,
            "```",
            "",
        ]

        if skipped:
            report_lines += [
                "## Skipped (not found / CRD unavailable)",
                "",
            ]
            for s in skipped:
                report_lines.append(f"- {s}")
            report_lines.append("")

        if mode != "match-kix":
            report_lines += [
                "## Filtered resource types",
                "",
                "The following resource types are always excluded from broad dumps",
                "(ephemeral, derived, or runtime-only state):",
                "",
            ]
            for r in sorted(SKIP_RESOURCES):
                report_lines.append(f"- `{r}`")
            report_lines.append("")

        with open(tmp / "README.md", "w") as f:
            f.write("\n".join(report_lines))

        # Swap: remove old directory, move temp into place
        if out.exists():
            shutil.rmtree(out)
        tmp.rename(out)

        click.echo(f"\nDumped {written} resources to {out}/", err=True)
        if skipped:
            click.echo(f"Skipped {len(skipped)} resources:", err=True)
            for s in skipped:
                click.echo(f"  - {s}", err=True)

    except BaseException:
        # Clean up temp dir on any failure (including KeyboardInterrupt)
        shutil.rmtree(tmp, ignore_errors=True)
        raise


if __name__ == "__main__":
    main()
