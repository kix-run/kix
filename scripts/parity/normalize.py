"""
Normalization logic for comparing kix output against live cluster state.

Strips server-side fields, cosmetic differences, and noise so the comparison
focuses on what actually matters to Kubernetes behavior.
"""

from __future__ import annotations

import re
from typing import Any


# --- Server-side fields that K8s adds and kix never produces ---

STRIP_METADATA_KEYS = {
    "uid",
    "resourceVersion",
    "creationTimestamp",
    "generation",
    "selfLink",
    "managedFields",
    "finalizers",
}

# Annotations that K8s or controllers add at runtime
STRIP_ANNOTATIONS = {
    "kubectl.kubernetes.io/last-applied-configuration",
    "deployment.kubernetes.io/revision",
    "pv.kubernetes.io/bind-completed",
    "pv.kubernetes.io/bound-by-controller",
    "deprecated.daemonset.template.generation",
}

# Annotation prefixes — any annotation starting with these is stripped from cluster side
STRIP_ANNOTATION_PREFIXES = [
    "control-plane.alpha.kubernetes.io/",
    "autoscaling.alpha.kubernetes.io/",
    "endpoints.kubernetes.io/",
    "meta.helm.sh/",
]

# Labels stripped from both sides — either build metadata or organizational
# labels that don't affect K8s behavior.
STRIP_LABELS = {
    "build.kix.dev/hash",
    # app.kubernetes.io organizational labels — differ between kix and existing cluster
    "app.kubernetes.io/managed-by",
    "app.kubernetes.io/instance",
    "app.kubernetes.io/part-of",
    "app.kubernetes.io/version",
    "app.kubernetes.io/component",
    "app.kubernetes.io/name",
    # K8s auto-adds this to namespaces
    "kubernetes.io/metadata.name",
    # Cluster-level labels kix adds
    "cluster",
    "team",
    # Helm labels on existing cluster resources
    "app",
    "app.kubernetes.io/created-by",
}

# Label prefixes stripped from both sides
STRIP_LABEL_PREFIXES = [
    "helm.sh/",
    "meta.helm.sh/",
]

# Annotation prefixes kix adds for build metadata
STRIP_KIX_ANNOTATION_PREFIXES = [
    "build.kix.dev/",
]


def normalize_cluster(doc: dict) -> dict:
    """Normalize a live cluster resource for behavioral comparison."""
    if not isinstance(doc, dict):
        return doc

    doc = _strip_server_fields(doc)
    doc = _strip_secret_data(doc)
    doc = _strip_labels_and_annotations(doc, cluster=True)
    doc = _strip_k8s_defaults(doc)
    doc = _strip_empty_fields(doc)
    doc = _normalize_configmap_data(doc)
    doc = _normalize_paths(doc)
    doc = _sort_arrays(doc)
    return doc


def normalize_kix(doc: dict) -> dict:
    """Normalize a kix-built resource for behavioral comparison."""
    if not isinstance(doc, dict):
        return doc

    doc = _strip_secret_data(doc)
    doc = _strip_labels_and_annotations(doc, cluster=False)
    doc = _strip_k8s_defaults(doc)
    doc = _strip_empty_fields(doc)
    doc = _normalize_configmap_data(doc)
    doc = _normalize_paths(doc)
    doc = _sort_arrays(doc)
    return doc


# --- Internals ---


def _strip_server_fields(doc: dict) -> dict:
    """Remove server-side metadata fields from a cluster resource."""
    doc = dict(doc)

    # Strip top-level status
    doc.pop("status", None)

    # Strip server-side metadata fields
    if "metadata" in doc and isinstance(doc["metadata"], dict):
        metadata = dict(doc["metadata"])
        for key in STRIP_METADATA_KEYS:
            metadata.pop(key, None)
        doc["metadata"] = metadata

    return doc


def _strip_secret_data(doc: dict) -> dict:
    """Strip data/stringData from Secret resources (keep metadata + type for comparison)."""
    if doc.get("kind") != "Secret":
        return doc
    doc = dict(doc)
    doc.pop("data", None)
    doc.pop("stringData", None)
    return doc


def _strip_k8s_defaults(doc: dict) -> dict:
    """Strip fields that K8s adds as defaults and are not behaviorally meaningful."""
    kind = doc.get("kind")

    # Namespace: spec.finalizers is server-managed
    if kind == "Namespace":
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            spec = dict(spec)
            spec.pop("finalizers", None)
            if spec:
                doc["spec"] = spec
            else:
                doc.pop("spec", None)

    # CRD: spec.conversion defaults to {strategy: None}
    if kind == "CustomResourceDefinition":
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            conv = spec.get("conversion")
            if conv == {"strategy": "None"} or conv is None:
                spec = dict(spec)
                spec.pop("conversion", None)
                doc["spec"] = spec

    # Namespace labels: strip the auto-added "name" label
    if kind == "Namespace":
        meta = doc.get("metadata", {})
        labels = meta.get("labels", {})
        labels.pop("name", None)

    # Deployments / StatefulSets / DaemonSets: strip K8s-defaulted spec fields
    if kind in ("Deployment", "StatefulSet", "DaemonSet"):
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            spec = dict(spec)
            spec.pop("progressDeadlineSeconds", None)
            spec.pop("revisionHistoryLimit", None)
            doc["spec"] = spec

    # Pod spec defaults (applies to any resource with a pod template)
    doc = _strip_pod_spec_defaults(doc)

    # Webhooks: strip server-injected caBundle and K8s-defaulted fields
    if kind in ("MutatingWebhookConfiguration", "ValidatingWebhookConfiguration"):
        doc = dict(doc)
        webhooks = doc.get("webhooks", [])
        if webhooks:
            new_webhooks = []
            for wh in webhooks:
                wh = dict(wh)
                # caBundle is injected by cert-manager at runtime
                cc = wh.get("clientConfig", {})
                if isinstance(cc, dict):
                    cc = dict(cc)
                    cc.pop("caBundle", None)
                    wh["clientConfig"] = cc
                # K8s defaults
                wh.pop("reinvocationPolicy", None)
                wh.pop("timeoutSeconds", None)
                # rules[].scope defaults to '*'
                rules = wh.get("rules", [])
                if rules:
                    new_rules = []
                    for r in rules:
                        r = dict(r)
                        if r.get("scope") == "*":
                            r.pop("scope")
                        new_rules.append(r)
                    wh["rules"] = new_rules
                # clientConfig.service.port defaults to 443
                svc = wh.get("clientConfig", {}).get("service")
                if isinstance(svc, dict) and svc.get("port") == 443:
                    svc = dict(svc)
                    svc.pop("port")
                    wh["clientConfig"] = dict(wh["clientConfig"])
                    wh["clientConfig"]["service"] = svc
                new_webhooks.append(wh)
            doc["webhooks"] = new_webhooks

    return doc


def _strip_pod_spec_defaults(doc: dict) -> dict:
    """Strip K8s-defaulted fields from pod specs embedded in any resource."""
    pod_specs = _find_pod_specs(doc)
    for pod_spec in pod_specs:
        # Pod-level defaults
        pod_spec.pop("dnsPolicy", None)
        pod_spec.pop("restartPolicy", None)
        pod_spec.pop("schedulerName", None)
        pod_spec.pop("terminationGracePeriodSeconds", None)
        # serviceAccount is a deprecated alias for serviceAccountName
        pod_spec.pop("serviceAccount", None)

        # Container-level defaults
        for container in pod_spec.get("containers", []) + pod_spec.get("initContainers", []):
            if not isinstance(container, dict):
                continue
            container.pop("terminationMessagePath", None)
            container.pop("terminationMessagePolicy", None)
            container.pop("imagePullPolicy", None)

            # Probe defaults
            for probe_key in ("livenessProbe", "readinessProbe", "startupProbe"):
                probe = container.get(probe_key)
                if not isinstance(probe, dict):
                    continue
                # successThreshold defaults to 1
                if probe.get("successThreshold") == 1:
                    probe.pop("successThreshold")
                # httpGet.scheme defaults to HTTP
                http_get = probe.get("httpGet")
                if isinstance(http_get, dict) and http_get.get("scheme") == "HTTP":
                    http_get.pop("scheme")

    return doc


def _find_pod_specs(doc: dict) -> list[dict]:
    """Find all pod spec dicts in a resource."""
    specs = []
    # Deployment/StatefulSet/DaemonSet/Job
    tmpl = doc.get("spec", {}).get("template", {}).get("spec")
    if isinstance(tmpl, dict):
        specs.append(tmpl)
    # CronJob
    job_spec = (
        doc.get("spec", {})
        .get("jobTemplate", {})
        .get("spec", {})
        .get("template", {})
        .get("spec")
    )
    if isinstance(job_spec, dict):
        specs.append(job_spec)
    # Pod directly
    if doc.get("kind") == "Pod":
        spec = doc.get("spec")
        if isinstance(spec, dict):
            specs.append(spec)
    return specs


def _strip_labels_and_annotations(doc: dict, cluster: bool) -> dict:
    """Remove cosmetic labels and annotations from all metadata locations."""
    for metadata in _find_metadata_blocks(doc):
        # Strip labels
        labels = metadata.get("labels", {})
        for key in list(labels.keys()):
            if key in STRIP_LABELS:
                del labels[key]
                continue
            for prefix in STRIP_LABEL_PREFIXES:
                if key.startswith(prefix):
                    del labels[key]
                    break

        # Strip annotations
        annotations = metadata.get("annotations", {})
        for key in list(annotations.keys()):
            if key in STRIP_ANNOTATIONS:
                del annotations[key]
                continue
            # Server-side annotation prefixes
            if cluster:
                for prefix in STRIP_ANNOTATION_PREFIXES:
                    if key.startswith(prefix):
                        del annotations[key]
                        break
            # kix build metadata
            else:
                for prefix in STRIP_KIX_ANNOTATION_PREFIXES:
                    if key.startswith(prefix):
                        del annotations[key]
                        break

        # Remove empty annotations/labels dicts
        if not annotations and "annotations" in metadata:
            del metadata["annotations"]
        if not labels and "labels" in metadata:
            del metadata["labels"]

    return doc


def _find_metadata_blocks(doc: dict) -> list[dict]:
    """Find all metadata dicts that may contain labels/annotations."""
    blocks = []

    top = doc.get("metadata")
    if isinstance(top, dict):
        blocks.append(top)

    tmpl = doc.get("spec", {}).get("template", {}).get("metadata")
    if isinstance(tmpl, dict):
        blocks.append(tmpl)

    for vct in doc.get("spec", {}).get("volumeClaimTemplates", []):
        if isinstance(vct, dict):
            vct_meta = vct.get("metadata")
            if isinstance(vct_meta, dict):
                blocks.append(vct_meta)

    # Job template (CronJob)
    job_tmpl = (
        doc.get("spec", {})
        .get("jobTemplate", {})
        .get("spec", {})
        .get("template", {})
        .get("metadata")
    )
    if isinstance(job_tmpl, dict):
        blocks.append(job_tmpl)

    return blocks


def _strip_empty_fields(obj: Any) -> Any:
    """Remove null values, empty dicts, and empty lists recursively."""
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            v = _strip_empty_fields(v)
            if v is None:
                continue
            if isinstance(v, dict) and not v:
                continue
            if isinstance(v, list) and not v:
                continue
            result[k] = v
        return result
    elif isinstance(obj, list):
        return [_strip_empty_fields(item) for item in obj]
    return obj


def _normalize_configmap_data(doc: dict) -> dict:
    """Normalize whitespace in ConfigMap data values."""
    if doc.get("kind") != "ConfigMap":
        return doc
    data = doc.get("data")
    if isinstance(data, dict):
        doc = dict(doc)

        def normalize_text(v: str) -> str:
            lines = [line.rstrip() for line in v.splitlines()]
            return re.sub(r"\n{2,}", "\n", "\n".join(lines)).strip()

        doc["data"] = {
            k: normalize_text(v) if isinstance(v, str) else v
            for k, v in data.items()
        }
    return doc


def _normalize_paths(obj: Any) -> Any:
    """Strip trailing slashes from mount paths."""
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            if k == "mountPath" and isinstance(v, str) and len(v) > 1:
                result[k] = v.rstrip("/")
            else:
                result[k] = _normalize_paths(v)
        return result
    elif isinstance(obj, list):
        return [_normalize_paths(item) for item in obj]
    return obj


def _sort_arrays(obj: Any) -> Any:
    """Sort arrays where ordering is not semantically significant."""
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            if k == "ports" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(p) for p in v),
                    key=lambda p: (p.get("name", ""), p.get("containerPort", 0), p.get("port", 0)),
                )
            elif k == "env" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(e) for e in v),
                    key=lambda e: e.get("name", ""),
                )
            elif k == "envFrom" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(e) for e in v),
                    key=lambda e: str(e),
                )
            elif k == "volumeMounts" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(vm) for vm in v),
                    key=lambda vm: vm.get("mountPath", ""),
                )
            elif k == "volumes" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(vol) for vol in v),
                    key=lambda vol: vol.get("name", ""),
                )
            elif k == "containers" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(c) for c in v),
                    key=lambda c: c.get("name", ""),
                )
            elif k == "initContainers" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(c) for c in v),
                    key=lambda c: c.get("name", ""),
                )
            elif k == "rules" and isinstance(v, list) and v and isinstance(v[0], dict):
                # RBAC rules — sort by apiGroups for stability
                result[k] = sorted(
                    (_sort_arrays(r) for r in v),
                    key=lambda r: str(sorted(r.get("apiGroups", []))),
                )
            elif k == "hostAliases" and isinstance(v, list) and v and isinstance(v[0], dict):
                result[k] = sorted(
                    (_sort_arrays(h) for h in v),
                    key=lambda h: h.get("ip", ""),
                )
            else:
                result[k] = _sort_arrays(v)
        return result
    elif isinstance(obj, list):
        return [_sort_arrays(item) for item in obj]
    return obj


def resource_key(doc: dict) -> str:
    """Generate a comparison key from kind + namespace + name."""
    kind = doc.get("kind", "Unknown")
    ns = doc.get("metadata", {}).get("namespace", "_cluster")
    name = doc.get("metadata", {}).get("name", "unknown")
    return f"{kind}/{ns}/{name}"
