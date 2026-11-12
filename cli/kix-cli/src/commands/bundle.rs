//! Implement `kix bundle`, which writes a cluster build to a standalone
//! `.kix.bundle` file that `--bundle` and `--deployed-bundle` can read without Nix.

use std::path::PathBuf;

use miette::{Result, miette};

use crate::cli::BundleArgs;
use crate::output;

use super::CommandContext;

/// Build `<cluster>` and write its bundle archive to `FILE` (or `<cluster>.kix.bundle`).
pub fn run(args: &BundleArgs, ctx: &mut CommandContext) -> Result<()> {
    let status = |msg: &str| output::status_line(msg);
    let build = super::build_flake(&ctx.global, &args.cluster, &status, super::BUILD_FAILED)?;
    output::clear_status_line();
    let receipt = ctx.receipts.of_build(&build, &ctx.global.flake);
    let object = |v: &serde_json::Value| v.as_object().cloned().unwrap_or_default();
    let provenance = kix_bundle::Provenance {
        source: object(&receipt["source"]),
        inputs: receipt["inputs"]
            .as_array()
            .into_iter()
            .flatten()
            .map(object)
            .collect(),
        builder: object(&receipt["builder"]),
    };
    let kix = crate::plan::kix_build();
    let kix_rev = match &kix.store_path {
        Some(path) => format!("{} ({path})", kix.version),
        None => kix.version,
    };
    let file = args
        .file
        .clone()
        .unwrap_or_else(|| PathBuf::from(format!("{}.{}", args.cluster, kix_bundle::EXTENSION)));
    let written = kix_bundle::write_build(build.graph(), &kix_rev, Some(provenance), &file)
        .map_err(|e| miette!("{e}"))?;
    crate::esay!(
        "Wrote {} ({} files, sha256:{})",
        file.display(),
        written.files,
        written.sha256
    );
    Ok(())
}
