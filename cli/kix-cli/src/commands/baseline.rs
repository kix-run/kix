//! The closures a plan compares against.
//!
//! A deploy or a rollback decides what to do by comparing compiler outputs:
//! the closure it is about to apply, and the closure the cluster is already
//! running. That second one comes from the Active Activation record.
//!
//! It is not the whole story. A deploy that stops part way applies some of its
//! closure and never becomes Active, so its leftovers are described by neither
//! side and the next plan cannot see them (kixpkgs#82). Since the record is
//! now created before the first wave and marked `Failed` when the run stops,
//! those closures can be recovered by hash and folded in.
//!
//! Everything here resolves a record to a closure in the local store. Nothing
//! reads the cluster's objects: the kix invariant is that live state is
//! consulted to execute and to observe, never to decide
//! (`v2_discussions/81_deploy_as_lifecycle_engine.md`, "Closure A to closure
//! B"). Listing the records is a read of our own bookkeeping, not of the
//! objects being reasoned about.

use kix::cluster::activation::{self, DeployingActivation, FailedActivation};
use kix::eval::store_graph::StoreGraph;
use kix::manifest::stamp::stamp_annotations;
use kube::{client::Client, discovery::ApiResource};
use serde_json::Value;

use crate::output;

/// Closures left behind by deploys that stopped before finalizing.
#[derive(Debug, Default)]
pub struct FailedBaseline {
    /// One stamped manifest set per record we could resolve, oldest first.
    pub closures: Vec<Vec<Value>>,
    /// Record names to supersede once this plan finalizes. Only the ones whose
    /// closure was actually folded in: a record we could not resolve has not
    /// been reconciled and must keep asking.
    pub consumed: Vec<String>,
    /// Records whose closure is not in this machine's store.
    pub unresolved: Vec<FailedActivation>,
}

impl FailedBaseline {
    pub fn is_empty(&self) -> bool {
        self.closures.is_empty()
    }
}

/// Resolve every `Failed` record for a cluster to its closure.
///
/// A record that cannot be resolved is reported, not fatal, and deliberately
/// not consumed. It usually means the deploy that failed ran on a different
/// machine, so this one cannot know what it applied; saying so and leaving the
/// record in place is more honest than superseding it and forgetting.
pub async fn load_failed(
    client: &Client,
    ar: &ApiResource,
    cluster: &str,
    quiet: bool,
) -> FailedBaseline {
    let records = match activation::find_failed(client, ar, cluster).await {
        Ok(records) => records,
        Err(e) => {
            tracing::debug!("could not list failed activations: {e}");
            return FailedBaseline::default();
        }
    };

    let mut out = FailedBaseline::default();
    for record in records {
        let Some(hash) = record.identity_hash.clone() else {
            out.unresolved.push(record);
            continue;
        };
        let result_dir = record
            .built_via
            .as_ref()
            .map(std::path::PathBuf::from)
            .filter(|p| p.join("kix-packages.json").exists())
            .or_else(|| kix::eval::store::resolve_activation_by_hash(cluster, &hash));

        let Some(result_dir) = result_dir else {
            out.unresolved.push(record);
            continue;
        };
        let noop = |_: &str| {};
        match StoreGraph::from_result_dir_with_status(&result_dir, &noop) {
            Ok(mut graph) => {
                stamp_annotations(&mut graph);
                if !quiet {
                    println!(
                        "  {} folding in the closure of failed deploy {} ({}...)",
                        output::yellow("!"),
                        output::bold(&record.name),
                        &hash[..8.min(hash.len())],
                    );
                    if let Some(reason) = &record.reason {
                        println!("    it stopped because: {reason}");
                    }
                }
                out.closures.push(
                    graph
                        .resources
                        .values()
                        .map(|r| r.manifest.clone())
                        .collect(),
                );
                out.consumed.push(record.name.clone());
            }
            Err(_) => out.unresolved.push(record),
        }
    }

    if !quiet {
        report_unresolved(&out.unresolved, cluster);
    }
    out
}

fn report_unresolved(unresolved: &[FailedActivation], cluster: &str) {
    for record in unresolved {
        eprintln!(
            "{} failed deploy {} left objects behind, and its build is not in this machine's store.",
            output::yellow("warning:"),
            output::bold(&record.name),
        );
        eprintln!(
            "  Nothing here can say what it applied, so this plan leaves it alone. Deploy from \
             the machine that built it, or sweep the objects with `kix gc --hard {cluster}` and \
             then discard the record, which hard gc does not touch:"
        );
        eprintln!(
            "    kubectl patch {}/{} --subresource=status --type=merge \
             -p '{{\"status\":{{\"phase\":\"Superseded\"}}}}'",
            kix::manifest::keys::ACTIVATIONS_CRD,
            record.name,
        );
    }
}

/// Whether another deploy of this cluster looks like it is still running, in
/// which case the failed closures must not be folded in.
///
/// A `Deploying` record is either a live deploy or one whose process died
/// before it could mark itself `Failed`, and nothing here can tell those
/// apart. The difference matters in one direction only: folding in a closure
/// that another machine is still applying could prune objects out from under
/// it. So this does not refuse, it drops the fold, which leaves the plan
/// exactly as it was before any of this existed. A wrong guess costs the user
/// one deploy that does not reconcile the leftovers, not a command they
/// cannot run.
///
/// Refusing outright was the first shape of this and it was worse: a deploy
/// killed with SIGKILL leaves a `Deploying` record forever, and every deploy
/// and rollback of that cluster would have been blocked behind a manual
/// `kubectl patch`.
///
/// Operator-driven records are ignored. Those belong to the controller, which
/// resumes them itself.
pub async fn deploy_in_flight(
    client: &Client,
    ar: &ApiResource,
    cluster: &str,
) -> Option<DeployingActivation> {
    match activation::find_deploying(client, ar, cluster).await {
        Ok(found) => found.into_iter().find(|record| !record.operator_driven),
        Err(e) => {
            tracing::debug!("could not list deploying activations: {e}");
            None
        }
    }
}

/// Say why the leftovers of failed deploys are not being reconciled this run,
/// and how to get them reconciled.
pub fn report_in_flight(record: &DeployingActivation, quiet: bool) {
    if quiet {
        return;
    }
    let since = record
        .created_at
        .as_deref()
        .map(|t| format!(", started {t}"))
        .unwrap_or_default();
    eprintln!(
        "{} activation {}{since} is still marked as deploying, so this plan leaves \
         any half-applied work alone.",
        output::yellow("note:"),
        output::bold(&record.name),
    );
    eprintln!("  If that deploy is still running, let it finish. If its process is gone, mark the");
    eprintln!("  record failed and re-run; the next plan will then reconcile what it left:");
    eprintln!(
        "    kubectl patch {}/{} --subresource=status --type=merge \\",
        kix::manifest::keys::ACTIVATIONS_CRD,
        record.name,
    );
    eprintln!(
        "      -p '{{\"status\":{{\"phase\":\"Failed\",\"failure\":{{\"reason\":\"abandoned\"}}}}}}'"
    );
}
