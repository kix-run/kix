//! Kinds by API group and name.
//!
//! Two API groups can serve a kind of one name, such as `Job` in `batch` and
//! in `batch.volcano.sh`. A rule about one of Kubernetes' built-in kinds
//! matches a [`GroupKind`] against the constants here, so a custom resource
//! that happens to share the name does not get the built-in rule.

use serde_json::Value;

/// A kind and the API group that serves it (`""` for the core group).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct GroupKind<'a> {
    pub group: &'a str,
    pub kind: &'a str,
}

impl<'a> GroupKind<'a> {
    pub const fn new(group: &'a str, kind: &'a str) -> GroupKind<'a> {
        GroupKind { group, kind }
    }

    /// Return the group and kind of `manifest`, from its `apiVersion` and
    /// `kind`. A field that is missing reads as `""`.
    pub fn of_manifest(manifest: &'a Value) -> GroupKind<'a> {
        let api_version = manifest
            .get("apiVersion")
            .and_then(Value::as_str)
            .unwrap_or("");
        GroupKind {
            group: super::types::api_group(api_version),
            kind: manifest.get("kind").and_then(Value::as_str).unwrap_or(""),
        }
    }

    /// Return the kind with its API group, as `kubectl` writes it:
    /// `"Job.batch"`, or `"ConfigMap"` for the core group.
    pub fn qualified(self) -> String {
        super::types::qualified_kind(self.group, self.kind)
    }
}

pub const CONFIG_MAP: GroupKind<'static> = GroupKind::new("", "ConfigMap");
pub const SECRET: GroupKind<'static> = GroupKind::new("", "Secret");
pub const SERVICE: GroupKind<'static> = GroupKind::new("", "Service");
pub const SERVICE_ACCOUNT: GroupKind<'static> = GroupKind::new("", "ServiceAccount");
pub const NAMESPACE: GroupKind<'static> = GroupKind::new("", "Namespace");
pub const POD: GroupKind<'static> = GroupKind::new("", "Pod");
pub const PERSISTENT_VOLUME_CLAIM: GroupKind<'static> = GroupKind::new("", "PersistentVolumeClaim");
pub const LIMIT_RANGE: GroupKind<'static> = GroupKind::new("", "LimitRange");
pub const RESOURCE_QUOTA: GroupKind<'static> = GroupKind::new("", "ResourceQuota");
pub const EVENT: GroupKind<'static> = GroupKind::new("", "Event");
pub const DEPLOYMENT: GroupKind<'static> = GroupKind::new("apps", "Deployment");
pub const STATEFUL_SET: GroupKind<'static> = GroupKind::new("apps", "StatefulSet");
pub const DAEMON_SET: GroupKind<'static> = GroupKind::new("apps", "DaemonSet");
pub const REPLICA_SET: GroupKind<'static> = GroupKind::new("apps", "ReplicaSet");
pub const JOB: GroupKind<'static> = GroupKind::new("batch", "Job");
pub const CRON_JOB: GroupKind<'static> = GroupKind::new("batch", "CronJob");
pub const CLUSTER_ROLE: GroupKind<'static> =
    GroupKind::new("rbac.authorization.k8s.io", "ClusterRole");
pub const CLUSTER_ROLE_BINDING: GroupKind<'static> =
    GroupKind::new("rbac.authorization.k8s.io", "ClusterRoleBinding");
pub const ROLE: GroupKind<'static> = GroupKind::new("rbac.authorization.k8s.io", "Role");
pub const ROLE_BINDING: GroupKind<'static> =
    GroupKind::new("rbac.authorization.k8s.io", "RoleBinding");
pub const INGRESS: GroupKind<'static> = GroupKind::new("networking.k8s.io", "Ingress");
pub const NETWORK_POLICY: GroupKind<'static> = GroupKind::new("networking.k8s.io", "NetworkPolicy");
pub const POD_DISRUPTION_BUDGET: GroupKind<'static> =
    GroupKind::new("policy", "PodDisruptionBudget");
pub const HORIZONTAL_POD_AUTOSCALER: GroupKind<'static> =
    GroupKind::new("autoscaling", "HorizontalPodAutoscaler");
pub const PRIORITY_CLASS: GroupKind<'static> = GroupKind::new("scheduling.k8s.io", "PriorityClass");
pub const STORAGE_CLASS: GroupKind<'static> = GroupKind::new("storage.k8s.io", "StorageClass");
pub const CUSTOM_RESOURCE_DEFINITION: GroupKind<'static> =
    GroupKind::new("apiextensions.k8s.io", "CustomResourceDefinition");
pub const SERVICE_MONITOR: GroupKind<'static> =
    GroupKind::new("monitoring.coreos.com", "ServiceMonitor");
pub const GATEWAY: GroupKind<'static> = GroupKind::new("gateway.networking.k8s.io", "Gateway");

/// Kinds that the Kubernetes apiserver serves in more than one API group as
/// one stored object: a write through either group changes the same object.
///
/// The list comes from the Kubernetes API reference: the apiserver serves the
/// core `v1` Event again as `events.k8s.io/v1` Event
/// (<https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/>).
/// Kubernetes 1.22 removed the last other aliases (`extensions/v1beta1`
/// Ingress, Deployment, DaemonSet, ReplicaSet, NetworkPolicy, and
/// PodSecurityPolicy). Add an entry when Kubernetes serves another kind in
/// two groups.
pub const ALIASED: &[&[GroupKind<'static>]] = &[&[EVENT, GroupKind::new("events.k8s.io", "Event")]];

/// Return whether `a` and `b` name one stored kind in two API groups
/// ([`ALIASED`]).
pub fn aliased(a: GroupKind<'_>, b: GroupKind<'_>) -> bool {
    a != b
        && ALIASED
            .iter()
            .any(|set| set.contains(&a) && set.contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_manifest_gives_its_group_and_kind() {
        let job = serde_json::json!({ "apiVersion": "batch/v1", "kind": "Job" });
        assert_eq!(GroupKind::of_manifest(&job), JOB);
        let other = serde_json::json!({ "apiVersion": "batch.volcano.sh/v1alpha1", "kind": "Job" });
        assert_ne!(GroupKind::of_manifest(&other), JOB);
        assert_eq!(JOB.qualified(), "Job.batch");
        assert_eq!(SECRET.qualified(), "Secret");
    }

    #[test]
    fn only_the_listed_groups_are_aliases() {
        let events = GroupKind::new("events.k8s.io", "Event");
        assert!(aliased(EVENT, events));
        assert!(aliased(events, EVENT));
        assert!(!aliased(EVENT, EVENT));
        assert!(!aliased(
            GroupKind::new("certmanager.k8s.io", "Certificate"),
            GroupKind::new("cert-manager.io", "Certificate")
        ));
    }
}
