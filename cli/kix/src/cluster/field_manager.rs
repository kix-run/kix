//! The field manager name each Kix cluster applies under.
//!
//! Kubernetes records, for each object, which field managers own which
//! fields (`metadata.managedFields`). Each Kix cluster applies under its own
//! name, `kix/<cluster>`, so an object shows which Kix clusters apply it,
//! and two Kix clusters that render a shared object differently get a
//! conflict instead of overwriting each other.
//!
//! Every Kix cluster applied under the one name `kix` before. An object
//! applied then still carries an entry under that name. The first deploy of
//! a Kix cluster by this Kix moves the entry to the cluster's name
//! ([`crate::cluster::migration_write`]). After that, an entry under `kix`
//! belongs to a Kix cluster that an older Kix still deploys, which may be
//! another one, so it is not this Kix cluster's ([`FieldManager::of`]).
//! Before that, every entry under `kix` on the cluster's objects is one an
//! older Kix wrote for it or for another Kix cluster, and a reader of a Kix
//! cluster that is not migrated counts it as the cluster's own
//! ([`FieldManager::unmigrated`]), as the older Kix did.
//!
//! The name is `kix/` followed by the cluster name. A cluster name holds only
//! letters, digits, `-`, and `_` ([`crate::eval::nix::is_valid_cluster_name`]),
//! so it never holds a `/`, and no name of this form equals `kix` or another
//! fixed name Kix writes under, such as `kix-migrate-domain`. Everything
//! after the prefix is the cluster name, so the name reads back exactly.
//!
//! Kubernetes refuses a field manager name longer than 128 characters. Each
//! deploy writes its record, labelled `kix.run/cluster=<cluster>`, before it
//! applies anything, and Kubernetes refuses a label value longer than 63
//! characters. So a cluster that applies anything has a name of at most 63
//! characters, and its manager name has at most 67.

use k8s_openapi::apimachinery::pkg::apis::meta::v1::ManagedFieldsEntry;

/// The field manager name every Kix cluster applied under before each Kix
/// cluster had its own.
pub const LEGACY: &str = "kix";

const PREFIX: &str = "kix/";

/// The longest field manager name Kubernetes accepts.
pub const MAX_LEN: usize = 128;

/// What a field manager name says about who wrote under it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Manager<'a> {
    /// A Kix cluster's own name, with the cluster's name.
    Cluster(&'a str),
    /// The name every Kix cluster applied under before ([`LEGACY`]).
    Legacy,
    /// A name no Kix cluster applies under.
    Other,
}

impl<'a> Manager<'a> {
    /// Read the field manager name `name`.
    pub fn parse(name: &'a str) -> Self {
        if name == LEGACY {
            return Manager::Legacy;
        }
        match name.strip_prefix(PREFIX) {
            Some(cluster) if !cluster.is_empty() => Manager::Cluster(cluster),
            _ => Manager::Other,
        }
    }

    /// Return whether a Kix cluster applies under the name, today's or the
    /// legacy one.
    pub fn is_kix(&self) -> bool {
        !matches!(self, Manager::Other)
    }
}

/// How a field manager name relates to one Kix cluster.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Whose<'a> {
    /// This Kix cluster's own name.
    This,
    /// The legacy name every Kix cluster applied under before.
    Legacy,
    /// Another Kix cluster's name, with that cluster's name.
    OtherCluster(&'a str),
    /// Not a name a Kix cluster applies under.
    NotKix,
}

/// The field manager name one Kix cluster applies under. Build it with
/// [`FieldManager::of`].
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FieldManager {
    cluster: String,
    name: String,
    /// Fields owned under [`LEGACY`] count as this Kix cluster's.
    legacy_is_own: bool,
}

impl FieldManager {
    /// Return the field manager of the Kix cluster `cluster`, for a cluster
    /// that this Kix has deployed. An entry under [`LEGACY`] is another
    /// manager's.
    pub fn of(cluster: &str) -> Self {
        FieldManager {
            cluster: cluster.to_string(),
            name: format!("{PREFIX}{cluster}"),
            legacy_is_own: false,
        }
    }

    /// Return the field manager of the Kix cluster `cluster` as an older Kix
    /// wrote its objects: an entry under [`LEGACY`] counts as the cluster's
    /// own. Read a Kix cluster that this Kix has not deployed yet with it,
    /// and an object whose `kix` entry the migration write moves to the
    /// cluster's name.
    pub fn unmigrated(cluster: &str) -> Self {
        FieldManager {
            legacy_is_own: true,
            ..FieldManager::of(cluster)
        }
    }

    /// Return the manager that applies under the legacy name [`LEGACY`] for
    /// the Kix cluster `cluster`. A dry run applies an object whose entry
    /// under `kix` the migration write will move under it, because that
    /// entry holds the fields the cluster's manager will own.
    pub(crate) fn legacy_for(cluster: &str) -> Self {
        FieldManager {
            cluster: cluster.to_string(),
            name: LEGACY.to_string(),
            legacy_is_own: true,
        }
    }

    /// Return this manager as [`FieldManager::unmigrated`] reads it.
    pub fn as_unmigrated(&self) -> Self {
        FieldManager::unmigrated(&self.cluster)
    }

    /// Return the name to apply under.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Return the Kix cluster this manager is for.
    pub fn cluster(&self) -> &str {
        &self.cluster
    }

    /// Return how the field manager name `name` relates to this Kix cluster.
    pub fn whose<'a>(&self, name: &'a str) -> Whose<'a> {
        match Manager::parse(name) {
            Manager::Cluster(c) if c == self.cluster => Whose::This,
            Manager::Cluster(c) => Whose::OtherCluster(c),
            Manager::Legacy => Whose::Legacy,
            Manager::Other => Whose::NotKix,
        }
    }

    /// Return whether fields owned under `name` count as this Kix cluster's.
    /// They do under its own name, and under the legacy name only for
    /// [`FieldManager::unmigrated`]. Another Kix cluster's name is another
    /// manager.
    ///
    /// Every reader that asks which fields Kix owns asks through this, or
    /// through [`FieldManager::apply_entry`], which uses it.
    pub fn counts_as_own(&self, name: Option<&str>) -> bool {
        match name.map(|n| self.whose(n)) {
            Some(Whose::This) => true,
            Some(Whose::Legacy) => self.legacy_is_own,
            Some(Whose::OtherCluster(_) | Whose::NotKix) | None => false,
        }
    }

    /// Return whether `entries` has an `Apply` entry of the object's main
    /// resource under exactly this field manager. The legacy manager never
    /// counts here, even for [`FieldManager::unmigrated`].
    pub fn holds_entry(&self, entries: &[ManagedFieldsEntry]) -> bool {
        entries.iter().any(|e| {
            e.operation.as_deref() == Some("Apply")
                && e.subresource.is_none()
                && e.manager.as_deref() == Some(self.name.as_str())
        })
    }

    /// Return the `Apply` entry of the object's main resource (no
    /// subresource) that holds the fields this Kix cluster applied. Its own
    /// entry comes first. For [`FieldManager::unmigrated`], an object
    /// without one may carry the legacy entry instead, and that one is
    /// returned.
    pub fn apply_entry<'a>(
        &self,
        entries: &'a [ManagedFieldsEntry],
    ) -> Option<&'a ManagedFieldsEntry> {
        let applied = |e: &&ManagedFieldsEntry| {
            e.operation.as_deref() == Some("Apply")
                && e.subresource.is_none()
                && self.counts_as_own(e.manager.as_deref())
        };
        let own = |e: &&ManagedFieldsEntry| e.manager.as_deref() == Some(self.name.as_str());
        entries
            .iter()
            .filter(applied)
            .find(own)
            .or_else(|| entries.iter().find(applied))
    }
}

impl std::fmt::Display for FieldManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.name)
    }
}

/// Return the Kix clusters other than `own`'s that have an `Apply` entry on
/// the object's main resource, sorted, once each.
pub fn other_clusters_applying<'a>(
    own: &FieldManager,
    entries: &'a [ManagedFieldsEntry],
) -> Vec<&'a str> {
    let mut clusters: Vec<&str> = entries
        .iter()
        .filter(|e| e.operation.as_deref() == Some("Apply") && e.subresource.is_none())
        .filter_map(|e| match own.whose(e.manager.as_deref()?) {
            Whose::OtherCluster(c) => Some(c),
            Whose::This | Whose::Legacy | Whose::NotKix => None,
        })
        .collect();
    clusters.sort_unstable();
    clusters.dedup();
    clusters
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(manager: &str, operation: &str) -> ManagedFieldsEntry {
        ManagedFieldsEntry {
            manager: Some(manager.to_string()),
            operation: Some(operation.to_string()),
            ..ManagedFieldsEntry::default()
        }
    }

    #[test]
    fn a_cluster_name_reads_back_exactly() {
        for cluster in ["a", "homelab-kind", "nw_1", "kix", "migrate-domain"] {
            let manager = FieldManager::of(cluster);
            assert_eq!(Manager::parse(manager.name()), Manager::Cluster(cluster));
            assert_eq!(manager.whose(manager.name()), Whose::This);
        }
    }

    /// No cluster's name equals the legacy name or another fixed name Kix
    /// writes under, even for clusters named after them.
    #[test]
    fn no_cluster_name_collides_with_a_fixed_name() {
        for cluster in ["", "kix", "migrate-domain", "-migrate-domain"] {
            let name = FieldManager::of(cluster).name().to_string();
            assert_ne!(name, LEGACY);
            assert_ne!(name, "kix-migrate-domain");
        }
        assert_eq!(Manager::parse("kix-migrate-domain"), Manager::Other);
        assert_eq!(Manager::parse("kix/"), Manager::Other);
        assert_eq!(Manager::parse(LEGACY), Manager::Legacy);
        assert_eq!(Manager::parse("kubectl"), Manager::Other);
    }

    /// A cluster name of 63 characters, the longest a label value may hold,
    /// gives a name Kubernetes accepts.
    #[test]
    fn the_longest_cluster_name_fits() {
        let name = FieldManager::of(&"c".repeat(63)).name().len();
        assert!(name <= MAX_LEN, "{name}");
    }

    #[test]
    fn whose_tells_the_four_apart() {
        let a = FieldManager::of("a");
        assert_eq!(a.whose("kix/a"), Whose::This);
        assert_eq!(a.whose("kix/b"), Whose::OtherCluster("b"));
        assert_eq!(a.whose("kix"), Whose::Legacy);
        assert_eq!(a.whose("kube-controller-manager"), Whose::NotKix);
        assert!(a.counts_as_own(Some("kix/a")));
        assert!(!a.counts_as_own(Some("kix")));
        assert!(!a.counts_as_own(Some("kix/b")));
        assert!(!a.counts_as_own(None));
        let unmigrated = FieldManager::unmigrated("a");
        assert!(unmigrated.counts_as_own(Some("kix")));
        assert!(unmigrated.counts_as_own(Some("kix/a")));
        assert!(!unmigrated.counts_as_own(Some("kix/b")));
    }

    /// The cluster's own `Apply` entry comes before the legacy one, which
    /// stands in only for an unmigrated reader when the object has no own
    /// entry. Another cluster's entry, an `Update` entry, and a subresource
    /// entry never count.
    #[test]
    fn the_apply_entry_prefers_the_own_name() {
        let a = FieldManager::of("a");
        let both = [entry("kix", "Apply"), entry("kix/a", "Apply")];
        assert_eq!(
            a.apply_entry(&both).unwrap().manager.as_deref(),
            Some("kix/a")
        );
        assert_eq!(
            a.as_unmigrated()
                .apply_entry(&both)
                .unwrap()
                .manager
                .as_deref(),
            Some("kix/a")
        );
        let legacy = [entry("kix/b", "Apply"), entry("kix", "Apply")];
        assert!(a.apply_entry(&legacy).is_none());
        assert_eq!(
            FieldManager::unmigrated("a")
                .apply_entry(&legacy)
                .unwrap()
                .manager
                .as_deref(),
            Some("kix")
        );
        let mut status = entry("kix/a", "Apply");
        status.subresource = Some("status".into());
        let none = [entry("kix/b", "Apply"), entry("kix/a", "Update"), status];
        assert!(a.apply_entry(&none).is_none());
    }

    #[test]
    fn other_clusters_applying_lists_each_other_cluster_once() {
        let a = FieldManager::of("a");
        let entries = [
            entry("kix/c", "Apply"),
            entry("kix/a", "Apply"),
            entry("kix", "Apply"),
            entry("kix/b", "Apply"),
            entry("kix/b", "Update"),
            entry("kix/d", "Update"),
        ];
        assert_eq!(other_clusters_applying(&a, &entries), ["b", "c"]);
    }
}
