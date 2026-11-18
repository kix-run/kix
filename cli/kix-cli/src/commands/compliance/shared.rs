//! Shared helpers for compliance exports.

use std::path::Path;

use miette::Result;

use kix::eval::store_graph::{StoreGraph, store_hash};

use crate::commands::CommandContext;

/// Build the cluster and load its stamped graph, so downstream consumers
/// see the same identity hashes that deploy uses.
pub fn build_and_load(ctx: &CommandContext, cluster: &str) -> Result<StoreGraph> {
    crate::esay!("Building cluster '{cluster}'...");
    let status = |msg: &str| {
        crate::esay!("  {msg}");
    };
    let build = crate::commands::build_flake(
        &ctx.global,
        cluster,
        &status,
        crate::commands::ACTIVATION_BUILD_FAILED,
    )?;
    Ok(build.into_graph())
}

/// Return the 32-character Nix store hash of the activation path in `graph`.
pub fn activation_identity_hash(graph: &StoreGraph) -> String {
    store_hash(&graph.activation_path)
}

/// Parse `flake.lock` at the given flake path, returning `None` if it is
/// missing or unreadable.
pub fn read_flake_lock(flake_path: &Path) -> Option<serde_json::Value> {
    kix::flake_lock::read(flake_path).ok()
}

/// Compute the BLAKE3 hex digest of `input`.
pub fn blake3_hex(input: &str) -> String {
    blake3::Hasher::new()
        .update(input.as_bytes())
        .finalize()
        .to_hex()
        .to_string()
}

/// Format the current UTC wall-clock time as an RFC 3339 string.
pub fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Git commit and working-tree cleanliness of the source directory at build time.
///
/// Recording `dirty` alongside `rev` ensures provenance receipts and SLSA
/// attestations distinguish clean commits from builds that included uncommitted
/// working-tree changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitState {
    /// The commit `HEAD` points at.
    pub rev: String,
    /// Whether tracked files differ from `rev`. Untracked files are not part
    /// of the flake Nix evaluates, so they do not count.
    pub dirty: bool,
}

impl GitState {
    /// Format the revision using Nix's convention (`<rev>-dirty` when dirty).
    pub fn dirty_rev(&self) -> String {
        if self.dirty {
            format!("{}-dirty", self.rev)
        } else {
            self.rev.clone()
        }
    }
}

/// Read the Git commit and working-tree status of the flake at `flake_path`
/// from `nix flake metadata`, returning `None` if the flake is not in a Git
/// repository with a commit, or Nix cannot read it.
pub fn git_state(flake_path: &Path) -> Option<GitState> {
    match kix::eval::nix::flake_revision(flake_path) {
        Ok(revision) => revision.map(|r| GitState {
            rev: r.rev,
            dirty: r.dirty,
        }),
        Err(e) => {
            tracing::debug!(error = %e, "could not read the flake's Git revision");
            None
        }
    }
}

/// Generate a random UUID v4 string.
pub fn new_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}
