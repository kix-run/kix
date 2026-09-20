//! Shared helpers for compliance exports.

use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};

use kix::eval::build_cluster_activation_with_status;
use kix::eval::store_graph::{StoreGraph, store_hash};
use kix::manifest::stamp::stamp_annotations;

use crate::commands::CommandContext;

/// Build the cluster and load its StoreGraph. Stamps annotations so downstream
/// consumers see the same identity-hashes / provenance that deploy uses.
pub fn build_and_load(ctx: &CommandContext, cluster: &str) -> Result<(PathBuf, StoreGraph)> {
    let flake_path = resolve_flake_path(&ctx.global.flake)?;

    if !ctx.global.quiet {
        eprintln!("Building cluster '{cluster}'...");
    }
    let overrides = ctx.global.input_overrides();
    let result_path =
        build_cluster_activation_with_status(&flake_path, cluster, &overrides, &|msg| {
            if !ctx.global.quiet {
                eprintln!("  {msg}");
            }
        })
        .map_err(|e| miette!("failed to build cluster activation: {e}"))?;

    let mut graph = StoreGraph::from_result_dir_with_status(&result_path, &|msg| {
        if !ctx.global.quiet {
            eprintln!("  {msg}");
        }
    })
    .map_err(|e| miette!("{e}"))?;

    stamp_annotations(&mut graph);
    Ok((result_path, graph))
}

/// 32-char identity hash of the activation store path (the kix "root" hash).
pub fn activation_identity_hash(graph: &StoreGraph) -> String {
    store_hash(&graph.activation_path)
}

pub fn resolve_flake_path(flake: &str) -> Result<PathBuf> {
    if flake.contains(':') {
        Ok(PathBuf::from(flake))
    } else {
        let path = PathBuf::from(flake);
        if path.is_absolute() {
            Ok(path)
        } else {
            let cwd = std::env::current_dir().into_diagnostic()?;
            Ok(cwd.join(path))
        }
    }
}

/// Parse `flake.lock` at the given flake path, returning `None` if it does not exist.
pub fn read_flake_lock(flake_path: &Path) -> Option<serde_json::Value> {
    let lock = flake_path.join("flake.lock");
    let contents = std::fs::read_to_string(&lock).ok()?;
    serde_json::from_str(&contents).ok()
}

/// BLAKE3 hex hash of a string (used for SLSA subject digests).
pub fn blake3_hex(input: &str) -> String {
    blake3::Hasher::new()
        .update(input.as_bytes())
        .finalize()
        .to_hex()
        .to_string()
}

/// Current wall-clock time in RFC3339 format.
pub fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// Where the source stood when this ran: the commit, and whether the working
/// tree matched it.
///
/// The second half is the part that was missing, and it mattered. Recording
/// `git rev-parse HEAD` alone says "this deploy came from commit X" even when
/// the tree that was built has uncommitted changes, which is exactly the
/// state CI used to deploy production from. An attestation that names a
/// commit not containing the deployed content is worse than no attestation,
/// because it will be believed.
///
/// Nix takes the same position and states it more strongly: a flake with a
/// dirty worktree gets no revision at all. Kix records the revision and the
/// dirty flag, and spells the combination the way Nix does, `<rev>-dirty`, so
/// the two agree when someone compares them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitState {
    /// The commit HEAD points at.
    pub rev: String,
    /// Whether the working tree differs from that commit, including
    /// untracked files.
    pub dirty: bool,
}

impl GitState {
    /// Nix's spelling: the revision, plus `-dirty` when the tree has changes.
    pub fn dirty_rev(&self) -> String {
        if self.dirty {
            format!("{}-dirty", self.rev)
        } else {
            self.rev.clone()
        }
    }
}

/// Read the git state at the given path. `None` when the directory is not a
/// git checkout or `git` is unavailable.
pub fn git_state(flake_path: &Path) -> Option<GitState> {
    let rev = run_git(flake_path, &["rev-parse", "HEAD"])?;
    if rev.is_empty() {
        return None;
    }
    // `--porcelain` lists modified, staged and untracked files. Untracked
    // counts: our own CI staged an edit precisely so Nix would pick it up, so
    // "staged but not committed" is the case this has to catch.
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

/// Try to resolve the nix version string. `None` if `nix` is unavailable.
pub fn nix_version() -> Option<String> {
    let out = std::process::Command::new("nix")
        .arg("--version")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout)
        .ok()
        .map(|s| s.trim().to_string())
}

/// UUID v4 as a string. kix doesn't pull in `uuid` as a workspace dep, and
/// OSCAL only requires the value be a syntactically valid UUID, so we build
/// one from `blake3` over a random-ish seed.
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
