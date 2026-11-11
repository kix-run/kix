//! Check runtime content drift using the `kix.run/applied-hash` annotation.
//!
//! Because Kix stamps the hash on each object at apply time, this command needs
//! only a kubeconfig and does not evaluate the flake or run a Nix build.

use miette::{IntoDiagnostic, Result, miette};

use crate::client;
use kix::cluster::activation::Records;
use kix::cluster::discovery;
use kix::cluster::drift::{self, DriftReport, DriftVerdict, ForeignOwner, UnrecordedScale};

use crate::cli::{DriftArgs, GlobalArgs, OutputFormat};
use crate::output;

pub fn run(args: &DriftArgs, global: &GlobalArgs) -> Result<()> {
    let runtime = tokio::runtime::Runtime::new().into_diagnostic()?;

    let json = output::format() == OutputFormat::Json;
    if !json {
        crate::say!("Connecting to cluster...");
    }

    let reports = runtime.block_on(async {
        let client = client::make_client(global.context.as_deref())
            .await
            .map_err(|e| miette!("failed to connect: {e}"))?;
        let discovery = discovery::discover_resources(&client)
            .await
            .map_err(|e| miette!("{e}"))?;
        // Open `Records` to enforce the domain gate; without it, objects under a
        // retired API group could not be attributed to a Kix cluster.
        let records = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;
        let (reports, tenancy) =
            drift::check_cluster(&client, &discovery, &records, args.cluster.as_deref())
                .await
                .map_err(|e| miette!("drift check failed: {e}"))?;
        if args.cluster.is_some() {
            tenancy.require_records().map_err(|e| miette!("{e}"))?;
        }
        Ok::<_, miette::Report>(reports)
    })?;

    let drifted = reports
        .iter()
        .filter(|r| matches!(r.verdict, DriftVerdict::Drifted { .. }))
        .count();

    if json {
        print_json(&reports)?;
    } else {
        // Show cluster names beside resources only when the check spans multiple
        // Kix clusters.
        let clusters: std::collections::BTreeSet<&str> = reports
            .iter()
            .flat_map(|r| r.clusters.iter().map(String::as_str))
            .collect();
        print_text(&reports, clusters.len() > 1, args.cluster.as_deref());
    }

    if drifted > 0 {
        std::process::exit(1);
    }
    Ok(())
}

fn print_text(reports: &[DriftReport], name_clusters: bool, cluster: Option<&str>) {
    crate::say!("{} Kix-managed resources", reports.len());
    crate::say!();

    for report in reports {
        let rid = if name_clusters {
            format!("{} [{}]", report.rid, owners_label(&report.clusters))
        } else {
            report.rid.to_string()
        };
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
                    output::dim(&format!(
                        "not checked (no {} annotation; the next deploy adds it)",
                        kix::manifest::keys::APPLIED_HASH
                    )),
                );
            }
            DriftVerdict::NoFieldset => {
                println!(
                    "  {} {:<50} {}",
                    output::yellow("?"),
                    rid,
                    output::yellow("not checked (no Kubernetes field ownership entry for Kix)"),
                );
            }
            DriftVerdict::Drifted {
                foreign,
                unrecorded_scale,
            } => {
                println!(
                    "  {} {:<50} {}",
                    output::red("✗"),
                    rid,
                    output::red("DRIFTED")
                );
                for owner in foreign {
                    print_owner(owner);
                }
                if let Some(scale) = unrecorded_scale {
                    println!("      {}", output::yellow(&scale_line(scale)));
                } else if foreign.is_empty() {
                    println!(
                        "      {}",
                        output::dim(
                            "fields Kix applied changed on the cluster (no other field manager recorded)"
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
        print!(
            ", {} missing applied-hash annotation",
            output::dim(&unstamped.to_string())
        );
    }
    if no_fieldset > 0 {
        print!(
            ", {} missing field ownership entry",
            output::yellow(&no_fieldset.to_string())
        );
    }
    println!();
    if drifted > 0 {
        let cluster = cluster.unwrap_or("<cluster>");
        println!();
        println!("Next:");
        println!(
            "  Run `kix plan {cluster}` to see how a deploy handles these objects, or `kix deploy {cluster} --reconcile` to restore Kix's values (add `--force-conflicts` when another tool owns the field)."
        );
    }
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
                "co-owned by {} ({}{}, {}; no specific fields recorded)",
                owner.manager, owner.operation, via, when
            )),
        );
    } else {
        for path in &owner.paths {
            println!(
                "      {}",
                output::yellow(&format!(
                    "{} owned by {} ({}{}, {})",
                    path, owner.manager, owner.operation, via, when
                )),
            );
        }
    }
}

/// Format a drift line for a replica-count change that Kubernetes did not record
/// in `managedFields`.
fn scale_line(scale: &UnrecordedScale) -> String {
    if scale.deployed == scale.live {
        format!(
            "{} is {} (matches deployed value, but a write via /scale took ownership from Kix)",
            scale.path, scale.live
        )
    } else {
        format!(
            "{} changed from {} to {} via /scale (no field manager recorded)",
            scale.path, scale.deployed, scale.live
        )
    }
}

/// Format the Kix cluster names owning a resource.
fn owners_label(clusters: &[String]) -> String {
    if clusters.is_empty() {
        "no Kix cluster".to_string()
    } else {
        clusters.join(", ")
    }
}

fn count(reports: &[DriftReport], pred: impl Fn(&DriftVerdict) -> bool) -> usize {
    reports.iter().filter(|r| pred(&r.verdict)).count()
}

fn print_json(reports: &[DriftReport]) -> Result<()> {
    let items: Vec<serde_json::Value> = reports
        .iter()
        .map(|r| {
            let (verdict, foreign, scale) = match &r.verdict {
                DriftVerdict::InSync => ("in-sync", vec![], None),
                DriftVerdict::Unstamped => ("unstamped", vec![], None),
                DriftVerdict::NoFieldset => ("no-fieldset", vec![], None),
                DriftVerdict::Drifted {
                    foreign,
                    unrecorded_scale,
                } => ("drifted", foreign.clone(), unrecorded_scale.as_ref()),
            };
            serde_json::json!({
                "kind": r.rid.kind,
                "namespace": r.rid.namespace,
                "name": r.rid.name,
                "verdict": verdict,
                "clusters": r.clusters,
                "foreignOwners": foreign.iter().map(|o| serde_json::json!({
                    "manager": o.manager,
                    "operation": o.operation,
                    "subresource": o.subresource,
                    "time": o.time,
                    "paths": o.paths,
                })).collect::<Vec<_>>(),
                "unrecordedScale": scale.map(|s| serde_json::json!({
                    "path": s.path,
                    "deployed": s.deployed,
                    "live": s.live,
                })),
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

#[cfg(test)]
mod tests {
    use super::*;

    fn scale(deployed: i64, live: i64) -> UnrecordedScale {
        UnrecordedScale {
            path: "spec.replicas".to_string(),
            deployed,
            live,
        }
    }

    #[test]
    fn scale_line_names_both_values_when_they_differ() {
        assert_eq!(
            scale_line(&scale(2, 0)),
            "spec.replicas changed from 2 to 0 via /scale (no field manager recorded)"
        );
    }

    #[test]
    fn scale_line_says_the_value_is_back_when_it_matches() {
        assert_eq!(
            scale_line(&scale(2, 2)),
            "spec.replicas is 2 (matches deployed value, but a write via /scale took ownership from Kix)"
        );
    }
}
