//! Load and verify saved plans for `kix deploy --plan`.

use miette::{IntoDiagnostic, Result, miette};

use crate::cli::PlanArgs;
use crate::output;
use crate::plan;
use kix::plan::document::PlanFlags;

use super::super::CommandContext;
use super::super::plan::{document, dry_run, prepare};

/// Exit status of `kix deploy --plan` when the reviewed plan no longer
/// matches.
pub(super) const EXIT_STALE: i32 = 4;

/// Saved plan loaded for `kix deploy --plan`, paired with its resolved planning
/// flags.
pub(super) struct SavedPlan {
    pub(super) path: String,
    /// The cluster this deploy names, for the commands a refusal suggests.
    pub(super) cluster: String,
    /// `sha256:<hex>` digest of the plan file.
    pub(super) sha256: String,
    pub(super) reviewed: kix::plan::document::Plan,
    pub(super) flags: PlanFlags,
}

/// Load and verify a saved plan file, returning an error before any build if
/// the plan cannot be used or `given` conflicts with its recorded flags.
pub(super) fn load_saved_plan(
    path: &std::path::Path,
    given: &PlanFlags,
    cluster: &str,
) -> Result<SavedPlan> {
    let file = std::fs::File::open(path)
        .map_err(|e| miette!("cannot read the plan {}: {e}", path.display()))?;
    let shown = path.display();
    let (file, sha256) = kix::plan::file::PlanFile::verify(std::io::BufReader::new(file))
        .map_err(|e| {
            use kix::plan::file::PlanFileError;
            let next = match &e {
                PlanFileError::TooLarge(_) => {
                    "deploy without `--plan`, or plan fewer objects per cluster.".to_string()
                }
                PlanFileError::NotAPlanFile => {
                    format!("create the file with `kix plan {cluster} --save {shown}`.")
                }
                PlanFileError::WrongFormat { .. } => format!(
                    "save a new plan file with `kix plan {cluster} --save {shown}` using Kix {}.",
                    kix::version::running().release()
                ),
                _ => format!("save a fresh plan with `kix plan {cluster} --save {shown}`."),
            };
            miette!(
                "cannot read the plan {shown}: {e}. Nothing was applied to the cluster. Next: {next}"
            )
        })?;
    let reviewed = file.into_header().plan;
    let file_name = shown.to_string();
    if let Some(why) = kix::plan::saved::unusable(&reviewed, &file_name, cluster) {
        return Err(miette!("cannot deploy from {shown}: {why}"));
    }
    let flags = kix::plan::saved::flags_for(&reviewed, given, &file_name, cluster)
        .map_err(|e| miette!("cannot deploy from {shown}: {e}"))?;
    Ok(SavedPlan {
        path: path.display().to_string(),
        cluster: cluster.to_string(),
        sha256: format!("sha256:{sha256}"),
        reviewed,
        flags,
    })
}

/// Recompute the plan for `kix deploy --plan <file> --dry-run`, compare it
/// against `saved`, and exit 0 on a match or [`EXIT_STALE`] on a mismatch.
pub(super) fn check_saved_plan(
    saved: &SavedPlan,
    args: &PlanArgs,
    ctx: &mut CommandContext,
) -> Result<()> {
    let format = output::format();
    let Some(mut p) = prepare(args, saved.flags, ctx)? else {
        return Ok(());
    };
    let report = match p.client.clone() {
        Some(client) => Some(dry_run(&mut p, false, client, ctx)?),
        None => None,
    };
    let doc = document(&mut p, report.as_ref(), false);
    let mut comparison = kix::plan::saved::compare(&saved.reviewed, &doc);
    comparison.plan_sha256 = Some(saved.sha256.clone());
    match format {
        crate::cli::OutputFormat::Json => println!(
            "{}",
            serde_json::to_string_pretty(&comparison).into_diagnostic()?
        ),
        crate::cli::OutputFormat::Yaml => {
            print!("{}", kix::yaml::to_string(&comparison).into_diagnostic()?)
        }
        _ => print!(
            "{}",
            plan::render::render_comparison(
                &comparison,
                &saved.reviewed,
                &saved.path,
                &saved.cluster
            )
        ),
    }
    if !comparison.matches {
        std::process::exit(EXIT_STALE);
    }
    // Exit with `EXIT_WOULD_STOP` when a matching plan still has rejected
    // writes or unaccepted migrations, matching `kix plan`.
    let migrations_refused = !doc.migrations.items().is_empty() && !saved.flags.accept_migrations;
    if doc.stops() || migrations_refused {
        if format == crate::cli::OutputFormat::Text {
            eprintln!(
                "{}",
                output::yellow(
                    "The deploy would stop: the saved plan has a refused write or a stateful workload replacement without `--accept-migrations`. Nothing was applied to the cluster."
                )
            );
        }
        std::process::exit(super::super::plan::EXIT_WOULD_STOP);
    }
    Ok(())
}
