//! Checked builds for planning and deployment, and where they came from.
//!
//! [`Build`] is a validated build and the only way a command or the operator
//! loads one. Every constructor runs validation once so callers cannot hold an
//! unchecked build:
//!
//! - [`Build::local`] loads and validates a build in the local Nix store.
//!   [`Build::of_flake`] evaluates the flake first.
//! - [`Build::carried`] reads a build produced on another machine through a
//!   [`CarriedBuild`] implementation such as `kix-bundle`. It hashes the bytes
//!   passed to the reader and rejects any build that fails validation or
//!   targets a different cluster.
//!
//! Both constructors check the loaded build for a retired domain before
//! stamping annotations, so the domain check sees the raw manifests and the
//! graph is stamped once. Commands that install the build's CRDs require an
//! [`InstallableBuild`], which only [`Build::installable`] produces after that
//! check passes.
//!
//! Bundle bytes are untrusted because they come from CI, whereas the reader is
//! trusted code chosen by the operator. The recorded digest hashes the bytes
//! handed to the reader, which must construct the graph from those exact
//! bytes. Validation here guards against a buggy reader rather than a hostile
//! one.
//!
//! Additional artifacts from a carried build are validated on demand:
//! [`Build::sops_sources`] verifies SOPS files against their store paths, and
//! [`Build::deployed_build`] verifies an earlier build against the Activation
//! record that names it. Whether a build lives in the local store and which
//! digest appears in the deploy receipt depend only on the [`Build`] variant.
//!
//! [`CarriedBuild`] is implemented outside this crate (for example, in
//! `kix-bundle`).

use std::collections::{HashMap, HashSet};
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::eval::KixEvalError;
use crate::eval::build_files::BuildFiles;
use crate::eval::library_record::{LibraryRecord, read_warnings};
use crate::eval::nix::eval_activation_index;
use crate::eval::stamp::stamp_annotations;
use crate::eval::store_graph::{StoreGraph, store_hash};
use crate::eval::store_path;
use crate::legacy_domain::{self, LegacyDomainError};
use crate::manifest::keys;
use crate::text::printable;

/// Extra artifacts carried alongside a build produced on another machine.
///
/// Implementations are trusted code. [`Build::carried`] hashes the bytes
/// handed to the reader, which must build the graph from those exact bytes.
/// Each method's return value is validated to catch implementation bugs.
pub trait CarriedBuild {
    /// Return the SOPS files carried by the build, keyed by store path.
    /// Secrets in the build may read only these SOPS files.
    fn sops_files(&mut self) -> Result<HashMap<String, Vec<u8>>, String>;

    /// Return the source metadata recorded by the builder for the deploy
    /// receipt.
    fn provenance(&self) -> Provenance;

    /// Return the build for the Activation record with `identity_hash`.
    ///
    /// Returns `Ok(None)` when this source does not hold that build, so the
    /// caller can check the local Nix store. Returns an error when the source
    /// holds the build but cannot read it.
    fn deployed_build(&self, identity_hash: &str) -> Result<Option<StoreGraph>, String>;
}

/// Source metadata recorded by the machine that produced a build (`source`,
/// `inputs`, and `builder` in the deploy receipt). These fields are unverified
/// claims from the builder and are copied into the receipt as such.
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

/// A validated build. See the module documentation for details.
pub struct Build {
    graph: StoreGraph,
    origin: Origin,
    /// The Kix library's warnings for this build. A carried build has
    /// none, because the command that made it showed them.
    warnings: Vec<LibraryRecord>,
    /// Retired-domain error recorded when the raw build was loaded, if any.
    legacy_domain: Option<LegacyDomainError>,
}

/// A build whose CRDs may be installed because its loaded manifests use Kix's
/// current API group rather than a retired one. Only [`Build::installable`]
/// constructs this type, and commands that install CRDs accept only this type.
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

/// Error from [`Build::of_flake`], distinguishing a failure to evaluate the
/// flake from a failure to load the resulting build so CLI commands can
/// report them differently.
#[derive(Debug, thiserror::Error)]
pub enum FlakeBuildError {
    #[error("{0}")]
    Build(KixEvalError),
    #[error("{0}")]
    Load(KixEvalError),
}

enum Origin {
    Local,
    /// `sha256` is the digest of the bytes [`Build::carried`] passed to `source`.
    Carried {
        source: Box<dyn CarriedBuild>,
        sha256: String,
    },
}

impl Build {
    /// Evaluate `cluster` from the flake at `flake_path` into the local Nix
    /// store and load it with [`Build::local`], forwarding progress lines
    /// from both steps to `status`.
    pub fn of_flake(
        flake_path: &Path,
        cluster: &str,
        input_overrides: &[(String, String)],
        status: &dyn Fn(&str),
    ) -> Result<Build, FlakeBuildError> {
        let index = eval_activation_index(flake_path, cluster, input_overrides, status)
            .map_err(FlakeBuildError::Build)?;
        Build::local(&index, status).map_err(FlakeBuildError::Load)
    }

    /// Load and validate the build at `built_via`, an index file or a result
    /// directory ([`crate::eval::build_files::BuildFiles`]), from the local
    /// Nix store. Its Secrets read SOPS files from the local filesystem.
    pub fn local(built_via: &Path, status: &dyn Fn(&str)) -> Result<Build, KixEvalError> {
        let graph = StoreGraph::from_local(built_via, status)?;
        let warnings = read_warnings(BuildFiles::read(built_via)?.warnings.as_ref());
        Ok(Build::stamped(graph, Origin::Local, warnings))
    }

    /// Load the build that `read` constructs from `bytes`, verifying that it
    /// is valid and targets `cluster`.
    ///
    /// The deploy receipt records the SHA-256 of `bytes` regardless of what
    /// the source claims. `read` must construct the graph from those exact
    /// bytes; the checks here guard against a buggy reader, not a hostile one.
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
        Ok(Build::stamped(graph, origin, Vec::new()))
    }

    /// Check the loaded `graph` for a retired domain, then stamp its annotations.
    fn stamped(mut graph: StoreGraph, origin: Origin, warnings: Vec<LibraryRecord>) -> Build {
        let legacy_domain =
            legacy_domain::check_build(graph.resources.values().map(|r| &r.manifest)).err();
        stamp_annotations(&mut graph);
        Build {
            graph,
            origin,
            warnings,
            legacy_domain,
        }
    }

    /// Return the Kix library's warnings for the build, which every command
    /// that evaluates a build shows. A carried build has none.
    pub fn warnings(&self) -> &[LibraryRecord] {
        &self.warnings
    }

    /// Return the build's stamped graph.
    pub fn graph(&self) -> &StoreGraph {
        &self.graph
    }

    /// Consume the build and return its stamped graph, discarding its origin,
    /// SOPS sources, and carried builds.
    pub fn into_graph(self) -> StoreGraph {
        self.graph
    }

    /// Convert the build into an [`InstallableBuild`] for commands that
    /// install CRDs.
    ///
    /// Fails when the loaded build renders Kix's own CRDs under a retired API
    /// group (`legacy_domain::check_build`). Commands that only read an
    /// existing Activation record do not call this because historical builds
    /// may predate the domain migration.
    pub fn installable(self) -> Result<InstallableBuild, LegacyDomainError> {
        match self.legacy_domain {
            Some(e) => Err(e),
            None => Ok(InstallableBuild(self)),
        }
    }

    /// Return whether the build lives in the local Nix store.
    pub fn is_local(&self) -> bool {
        matches!(self.origin, Origin::Local)
    }

    /// Return the builder provenance and SHA-256 digest of the read bytes for
    /// a carried build, or `None` for a local build.
    pub fn carried_provenance(&self) -> Option<(Provenance, &str)> {
        match &self.origin {
            Origin::Local => None,
            Origin::Carried { source, sha256 } => Some((source.provenance(), sha256)),
        }
    }

    /// Return the SOPS sources for the build's Secrets.
    ///
    /// Local builds read the paths referenced by Secrets on the local
    /// machine, while carried builds read only the files bundled with the
    /// build (`carried_sops`). When `placeholders` is true, nothing is
    /// decrypted and each Secret receives placeholder values so unapproved
    /// plans do not read secrets.
    pub fn sops_sources(&mut self, placeholders: bool) -> Result<SopsSources, String> {
        let Origin::Carried { source, .. } = &mut self.origin else {
            return Ok(SopsSources::Local);
        };
        let manifests = self.graph.resources.values().map(|r| &r.manifest);
        carried_sops(source.sops_files()?, manifests, placeholders)
    }

    /// Return the stamped build carried for the Activation record with
    /// `identity_hash`, after verifying its identity hash and validating the
    /// graph. Returns `Ok(None)` for a local build.
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
                "internal error in Kix: bundle returned a build with the wrong hash\n  \
                 This is a bug in Kix (in `kix bundle`). No project files or cluster resources were changed.\n\n  \
                 Detail:\n    \
                 requested build hash {} from bundle, got build hash {}\n\n  \
                 Next:\n    \
                 {}",
                printable(identity_hash),
                printable(&found),
                crate::eval::error::REPORT_A_BUG
            ));
        }
        graph
            .validate()
            .map_err(|e| format!("the build source's activation {identity_hash}: {e}"))?;
        stamp_annotations(&mut graph);
        Ok(Some(graph))
    }
}

/// Where SOPS sources are read from.
#[derive(Debug, Clone, Default)]
pub enum SopsSources {
    /// The path in each Secret's `kix.run/sops-source`, on this machine.
    #[default]
    Local,
    /// Only the SOPS files the build carries with it
    /// (`SopsSources::carried`).
    Carried(Arc<CarriedSources>),
}

/// The SOPS files a build carries, written to a private directory.
#[derive(Debug)]
pub struct CarriedSources {
    /// Store path named by `kix.run/sops-source` to the file on disk.
    pub files: HashMap<String, PathBuf>,
    /// Plan without decrypting: each Secret gets placeholder values for
    /// the keys it declares.
    pub placeholders: bool,
    _dir: tempfile::TempDir,
}

impl SopsSources {
    /// Write the SOPS files a build carries, by store path, to a fresh
    /// directory, each under its SHA-256 and the end of its store name, and
    /// read them only from there. The caller has checked each file's store
    /// path against its bytes: see [`Build::sops_sources`].
    pub fn carried(sources: HashMap<String, Vec<u8>>, placeholders: bool) -> std::io::Result<Self> {
        let dir = tempfile::tempdir()?;
        let mut files = HashMap::new();
        for (store_path, bytes) in sources {
            let digest: String = Sha256::digest(&bytes)
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect();
            let name = store_path::name_of(&store_path).unwrap_or("source");
            // A file name holds at most 255 bytes. The end of the store name
            // keeps its extension, which sops reads for the file's format.
            let name = name.get(name.len().saturating_sub(190)..).unwrap_or(name);
            let file = dir.path().join(format!("{digest}-{name}"));
            std::fs::write(&file, &bytes)?;
            files.insert(store_path, file);
        }
        Ok(SopsSources::Carried(Arc::new(CarriedSources {
            files,
            placeholders,
            _dir: dir,
        })))
    }
}

/// Filter `files` to the paths referenced by Secrets in `manifests`, and
/// reject any file whose store path does not match its bytes. Each SOPS
/// source comes from `builtins.path` on a single file, so its store path has
/// no references.
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
                "bundled SOPS file {} does not match the checksum recorded when the bundle was built\n  \
                 Nothing was applied to the cluster.\n\n  \
                 Why:\n    \
                 The bundle file was modified or damaged after `kix bundle` created it.\n\n  \
                 Next:\n    \
                 Create a fresh bundle from your project with `kix bundle <cluster>` and run `kix deploy` with the new bundle.",
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
    use crate::eval::store_path::{Method, path_for};

    fn fixture() -> StoreGraph {
        crate::eval::fixtures::kix_enterprise_test()
    }

    /// A source that returns `.0` as the build for any Activation record.
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

    /// Build a carried `Build` of `graph` for `cluster` that returns
    /// `deployed` for any Activation record.
    fn carried_for(
        cluster: &str,
        graph: &StoreGraph,
        deployed: &StoreGraph,
    ) -> Result<Build, String> {
        let (graph, deployed) = (graph.clone(), deployed.clone());
        // Ignores the bytes so a test can hand the core a graph no carried
        // build would hold.
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
