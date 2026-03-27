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

import re
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path

import click
import yaml

# Use the C-accelerated YAML loader when available (~5-10x faster).
_YAMLLoader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from parity.normalize import (
    normalize_kix,
    normalize_cluster,
    strip_port_names,
    normalize_dns_suffix,
)
from parity.structural_diff import structural_diff, format_diffs, DiffKind

# Fields that Kubernetes auto-assigns at runtime — never present in kix output.
# These are skipped entirely during comparison (any value is ignored).
# For fields with known default *values*, use _strip_k8s_defaults in normalize.py instead.
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


# Kinds that are always created by operators/controllers at runtime, never declarative.
_RUNTIME_KINDS = {
    "volumesnapshot",
    "virtualmachineclusterinstancetype",
    "virtualmachineclusterpreference",
}

# Namespaces that are entirely K8s internal plumbing.
_RUNTIME_NAMESPACES = {
    "kube-public",
    "kube-node-lease",
}


def _is_runtime_resource(doc: dict) -> bool:
    """Check if a resource is auto-generated at runtime and should be skipped.

    Detects:
    - metadata.generateName (controller-generated random name)
    - Known runtime-only kinds (VolumeSnapshot, KubeVirt instance types/prefs)
    - Built-in K8s RBAC (kubernetes.io/bootstrapping: rbac-defaults label)
    - Default ServiceAccount per namespace
    - kube-root-ca.crt ConfigMap per namespace
    - Helm release secrets (sh.helm.release.v1.*)
    - Velero backup artifacts (velero.io/backup-name annotation)
    - Resources in kube-public / kube-node-lease namespaces
    - RKE2 distribution resources (metrics-server, snapshot-controller, cilium helm configs)
    - StatefulSet-generated PVCs (named {template}-{sts}-{ordinal})
    - K8s extension-apiserver-authentication ConfigMap
    """
    metadata = doc.get("metadata", {})
    kind = doc.get("kind", "").lower()
    name = metadata.get("name", "")
    labels = metadata.get("labels", {}) or {}
    annotations = metadata.get("annotations", {}) or {}
    ns = metadata.get("namespace", "")

    # generateName means a controller created this with a random suffix
    if metadata.get("generateName"):
        return True

    # Entire kinds that are always operator-generated
    if kind in _RUNTIME_KINDS:
        return True

    # Built-in K8s RBAC resources
    if labels.get("kubernetes.io/bootstrapping") == "rbac-defaults":
        return True

    # Auto-created per namespace
    if kind == "serviceaccount" and name == "default":
        return True
    if kind == "configmap" and name == "kube-root-ca.crt":
        return True
    # K8s auto-creates this in kube-system for webhook auth delegation.
    if kind == "configmap" and name == "extension-apiserver-authentication":
        return True

    # Bare ServiceAccounts in kube-system (no labels, no annotations) are
    # auto-created by kube-controller-manager for built-in controllers.
    if (
        kind == "serviceaccount"
        and ns == "kube-system"
        and not labels
        and not annotations
    ):
        return True

    # Helm internal bookkeeping
    if kind == "secret" and name.startswith("sh.helm.release.v1."):
        return True

    # ---------------------------------------------------------------
    # Operator-generated secrets
    # ---------------------------------------------------------------
    if kind == "secret":
        # Legacy ServiceAccount token secrets (auto-created by K8s < 1.24,
        # or by the token-controller for SAs that request them).
        # Evidence: type field is kubernetes.io/service-account-token.
        secret_type = doc.get("type", "")
        if secret_type == "kubernetes.io/service-account-token":
            return True

        # cert-manager managed secrets (webhook CA, ACME account keys).
        # Evidence: label app.kubernetes.io/managed-by: cert-manager.
        if labels.get("app.kubernetes.io/managed-by") == "cert-manager":
            return True

        # Infisical operator output secrets. The operator creates two secrets
        # per InfisicalSecret CR: "infisical-managed-secret" (raw sync output)
        # and "managed-secret" (the final projected secret).
        # Evidence: these secrets reference infisical in their annotations/data.
        if name in ("infisical-managed-secret", "managed-secret"):
            return True

        # StackGres init-script secrets. The operator generates these from
        # SGScript CRs — they contain the rendered SQL init scripts.
        # Evidence: naming pattern {cluster}-init-script, always paired with
        # an sgscript CR of the same name in the cluster dump.
        if name.endswith("-init-script"):
            return True

        # nginx ingress admission webhook secrets (auto-generated TLS certs).
        # Evidence: created by the ingress controller admission webhook setup.
        if name.endswith("-admission") and ns in ("nginx-system", "nginx"):
            return True

    # Velero backup artifacts
    if "velero.io/backup-name" in annotations:
        return True

    # K8s internal namespaces
    if ns in _RUNTIME_NAMESPACES:
        return True

    # ---------------------------------------------------------------
    # RKE2 distribution resources
    # ---------------------------------------------------------------
    # RKE2 bundles metrics-server, snapshot-controller, cilium, and
    # runtime classes as internal Helm charts. These resources are
    # managed by RKE2, not by kix.
    #
    # Evidence: annotations like meta.helm.sh/release-name: rke2-*,
    # names matching helm-rke2-*, chart-content-rke2-*, chart-values-rke2-*.
    # Verified via cluster dump inspection.
    release_name = annotations.get("meta.helm.sh/release-name", "")
    if release_name.startswith("rke2-"):
        return True
    # RKE2 Helm controller creates ServiceAccounts, ConfigMaps, and Secrets
    # for its internal charts with predictable name prefixes.
    if ns == "kube-system" and (
        name.startswith("helm-rke2-")
        or name.startswith("chart-content-rke2-")
        or name.startswith("chart-values-rke2-")
        or name.startswith("rke2-")
    ):
        return True
    # RKE2 Helm controller ClusterRoleBindings for its service accounts.
    if kind == "clusterrolebinding" and name.startswith("helm-kube-system-rke2-"):
        return True
    # RKE2 node password secrets (created during node join).
    if (
        kind == "secret"
        and ns == "kube-system"
        and name.endswith(".node-password.rke2")
    ):
        return True
    # objectset.rio.cattle.io labels indicate resources managed by RKE2's
    # internal controller (cattle agent / fleet).
    if annotations.get("objectset.rio.cattle.io/owner-name", "").startswith("rke2-"):
        return True
    # Cilium CRDs and cluster-scoped resources are deployed by RKE2's
    # bundled cilium, not by kix.  The cilium-rke2 kix package only
    # generates a HelmChartConfig (a configuration overlay), not the
    # operator itself.
    # Evidence: cilium CRDs have no helm annotations — they're created
    # by the cilium agent DaemonSet at startup.
    if kind == "customresourcedefinition" and name.endswith(".cilium.io"):
        return True
    # Hubble resources (UI, relay, metrics) are part of RKE2's cilium.
    if ns == "kube-system" and name.startswith("hubble"):
        return True
    # RKE2 cattle.io CRDs (HelmChart, HelmChartConfig, EtcdSnapshotFile, Addon).
    _RKE2_CRD_DOMAINS = {"k3s.cattle.io", "helm.cattle.io"}
    if kind == "customresourcedefinition":
        crd_domain = ".".join(name.split(".")[-2:]) if "." in name else ""
        if crd_domain in _RKE2_CRD_DOMAINS:
            return True
    # Volume snapshot CRDs are deployed by RKE2's snapshot-controller.
    _SNAPSHOT_CRD_DOMAINS = {"snapshot.storage.k8s.io", "groupsnapshot.storage.k8s.io"}
    if kind == "customresourcedefinition":
        crd_domain = ".".join(name.split(".")[-3:]) if name.count(".") >= 2 else ""
        if crd_domain in _SNAPSHOT_CRD_DOMAINS:
            return True

    # ---------------------------------------------------------------
    # StatefulSet-generated PVCs
    # ---------------------------------------------------------------
    # K8s creates PVCs from StatefulSet volumeClaimTemplates automatically.
    # Their names follow the pattern: {vctName}-{stsName}-{ordinal}
    # (e.g. data-loki-write-0, valkey-data-valkey-shopfront-prod-node-2).
    #
    # We require TWO conditions to avoid false positives:
    # 1. Name ends with -{digit} (the StatefulSet ordinal suffix)
    # 2. Has a label from a known workload label scheme, proving it was
    #    created by a StatefulSet controller rather than manually.
    #
    # Evidence: cluster dump PVCs carry StatefulSet selector labels:
    #   - valkey PVCs: app.kubernetes.io/instance, app.kubernetes.io/name
    #   - loki PVCs:   app.kubernetes.io/component, app.kubernetes.io/name
    #   - StackGres PVCs: stackgres.io/cluster-name (+ ownerRefs, caught earlier)
    #   - prometheus PVCs: operator.prometheus.io/name
    _STS_PVC_LABELS = {
        "app.kubernetes.io/name",  # Helm-standard: valkey, loki, etc.
        "app.kubernetes.io/instance",  # Helm-standard: instance name
        "stackgres.io/cluster-name",  # StackGres PVCs
        "operator.prometheus.io/name",  # Prometheus operator PVCs
        "app",  # Legacy label used by some charts
    }
    if kind == "persistentvolumeclaim" and re.search(r"-\d+$", name):
        if labels.keys() & _STS_PVC_LABELS:
            return True

    return False


def _is_controller_owned(doc: dict) -> bool:
    """Check if a resource is owned by a controller (auto-created, not user-deployed).

    Detects three patterns:
    - ownerReferences with controller=true (standard K8s ownership)
    - cert-manager.io annotations indicating controller management
    - app.kubernetes.io/managed-by label indicating operator management
      (e.g. virt-operator creates all kubevirt/* resources with this label
      but does NOT set ownerReferences on them)
    """
    metadata = doc.get("metadata", {})
    labels = metadata.get("labels", {}) or {}

    # managed-by label: operators like virt-operator, cilium-operator set this
    # to indicate they control the resource's lifecycle.
    # Evidence: kubevirt/* resources all have managed-by: virt-operator with
    # NO ownerReferences — verified via cluster dump inspection.
    managed_by = labels.get("app.kubernetes.io/managed-by", "")
    _OPERATOR_MANAGERS = {
        "virt-operator",  # KubeVirt: creates virt-api, virt-controller, etc.
        "cdi-operator",  # CDI: creates cdi-apiserver, cdi-uploadproxy, etc.
    }
    if managed_by in _OPERATOR_MANAGERS:
        return True

    owner_refs = metadata.get("ownerReferences", [])
    if any(
        ref.get("controller") is True for ref in owner_refs if isinstance(ref, dict)
    ):
        return True
    for field in ("annotations", "labels"):
        entries = metadata.get(field, {})
        if any(k.startswith("controller.") and v == "true" for k, v in entries.items()):
            return True
    return False


def load_resources(
    directory: Path,
    normalizer,
    service: str | None = None,
    skip_controller_owned: bool = False,
    skip_runtime: bool = False,
) -> dict[str, dict]:
    """Load and normalize all YAML files from a directory.

    Supports both layouts:
    - Nested: {namespace}/{name}-{kind}.yaml  (dump output)
    - Flat:   {namespace}--{name}-{kind}.yaml  (kix nix build output)

    If *service* is given, only files whose stem starts with that name
    (before the first ``-``) are included.

    If *skip_controller_owned* is True, resources with ownerReferences
    where controller=true are excluded (they are managed by a controller,
    not deployed directly).

    If *skip_runtime* is True, resources that are auto-generated at runtime
    are excluded (generateName, built-in RBAC, default SAs, helm secrets, etc.).

    Returns dict mapping "{namespace}/{name}-{kind}" -> normalized doc.
    """

    def _matches_service(stem: str) -> bool:
        if service is None:
            return True
        # stem is e.g. "coredns-deployment"; extract the name part before the kind suffix
        name_part = stem.rsplit("-", 1)[0] if "-" in stem else stem
        return name_part == service or name_part.startswith(service + "-")

    def _process(f: Path, key: str) -> list[tuple[str, dict]]:
        """Parse, filter, and normalize a single file. Returns [(key, doc), ...]."""
        with open(f) as fh:
            doc = yaml.load(fh, Loader=_YAMLLoader)
        if doc is None:
            return []
        # Unpack List resources (e.g. helm-generated bundled PrometheusRules)
        # into individual items so they match cluster dump entries one-to-one.
        if doc.get("kind") == "List" and isinstance(doc.get("items"), list):
            items = []
            for item in doc["items"]:
                item_kind = item.get("kind", "Unknown").lower()
                item_meta = item.get("metadata", {})
                item_ns = item_meta.get("namespace", "_cluster")
                item_name = item_meta.get("name", "unknown")
                item_key = f"{item_ns}/{item_name}-{item_kind}"
                if skip_controller_owned and _is_controller_owned(item):
                    continue
                if skip_runtime and _is_runtime_resource(item):
                    continue
                items.append((item_key, normalizer(item)))
            return items
        if skip_controller_owned and _is_controller_owned(doc):
            return []
        if skip_runtime and _is_runtime_resource(doc):
            return []
        return [(key, normalizer(doc))]

    # Collect (file, key) pairs to process
    file_list: list[tuple[Path, str]] = []

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
                file_list.append((f, f"{ns}/{f.stem}"))
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
            file_list.append((f, f"{ns}/{rest}"))

    # Process files in parallel (CSafeLoader releases the GIL during C parsing)
    resources = {}
    with ThreadPoolExecutor() as pool:
        for results in pool.map(lambda args: _process(*args), file_list):
            for key, doc in results:
                resources[key] = doc

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
        kix_only,
        cluster_only,
        kix_resources,
        cluster_resources,
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
        lines.append(
            f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}"
        )
        lines.append(f"kix:     {kix_dir} ({len(kix_resources)} resources)")
        lines.append(f"cluster: {cluster_dir} ({len(cluster_resources)} resources)")
    else:
        lines.append("# kix diff report")
        lines.append("")
        lines.append(
            f"**Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}"
        )
        lines.append(f"**kix:** `{kix_dir}` ({len(kix_resources)} resources)")
        lines.append(
            f"**cluster:** `{cluster_dir}` ({len(cluster_resources)} resources)"
        )
    lines.append("")

    # Summary (exclude renames from kix-only / cluster-only counts)
    n_kix_only = len(kix_only) - len(renamed_kix)
    n_cluster_only = len(cluster_only) - len(renamed_cluster)
    n_total = len(identical) + len(modified) + n_kix_only + n_cluster_only

    # Aggregate diff counts across all modified resources
    total_extra = sum(
        sum(1 for d in diffs if d.kind == DiffKind.EXTRA_IN_B) for _, diffs in modified
    )
    total_missing = sum(
        sum(1 for d in diffs if d.kind == DiffKind.MISSING_IN_B)
        for _, diffs in modified
    )
    total_changed = sum(
        sum(
            1
            for d in diffs
            if d.kind in (DiffKind.VALUE_MISMATCH, DiffKind.TYPE_MISMATCH)
        )
        for _, diffs in modified
    )

    if color:
        lines.append(f"{_BOLD}Summary{_RESET}  {_DIM}({n_total} resources){_RESET}")
        lines.append(f"  Identical:    {_DIM}{len(identical)}{_RESET}")
        lines.append(
            f"  Modified:     {_YELLOW}{len(modified)}{_RESET}  {_GREEN}+{total_extra}{_RESET} {_RED}-{total_missing}{_RESET} {_YELLOW}~{total_changed}{_RESET}"
        )
        lines.append(f"  kix-only:     {_RED}{n_kix_only}{_RESET}")
        lines.append(f"  Cluster-only: {_GREEN}{n_cluster_only}{_RESET}")
    else:
        lines.append("## Summary")
        lines.append("")
        lines.append("| Category | Count |")
        lines.append("|----------|-------|")
        lines.append(f"| Identical | {len(identical)} |")
        lines.append(
            f"| Modified | {len(modified)}  (+{total_extra} -{total_missing} ~{total_changed}) |"
        )
        lines.append(f"| kix-only | {n_kix_only} |")
        lines.append(f"| Cluster-only | {n_cluster_only} |")
        lines.append(f"| **Total** | **{n_total}** |")
    lines.append("")

    # Probable renames section (before kix-only/cluster-only so context is clear)
    if rename_pairs:
        lines.append(
            f"{_BOLD}Probable renames / moves{_RESET}"
            if color
            else "## Probable renames / moves"
        )
        lines.append("")
        for kix_key, cluster_key, ratio, diffs in rename_pairs:
            non_rename_diffs = [d for d in diffs if d.path not in _RENAME_ONLY_PATHS]
            pct = int(ratio * 100)
            if color:
                lines.append(
                    f"  {_CYAN}{_BOLD}{format_resource(kix_key)}{_RESET} <-> {_CYAN}{_BOLD}{format_resource(cluster_key)}{_RESET} {_DIM}({pct}% match){_RESET}"
                )
            else:
                lines.append(
                    f"### `{format_resource(kix_key)}` <-> `{format_resource(cluster_key)}` ({pct}% match)"
                )
            lines.append("")
            if not files_only:
                if non_rename_diffs:
                    if not color:
                        lines.append("```")
                    lines.append(
                        format_diffs(non_rename_diffs, color=color, full_diff=full_diff)
                    )
                    if not color:
                        lines.append("```")
                else:
                    if color:
                        lines.append(
                            f"  {_DIM}(identical apart from name/namespace){_RESET}"
                        )
                    else:
                        lines.append(
                            "*Structurally identical (only name/namespace differs)*"
                        )
            lines.append("")

    # kix-only section (excluding resources that were matched as renames)
    unmatched_kix = [k for k in kix_only if k not in renamed_kix]
    if unmatched_kix:
        lines.append(
            f"{_BOLD}{_RED}kix-only (not in cluster){_RESET}"
            if color
            else "## kix-only (not in cluster)"
        )
        lines.append("")
        for key in unmatched_kix:
            lines.append(
                f"  {_RED}- {format_resource(key)}{_RESET}"
                if color
                else f"- `{format_resource(key)}`"
            )
        lines.append("")

    # Cluster-only section (excluding resources that were matched as renames)
    unmatched_cluster = [k for k in cluster_only if k not in renamed_cluster]
    if unmatched_cluster:
        lines.append(
            f"{_BOLD}{_GREEN}Cluster-only (not in kix){_RESET}"
            if color
            else "## Cluster-only (not in kix)"
        )
        lines.append("")
        for key in unmatched_cluster:
            lines.append(
                f"  {_GREEN}+ {format_resource(key)}{_RESET}"
                if color
                else f"- `{format_resource(key)}`"
            )
        lines.append("")

    # Modified section
    if modified:
        lines.append(f"{_BOLD}{_YELLOW}Modified{_RESET}" if color else "## Modified")
        lines.append("")
        for key, diffs in modified:
            kind, ns, name = parse_resource_id(key)
            # Diff counts for the header
            n_missing = sum(1 for d in diffs if d.kind == DiffKind.MISSING_IN_B)
            n_extra = sum(1 for d in diffs if d.kind == DiffKind.EXTRA_IN_B)
            n_changed = sum(
                1
                for d in diffs
                if d.kind in (DiffKind.VALUE_MISMATCH, DiffKind.TYPE_MISMATCH)
            )

            if color:
                label = f"{name}" if ns == "_cluster" else f"{ns}/{name}"
                counts = f"{_GREEN}+{n_extra}{_RESET} {_RED}-{n_missing}{_RESET} {_YELLOW}~{n_changed}{_RESET}"
                lines.append(f"  {_BOLD}{kind} {label}{_RESET}  {counts}")
            else:
                label = name if ns == "_cluster" else f"{ns}/{name}"
                lines.append(
                    f"### {kind} {label}  (+{n_extra} -{n_missing} ~{n_changed})"
                )
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
            lines.append(
                f"{_BOLD}Identical{_RESET} {_DIM}({len(identical)} resources match exactly){_RESET}"
            )
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


def _strip_crd_schema(doc: dict) -> dict:
    """Remove the OpenAPI schema from CRD versions to skip schema comparison."""
    if doc.get("kind") != "CustomResourceDefinition":
        return doc
    for version in doc.get("spec", {}).get("versions", []):
        version.pop("schema", None)
    return doc


# --- Main ---


@click.command()
@click.argument("kix_dir", type=click.Path(exists=True, file_okay=False))
@click.argument("cluster_dir", type=click.Path(exists=True, file_okay=False))
@click.option(
    "--ignore-path",
    multiple=True,
    help="JSON paths to ignore (e.g. '*.annotations', '$.spec.strategy')",
)
@click.option(
    "--service",
    default=None,
    help="Only compare resources whose name matches this service (e.g. 'coredns')",
)
@click.option(
    "--color/--no-color",
    default=None,
    help="Colorize diff output (default: auto-detect TTY)",
)
@click.option(
    "--ignore-cluster-defaults/--no-ignore-cluster-defaults",
    default=True,
    help="Ignore fields that K8s auto-assigns (clusterIP, ipFamilies, sessionAffinity, etc.). On by default.",
)
@click.option(
    "--full-diff",
    is_flag=True,
    default=False,
    help="Show full unified diffs for multi-line string values (e.g. ConfigMaps)",
)
@click.option(
    "--ignore-port-names/--no-ignore-port-names",
    default=True,
    help="Ignore port name differences in container ports (default: enabled)",
)
@click.option(
    "--ignore-dns-suffix/--no-ignore-dns-suffix",
    default=True,
    help="Treat FQDN service DNS names (x.ns.svc.cluster.local) as equivalent to short names (default: enabled)",
)
@click.option(
    "--skip-controller-owned/--no-skip-controller-owned",
    default=True,
    help="Skip cluster resources with ownerReferences[controller=true] (auto-created by controllers)",
)
@click.option(
    "--skip-runtime/--no-skip-runtime",
    default=True,
    help="Skip runtime-generated cluster resources (built-in RBAC, default SAs, helm secrets, velero snapshots, etc.)",
)
@click.option(
    "--skip-crd-schema/--no-skip-crd-schema",
    default=False,
    help="Skip the OpenAPI schema validation section of CRDs (spec.versions[].schema)",
)
@click.option(
    "--skip-all",
    is_flag=True,
    default=False,
    help="Enable all skip/ignore flags (cluster-defaults, port-names, dns-suffix, controller-owned, runtime, crd-schema)",
)
@click.option(
    "--files-only",
    is_flag=True,
    default=False,
    help="Only show file-level info, skip detailed line-by-line diffs",
)
@click.option(
    "--only-broken",
    is_flag=True,
    default=False,
    help="Hide identical resources from the output",
)
def main(
    kix_dir: str,
    cluster_dir: str,
    ignore_path: tuple[str, ...],
    service: str | None,
    color: bool | None,
    ignore_cluster_defaults: bool,
    full_diff: bool,
    ignore_port_names: bool,
    ignore_dns_suffix: bool,
    skip_crd_schema: bool,
    skip_controller_owned: bool,
    skip_runtime: bool,
    skip_all: bool,
    files_only: bool,
    only_broken: bool,
):
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
        skip_runtime = True
        skip_crd_schema = True

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
    if skip_crd_schema:
        post_steps.append(_strip_crd_schema)

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
    cluster_resources = load_resources(
        cluster_path,
        _with_post(normalize_cluster),
        service,
        skip_controller_owned=skip_controller_owned,
        skip_runtime=skip_runtime,
    )
    click.echo(f"  {len(cluster_resources)} resources", err=True)

    # Resolve color: explicit flag wins, otherwise auto-detect TTY on stdout
    use_color = color if color is not None else sys.stdout.isatty()

    report = generate_report(
        kix_path,
        cluster_path,
        kix_resources,
        cluster_resources,
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
