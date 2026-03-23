//! Manifest normalization pipeline.
//!
//! Ports scripts/parity/normalize.py. Strips server-side fields, cosmetic differences,
//! and noise so behavioral comparison focuses on what actually matters.

use serde_json::{Map, Value};

// --- Server-side metadata fields K8s adds ---

const STRIP_METADATA_KEYS: &[&str] = &[
    "uid",
    "resourceVersion",
    "creationTimestamp",
    "generation",
    "selfLink",
    "managedFields",
    "finalizers",
];

// Annotations K8s or controllers add at runtime
const STRIP_ANNOTATIONS: &[&str] = &[
    "kubectl.kubernetes.io/last-applied-configuration",
    "deployment.kubernetes.io/revision",
    "pv.kubernetes.io/bind-completed",
    "pv.kubernetes.io/bound-by-controller",
    "deprecated.daemonset.template.generation",
];

// Annotation prefixes — any annotation starting with these is stripped from cluster side
const STRIP_ANNOTATION_PREFIXES: &[&str] = &[
    "control-plane.alpha.kubernetes.io/",
    "autoscaling.alpha.kubernetes.io/",
    "endpoints.kubernetes.io/",
    "meta.helm.sh/",
    "checksum/",
];

// Labels stripped from both sides
const STRIP_LABELS: &[&str] = &[
    "build.kix.dev/hash",
    "app.kubernetes.io/managed-by",
    "app.kubernetes.io/instance",
    "app.kubernetes.io/part-of",
    "app.kubernetes.io/version",
    "app.kubernetes.io/component",
    "app.kubernetes.io/name",
    "kubernetes.io/metadata.name",
    "cluster",
    "team",
    "app",
    "app.kubernetes.io/created-by",
    "chart",
    "heritage",
    "release",
    "component",
];

// Label prefixes stripped from both sides
const STRIP_LABEL_PREFIXES: &[&str] = &["helm.sh/", "meta.helm.sh/"];

// Annotation prefixes kix adds for build metadata
const STRIP_KIX_ANNOTATION_PREFIXES: &[&str] = &["build.kix.dev/"];

/// Normalize a live cluster resource for behavioral comparison.
pub fn normalize_cluster(mut doc: Value) -> Value {
    if !doc.is_object() {
        return doc;
    }
    strip_server_fields(&mut doc);
    strip_secret_data(&mut doc);
    strip_labels_and_annotations(&mut doc, true);
    strip_k8s_defaults(&mut doc);
    strip_empty_fields_inplace(&mut doc);
    normalize_configmap_data(&mut doc);
    normalize_paths(&mut doc);
    sort_arrays(&mut doc);
    doc
}

/// Normalize a kix-built resource for behavioral comparison.
pub fn normalize_kix(mut doc: Value) -> Value {
    if !doc.is_object() {
        return doc;
    }
    strip_secret_data(&mut doc);
    strip_labels_and_annotations(&mut doc, false);
    strip_k8s_defaults(&mut doc);
    strip_empty_fields_inplace(&mut doc);
    normalize_configmap_data(&mut doc);
    normalize_paths(&mut doc);
    sort_arrays(&mut doc);
    doc
}

/// Remove server-side metadata fields from a cluster resource.
pub fn strip_server_fields(doc: &mut Value) {
    let obj = match doc.as_object_mut() {
        Some(o) => o,
        None => return,
    };

    // Strip top-level status
    obj.remove("status");

    // Strip server-side metadata fields
    if let Some(Value::Object(metadata)) = obj.get_mut("metadata") {
        for key in STRIP_METADATA_KEYS {
            metadata.remove(*key);
        }
    }
}

/// Strip data/stringData from Secret resources (keep metadata + type for comparison).
pub fn strip_secret_data(doc: &mut Value) {
    if doc.pointer("/kind").and_then(|v| v.as_str()) != Some("Secret") {
        return;
    }
    if let Some(obj) = doc.as_object_mut() {
        obj.remove("data");
        obj.remove("stringData");
    }
}

/// Remove cosmetic labels and annotations from all metadata locations.
pub fn strip_labels_and_annotations(doc: &mut Value, cluster: bool) {
    let metadata_blocks = find_metadata_blocks(doc);
    for meta in metadata_blocks {
        // Strip labels
        if let Some(Value::Object(labels)) = meta.get_mut("labels") {
            labels.retain(|key, _| {
                if STRIP_LABELS.contains(&key.as_str()) {
                    return false;
                }
                for prefix in STRIP_LABEL_PREFIXES {
                    if key.starts_with(prefix) {
                        return false;
                    }
                }
                true
            });
            if labels.is_empty() {
                // Mark for removal
            }
        }
        // Remove empty labels
        if meta
            .get("labels")
            .and_then(|v| v.as_object())
            .is_some_and(|m| m.is_empty())
        {
            meta.remove("labels");
        }

        // Strip annotations
        if let Some(Value::Object(annotations)) = meta.get_mut("annotations") {
            let annotation_prefixes = if cluster {
                STRIP_ANNOTATION_PREFIXES
            } else {
                STRIP_KIX_ANNOTATION_PREFIXES
            };
            annotations.retain(|key, _| {
                if STRIP_ANNOTATIONS.contains(&key.as_str()) {
                    return false;
                }
                for prefix in annotation_prefixes {
                    if key.starts_with(prefix) {
                        return false;
                    }
                }
                true
            });
        }
        // Remove empty annotations
        if meta
            .get("annotations")
            .and_then(|v| v.as_object())
            .is_some_and(|m| m.is_empty())
        {
            meta.remove("annotations");
        }
    }
}

/// Find all metadata dicts (as mutable references). Returns them collected
/// to avoid borrow issues — we collect pointers via indices.
fn find_metadata_blocks(doc: &mut Value) -> Vec<&mut Map<String, Value>> {
    // We need to collect metadata blocks from multiple locations.
    // Due to borrow checker constraints, we use raw pointer tricks safely.
    let mut ptrs: Vec<*mut Map<String, Value>> = Vec::new();

    if let Some(obj) = doc.as_object_mut() {
        // Top-level metadata
        if let Some(Value::Object(meta)) = obj.get_mut("metadata") {
            ptrs.push(meta as *mut _);
        }

        // spec.template.metadata (Deployment/StatefulSet/DaemonSet/Job)
        if let Some(Value::Object(spec)) = obj.get_mut("spec") {
            if let Some(Value::Object(template)) = spec.get_mut("template")
                && let Some(Value::Object(meta)) = template.get_mut("metadata")
            {
                ptrs.push(meta as *mut _);
            }
            // spec.volumeClaimTemplates[].metadata
            if let Some(Value::Array(vcts)) = spec.get_mut("volumeClaimTemplates") {
                for vct in vcts.iter_mut() {
                    if let Some(vct_obj) = vct.as_object_mut()
                        && let Some(Value::Object(meta)) = vct_obj.get_mut("metadata")
                    {
                        ptrs.push(meta as *mut _);
                    }
                }
            }
            // spec.jobTemplate.spec.template.metadata (CronJob)
            if let Some(Value::Object(job_template)) = spec.get_mut("jobTemplate")
                && let Some(Value::Object(jt_spec)) = job_template.get_mut("spec")
                && let Some(Value::Object(template)) = jt_spec.get_mut("template")
                && let Some(Value::Object(meta)) = template.get_mut("metadata")
            {
                ptrs.push(meta as *mut _);
            }
        }
    }

    // SAFETY: All pointers are derived from non-overlapping sub-fields of `doc`,
    // and `doc` is borrowed mutably for the entire duration.
    ptrs.into_iter().map(|p| unsafe { &mut *p }).collect()
}

/// Strip fields that K8s adds as defaults.
pub fn strip_k8s_defaults(doc: &mut Value) {
    let kind = doc
        .pointer("/kind")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let obj = match doc.as_object_mut() {
        Some(o) => o,
        None => return,
    };

    // Namespace: spec.finalizers is server-managed
    if kind == "Namespace" {
        if let Some(Value::Object(spec)) = obj.get_mut("spec") {
            spec.remove("finalizers");
            if spec.is_empty() {
                obj.remove("spec");
            }
        }
        // Strip auto-added "name" label
        if let Some(Value::Object(meta)) = obj.get_mut("metadata")
            && let Some(Value::Object(labels)) = meta.get_mut("labels")
        {
            labels.remove("name");
        }
    }

    // CRD: spec.conversion defaults to {strategy: None}
    if kind == "CustomResourceDefinition"
        && let Some(Value::Object(spec)) = obj.get_mut("spec")
    {
        let should_remove = match spec.get("conversion") {
            Some(Value::Object(conv)) => {
                conv.len() == 1 && conv.get("strategy").and_then(|v| v.as_str()) == Some("None")
            }
            Some(Value::Null) | None => true,
            _ => false,
        };
        if should_remove {
            spec.remove("conversion");
        }
    }

    // Deployments / StatefulSets / DaemonSets
    if matches!(kind.as_str(), "Deployment" | "StatefulSet" | "DaemonSet")
        && let Some(Value::Object(spec)) = obj.get_mut("spec")
    {
        spec.remove("progressDeadlineSeconds");
        spec.remove("revisionHistoryLimit");
        // Default RollingUpdate strategy
        let should_remove_strategy = if let Some(Value::Object(strategy)) = spec.get("strategy") {
            strategy.get("type").and_then(|v| v.as_str()) == Some("RollingUpdate")
                && match strategy.get("rollingUpdate") {
                    Some(Value::Object(ru)) => {
                        ru.len() == 2
                            && ru.get("maxSurge").and_then(|v| v.as_str()) == Some("25%")
                            && ru.get("maxUnavailable").and_then(|v| v.as_str()) == Some("25%")
                    }
                    _ => false,
                }
        } else {
            false
        };
        if should_remove_strategy {
            spec.remove("strategy");
        }
    }

    // PersistentVolumeClaim
    if kind == "PersistentVolumeClaim"
        && let Some(Value::Object(spec)) = obj.get_mut("spec")
    {
        if spec.get("volumeMode").and_then(|v| v.as_str()) == Some("Filesystem") {
            spec.remove("volumeMode");
        }
        spec.remove("volumeName");
    }

    // Pod spec defaults
    strip_pod_spec_defaults(obj);

    // Webhooks
    if matches!(
        kind.as_str(),
        "MutatingWebhookConfiguration" | "ValidatingWebhookConfiguration"
    ) && let Some(Value::Array(webhooks)) = obj.get_mut("webhooks")
    {
        for wh in webhooks.iter_mut() {
            if let Some(wh_obj) = wh.as_object_mut() {
                // Strip caBundle from clientConfig
                if let Some(Value::Object(cc)) = wh_obj.get_mut("clientConfig") {
                    cc.remove("caBundle");
                }
                // K8s defaults
                wh_obj.remove("reinvocationPolicy");
                wh_obj.remove("timeoutSeconds");
                // rules[].scope defaults to '*'
                if let Some(Value::Array(rules)) = wh_obj.get_mut("rules") {
                    for rule in rules.iter_mut() {
                        if let Some(r) = rule.as_object_mut()
                            && r.get("scope").and_then(|v| v.as_str()) == Some("*")
                        {
                            r.remove("scope");
                        }
                    }
                }
                // clientConfig.service.port defaults to 443
                if let Some(Value::Object(cc)) = wh_obj.get_mut("clientConfig")
                    && let Some(Value::Object(svc)) = cc.get_mut("service")
                    && svc.get("port").and_then(|v| v.as_u64()) == Some(443)
                {
                    svc.remove("port");
                }
            }
        }
    }
}

/// Strip K8s-defaulted fields from pod specs embedded in any resource.
fn strip_pod_spec_defaults(obj: &mut Map<String, Value>) {
    let kind = obj
        .get("kind")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let mut pod_spec_ptrs: Vec<*mut Map<String, Value>> = Vec::new();

    // Deployment/StatefulSet/DaemonSet/Job: spec.template.spec
    if let Some(Value::Object(spec)) = obj.get_mut("spec") {
        if let Some(Value::Object(template)) = spec.get_mut("template")
            && let Some(Value::Object(pod_spec)) = template.get_mut("spec")
        {
            pod_spec_ptrs.push(pod_spec as *mut _);
        }
        // CronJob: spec.jobTemplate.spec.template.spec
        if let Some(Value::Object(jt)) = spec.get_mut("jobTemplate")
            && let Some(Value::Object(jt_spec)) = jt.get_mut("spec")
            && let Some(Value::Object(template)) = jt_spec.get_mut("template")
            && let Some(Value::Object(pod_spec)) = template.get_mut("spec")
        {
            pod_spec_ptrs.push(pod_spec as *mut _);
        }
    }

    // Pod directly
    if kind == "Pod"
        && let Some(Value::Object(spec)) = obj.get_mut("spec")
    {
        pod_spec_ptrs.push(spec as *mut _);
    }

    for ptr in pod_spec_ptrs {
        // SAFETY: Non-overlapping sub-fields of obj
        let pod_spec = unsafe { &mut *ptr };

        pod_spec.remove("dnsPolicy");
        pod_spec.remove("restartPolicy");
        pod_spec.remove("schedulerName");
        pod_spec.remove("terminationGracePeriodSeconds");
        pod_spec.remove("serviceAccount");

        // Container-level defaults
        for container_key in &["containers", "initContainers"] {
            if let Some(Value::Array(containers)) = pod_spec.get_mut(*container_key) {
                for container in containers.iter_mut() {
                    if let Some(c) = container.as_object_mut() {
                        c.remove("terminationMessagePath");
                        c.remove("terminationMessagePolicy");
                        c.remove("imagePullPolicy");

                        // Probe defaults
                        for probe_key in &["livenessProbe", "readinessProbe", "startupProbe"] {
                            if let Some(Value::Object(probe)) = c.get_mut(*probe_key) {
                                if probe.get("successThreshold").and_then(|v| v.as_u64()) == Some(1)
                                {
                                    probe.remove("successThreshold");
                                }
                                if let Some(Value::Object(http_get)) = probe.get_mut("httpGet")
                                    && http_get.get("scheme").and_then(|v| v.as_str())
                                        == Some("HTTP")
                                {
                                    http_get.remove("scheme");
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Remove null values, empty dicts, and empty lists recursively.
pub fn strip_empty_fields_inplace(val: &mut Value) {
    match val {
        Value::Object(map) => {
            for v in map.values_mut() {
                strip_empty_fields_inplace(v);
            }
            map.retain(|_, v| !v.is_null());
            map.retain(|_, v| !matches!(v, Value::Object(m) if m.is_empty()));
            map.retain(|_, v| !matches!(v, Value::Array(a) if a.is_empty()));
        }
        Value::Array(arr) => {
            for item in arr.iter_mut() {
                strip_empty_fields_inplace(item);
            }
        }
        _ => {}
    }
}

/// Normalize whitespace in ConfigMap data values.
pub fn normalize_configmap_data(doc: &mut Value) {
    if doc.pointer("/kind").and_then(|v| v.as_str()) != Some("ConfigMap") {
        return;
    }
    if let Some(Value::Object(data)) = doc.as_object_mut().and_then(|obj| obj.get_mut("data")) {
        for v in data.values_mut() {
            if let Some(s) = v.as_str() {
                let normalized = normalize_text(s);
                *v = Value::String(normalized);
            }
        }
    }
}

fn normalize_text(s: &str) -> String {
    let lines: Vec<&str> = s.lines().map(|l| l.trim_end()).collect();
    let joined = lines.join("\n");
    // Collapse multiple consecutive newlines into one
    let mut result = String::with_capacity(joined.len());
    let mut prev_newline = false;
    for ch in joined.chars() {
        if ch == '\n' {
            if !prev_newline {
                result.push('\n');
            }
            prev_newline = true;
        } else {
            prev_newline = false;
            result.push(ch);
        }
    }
    result.trim().to_string()
}

/// Strip trailing slashes from mount paths.
pub fn normalize_paths(val: &mut Value) {
    match val {
        Value::Object(map) => {
            for (k, v) in map.iter_mut() {
                if k == "mountPath" {
                    if let Some(s) = v.as_str()
                        && s.len() > 1
                    {
                        let trimmed = s.trim_end_matches('/');
                        if trimmed != s {
                            *v = Value::String(trimmed.to_string());
                        }
                    }
                } else {
                    normalize_paths(v);
                }
            }
        }
        Value::Array(arr) => {
            for item in arr.iter_mut() {
                normalize_paths(item);
            }
        }
        _ => {}
    }
}

/// Sort arrays where ordering is not semantically significant.
pub fn sort_arrays(val: &mut Value) {
    match val {
        Value::Object(map) => {
            for (k, v) in map.iter_mut() {
                match k.as_str() {
                    "ports" => sort_array_of_objects(v, |obj| {
                        let name = obj.get("name").and_then(|v| v.as_str()).unwrap_or("");
                        let container_port = obj
                            .get("containerPort")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0);
                        let port = obj.get("port").and_then(|v| v.as_i64()).unwrap_or(0);
                        format!("{}\x00{:010}\x00{:010}", name, container_port, port)
                    }),
                    "env" => sort_array_of_objects(v, |obj| {
                        obj.get("name")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string()
                    }),
                    "envFrom" => {
                        sort_array_of_objects(v, |obj| format!("{}", Value::Object(obj.clone())))
                    }
                    "volumeMounts" => sort_array_of_objects(v, |obj| {
                        obj.get("mountPath")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string()
                    }),
                    "volumes" | "containers" | "initContainers" => {
                        sort_array_of_objects(v, |obj| {
                            obj.get("name")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string()
                        })
                    }
                    "rules" => sort_array_of_objects(v, |obj| {
                        let mut groups: Vec<String> = obj
                            .get("apiGroups")
                            .and_then(|v| v.as_array())
                            .map(|a| {
                                a.iter()
                                    .filter_map(|v| v.as_str().map(String::from))
                                    .collect()
                            })
                            .unwrap_or_default();
                        groups.sort();
                        format!("{:?}", groups)
                    }),
                    "hostAliases" => sort_array_of_objects(v, |obj| {
                        obj.get("ip")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string()
                    }),
                    _ => sort_arrays(v),
                }
            }
        }
        Value::Array(arr) => {
            for item in arr.iter_mut() {
                sort_arrays(item);
            }
        }
        _ => {}
    }
}

/// Sort an array of objects by a key function. Recurses into each element first.
fn sort_array_of_objects<F>(val: &mut Value, key_fn: F)
where
    F: Fn(&Map<String, Value>) -> String,
{
    if let Value::Array(arr) = val {
        // First recurse into each element
        for item in arr.iter_mut() {
            sort_arrays(item);
        }
        // Then sort if all elements are objects
        if arr.iter().all(|v| v.is_object()) {
            arr.sort_by(|a, b| {
                let ka = a.as_object().map(&key_fn).unwrap_or_default();
                let kb = b.as_object().map(&key_fn).unwrap_or_default();
                ka.cmp(&kb)
            });
        }
    } else {
        sort_arrays(val);
    }
}

/// Strip 'name' field from container and service ports.
pub fn strip_port_names(doc: &mut Value) {
    let kind = doc
        .pointer("/kind")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // Container ports in pod specs
    let obj = match doc.as_object_mut() {
        Some(o) => o,
        None => return,
    };

    // Find pod specs and strip port names
    if let Some(Value::Object(spec)) = obj.get_mut("spec") {
        // spec.template.spec (Deployment etc.)
        if let Some(pod_spec) = spec
            .get_mut("template")
            .and_then(|t| t.get_mut("spec"))
            .and_then(|s| s.as_object_mut())
        {
            strip_port_names_from_containers(pod_spec);
        }
        // CronJob
        if let Some(pod_spec) = spec
            .get_mut("jobTemplate")
            .and_then(|jt| jt.get_mut("spec"))
            .and_then(|s| s.get_mut("template"))
            .and_then(|t| t.get_mut("spec"))
            .and_then(|s| s.as_object_mut())
        {
            strip_port_names_from_containers(pod_spec);
        }
        // Service ports
        if kind == "Service"
            && let Some(Value::Array(ports)) = spec.get_mut("ports")
        {
            for port in ports.iter_mut() {
                if let Some(p) = port.as_object_mut() {
                    p.remove("name");
                }
            }
        }
    }

    // Pod directly
    if kind == "Pod"
        && let Some(Value::Object(spec)) = obj.get_mut("spec")
    {
        strip_port_names_from_containers(spec);
    }
}

fn strip_port_names_from_containers(pod_spec: &mut Map<String, Value>) {
    for key in &["containers", "initContainers"] {
        if let Some(Value::Array(containers)) = pod_spec.get_mut(*key) {
            for container in containers.iter_mut() {
                if let Some(c) = container.as_object_mut()
                    && let Some(Value::Array(ports)) = c.get_mut("ports")
                {
                    for port in ports.iter_mut() {
                        if let Some(p) = port.as_object_mut() {
                            p.remove("name");
                        }
                    }
                }
            }
        }
    }
}

/// Replace FQDN service DNS names with short names in all string values.
pub fn normalize_dns_suffix(val: &mut Value) {
    walk_strings(val, &shorten_fqdn);
}

fn shorten_fqdn(s: &str) -> String {
    // Match pattern: svcname.namespace.svc.cluster-domain
    // Replace with just the service name
    let mut result = String::with_capacity(s.len());
    let mut remaining = s;

    while !remaining.is_empty() {
        if let Some(replacement) = try_match_fqdn(remaining) {
            result.push_str(&replacement.0);
            remaining = &remaining[replacement.1..];
        } else {
            // Advance one character
            let ch = remaining.chars().next().unwrap();
            result.push(ch);
            remaining = &remaining[ch.len_utf8()..];
        }
    }
    result
}

/// Try to match an FQDN at the start of `s`.
/// Returns (service_name, bytes_consumed) if matched.
fn try_match_fqdn(s: &str) -> Option<(String, usize)> {
    fn is_label_char(c: char) -> bool {
        c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'
    }

    fn parse_dns_label(s: &str) -> Option<(&str, &str)> {
        // Must start with [a-z0-9]
        let first = s.chars().next()?;
        if !first.is_ascii_lowercase() && !first.is_ascii_digit() {
            return None;
        }
        let end = s
            .char_indices()
            .take_while(|(_, c)| is_label_char(*c))
            .last()
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(0);
        if end == 0 {
            return None;
        }
        // Must not end with '-'
        if s.as_bytes()[end - 1] == b'-' {
            return None;
        }
        Some((&s[..end], &s[end..]))
    }

    // Parse: svcname.namespace.svc.cluster-domain
    let (svc_name, rest) = parse_dns_label(s)?;
    let rest = rest.strip_prefix('.')?;
    let (_ns, rest) = parse_dns_label(rest)?;
    let rest = rest.strip_prefix('.')?;
    let rest = rest.strip_prefix("svc.")?;
    // Must have at least one more label char for cluster domain
    let first_domain = rest.chars().next()?;
    if !first_domain.is_ascii_lowercase() && !first_domain.is_ascii_digit() {
        return None;
    }
    // Consume the rest of the cluster domain (word chars, dots, hyphens)
    let domain_end = rest
        .char_indices()
        .take_while(|(_, c)| c.is_ascii_alphanumeric() || *c == '.' || *c == '-' || *c == '_')
        .last()
        .map(|(i, c)| i + c.len_utf8())
        .unwrap_or(0);

    let total_consumed = svc_name.len() + 1 + // svcname.
        s[svc_name.len() + 1..].len()
        - rest[domain_end..].len(); // namespace.svc.domain

    Some((svc_name.to_string(), total_consumed))
}

fn walk_strings(val: &mut Value, f: &dyn Fn(&str) -> String) {
    match val {
        Value::String(s) => {
            let new = f(s);
            if new != *s {
                *s = new;
            }
        }
        Value::Object(map) => {
            for v in map.values_mut() {
                walk_strings(v, f);
            }
        }
        Value::Array(arr) => {
            for item in arr.iter_mut() {
                walk_strings(item, f);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // --- strip_server_fields ---

    #[test]
    fn strip_server_fields_removes_status_and_metadata() {
        let mut doc = json!({
            "kind": "Deployment",
            "status": {"replicas": 3},
            "metadata": {
                "name": "test",
                "uid": "abc-123",
                "resourceVersion": "456",
                "creationTimestamp": "2024-01-01T00:00:00Z",
                "generation": 5,
                "selfLink": "/api/v1/...",
                "managedFields": [{"manager": "kubectl"}],
                "finalizers": ["foregroundDeletion"],
                "labels": {"app": "test"}
            }
        });
        strip_server_fields(&mut doc);
        assert!(doc.get("status").is_none());
        let meta = doc.get("metadata").unwrap().as_object().unwrap();
        assert_eq!(meta.get("name").unwrap(), "test");
        assert!(meta.get("uid").is_none());
        assert!(meta.get("resourceVersion").is_none());
        assert!(meta.get("creationTimestamp").is_none());
        assert!(meta.get("generation").is_none());
        assert!(meta.get("selfLink").is_none());
        assert!(meta.get("managedFields").is_none());
        assert!(meta.get("finalizers").is_none());
        assert_eq!(meta.get("labels").unwrap(), &json!({"app": "test"}));
    }

    // --- strip_secret_data ---

    #[test]
    fn strip_secret_data_removes_data_and_stringdata() {
        let mut doc = json!({
            "kind": "Secret",
            "metadata": {"name": "my-secret"},
            "type": "Opaque",
            "data": {"key": "dmFsdWU="},
            "stringData": {"plain": "value"}
        });
        strip_secret_data(&mut doc);
        assert!(doc.get("data").is_none());
        assert!(doc.get("stringData").is_none());
        assert_eq!(doc["type"], "Opaque");
        assert_eq!(doc["metadata"]["name"], "my-secret");
    }

    #[test]
    fn strip_secret_data_ignores_non_secret() {
        let mut doc = json!({
            "kind": "ConfigMap",
            "data": {"key": "value"}
        });
        strip_secret_data(&mut doc);
        assert!(doc.get("data").is_some());
    }

    // --- strip_labels_and_annotations ---

    #[test]
    fn strip_labels_cluster_side() {
        let mut doc = json!({
            "metadata": {
                "labels": {
                    "app": "test",
                    "app.kubernetes.io/name": "test",
                    "custom-label": "keep",
                    "helm.sh/chart": "test-1.0"
                }
            }
        });
        strip_labels_and_annotations(&mut doc, true);
        let labels = doc["metadata"]["labels"].as_object().unwrap();
        assert!(labels.get("app").is_none());
        assert!(labels.get("app.kubernetes.io/name").is_none());
        assert!(labels.get("helm.sh/chart").is_none());
        assert_eq!(labels.get("custom-label").unwrap(), "keep");
    }

    #[test]
    fn strip_annotations_cluster_side() {
        let mut doc = json!({
            "metadata": {
                "annotations": {
                    "kubectl.kubernetes.io/last-applied-configuration": "{}",
                    "deployment.kubernetes.io/revision": "1",
                    "meta.helm.sh/release-name": "test",
                    "custom-annotation": "keep"
                }
            }
        });
        strip_labels_and_annotations(&mut doc, true);
        let annotations = doc["metadata"]["annotations"].as_object().unwrap();
        assert!(
            annotations
                .get("kubectl.kubernetes.io/last-applied-configuration")
                .is_none()
        );
        assert!(
            annotations
                .get("deployment.kubernetes.io/revision")
                .is_none()
        );
        assert!(annotations.get("meta.helm.sh/release-name").is_none());
        assert_eq!(annotations.get("custom-annotation").unwrap(), "keep");
    }

    #[test]
    fn strip_annotations_kix_side() {
        let mut doc = json!({
            "metadata": {
                "annotations": {
                    "build.kix.dev/hash": "abc123",
                    "build.kix.dev/timestamp": "2024-01-01",
                    "custom-annotation": "keep"
                }
            }
        });
        strip_labels_and_annotations(&mut doc, false);
        let annotations = doc["metadata"]["annotations"].as_object().unwrap();
        assert!(annotations.get("build.kix.dev/hash").is_none());
        assert!(annotations.get("build.kix.dev/timestamp").is_none());
        assert_eq!(annotations.get("custom-annotation").unwrap(), "keep");
    }

    #[test]
    fn strip_labels_from_template_metadata() {
        let mut doc = json!({
            "kind": "Deployment",
            "metadata": {"labels": {"app": "test"}},
            "spec": {
                "template": {
                    "metadata": {
                        "labels": {"app": "test", "custom": "keep"}
                    }
                }
            }
        });
        strip_labels_and_annotations(&mut doc, true);
        assert!(doc.get("metadata").unwrap().get("labels").is_none()); // empty → removed
        let tmpl_labels = doc["spec"]["template"]["metadata"]["labels"]
            .as_object()
            .unwrap();
        assert!(tmpl_labels.get("app").is_none());
        assert_eq!(tmpl_labels.get("custom").unwrap(), "keep");
    }

    #[test]
    fn empty_labels_annotations_removed() {
        let mut doc = json!({
            "metadata": {
                "name": "test",
                "labels": {"app": "test"},
                "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{}"}
            }
        });
        strip_labels_and_annotations(&mut doc, true);
        assert!(doc["metadata"].get("labels").is_none());
        assert!(doc["metadata"].get("annotations").is_none());
    }

    // --- strip_k8s_defaults ---

    #[test]
    fn strip_namespace_defaults() {
        let mut doc = json!({
            "kind": "Namespace",
            "metadata": {
                "name": "test",
                "labels": {"name": "test", "custom": "keep"}
            },
            "spec": {"finalizers": ["kubernetes"]}
        });
        strip_k8s_defaults(&mut doc);
        assert!(doc.get("spec").is_none()); // spec removed after finalizers stripped
        let labels = doc["metadata"]["labels"].as_object().unwrap();
        assert!(labels.get("name").is_none());
        assert_eq!(labels.get("custom").unwrap(), "keep");
    }

    #[test]
    fn strip_crd_conversion_default() {
        let mut doc = json!({
            "kind": "CustomResourceDefinition",
            "spec": {
                "group": "example.com",
                "conversion": {"strategy": "None"}
            }
        });
        strip_k8s_defaults(&mut doc);
        assert!(doc["spec"].get("conversion").is_none());
        assert_eq!(doc["spec"]["group"], "example.com");
    }

    #[test]
    fn strip_deployment_defaults() {
        let mut doc = json!({
            "kind": "Deployment",
            "spec": {
                "replicas": 3,
                "progressDeadlineSeconds": 600,
                "revisionHistoryLimit": 10,
                "strategy": {
                    "type": "RollingUpdate",
                    "rollingUpdate": {
                        "maxSurge": "25%",
                        "maxUnavailable": "25%"
                    }
                }
            }
        });
        strip_k8s_defaults(&mut doc);
        let spec = doc["spec"].as_object().unwrap();
        assert!(spec.get("progressDeadlineSeconds").is_none());
        assert!(spec.get("revisionHistoryLimit").is_none());
        assert!(spec.get("strategy").is_none());
        assert_eq!(spec.get("replicas").unwrap(), 3);
    }

    #[test]
    fn strip_deployment_keeps_custom_strategy() {
        let mut doc = json!({
            "kind": "Deployment",
            "spec": {
                "strategy": {
                    "type": "RollingUpdate",
                    "rollingUpdate": {
                        "maxSurge": "50%",
                        "maxUnavailable": "0"
                    }
                }
            }
        });
        strip_k8s_defaults(&mut doc);
        assert!(doc["spec"].get("strategy").is_some());
    }

    #[test]
    fn strip_pvc_defaults() {
        let mut doc = json!({
            "kind": "PersistentVolumeClaim",
            "spec": {
                "accessModes": ["ReadWriteOnce"],
                "volumeMode": "Filesystem",
                "volumeName": "pvc-abc123"
            }
        });
        strip_k8s_defaults(&mut doc);
        let spec = doc["spec"].as_object().unwrap();
        assert!(spec.get("volumeMode").is_none());
        assert!(spec.get("volumeName").is_none());
        assert_eq!(spec["accessModes"], json!(["ReadWriteOnce"]));
    }

    #[test]
    fn strip_pod_spec_defaults_deployment() {
        let mut doc = json!({
            "kind": "Deployment",
            "spec": {
                "template": {
                    "spec": {
                        "dnsPolicy": "ClusterFirst",
                        "restartPolicy": "Always",
                        "schedulerName": "default-scheduler",
                        "terminationGracePeriodSeconds": 30,
                        "serviceAccount": "default",
                        "serviceAccountName": "default",
                        "containers": [{
                            "name": "app",
                            "image": "nginx",
                            "terminationMessagePath": "/dev/termination-log",
                            "terminationMessagePolicy": "File",
                            "imagePullPolicy": "Always",
                            "livenessProbe": {
                                "httpGet": {"path": "/health", "port": 8080, "scheme": "HTTP"},
                                "successThreshold": 1,
                                "failureThreshold": 3
                            }
                        }]
                    }
                }
            }
        });
        strip_k8s_defaults(&mut doc);
        let pod = &doc["spec"]["template"]["spec"];
        assert!(pod.get("dnsPolicy").is_none());
        assert!(pod.get("restartPolicy").is_none());
        assert!(pod.get("schedulerName").is_none());
        assert!(pod.get("terminationGracePeriodSeconds").is_none());
        assert!(pod.get("serviceAccount").is_none());
        assert_eq!(pod["serviceAccountName"], "default");

        let container = &pod["containers"][0];
        assert!(container.get("terminationMessagePath").is_none());
        assert!(container.get("terminationMessagePolicy").is_none());
        assert!(container.get("imagePullPolicy").is_none());

        let probe = &container["livenessProbe"];
        assert!(probe.get("successThreshold").is_none());
        assert_eq!(probe["failureThreshold"], 3);
        assert!(probe["httpGet"].get("scheme").is_none());
    }

    #[test]
    fn strip_webhook_defaults() {
        let mut doc = json!({
            "kind": "ValidatingWebhookConfiguration",
            "webhooks": [{
                "name": "test",
                "clientConfig": {
                    "caBundle": "base64data",
                    "service": {"name": "svc", "namespace": "ns", "port": 443}
                },
                "reinvocationPolicy": "Never",
                "timeoutSeconds": 10,
                "rules": [{"operations": ["CREATE"], "scope": "*"}]
            }]
        });
        strip_k8s_defaults(&mut doc);
        let wh = &doc["webhooks"][0];
        assert!(wh["clientConfig"].get("caBundle").is_none());
        assert!(wh["clientConfig"]["service"].get("port").is_none());
        assert!(wh.get("reinvocationPolicy").is_none());
        assert!(wh.get("timeoutSeconds").is_none());
        assert!(wh["rules"][0].get("scope").is_none());
    }

    // --- strip_empty_fields ---

    #[test]
    fn strip_empty_fields() {
        let mut doc = json!({
            "a": 1,
            "b": null,
            "c": {},
            "d": [],
            "e": {"f": null, "g": []},
            "h": "keep"
        });
        strip_empty_fields_inplace(&mut doc);
        let obj = doc.as_object().unwrap();
        assert_eq!(obj.len(), 2);
        assert_eq!(obj["a"], 1);
        assert_eq!(obj["h"], "keep");
    }

    // --- normalize_configmap_data ---

    #[test]
    fn normalize_configmap_whitespace() {
        let mut doc = json!({
            "kind": "ConfigMap",
            "data": {
                "config.yaml": "line1  \n\n\nline2  \nline3"
            }
        });
        normalize_configmap_data(&mut doc);
        assert_eq!(doc["data"]["config.yaml"], "line1\nline2\nline3");
    }

    #[test]
    fn normalize_configmap_ignores_non_configmap() {
        let mut doc = json!({
            "kind": "Secret",
            "data": {"key": "value  "}
        });
        normalize_configmap_data(&mut doc);
        assert_eq!(doc["data"]["key"], "value  ");
    }

    // --- normalize_paths ---

    #[test]
    fn normalize_trailing_slash() {
        let mut doc = json!({
            "spec": {
                "containers": [{
                    "volumeMounts": [
                        {"mountPath": "/data/", "name": "data"},
                        {"mountPath": "/", "name": "root"}
                    ]
                }]
            }
        });
        normalize_paths(&mut doc);
        assert_eq!(
            doc["spec"]["containers"][0]["volumeMounts"][0]["mountPath"],
            "/data"
        );
        // Root "/" stays as-is (len == 1)
        assert_eq!(
            doc["spec"]["containers"][0]["volumeMounts"][1]["mountPath"],
            "/"
        );
    }

    // --- sort_arrays ---

    #[test]
    fn sort_containers_by_name() {
        let mut doc = json!({
            "containers": [
                {"name": "sidecar", "image": "envoy"},
                {"name": "app", "image": "nginx"}
            ]
        });
        sort_arrays(&mut doc);
        assert_eq!(doc["containers"][0]["name"], "app");
        assert_eq!(doc["containers"][1]["name"], "sidecar");
    }

    #[test]
    fn sort_env_by_name() {
        let mut doc = json!({
            "env": [
                {"name": "Z_VAR", "value": "z"},
                {"name": "A_VAR", "value": "a"}
            ]
        });
        sort_arrays(&mut doc);
        assert_eq!(doc["env"][0]["name"], "A_VAR");
        assert_eq!(doc["env"][1]["name"], "Z_VAR");
    }

    #[test]
    fn sort_ports_by_name_then_port() {
        let mut doc = json!({
            "ports": [
                {"name": "https", "containerPort": 443},
                {"name": "http", "containerPort": 80}
            ]
        });
        sort_arrays(&mut doc);
        assert_eq!(doc["ports"][0]["name"], "http");
        assert_eq!(doc["ports"][1]["name"], "https");
    }

    #[test]
    fn sort_volumes_by_name() {
        let mut doc = json!({
            "volumes": [
                {"name": "config"},
                {"name": "certs"},
                {"name": "data"}
            ]
        });
        sort_arrays(&mut doc);
        assert_eq!(doc["volumes"][0]["name"], "certs");
        assert_eq!(doc["volumes"][1]["name"], "config");
        assert_eq!(doc["volumes"][2]["name"], "data");
    }

    #[test]
    fn sort_volume_mounts_by_mount_path() {
        let mut doc = json!({
            "volumeMounts": [
                {"mountPath": "/var/log", "name": "logs"},
                {"mountPath": "/etc/config", "name": "config"}
            ]
        });
        sort_arrays(&mut doc);
        assert_eq!(doc["volumeMounts"][0]["mountPath"], "/etc/config");
        assert_eq!(doc["volumeMounts"][1]["mountPath"], "/var/log");
    }

    // --- strip_port_names ---

    #[test]
    fn strip_port_names_from_deployment() {
        let mut doc = json!({
            "kind": "Deployment",
            "spec": {
                "template": {
                    "spec": {
                        "containers": [{
                            "name": "app",
                            "ports": [{"name": "http", "containerPort": 80, "protocol": "TCP"}]
                        }]
                    }
                }
            }
        });
        strip_port_names(&mut doc);
        let port = &doc["spec"]["template"]["spec"]["containers"][0]["ports"][0];
        assert!(port.get("name").is_none());
        assert_eq!(port["containerPort"], 80);
    }

    #[test]
    fn strip_port_names_from_service() {
        let mut doc = json!({
            "kind": "Service",
            "spec": {
                "ports": [{"name": "http", "port": 80, "targetPort": 8080}]
            }
        });
        strip_port_names(&mut doc);
        let port = &doc["spec"]["ports"][0];
        assert!(port.get("name").is_none());
        assert_eq!(port["port"], 80);
    }

    // --- normalize_dns_suffix ---

    #[test]
    fn normalize_fqdn_to_short_name() {
        let mut doc = json!({
            "spec": {
                "config": "connect to my-svc.my-ns.svc.cluster.local:8080"
            }
        });
        normalize_dns_suffix(&mut doc);
        assert_eq!(doc["spec"]["config"], "connect to my-svc:8080");
    }

    #[test]
    fn normalize_fqdn_preserves_non_fqdn() {
        let mut doc = json!({
            "value": "just-a-hostname"
        });
        normalize_dns_suffix(&mut doc);
        assert_eq!(doc["value"], "just-a-hostname");
    }

    // --- Full pipeline tests ---

    #[test]
    fn normalize_cluster_full_pipeline() {
        let doc = json!({
            "kind": "Deployment",
            "status": {"replicas": 3},
            "metadata": {
                "name": "test",
                "uid": "abc",
                "resourceVersion": "123",
                "creationTimestamp": "2024-01-01",
                "labels": {"app": "test", "custom": "keep"},
                "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{}"}
            },
            "spec": {
                "progressDeadlineSeconds": 600,
                "revisionHistoryLimit": 10,
                "template": {
                    "metadata": {"labels": {"app": "test"}},
                    "spec": {
                        "dnsPolicy": "ClusterFirst",
                        "containers": [{
                            "name": "app",
                            "image": "nginx",
                            "imagePullPolicy": "Always"
                        }]
                    }
                }
            }
        });
        let result = normalize_cluster(doc);
        assert!(result.get("status").is_none());
        assert!(result["metadata"].get("uid").is_none());
        assert!(result["metadata"].get("annotations").is_none());
        let labels = result["metadata"]["labels"].as_object().unwrap();
        assert!(labels.get("app").is_none());
        assert_eq!(labels["custom"], "keep");
        assert!(result["spec"].get("progressDeadlineSeconds").is_none());
        let pod = &result["spec"]["template"]["spec"];
        assert!(pod.get("dnsPolicy").is_none());
        assert!(
            result["spec"]["template"]["metadata"]
                .get("labels")
                .is_none()
        );
    }

    #[test]
    fn normalize_kix_full_pipeline() {
        let doc = json!({
            "kind": "Deployment",
            "metadata": {
                "name": "test",
                "annotations": {
                    "build.kix.dev/hash": "abc123",
                    "custom": "keep"
                }
            },
            "spec": {
                "template": {
                    "spec": {
                        "containers": [{
                            "name": "app",
                            "image": "nginx"
                        }]
                    }
                }
            }
        });
        let result = normalize_kix(doc);
        let annotations = result["metadata"]["annotations"].as_object().unwrap();
        assert!(annotations.get("build.kix.dev/hash").is_none());
        assert_eq!(annotations["custom"], "keep");
    }
}
