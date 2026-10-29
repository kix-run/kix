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

/// Parse `flake.lock` at the given flake path, returning `None` if it does not exist.
pub fn read_flake_lock(flake_path: &Path) -> Option<serde_json::Value> {
    let lock = flake_path.join("flake.lock");
    let contents = std::fs::read_to_string(&lock).ok()?;
    serde_json::from_str(&contents).ok()
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
    /// Whether the working tree differs from `rev`, including untracked files.
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

/// Read the Git commit and working-tree status at `flake_path`, returning `None`
/// if `flake_path` is not in a Git worktree or `git` is unavailable.
pub fn git_state(flake_path: &Path) -> Option<GitState> {
    let rev = run_git(flake_path, &["rev-parse", "HEAD"])?;
    if rev.is_empty() {
        return None;
    }
    // `git status --porcelain` reports modified, staged, and untracked files,
    // all of which can affect what Nix evaluates in a local directory.
    let status = run_git(flake_path, &["status", "--porcelain"])?;
    Some(GitState {
        rev,
        dirty: !status.is_empty(),
    })
}

fn run_git(path: &Path, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8(out.stdout).ok()?.trim().to_string())
}

/// Generate a syntactically valid UUID v4 string from a BLAKE3 hash of the
/// timestamp, PID, and a monotonic counter.
pub fn new_uuid() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let seed = format!("{nanos}-{pid}-{}", rand_counter());
    let hex = blake3::hash(seed.as_bytes()).to_hex().to_string();
    // Format as 8-4-4-4-12 with version 4 / variant bits.
    let b = hex.as_bytes();
    let g = |r: std::ops::Range<usize>| std::str::from_utf8(&b[r]).unwrap();
    format!(
        "{}-{}-4{}-8{}-{}",
        g(0..8),
        g(8..12),
        g(13..16),
        g(17..20),
        g(20..32)
    )
}

fn rand_counter() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}
