//! The objects a deploy writes and deletes, held to the objects its plan
//! shows.
//!
//! A deploy runs the engine plan, a flat list of the build's objects, while
//! people review the package-grouped [`super::PackageDiff`]. `of` joins
//! the two before anything is sent, so `kix plan` and `kix deploy` refuse a
//! build whose package view leaves out an object the deploy would write or
//! delete:
//!
//! - Each write, by object id and the store hash of its file, must be one
//!   the diff lists as added, modified, or dep-affected, or the new
//!   Activation record, or a re-apply.
//! - A re-apply is a write of a file that a build this cluster already ran
//!   holds for the same object: the deployed build, or the closure of a
//!   deploy that stopped part way or kept its orphans. `--reconcile` writes
//!   unchanged objects again this way, a deploy repairs what a stopped
//!   deploy changed, and a probe Job under `kix.run/rerun` is created again.
//!   It adds no object and no file those builds lack, so the diff does not
//!   list it; the plan document's `objects` does.
//! - Each delete must be one the diff lists as removed, or, when the plan
//!   read the cluster, one its `prune` section lists.
//!
//! A write's hash comes from its store path, the file's content hash, never
//! from its stamped manifest's annotation. The builds the cluster ran are
//! known by their `kix.run/identity-hash` stamps, which on a plan without a
//! deployed build are read off the live objects. A forged stamp cannot add
//! a write: a re-apply is only a write the diff does not list, and the diff
//! lists every object whose file differs from the old side in content,
//! list order included.
//!
//! The plan document lists these objects as `objects` and their [`digest`]
//! as `objects_digest`, and `kix deploy --plan` refuses a deploy whose
//! digest differs from the reviewed plan's.
//!
//! Kix makes some writes that no build file describes, and these are outside
//! the check: the Activation record's lifecycle (created before the first
//! wave, its status, and the older records it supersedes), the
//! `kix.run/activations` stamp the engine puts on unchanged objects, the
//! `--record-annotation` values, the `kix.run/*` stamps on every write, the
//! values a deploy decrypts into a Secret from the SOPS file the Secret's
//! store path names, and the delete before the create of a write whose
//! immutable field changed.

use std::collections::{HashMap, HashSet};
use std::fmt;
use std::path::Path;

use crate::cluster::apply::ChangeAction;
use crate::cluster::scheduler::DeployPlan;
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::manifest::keys;
use crate::manifest::types::ResourceId;
use serde_json::Value;

use super::document::{ObjectDelete, ObjectWrite, Objects, WriteChange};
use super::{CLUSTER_LEVEL_KEY, Shown};

/// Verify that every write and delete in `plan` and `deletes` matches an entry
/// in `shown`, and return the [`Objects`] list.
///
/// `graph` is the new build `plan` was made from. `deletes` are the orphans
/// the prune deletes; `listed_deletes` are the orphans the plan's `prune`
/// section lists (empty when the plan did not read the cluster). `old` are the
/// manifests of the builds the cluster ran.
pub(crate) fn of<'a>(
    shown: &Shown,
    graph: &StoreGraph,
    plan: &DeployPlan,
    deletes: &[ResourceId],
    listed_deletes: &[ResourceId],
    old: impl IntoIterator<Item = &'a Value>,
) -> Result<Objects, Unshown> {
    let mut files: HashMap<ResourceId, Vec<&Path>> = HashMap::new();
    for (path, node) in &graph.resources {
        files
            .entry(ResourceId::from_value(&node.manifest))
            .or_default()
            .push(path);
    }
    let ran: HashSet<(ResourceId, &str)> = old
        .into_iter()
        .filter_map(|m| {
            Some((
                ResourceId::from_value(m),
                keys::get(m, keys::IDENTITY_HASH)?,
            ))
        })
        .collect();

    let mut unshown = Unshown::default();
    let mut writes = Vec::new();
    for node in &plan.nodes {
        let id = match (&node.action, &node.rerun) {
            (ChangeAction::Apply(m), _) => ResourceId::from_value(m),
            (ChangeAction::Skip(id), Some(_)) => id.clone(),
            _ => continue,
        };
        let path = match files.get(&id).map(Vec::as_slice) {
            Some([path]) => *path,
            Some(paths) => {
                unshown.writes.push(format!(
                    "{} (in {} build files)",
                    shown_id(&id),
                    paths.len()
                ));
                continue;
            }
            None => {
                unshown
                    .writes
                    .push(format!("{} (in no build file)", shown_id(&id)));
                continue;
            }
        };
        let hash = store_hash(path);
        let (package, change) = match shown.writes.get(&(id.clone(), hash.clone())) {
            Some((package, change)) => (package.clone(), *change),
            None if ran.contains(&(id.clone(), hash.as_str())) => {
                (owner(graph, path), WriteChange::Reapplied)
            }
            None => {
                unshown
                    .writes
                    .push(format!("{} (store hash {hash})", shown_id(&id)));
                continue;
            }
        };
        writes.push(ObjectWrite {
            kind: id.kind,
            namespace: id.namespace,
            name: id.name,
            store_hash: hash,
            package,
            change,
        });
    }

    let listed_deletes: HashSet<&ResourceId> = listed_deletes.iter().collect();
    let mut removed = Vec::new();
    for id in deletes {
        if shown.deletes.contains_key(id) || listed_deletes.contains(id) {
            removed.push(ObjectDelete {
                kind: id.kind.clone(),
                namespace: id.namespace.clone(),
                name: id.name.clone(),
            });
        } else {
            unshown.deletes.push(shown_id(id));
        }
    }

    if !unshown.writes.is_empty() || !unshown.deletes.is_empty() {
        unshown.writes.sort();
        unshown.deletes.sort();
        return Err(unshown);
    }
    writes.sort();
    removed.sort();
    Ok(Objects {
        writes,
        deletes: removed,
    })
}

/// Compute `sha256:` followed by the hex SHA-256 of the compact JSON
/// `{"writes":[[kind,namespace,name,store_hash,package],...],"deletes":[[kind,namespace,name],...]}`
/// of `objects`, with each list sorted by its string arrays in byte order.
/// `serde_json` escapes `"`, `\`, and control characters and writes the rest
/// of the text as UTF-8. A write's `change` is omitted because it describes how
/// the plan displays the write rather than what is written.
pub fn digest(objects: &Objects) -> String {
    use sha2::{Digest, Sha256};

    #[derive(serde::Serialize)]
    struct Canonical<'a> {
        writes: Vec<[&'a str; 5]>,
        deletes: Vec<[&'a str; 3]>,
    }
    let mut canonical = Canonical {
        writes: objects
            .writes
            .iter()
            .map(|w| {
                [
                    w.kind.as_str(),
                    &w.namespace,
                    &w.name,
                    &w.store_hash,
                    &w.package,
                ]
            })
            .collect(),
        deletes: objects
            .deletes
            .iter()
            .map(|d| [d.kind.as_str(), &d.namespace, &d.name])
            .collect(),
    };
    canonical.writes.sort();
    canonical.deletes.sort();
    let json = serde_json::to_vec(&canonical).expect("strings serialize");
    format!("sha256:{:x}", Sha256::digest(json))
}

/// The objects a deploy would write or delete that its plan does not show.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Unshown {
    pub writes: Vec<String>,
    pub deletes: Vec<String>,
}

/// How many objects of each list an [`Unshown`] error names.
const NAMED: usize = 20;

impl fmt::Display for Unshown {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "the deploy would write or delete objects the plan does not show, so nothing was \
             planned or applied. The build's package index and its objects disagree; build it \
             again with Kix and plan that build."
        )?;
        for (what, list) in [("writes", &self.writes), ("deletes", &self.deletes)] {
            if list.is_empty() {
                continue;
            }
            writeln!(f, "  {what} not shown ({}):", list.len())?;
            for item in list.iter().take(NAMED) {
                writeln!(f, "    {item}")?;
            }
            if list.len() > NAMED {
                writeln!(f, "    and {} more", list.len() - NAMED)?;
            }
        }
        Ok(())
    }
}

impl std::error::Error for Unshown {}

/// Format `id` for an error message with build-supplied text escaped.
fn shown_id(id: &ResourceId) -> String {
    crate::text::printable_up_to(&id.display_id(), 300)
}

/// Return the key of the package that owns the file at `path`, or
/// [`CLUSTER_LEVEL_KEY`] when unowned.
fn owner(graph: &StoreGraph, path: &Path) -> String {
    let package = graph
        .resource_owner
        .get(path)
        .and_then(|pi| graph.packages.get(pi))
        .or_else(|| graph.packages.get(path));
    match package {
        Some(p) => format!("{}/{}", p.namespace, p.instance_name),
        None => CLUSTER_LEVEL_KEY.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The digest's encoding, written out: a change to it changes every
    /// saved plan's digest.
    #[test]
    fn the_digest_is_of_the_canonical_json() {
        use sha2::{Digest, Sha256};
        let objects = Objects {
            writes: vec![ObjectWrite {
                kind: "ConfigMap".into(),
                namespace: "app".into(),
                name: "a\"b".into(),
                store_hash: "h".into(),
                package: "app/web".into(),
                change: WriteChange::Reapplied,
            }],
            deletes: vec![ObjectDelete {
                kind: "Secret".into(),
                namespace: "_cluster".into(),
                name: "s".into(),
            }],
        };
        let json = r#"{"writes":[["ConfigMap","app","a\"b","h","app/web"]],"deletes":[["Secret","_cluster","s"]]}"#;
        assert_eq!(
            digest(&objects),
            format!("sha256:{:x}", Sha256::digest(json))
        );
        assert_eq!(digest(&Objects::default()), {
            let empty = r#"{"writes":[],"deletes":[]}"#;
            format!("sha256:{:x}", Sha256::digest(empty))
        });
    }
}
