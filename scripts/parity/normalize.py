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
    "kubectl.kubernetes.io/restartedAt",
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
    "checksum/",
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
    "chart",
    "heritage",
    "release",
    "component",
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

    # Service: strip K8s-defaulted spec fields
    if kind == "Service":
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            spec = dict(spec)
            # type defaults to ClusterIP
            if spec.get("type") == "ClusterIP":
                spec.pop("type")
            # publishNotReadyAddresses defaults to false
            if spec.get("publishNotReadyAddresses") is False:
                spec.pop("publishNotReadyAddresses")
            # protocol defaults to TCP on service ports
            ports = spec.get("ports")
            if isinstance(ports, list):
                spec["ports"] = [
                    _strip_port_protocol_default(p) if isinstance(p, dict) else p
                    for p in ports
                ]
            doc["spec"] = spec

    # Deployments / StatefulSets / DaemonSets: strip K8s-defaulted spec fields
    if kind in ("Deployment", "StatefulSet", "DaemonSet"):
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            spec = dict(spec)
            spec.pop("progressDeadlineSeconds", None)
            spec.pop("revisionHistoryLimit", None)
            # Default RollingUpdate strategy with default values (Deployment)
            strategy = spec.get("strategy", {})
            if isinstance(strategy, dict) and strategy.get("type") == "RollingUpdate":
                rolling = strategy.get("rollingUpdate", {})
                if not rolling or rolling == {
                    "maxSurge": "25%",
                    "maxUnavailable": "25%",
                }:
                    spec.pop("strategy", None)
            doc["spec"] = spec

    # StatefulSet: additional defaults
    if kind == "StatefulSet":
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            spec = dict(spec)
            # persistentVolumeClaimRetentionPolicy defaults to Retain/Retain
            pvcrp = spec.get("persistentVolumeClaimRetentionPolicy")
            if pvcrp == {"whenDeleted": "Retain", "whenScaled": "Retain"}:
                spec.pop("persistentVolumeClaimRetentionPolicy")
            # updateStrategy defaults to RollingUpdate
            us = spec.get("updateStrategy", {})
            if isinstance(us, dict) and us.get("type") == "RollingUpdate":
                rolling = us.get("rollingUpdate", {})
                if not rolling or rolling == {"partition": 0}:
                    spec.pop("updateStrategy", None)
            # Normalize VolumeClaimTemplates
            vcts = spec.get("volumeClaimTemplates")
            if isinstance(vcts, list):
                spec["volumeClaimTemplates"] = [_strip_vct_defaults(v) for v in vcts]
            doc["spec"] = spec

    # DaemonSet: updateStrategy defaults
    if kind == "DaemonSet":
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            spec = dict(spec)
            us = spec.get("updateStrategy", {})
            if isinstance(us, dict) and us.get("type") == "RollingUpdate":
                rolling = us.get("rollingUpdate", {})
                if (
                    not rolling
                    or rolling == {"maxSurge": 0, "maxUnavailable": 1}
                    or rolling == {"maxUnavailable": 1}
                ):
                    spec.pop("updateStrategy", None)
            doc["spec"] = spec

    # PersistentVolumeClaim: strip runtime-assigned fields
    if kind == "PersistentVolumeClaim":
        doc = dict(doc)
        spec = doc.get("spec", {})
        if isinstance(spec, dict):
            spec = dict(spec)
            # volumeMode defaults to Filesystem
            if spec.get("volumeMode") == "Filesystem":
                spec.pop("volumeMode")
            # volumeName is assigned at bind time
            spec.pop("volumeName", None)
            doc["spec"] = spec

    # PriorityClass: preemptionPolicy defaults to PreemptLowerPriority
    if kind == "PriorityClass":
        doc = dict(doc)
        if doc.get("preemptionPolicy") == "PreemptLowerPriority":
            doc.pop("preemptionPolicy")

    # ClusterRole / Role: normalize RBAC rules for semantic comparison
    if kind in ("ClusterRole", "Role"):
        doc = _normalize_rbac_rules(doc)

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
        # Boolean pod-level defaults
        if pod_spec.get("hostIPC") is False:
            pod_spec.pop("hostIPC")
        if pod_spec.get("hostNetwork") is False:
            pod_spec.pop("hostNetwork")
        if pod_spec.get("hostPID") is False:
            pod_spec.pop("hostPID")
        if pod_spec.get("enableServiceLinks") is True:
            pod_spec.pop("enableServiceLinks")

        # Volume defaults
        for volume in pod_spec.get("volumes") or []:
            if not isinstance(volume, dict):
                continue
            # secret.defaultMode defaults to 420 (0644)
            secret = volume.get("secret")
            if isinstance(secret, dict) and secret.get("defaultMode") == 420:
                secret.pop("defaultMode")
            # configMap.defaultMode defaults to 420 (0644)
            config_map = volume.get("configMap")
            if isinstance(config_map, dict) and config_map.get("defaultMode") == 420:
                config_map.pop("defaultMode")
            # projected.defaultMode defaults to 420
            projected = volume.get("projected")
            if isinstance(projected, dict) and projected.get("defaultMode") == 420:
                projected.pop("defaultMode")
            # hostPath.type defaults to empty string
            host_path = volume.get("hostPath")
            if isinstance(host_path, dict) and host_path.get("type") == "":
                host_path.pop("type")

        # Container-level defaults
        for container in pod_spec.get("containers", []) + pod_spec.get(
            "initContainers", []
        ):
            if not isinstance(container, dict):
                continue
            container.pop("terminationMessagePath", None)
            container.pop("terminationMessagePolicy", None)
            container.pop("imagePullPolicy", None)

            # protocol defaults to TCP on container ports
            ports = container.get("ports")
            if isinstance(ports, list):
                container["ports"] = [
                    _strip_port_protocol_default(p) if isinstance(p, dict) else p
                    for p in ports
                ]

            # fieldRef.apiVersion defaults to "v1" in env vars
            env = container.get("env")
            if isinstance(env, list):
                for env_var in env:
                    if not isinstance(env_var, dict):
                        continue
                    vf = env_var.get("valueFrom")
                    if isinstance(vf, dict):
                        fr = vf.get("fieldRef")
                        if isinstance(fr, dict) and fr.get("apiVersion") == "v1":
                            fr.pop("apiVersion")

            # Probe defaults
            for probe_key in ("livenessProbe", "readinessProbe", "startupProbe"):
                probe = container.get(probe_key)
                if not isinstance(probe, dict):
                    continue
                # successThreshold defaults to 1
                if probe.get("successThreshold") == 1:
                    probe.pop("successThreshold")
                # failureThreshold defaults to 3
                if probe.get("failureThreshold") == 3:
                    probe.pop("failureThreshold")
                # periodSeconds defaults to 10
                if probe.get("periodSeconds") == 10:
                    probe.pop("periodSeconds")
                # timeoutSeconds defaults to 1
                if probe.get("timeoutSeconds") == 1:
                    probe.pop("timeoutSeconds")
                # initialDelaySeconds defaults to 0
                if probe.get("initialDelaySeconds") == 0:
                    probe.pop("initialDelaySeconds")
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


def _strip_port_protocol_default(port: dict) -> dict:
    """Strip protocol: TCP from a port dict (it's the K8s default)."""
    if port.get("protocol") == "TCP":
        port = dict(port)
        port.pop("protocol")
    return port


def _strip_vct_defaults(vct: Any) -> Any:
    """Strip server-side defaults from a VolumeClaimTemplate."""
    if not isinstance(vct, dict):
        return vct
    vct = dict(vct)
    # K8s adds apiVersion and kind to VCTs in responses
    vct.pop("apiVersion", None)
    vct.pop("kind", None)
    # status is server-side
    vct.pop("status", None)
    # volumeMode defaults to Filesystem
    spec = vct.get("spec")
    if isinstance(spec, dict):
        spec = dict(spec)
        if spec.get("volumeMode") == "Filesystem":
            spec.pop("volumeMode")
        vct["spec"] = spec
    return vct


def _normalize_rbac_rules(doc: dict) -> dict:
    """Normalize RBAC rules for semantic comparison.

    The kix `grant` function merges rules that share apiGroups+verbs into
    one rule with combined resources. Helm keeps them separate. Both are
    semantically equivalent. This normalizes to a canonical merged form.
    """
    rules = doc.get("rules")
    if not isinstance(rules, list) or not rules:
        return doc

    # Expand all rules into atomic (apiGroups, resources, verbs, resourceNames) and re-merge
    # Group key: (sorted apiGroups, sorted verbs, sorted resourceNames)
    merged: dict[tuple, set] = {}
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        api_groups = tuple(sorted(rule.get("apiGroups", [])))
        verbs = tuple(sorted(rule.get("verbs", [])))
        resource_names = tuple(sorted(rule.get("resourceNames", [])))
        non_resource_urls = tuple(sorted(rule.get("nonResourceURLs", [])))
        resources = rule.get("resources", [])

        # Non-resource URL rules don't have resources/apiGroups
        if non_resource_urls:
            key = ("nonres", non_resource_urls, verbs)
            merged.setdefault(key, set())
            # nothing to merge for nonResourceURL rules
        else:
            key = ("res", api_groups, verbs, resource_names)
            merged.setdefault(key, set()).update(resources)

    # Rebuild rules in canonical order
    canonical = []
    for key, resources in sorted(merged.items()):
        if key[0] == "nonres":
            _, urls, verbs = key
            canonical.append(
                {
                    "nonResourceURLs": list(urls),
                    "verbs": list(verbs),
                }
            )
        else:
            _, api_groups, verbs, resource_names = key
            rule = {
                "apiGroups": list(api_groups),
                "resources": sorted(resources),
                "verbs": list(verbs),
            }
            if resource_names:
                rule["resourceNames"] = list(resource_names)
            canonical.append(rule)

    doc = dict(doc)
    doc["rules"] = canonical
    return doc


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
        annotations = metadata.get("annotations") or {}
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
            k: normalize_text(v) if isinstance(v, str) else v for k, v in data.items()
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


# Sort key functions for dict arrays where ordering is not semantically significant.
_SORT_DICT_ARRAYS: dict[str, Any] = {
    "ports": lambda p: (p.get("name", ""), p.get("containerPort", 0), p.get("port", 0)),
    "env": lambda e: e.get("name", ""),
    "envFrom": lambda e: str(e),
    "volumeMounts": lambda vm: vm.get("mountPath", ""),
    "volumes": lambda vol: vol.get("name", ""),
    "containers": lambda c: c.get("name", ""),
    "initContainers": lambda c: c.get("name", ""),
    # RBAC rules by apiGroups, Ingress rules by host — both work via the tuple fallback
    "rules": lambda r: (str(sorted(r.get("apiGroups", []))), r.get("host", "")),
    "hostAliases": lambda h: h.get("ip", ""),
    "webhooks": lambda w: w.get("name", ""),
    "topologySpreadConstraints": lambda t: t.get("topologyKey", ""),
    "tolerations": lambda t: (
        t.get("key", ""),
        t.get("operator", ""),
        t.get("effect", ""),
    ),
    "imagePullSecrets": lambda s: s.get("name", ""),
    "groups": lambda g: g.get("name", ""),
    "volumeClaimTemplates": lambda v: v.get("metadata", {}).get("name", ""),
    "subjects": lambda s: (s.get("kind", ""), s.get("name", "")),
    "ownerReferences": lambda o: (o.get("kind", ""), o.get("name", "")),
}

# String/scalar array fields where ordering is not semantically significant.
_SORT_SCALAR_ARRAYS = {
    "accessModes",
}


def _sort_arrays(obj: Any) -> Any:
    """Sort arrays where ordering is not semantically significant."""
    if isinstance(obj, dict):
        result = {}
        for k, v in obj.items():
            if isinstance(v, list) and v:
                if isinstance(v[0], dict) and k in _SORT_DICT_ARRAYS:
                    result[k] = sorted(
                        (_sort_arrays(item) for item in v),
                        key=_SORT_DICT_ARRAYS[k],
                    )
                elif k in _SORT_SCALAR_ARRAYS and all(isinstance(x, str) for x in v):
                    result[k] = sorted(v)
                else:
                    result[k] = _sort_arrays(v)
            else:
                result[k] = _sort_arrays(v)
        return result
    elif isinstance(obj, list):
        return [_sort_arrays(item) for item in obj]
    return obj


def strip_port_names(doc: dict) -> dict:
    """Strip 'name' field from container and service ports so named vs unnamed ports compare equal."""
    # Container ports
    pod_specs = _find_pod_specs(doc)
    for pod_spec in pod_specs:
        for container in pod_spec.get("containers", []) + pod_spec.get(
            "initContainers", []
        ):
            if not isinstance(container, dict):
                continue
            ports = container.get("ports")
            if isinstance(ports, list):
                container["ports"] = [
                    {k: v for k, v in p.items() if k != "name"}
                    for p in ports
                    if isinstance(p, dict)
                ]
    # Service ports
    if doc.get("kind") == "Service":
        spec = doc.get("spec", {})
        ports = spec.get("ports")
        if isinstance(ports, list):
            spec["ports"] = [
                {k: v for k, v in p.items() if k != "name"}
                for p in ports
                if isinstance(p, dict)
            ]
    return doc


def normalize_dns_suffix(doc: dict) -> dict:
    """Replace FQDN service DNS names with short names in all string values."""
    return _walk_strings(doc, _shorten_fqdn)


_FQDN_RE = re.compile(
    r"([a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\.(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\.svc\.[a-z0-9][\w.-]*"
)


def _shorten_fqdn(s: str) -> str:
    return _FQDN_RE.sub(r"\1", s)


def _walk_strings(obj: Any, fn) -> Any:
    """Apply fn to every string value in a nested dict/list structure."""
    if isinstance(obj, str):
        return fn(obj)
    if isinstance(obj, dict):
        return {k: _walk_strings(v, fn) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_walk_strings(item, fn) for item in obj]
    return obj


def resource_key(doc: dict) -> str:
    """Generate a comparison key from kind + namespace + name."""
    kind = doc.get("kind", "Unknown")
    ns = doc.get("metadata", {}).get("namespace", "_cluster")
    name = doc.get("metadata", {}).get("name", "unknown")
    return f"{kind}/{ns}/{name}"
