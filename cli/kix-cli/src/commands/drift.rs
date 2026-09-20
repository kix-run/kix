//! Check runtime content drift through the applied-hash stamp. This command
//! needs a kubeconfig but no flake or Nix build because the hash is cached on
//! the object at apply time.

use miette::{IntoDiagnostic, Result, miette};

use kix::cluster::drift::{self, DriftReport, DriftVerdict, ForeignOwner};
use kix::cluster::fetch;

use crate::cli::{DriftArgs, GlobalArgs, OutputFormat};
use crate::output;

pub fn run(args: &DriftArgs, global: &GlobalArgs) -> Result<()> {
    let _ = args;
    let runtime = tokio::runtime::Runtime::new().into_diagnostic()?;

    let json = global.output == Some(OutputFormat::Json);
    if !global.quiet && !json {
        println!("Connecting to cluster...");
    }

    let reports = runtime.block_on(async {
        let client = fetch::make_client(global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect: {e}"))?;
        let discovery = fetch::discover_resources(&client)
            .await
            .map_err(|e| miette!("{e}"))?;
        drift::check_cluster(&client, &discovery)
            .await
            .map_err(|e| miette!("drift check failed: {e}"))
    })?;

    let drifted = reports
        .iter()
        .filter(|r| matches!(r.verdict, DriftVerdict::Drifted { .. }))
        .count();

    if json {
        print_json(&reports)?;
    } else {
        print_text(&reports, global.quiet);
    }

    if drifted > 0 {
        std::process::exit(1);
    }
    Ok(())
}

fn print_text(reports: &[DriftReport], quiet: bool) {
    if !quiet {
        println!("{} kix-managed resources", reports.len());
        println!();
    }

    for report in reports {
        let rid = report.rid.to_string();
        match &report.verdict {
            DriftVerdict::InSync => {
                println!(
                    "  {} {:<50} {}",
                    output::green("✓"),
                    rid,
                    output::green("in sync")
                );
            }
            DriftVerdict::Unstamped => {
                println!(
                    "  {} {:<50} {}",
                    output::dim("·"),
                    rid,
                    output::dim("unstamped (no applied-hash; predates stamping)"),
                );
            }
            DriftVerdict::NoFieldset => {
                println!(
                    "  {} {:<50} {}",
                    output::yellow("?"),
                    rid,
                    output::yellow("no managedFields. Check cannot run"),
                );
            }
            DriftVerdict::Drifted { foreign } => {
                println!(
                    "  {} {:<50} {}",
                    output::red("✗"),
                    rid,
                    output::red("DRIFTED")
                );
                for owner in foreign {
                    print_owner(owner);
                }
                if foreign.is_empty() {
                    println!(
                        "      {}",
                        output::dim(
                            "fields managed by Kix have changed; Kubernetes has not recorded another tool as their owner"
                        ),
                    );
                }
            }
        }
    }

    let in_sync = count(reports, |v| matches!(v, DriftVerdict::InSync));
    let drifted = count(reports, |v| matches!(v, DriftVerdict::Drifted { .. }));
    let unstamped = count(reports, |v| matches!(v, DriftVerdict::Unstamped));
    let no_fieldset = count(reports, |v| matches!(v, DriftVerdict::NoFieldset));

    println!();
    print!("Drift: {} in sync", output::green(&in_sync.to_string()));
    if drifted > 0 {
        print!(", {} drifted", output::red(&drifted.to_string()));
    }
    if unstamped > 0 {
        print!(", {} unstamped", output::dim(&unstamped.to_string()));
    }
    if no_fieldset > 0 {
        print!(", {} unreadable", output::yellow(&no_fieldset.to_string()));
    }
    println!();
}

fn print_owner(owner: &ForeignOwner) {
    let when = owner.time.as_deref().unwrap_or("unknown time");
    let via = owner
        .subresource
        .as_deref()
        .map(|s| format!(" via /{s}"))
        .unwrap_or_default();
    if owner.paths.is_empty() {
        println!(
            "      {}",
            output::yellow(&format!(
                "co-owned by {} ({}{}) at {}",
                owner.manager, owner.operation, via, when
            )),
        );
    } else {
        for path in &owner.paths {
            println!(
                "      {}",
                output::yellow(&format!(
                    "{} taken by {} ({}{}) at {}",
                    path, owner.manager, owner.operation, via, when
                )),
            );
        }
    }
}

fn count(reports: &[DriftReport], pred: impl Fn(&DriftVerdict) -> bool) -> usize {
    reports.iter().filter(|r| pred(&r.verdict)).count()
}

fn print_json(reports: &[DriftReport]) -> Result<()> {
    let items: Vec<serde_json::Value> = reports
        .iter()
        .map(|r| {
            let (verdict, foreign) = match &r.verdict {
                DriftVerdict::InSync => ("in-sync", vec![]),
                DriftVerdict::Unstamped => ("unstamped", vec![]),
                DriftVerdict::NoFieldset => ("no-fieldset", vec![]),
                DriftVerdict::Drifted { foreign } => ("drifted", foreign.clone()),
            };
            serde_json::json!({
                "kind": r.rid.kind,
                "namespace": r.rid.namespace,
                "name": r.rid.name,
                "verdict": verdict,
                "foreignOwners": foreign.iter().map(|o| serde_json::json!({
                    "manager": o.manager,
                    "operation": o.operation,
                    "subresource": o.subresource,
                    "time": o.time,
                    "paths": o.paths,
                })).collect::<Vec<_>>(),
            })
        })
        .collect();

    let summary = serde_json::json!({
        "inSync": count(reports, |v| matches!(v, DriftVerdict::InSync)),
        "drifted": count(reports, |v| matches!(v, DriftVerdict::Drifted { .. })),
        "unstamped": count(reports, |v| matches!(v, DriftVerdict::Unstamped)),
        "noFieldset": count(reports, |v| matches!(v, DriftVerdict::NoFieldset)),
    });

    let out = serde_json::json!({ "resources": items, "summary": summary });
    println!("{}", serde_json::to_string_pretty(&out).into_diagnostic()?);
    Ok(())
}
