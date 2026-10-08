//! Where the build a command plans and deploys comes from.
//!
//! A [`BuildSource`] is made together with the build it holds, as a
//! [`StoreGraph`]: whoever makes a source reads and verifies the build first,
//! and gives the graph only once it has passed. Plan and deploy then work
//! from that one graph and ask the source only for what goes with it: the
//! SOPS files the build carries, what the machine that made the build
//! recorded about its source, and the earlier builds the cluster's
//! Activation records name.
//!
//! The caller trusts nothing a source gives it. It checks a build a source
//! read with [`check_read_build`], a deployed build with
//! [`check_deployed_build`], and the carried SOPS files with
//! [`carried_sops_sources`]. It alone decides whether the build is in this
//! machine's Nix store, and the digest the deploy receipt names.
//!
//! [`NixStore`] is a build in this machine's Nix store, built from the flake
//! the command names. Another source can be implemented outside this crate:
//! it reads its files and assembles them with [`StoreGraph::assemble`], as a
//! result directory is read.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::cluster::secrets::SopsSources;
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::eval::store_path;
use crate::manifest::keys;
use crate::text::printable;

/// The source of a build, beyond the build's graph.
pub trait BuildSource {
    /// The SOPS files the build carries, by store path, as read. For a build
    /// this machine did not make, these are the only SOPS files its Secrets
    /// may read: see [`carried_sops_sources`].
    fn carried_sops_files(&mut self) -> Result<HashMap<String, Vec<u8>>, String>;

    /// What the machine that made the build recorded about its source, for
    /// the deploy receipt. These are claims by whoever made the build. Not
    /// asked of a build this machine made from the flake the command names,
    /// whose source tree it reads itself.
    fn provenance(&self) -> Provenance;

    /// The build of the Activation record with `identity_hash`, read and
    /// verified as the new build was. `Ok(None)` when this source holds no
    /// such build, and the caller looks in the local Nix store. An error
    /// when it holds the build and the build no longer verifies, which is
    /// not the same as a missing build. The caller checks what it gets with
    /// [`check_deployed_build`].
    fn deployed_build(&self, identity_hash: &str) -> Result<Option<StoreGraph>, String>;
}

/// A build in this machine's Nix store. Its SOPS sources are the files its
/// Secrets name on this machine, and it holds no earlier build beyond what
/// the store holds.
#[derive(Debug, Clone, Copy, Default)]
pub struct NixStore;

impl BuildSource for NixStore {
    fn carried_sops_files(&mut self) -> Result<HashMap<String, Vec<u8>>, String> {
        Ok(HashMap::new())
    }

    fn provenance(&self) -> Provenance {
        Provenance::default()
    }

    fn deployed_build(&self, _identity_hash: &str) -> Result<Option<StoreGraph>, String> {
        Ok(None)
    }
}

/// What the machine that made a build recorded about its source: the deploy
/// receipt's `source`, `inputs` and `builder`. These are claims by whoever
/// made the build, and the receipt repeats them as such.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provenance {
    #[serde(default)]
    pub source: serde_json::Map<String, serde_json::Value>,
    #[serde(default)]
    pub inputs: Vec<serde_json::Map<String, serde_json::Value>>,
    #[serde(default)]
    pub builder: serde_json::Map<String, serde_json::Value>,
}

/// Refuse a build a source read unless it is valid
/// ([`StoreGraph::validate`]) and a build of `cluster`.
pub fn check_read_build(graph: &StoreGraph, cluster: &str) -> Result<(), String> {
    graph.validate().map_err(|e| e.to_string())?;
    if graph.cluster_name != cluster {
        return Err(format!(
            "the build is for cluster '{}', not '{cluster}'",
            printable(&graph.cluster_name)
        ));
    }
    Ok(())
}

/// Refuse a build a source gave for the Activation record with
/// `identity_hash` ([`BuildSource::deployed_build`]) unless its record has
/// that identity hash and the build is valid.
pub fn check_deployed_build(graph: &StoreGraph, identity_hash: &str) -> Result<(), String> {
    let found = store_hash(&graph.activation_path);
    if found != identity_hash {
        return Err(format!(
            "the build source gave activation {} for activation {}",
            printable(&found),
            printable(identity_hash)
        ));
    }
    graph
        .validate()
        .map_err(|e| format!("the build source's activation {identity_hash}: {e}"))
}

/// The SOPS sources of a build this machine did not make: only the files
/// the build carries (`files`, from [`BuildSource::carried_sops_files`]).
/// Keeps the files a Secret in `manifests` names, and refuses one whose
/// store path is not made from its bytes. A SOPS source comes from
/// `builtins.path` of one file, so its path has no references. With
/// `placeholders`, nothing is decrypted: each Secret gets placeholder
/// values, so a plan made before anyone approved it reads no secret.
pub fn carried_sops_sources(
    mut files: HashMap<String, Vec<u8>>,
    manifests: &[Value],
    placeholders: bool,
) -> Result<SopsSources, String> {
    let named: HashSet<&str> = manifests
        .iter()
        .filter_map(|m| keys::get(m, keys::SOPS_SOURCE))
        .collect();
    files.retain(|path, _| named.contains(path.as_str()));
    for (path, bytes) in &files {
        if store_path::method_of::<&str>(path, bytes, &[]).is_none() {
            return Err(format!(
                "the SOPS file the build carries at {} is not made from its bytes",
                printable(path)
            ));
        }
    }
    SopsSources::carried(files, placeholders)
        .map_err(|e| format!("cannot write the SOPS files the build carries: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::bundle::Bundle;
    use crate::eval::store_path::{Method, path_for};

    fn fixture() -> StoreGraph {
        let bytes: &[u8] =
            include_bytes!("../tests/fixtures/bundles/kix-enterprise-test.kixbundle");
        Bundle::read(std::io::Cursor::new(bytes)).unwrap().1
    }

    /// A source that gives an invalid build, or a build of another cluster,
    /// is refused.
    #[test]
    fn a_read_build_must_be_valid_and_of_the_cluster() {
        let graph = fixture();
        assert!(check_read_build(&graph, "kix-enterprise-test").is_ok());
        assert!(check_read_build(&graph, "other").is_err());
        let mut invalid = graph;
        invalid.cluster_name = "other".to_string();
        assert!(check_read_build(&invalid, "other").is_err());
    }

    /// A deployed build must be the build the record names, and valid.
    #[test]
    fn a_deployed_build_must_have_the_identity_hash_and_be_valid() {
        let graph = fixture();
        let hash = store_hash(&graph.activation_path);
        assert!(check_deployed_build(&graph, &hash).is_ok());
        assert!(check_deployed_build(&graph, &"0".repeat(32)).is_err());
        let mut invalid = graph;
        invalid.resources.remove(&invalid.activation_path.clone());
        assert!(check_deployed_build(&invalid, &hash).is_err());
    }

    fn secret(source: &str) -> Value {
        serde_json::json!({
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "db", "annotations": {(keys::SOPS_SOURCE): source}},
        })
    }

    /// A carried SOPS file is checked against its store path here, whatever
    /// the source checked.
    #[test]
    fn a_carried_sops_file_not_made_from_its_bytes_is_refused() {
        let bytes = b"x: 1\n".to_vec();
        let path = path_for(Method::Source, &bytes, &[], "db.sops.yaml");
        let manifests = [secret(&path)];
        let good = HashMap::from([(path.clone(), bytes)]);
        assert!(carried_sops_sources(good, &manifests, true).is_ok());
        let swapped = HashMap::from([(path, b"x: 2\n".to_vec())]);
        assert!(carried_sops_sources(swapped, &manifests, true).is_err());
    }

    /// A carried file no Secret names, such as a marker with references,
    /// is never read as a SOPS file, so it is left out, not refused.
    #[test]
    fn a_carried_file_no_secret_names_is_left_out() {
        let marker = path_for(Method::Text, b"x", &[], "kix-untracked-ref");
        let files = HashMap::from([(marker, b"other bytes".to_vec())]);
        assert!(carried_sops_sources(files, &[], true).is_ok());
    }
}
