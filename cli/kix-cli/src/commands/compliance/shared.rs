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
    .map_err(|e| miette!("failed to load store graph: {e}"))?;

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

/// Try to resolve a short git commit SHA at the given flake path. Returns
/// `None` if the directory is not a git checkout or `git` is unavailable.
pub fn git_commit(flake_path: &Path) -> Option<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(flake_path)
        .args(["rev-parse", "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?;
    let t = s.trim();
    if t.is_empty() {
        None
    } else {
        Some(t.to_string())
    }
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
