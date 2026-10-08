//! Where the build a command plans and deploys comes from.
//!
//! A [`BuildSource`] is made together with the build it holds, as a
//! [`StoreGraph`]: whoever makes a source reads and verifies the build first,
//! and gives the graph only once it has passed. Plan and deploy then work
//! from that one graph and ask the source only for what goes with it: where
//! the Secrets' SOPS files are read from, what the machine that made the
//! build recorded about its source, and the earlier builds the cluster's
//! Activation records name.
//!
//! [`NixStore`] is a build in this machine's Nix store, built from the flake
//! the command names. Another source can be implemented outside this crate:
//! it reads its files with [`crate::eval::manifest_json::parse_manifest`],
//! assembles them with [`StoreGraph::assemble`], and checks the result with
//! [`StoreGraph::validate`], as a result directory is read.

use serde::{Deserialize, Serialize};

use crate::cluster::secrets::SopsSources;
use crate::eval::store_graph::StoreGraph;

/// The source of a build, beyond the build's graph.
pub trait BuildSource {
    /// Whether the build is in this machine's Nix store at its graph's
    /// `result_dir`, so that later commands can find it there: the local
    /// activation cache, `--current-activation`, and soft `kix gc`.
    fn in_local_store(&self) -> bool;

    /// Where the Secrets' SOPS sources are read from. With `placeholders`,
    /// a source whose SOPS files come with the build decrypts nothing, and
    /// each Secret gets placeholder values, so a plan made before anyone
    /// approved it reads no secret. [`SopsSources::Local`] reads the files on
    /// this machine and ignores `placeholders`.
    fn sops_sources(&mut self, placeholders: bool) -> Result<SopsSources, String>;

    /// What the machine that made the build recorded about its source, for
    /// the deploy receipt. `None` when this machine made the build from the
    /// flake the command names, whose source tree it reads itself.
    fn provenance(&self) -> Option<Provenance>;

    /// The build of the Activation record with `identity_hash`, read and
    /// verified as the new build was. `Ok(None)` when this source holds no
    /// such build, and the caller looks in the local Nix store. An error
    /// when it holds the build and the build no longer verifies, which is
    /// not the same as a missing build.
    fn deployed_build(&self, identity_hash: &str) -> Result<Option<StoreGraph>, String>;
}

/// A build in this machine's Nix store. Its SOPS sources are the files its
/// Secrets name on this machine, and it holds no earlier build beyond what
/// the store holds.
#[derive(Debug, Clone, Copy, Default)]
pub struct NixStore;

impl BuildSource for NixStore {
    fn in_local_store(&self) -> bool {
        true
    }

    fn sops_sources(&mut self, _placeholders: bool) -> Result<SopsSources, String> {
        Ok(SopsSources::Local)
    }

    fn provenance(&self) -> Option<Provenance> {
        None
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
