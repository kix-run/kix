//! Build a cluster's activation derivation via `nix build`.
//!
//! Returns the store path of the activation folder, which contains:
//! - `activation` — symlink to the Activation CRD store path
//! - `kix-packages.json` — PI→resource store path index
//!
//! The Rust CLI then uses `StoreGraph::from_result_dir` to load the graph.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::error::KixEvalError;

/// Build `cluster-<name>-activation` and return the result store path.
///
/// `status_fn` is called with nix build progress lines as they arrive,
/// allowing the caller to update a spinner or progress bar.
pub fn build_cluster_activation(
    flake_path: &Path,
    cluster_name: &str,
) -> Result<PathBuf, KixEvalError> {
    build_cluster_activation_with_status(flake_path, cluster_name, &|_| {})
}

/// Build with a status callback for progress updates.
pub fn build_cluster_activation_with_status(
    flake_path: &Path,
    cluster_name: &str,
    status_fn: &dyn Fn(&str),
) -> Result<PathBuf, KixEvalError> {
    if !cluster_name
        .chars()
        .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
    {
        return Err(KixEvalError::not_found(cluster_name));
    }

    let flake_ref = format!(".#cluster-{}-activation", cluster_name);

    tracing::info!(
        cluster = cluster_name,
        flake_ref = %flake_ref,
        flake_path = %flake_path.display(),
        "building cluster activation"
    );

    status_fn(&format!("Evaluating cluster '{cluster_name}'..."));

    let mut child = Command::new("nix")
        .args([
            "build",
            &flake_ref,
            "--no-link",
            "--print-out-paths",
            "--extra-experimental-features",
            "nix-command flakes pipe-operators",
        ])
        .current_dir(flake_path)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| KixEvalError::StoreGraphError {
            message: format!("failed to run nix build: {e}"),
        })?;

    // Stream stderr to update progress
    let stderr = child.stderr.take().unwrap();
    let stderr_reader = BufReader::new(stderr);
    let mut stderr_lines = Vec::new();

    for line in stderr_reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };
        // Nix build outputs progress on stderr — show the latest line
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            // Extract meaningful progress from nix output
            if trimmed.starts_with("building") || trimmed.starts_with("copying") {
                status_fn(trimmed);
            } else if trimmed.contains("evaluating") {
                status_fn(&format!("Evaluating '{cluster_name}'..."));
            } else if trimmed.starts_with("this derivation") {
                status_fn(&format!("Building '{cluster_name}'..."));
            }
        }
        stderr_lines.push(line);
    }

    let output = child
        .wait_with_output()
        .map_err(|e| KixEvalError::StoreGraphError {
            message: format!("nix build failed to complete: {e}"),
        })?;

    if !output.status.success() {
        let stderr_text = stderr_lines.join("\n");
        if stderr_text.contains("does not provide attribute")
            || (stderr_text.contains("attribute") && stderr_text.contains("missing"))
        {
            return Err(KixEvalError::not_found(cluster_name));
        }
        return Err(KixEvalError::StoreGraphError {
            message: format!("nix build failed: {stderr_text}"),
        });
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let result_path = stdout.trim();
    if result_path.is_empty() {
        return Err(KixEvalError::StoreGraphError {
            message: "nix build produced no output path".to_string(),
        });
    }

    let path = PathBuf::from(result_path);
    tracing::info!(
        cluster = cluster_name,
        path = %path.display(),
        "activation built"
    );
    Ok(path)
}
