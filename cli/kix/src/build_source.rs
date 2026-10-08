//! The build a command plans and deploys, and where it came from.
//!
//! A [`Build`] is a checked build, and the only way a command or the
//! operator loads one. It is made in one of two ways, and each does every
//! check once, so a caller cannot hold a build it has not checked:
//!
//! - [`Build::local`] loads and validates a result directory in this
//!   machine's Nix store; [`Build::of_flake`] builds one first.
//! - [`Build::carried`] reads a build made elsewhere, through a
//!   [`CarriedBuild`] such as a bundle. It hashes the bytes it hands the
//!   reader itself, and refuses a build that is not valid or not of the
//!   named cluster.
//!
//! Either way the build is then checked for a retired domain and stamped,
//! in that order, so its graph is stamped once and the check sees it as
//! loaded. A command that installs the build's CRDs takes an
//! [`InstallableBuild`], which only [`Build::installable`] makes, and only
//! from a build that passed that check.
//!
//! The bytes are untrusted: a bundle comes from CI. The reader is not
//! checked against them: it is code the operator chose to run. The digest
//! names the bytes handed to the reader, and the reader must build the
//! graph from exactly those bytes. The core's checks guard against a wrong
//! or careless reader, not a hostile one.
//!
//! What a carried build gives later is checked as it is asked for: its
//! SOPS files against their store paths ([`Build::sops_sources`]), and an
//! earlier build against the record that names it ([`Build::deployed_build`]).
//! Which kind of build it is, never the source, decides whether it is in
//! the local store and the digest the deploy receipt names.
//!
//! A [`CarriedBuild`] can be implemented outside this crate: it reads its
//! files and assembles them with [`StoreGraph::assemble`], as a result
//! directory is read.

use std::collections::{HashMap, HashSet};
use std::ops::{Deref, DerefMut};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::cluster::secrets::SopsSources;
use crate::eval::KixEvalError;
use crate::eval::build::build_cluster_activation;
use crate::eval::stamp::stamp_annotations;
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::eval::store_path;
use crate::legacy_domain::{self, LegacyDomainError};
use crate::manifest::keys;
use crate::text::printable;

/// A build made elsewhere and carried here, beyond its graph.
///
/// An implementation is trusted code: [`Build::carried`] names the digest
/// of the bytes it hands the reader, and cannot tell whether the graph came
/// from them. The reader must build the graph from exactly those bytes.
/// What each method gives is checked, against a wrong or careless
/// implementation, not a hostile one.
pub trait CarriedBuild {
    /// The SOPS files the build carries, by store path, as read. These are
    /// the only SOPS files its Secrets may read.
    fn sops_files(&mut self) -> Result<HashMap<String, Vec<u8>>, String>;

    /// What the machine that made the build recorded about its source, for
    /// the deploy receipt. These are claims by whoever made the build.
    fn provenance(&self) -> Provenance;

    /// The build of the Activation record with `identity_hash`. `Ok(None)`
    /// when this source holds no such build, and the caller looks in the
    /// local Nix store. An error when it holds the build and the build no
    /// longer reads, which is not the same as a missing build.
    fn deployed_build(&self, identity_hash: &str) -> Result<Option<StoreGraph>, String>;
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

/// A checked build. See the module doc.
pub struct Build {
    graph: StoreGraph,
    origin: Origin,
    /// Why the build, as loaded, may not install its CRDs.
    legacy_domain: Option<LegacyDomainError>,
}

/// A build whose CRDs may be installed: as loaded, it renders Kix's own
/// CRDs under the current group, not a retired one. Only
/// [`Build::installable`] makes one, and the commands that install a
/// build's CRDs take only this.
pub struct InstallableBuild(Build);

impl Deref for InstallableBuild {
    type Target = Build;

    fn deref(&self) -> &Build {
        &self.0
    }
}

impl DerefMut for InstallableBuild {
    fn deref_mut(&mut self) -> &mut Build {
        &mut self.0
    }
}

/// Why [`Build::of_flake`] failed: at the `nix build`, or loading what it
/// built. Commands word the two differently.
#[derive(Debug, thiserror::Error)]
pub enum FlakeBuildError {
    #[error("{0}")]
    Build(KixEvalError),
    #[error("{0}")]
    Load(KixEvalError),
}

enum Origin {
    Local,
    /// `sha256` is of the bytes [`Build::carried`] handed `source`.
    Carried {
        source: Box<dyn CarriedBuild>,
        sha256: String,
    },
}

impl Build {
    /// A build of `cluster` from the flake at `flake_path`, made now into
    /// this machine's Nix store and loaded as [`Build::local`] loads it.
    /// `status` gets progress lines from both steps.
    pub fn of_flake(
        flake_path: &Path,
        cluster: &str,
        input_overrides: &[(String, String)],
        status: &dyn Fn(&str),
    ) -> Result<Build, FlakeBuildError> {
        let result_dir = build_cluster_activation(flake_path, cluster, input_overrides, status)
            .map_err(FlakeBuildError::Build)?;
        Build::local(&result_dir, status).map_err(FlakeBuildError::Load)
    }

    /// The build in the result directory `result_dir`, in this machine's
    /// Nix store, validated as it is loaded. Its Secrets read SOPS files
    /// from this machine.
    pub fn local(result_dir: &Path, status: &dyn Fn(&str)) -> Result<Build, KixEvalError> {
        let graph = StoreGraph::from_result_dir(result_dir, status)?;
        Ok(Build::stamped(graph, Origin::Local))
    }

    /// The build `read` makes of `bytes`, which must be valid and a build
    /// of `cluster`. The receipt names the SHA-256 of `bytes`, whatever the
    /// source claims.
    ///
    /// The digest names the bytes handed to `read`, and `read` must build
    /// the graph from exactly those bytes: nothing here checks that it did.
    /// The checks guard against a wrong or careless reader, not a hostile
    /// one.
    pub fn carried<S: CarriedBuild + 'static>(
        bytes: Vec<u8>,
        cluster: &str,
        read: impl FnOnce(Vec<u8>) -> Result<(S, StoreGraph), String>,
    ) -> Result<Build, String> {
        let sha256 = format!("{:x}", Sha256::digest(&bytes));
        let (source, graph) = read(bytes)?;
        graph.validate().map_err(|e| e.to_string())?;
        if graph.cluster_name != cluster {
            return Err(format!(
                "the build is for cluster '{}', not '{cluster}'",
                printable(&graph.cluster_name)
            ));
        }
        let origin = Origin::Carried {
            source: Box::new(source),
            sha256,
        };
        Ok(Build::stamped(graph, origin))
    }

    /// Checks the loaded `graph` for a retired domain, then stamps it.
    fn stamped(mut graph: StoreGraph, origin: Origin) -> Build {
        let legacy_domain =
            legacy_domain::check_build(graph.resources.values().map(|r| &r.manifest)).err();
        stamp_annotations(&mut graph);
        Build {
            graph,
            origin,
            legacy_domain,
        }
    }

    /// The build's graph, stamped.
    pub fn graph(&self) -> &StoreGraph {
        &self.graph
    }

    /// The build's graph, stamped, for a caller that needs nothing else
    /// of the build: not where it came from, its SOPS sources or the
    /// builds it carries.
    pub fn into_graph(self) -> StoreGraph {
        self.graph
    }

    /// The build, for a command that installs its CRDs. Refused when the
    /// build, as loaded, renders Kix's own CRDs under a retired group: a
    /// kixpkgs pin from before the domain move
    /// ([`legacy_domain::check_build`]). A build an Activation record names
    /// may predate the move, so a command that only reads one does not ask.
    pub fn installable(self) -> Result<InstallableBuild, LegacyDomainError> {
        match self.legacy_domain {
            Some(e) => Err(e),
            None => Ok(InstallableBuild(self)),
        }
    }

    /// Whether the build is in this machine's Nix store, so later commands
    /// can find it there.
    pub fn is_local(&self) -> bool {
        matches!(self.origin, Origin::Local)
    }

    /// For a carried build, what its maker recorded and the SHA-256 of the
    /// bytes read. `None` for a local build, whose source tree is read here.
    pub fn carried_provenance(&self) -> Option<(Provenance, &str)> {
        match &self.origin {
            Origin::Local => None,
            Origin::Carried { source, sha256 } => Some((source.provenance(), sha256)),
        }
    }

    /// The SOPS sources of the build's Secrets. A local build reads the
    /// files they name on this machine. A carried build reads only the files
    /// it carries ([`carried_sops`]). With `placeholders`, nothing is
    /// decrypted: each Secret gets placeholder values, so a plan made before
    /// anyone approved it reads no secret.
    pub fn sops_sources(&mut self, placeholders: bool) -> Result<SopsSources, String> {
        let Origin::Carried { source, .. } = &mut self.origin else {
            return Ok(SopsSources::Local);
        };
        let manifests = self.graph.resources.values().map(|r| &r.manifest);
        carried_sops(source.sops_files()?, manifests, placeholders)
    }

    /// The build of the Activation record with `identity_hash` that this
    /// build carries, stamped, and refused unless its record has that
    /// identity hash and it is valid. `Ok(None)` for a local build.
    pub fn deployed_build(&self, identity_hash: &str) -> Result<Option<StoreGraph>, String> {
        let Origin::Carried { source, .. } = &self.origin else {
            return Ok(None);
        };
        let Some(mut graph) = source.deployed_build(identity_hash)? else {
            return Ok(None);
        };
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
            .map_err(|e| format!("the build source's activation {identity_hash}: {e}"))?;
        stamp_annotations(&mut graph);
        Ok(Some(graph))
    }
}

/// Keeps the carried `files` a Secret in `manifests` names, and refuses one
/// whose store path is not made from its bytes. A SOPS source comes from
/// `builtins.path` of one file, so its path has no references.
fn carried_sops<'a>(
    mut files: HashMap<String, Vec<u8>>,
    manifests: impl Iterator<Item = &'a Value>,
    placeholders: bool,
) -> Result<SopsSources, String> {
    let named: HashSet<&str> = manifests
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

    /// A source that gives `.0` as its build of any record.
    struct Gives(StoreGraph);

    impl CarriedBuild for Gives {
        fn sops_files(&mut self) -> Result<HashMap<String, Vec<u8>>, String> {
            Ok(HashMap::new())
        }
        fn provenance(&self) -> Provenance {
            Provenance::default()
        }
        fn deployed_build(&self, _identity_hash: &str) -> Result<Option<StoreGraph>, String> {
            Ok(Some(self.0.clone()))
        }
    }

    /// A carried build of `graph` for `cluster`, giving `deployed` for any
    /// record.
    fn carried_for(
        cluster: &str,
        graph: &StoreGraph,
        deployed: &StoreGraph,
    ) -> Result<Build, String> {
        let (graph, deployed) = (graph.clone(), deployed.clone());
        // Ignores the bytes so a test can hand the core a graph a bundle
        // would not hold.
        Build::carried(b"bytes".to_vec(), cluster, |_| Ok((Gives(deployed), graph)))
    }

    fn carried(graph: &StoreGraph, deployed: &StoreGraph) -> Result<Build, String> {
        carried_for("kix-enterprise-test", graph, deployed)
    }

    /// A source that gives an invalid build, or a build of another cluster,
    /// is refused.
    #[test]
    fn a_carried_build_must_be_valid_and_of_the_cluster() {
        let graph = fixture();
        assert!(carried(&graph, &graph).is_ok());
        let mut other = graph.clone();
        other.cluster_name = "other".to_string();
        assert!(carried(&other, &graph).is_err());
        let mut invalid = graph.clone();
        invalid.resources.remove(&invalid.activation_path.clone());
        assert!(carried(&invalid, &graph).is_err());
    }

    /// A build whose cluster name is changed to the one asked for still
    /// names its real cluster in its manifests, so validation refuses it.
    #[test]
    fn a_carried_build_renamed_to_the_cluster_is_refused() {
        let mut renamed = fixture();
        renamed.cluster_name = "other".to_string();
        let deployed = fixture();
        assert!(carried_for("other", &renamed, &deployed).is_err());
    }

    /// The digest is of the bytes the core read, whatever the source says.
    #[test]
    fn a_carried_build_names_the_digest_of_the_bytes_read() {
        let graph = fixture();
        let build = carried(&graph, &graph).unwrap();
        let (_, sha256) = build.carried_provenance().unwrap();
        assert_eq!(sha256, format!("{:x}", Sha256::digest(b"bytes")));
    }

    /// A deployed build must be the build the record names, and valid.
    #[test]
    fn a_deployed_build_must_have_the_identity_hash_and_be_valid() {
        let graph = fixture();
        let hash = store_hash(&graph.activation_path);
        let build = carried(&graph, &graph).unwrap();
        assert!(build.deployed_build(&hash).unwrap().is_some());
        assert!(build.deployed_build(&"0".repeat(32)).is_err());
        let mut invalid = graph.clone();
        invalid.resources.remove(&invalid.activation_path.clone());
        let build = carried(&graph, &invalid).unwrap();
        assert!(build.deployed_build(&hash).is_err());
    }

    /// The retired-domain check sees the build as loaded, and the graph a
    /// caller gets is stamped, which upgrades it to the current domain.
    #[test]
    fn the_domain_is_checked_before_stamping() {
        let mut graph = fixture();
        let record = graph
            .resources
            .values_mut()
            .find(|r| crate::manifest::lifecycle::is_record(&r.manifest))
            .unwrap();
        let version = record.manifest["apiVersion"].as_str().unwrap();
        let legacy = version.replace(keys::GROUP, legacy_domain::DOMAINS[0]);
        record.manifest["apiVersion"] = Value::String(legacy);
        let build = carried(&graph, &fixture()).unwrap();
        let stamped = build.graph().resources.values();
        assert!(
            stamped
                .filter_map(|r| r.manifest["apiVersion"].as_str())
                .all(|v| !v.starts_with(legacy_domain::DOMAINS[0]))
        );
        assert!(build.installable().is_err());
        assert!(
            carried(&fixture(), &fixture())
                .unwrap()
                .installable()
                .is_ok()
        );
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
        assert!(carried_sops(good, manifests.iter(), true).is_ok());
        let swapped = HashMap::from([(path, b"x: 2\n".to_vec())]);
        assert!(carried_sops(swapped, manifests.iter(), true).is_err());
    }

    /// A carried file no Secret names, such as a marker with references,
    /// is never read as a SOPS file, so it is left out, not refused.
    #[test]
    fn a_carried_file_no_secret_names_is_left_out() {
        let marker = path_for(Method::Text, b"x", &[], "kix-untracked-ref");
        let files = HashMap::from([(marker, b"other bytes".to_vec())]);
        assert!(carried_sops(files, std::iter::empty(), true).is_ok());
    }
}
