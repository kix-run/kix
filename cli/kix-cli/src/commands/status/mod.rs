//! `kix status`: is what Kix deployed present, unchanged, and ready?
//!
//! [`kix::cluster::observe`] reads the cluster once. This module selects the
//! checks, builds the [`StatusDocument`], and prints it.

mod document;
#[cfg(test)]
mod tests;
mod text;

use std::collections::BTreeMap;

use miette::{IntoDiagnostic, Result, miette};

use crate::cli::StatusArgs;
use crate::client;
use crate::exit::Exit;
use crate::output::{self, CommandResponse};
use kix::cluster::activation::{PinnedInterface, Record, Records, RecordsError};
use kix::cluster::binding::{self, Connection, Target};
use kix::cluster::discovery;
use kix::cluster::errors::{api_error, forbidden};
use kix::cluster::head::{self, LockView};
use kix::cluster::kubernetes_version::{self, LiveVersion};
use kix::cluster::observe::{self, Observation, ObserveScope};

use super::CommandContext;

pub use document::StatusDocument;

/// What `kix status` prints: the document, and how much of it the text
/// form shows.
#[derive(serde::Serialize, schemars::JsonSchema)]
#[serde(transparent)]
pub struct StatusResponse {
    doc: StatusDocument,
    #[serde(skip)]
    #[schemars(skip)]
    detail: text::Detail,
}

impl CommandResponse for StatusResponse {
    fn text(&self) -> String {
        text::render(&self.doc, self.detail, &age)
    }
}

pub fn run(args: &StatusArgs, ctx: &mut CommandContext) -> Result<Exit> {
    let checks = document::selected(&args.checks);
    let global = ctx.global.clone();
    // A person types the cluster's key in flake.nix. Its deploy records
    // carry its name, which differs when the definition sets one.
    let cluster = match args.cluster.as_deref() {
        Some(arg) => Some(
            ctx.cluster_identity_after(arg, super::Lookup::ReadOnly, || {
                crate::dispatch::prepare_evaluation(&global, Some(arg))
            })?,
        ),
        None => None,
    };
    let (observation, kubernetes, notes, locks) = ctx
        .runtime()?
        .block_on(read_cluster(cluster.as_deref(), &global))?;
    let mut doc = document::build(
        &observation,
        kubernetes,
        &notes,
        &checks,
        args.package.as_deref(),
    )
    .map_err(|e| miette!("{e}"))?;
    doc.set_locks(&locks);
    let detail = if global.quiet {
        text::Detail::Problems
    } else if global.verbose > 0 {
        text::Detail::Everything
    } else {
        text::Detail::Packages
    };
    let exit = doc.exit();
    output::result(&StatusResponse { doc, detail })?;
    Ok(exit)
}

/// Read the deploy records and Kix's objects, the Kubernetes cluster's ID
/// and version, the platform interface warnings of each Kix cluster, and
/// the run that holds each one's deploy lock.
async fn read_cluster(
    cluster: Option<&str>,
    global: &crate::cli::GlobalArgs,
) -> Result<(
    Observation,
    document::Kubernetes,
    BTreeMap<String, Vec<String>>,
    BTreeMap<String, LockView>,
)> {
    let spinner = output::spinner("Reading the cluster...");
    let client = client::make_client(global.context.as_deref())
        .await
        .into_diagnostic()?;
    let discovery = discovery::discover_resources(&client)
        .await
        .into_diagnostic()?;
    let id = KubernetesId::read(&client).await;
    let opened = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;
    let scope = match cluster {
        Some(name) => ObserveScope::Cluster(name),
        None => ObserveScope::All,
    };
    let observation = observe::observe(&client, &discovery, &opened, scope)
        .await
        .into_diagnostic()?;
    let connection = Connection::of_context(global.context.as_deref());
    if observation.clusters.is_empty() {
        if let Some(sp) = &spinner {
            sp.finish_and_clear();
        }
        let deployed: Vec<String> = match opened.records() {
            Some(records) => records
                .all_current()
                .await
                .into_diagnostic()?
                .into_keys()
                .collect(),
            None => Vec::new(),
        };
        return Err(no_deploy(cluster, &deployed, &connection.describe()));
    }
    let mut locks = BTreeMap::new();
    for view in &observation.clusters {
        if let Some(lock) = read_lock(&client, &view.cluster).await {
            locks.insert(view.cluster.clone(), lock);
        }
    }
    let mut notes = BTreeMap::new();
    if let Some(records) = opened.records() {
        for view in &observation.clusters {
            let mut cluster_notes = interface_notes(records, &view.cluster, &view.record).await?;
            let shown = view.failed.as_ref().map(|f| f.record.name.as_str());
            cluster_notes.extend(stopped_notes(records, &view.cluster, &view.record, shown).await?);
            cluster_notes.extend(
                observation
                    .problems
                    .iter()
                    .filter(|p| p.cluster().is_none_or(|c| c == view.cluster))
                    .map(|p| format!("{p}. Showing the objects Kix could read.")),
            );
            notes.insert(view.cluster.clone(), cluster_notes);
        }
    }
    if let Some(sp) = &spinner {
        sp.finish_and_clear();
    }
    for note in id.unread_notes() {
        crate::esay!("{note}");
    }
    let target = Target::from(&connection);
    let kubernetes = document::Kubernetes {
        context: target.context,
        server: target.server,
        uid: id.uid,
        version: id.version,
    };
    Ok((observation, kubernetes, notes, locks))
}

/// Return the run that holds the deploy lock of Kix cluster `cluster`, as of
/// now by this machine's clock, or `None` when none does. A lock that cannot
/// be read, as for an account that may not read it, is left out.
async fn read_lock(client: &kube::Client, cluster: &str) -> Option<LockView> {
    match head::read(client, cluster).await {
        Ok(found) => found
            .as_ref()
            .and_then(|h| h.lock())
            .map(|l| LockView::of(l, chrono::Utc::now())),
        Err(e) => {
            tracing::debug!(cluster, error = %e, "could not read the deploy lock");
            None
        }
    }
}

/// Return the error for a Kix cluster with no current deploy here, or for a
/// Kubernetes cluster where no Kix cluster has one.
fn no_deploy(cluster: Option<&str>, deployed: &[String], connection: &str) -> miette::Report {
    match cluster {
        Some(cluster) if deployed.is_empty() => miette!(
            "Kix cluster '{cluster}' has no current deploy on the Kubernetes cluster of {connection}, \
             and no other Kix cluster has one there.\n\
             Next: run `kix deploy {cluster}`, or pass --context <name> to read another Kubernetes cluster."
        ),
        Some(cluster) => miette!(
            "Kix cluster '{cluster}' has no current deploy on the Kubernetes cluster of {connection}. \
             Kix clusters with a deploy there: {}.\n\
             Next: run `kix status` with one of those names, or pass --context <name> to read another Kubernetes cluster.",
            deployed.join(", ")
        ),
        None => miette!(
            "No Kix cluster has a current deploy on the Kubernetes cluster of {connection}.\n\
             Next: run `kix deploy <cluster>`, or pass --context <name> to read another Kubernetes cluster."
        ),
    }
}

/// Return how long ago the RFC 3339 time `at` was, such as `2d3h ago`, or
/// `at` itself when it does not parse.
fn age(at: &str) -> String {
    match chrono::DateTime::parse_from_rfc3339(at) {
        Ok(t) => format!(
            "{} ago",
            format_duration(chrono::Utc::now().signed_duration_since(t))
        ),
        Err(_) => at.to_string(),
    }
}

/// Return a line for each `Partial` or `Failed` deploy record of `cluster`
/// except `shown`, the failed deploy the status reports in its own section.
/// `active` is the record the cluster runs.
async fn stopped_notes(
    records: &Records,
    cluster: &str,
    active: &Record,
    shown: Option<&str>,
) -> Result<Vec<String>> {
    let stopped = records.stopped(cluster).await.map_err(|e| miette!("{e}"))?;
    Ok(stopped
        .iter()
        .filter(|r| Some(r.name.as_str()) != shown)
        .map(|r| stopped_note(cluster, r, &active.name))
        .collect())
}

/// Return the note for the `Partial` or `Failed` deploy record `record` of
/// `cluster`, while the cluster runs record `active`.
fn stopped_note(cluster: &str, record: &Record, active: &str) -> String {
    let build = match record.identity_hash.as_deref() {
        Some(hash) => format!("build {}", &hash[..12.min(hash.len())]),
        None => "build unknown".to_string(),
    };
    let name = &record.name;
    match record.partly_deployed() {
        Some(partial) => format!(
            "Deployment record {name} ({build}) is in phase Partial: `kix deploy --only` applied {}, \
             while {active} remains the active deployment. Run `kix deploy {cluster}` to deploy \
             the rest of that build, or to replace it if your local files have changed.",
            partial.only.join(", ")
        ),
        None => {
            let reason = record
                .failure_reason
                .as_deref()
                .and_then(|r| r.lines().next())
                .unwrap_or("no reason recorded");
            format!(
                "Deployment record {name} ({build}) failed ({reason}), while {active} remains \
                 the active deployment. The next `kix deploy {cluster}` will reconcile any \
                 resources that {name} applied."
            )
        }
    }
}

/// Return a warning line for each upstream platform interface whose live digest
/// differs from what `active` was built against.
async fn interface_notes(records: &Records, cluster: &str, active: &Record) -> Result<Vec<String>> {
    let mut notes = vec![];
    for (platform, pinned) in &active.interfaces {
        let live = records.active(platform).await;
        notes.extend(interface_note(cluster, platform, pinned, live)?);
    }
    Ok(notes)
}

/// Compare a single pinned upstream interface against the platform's live
/// `Activation` record.
///
/// Reports HTTP 403 as a note rather than an error so the consumer cluster's
/// own status can still be displayed.
fn interface_note(
    cluster: &str,
    platform: &str,
    pinned: &PinnedInterface,
    live: Result<Option<Record>, RecordsError>,
) -> Result<Option<String>> {
    let live = match live {
        Ok(live) => live,
        Err(e) if e.forbidden() => {
            return Ok(Some(format!(
                "note: cannot verify whether '{cluster}' matches platform '{platform}': this \
                 Kubernetes account is not allowed to read '{platform}'s deploy record (HTTP 403)."
            )));
        }
        Err(e) => return Err(e).into_diagnostic(),
    };
    let Some(live) = live else {
        return Ok(Some(format!(
            "note: cannot verify whether '{cluster}' matches platform '{platform}': '{platform}' \
             has no active deploy on this Kubernetes cluster."
        )));
    };
    Ok(match live.published_interfaces.get(&pinned.consumer) {
        None => Some(format!(
            "warning: platform '{platform}' no longer publishes an interface for consumer '{consumer}', \
             which '{cluster}' was built with.\n  Next: ask the '{platform}' platform team to restore \
             `consumers.{consumer}`, or update '{cluster}'s `kix.interface` file and redeploy '{cluster}'.",
            consumer = pinned.consumer
        )),
        Some(sha256) if *sha256 != pinned.sha256 => Some(format!(
            "warning: '{cluster}' was built with an older interface file than platform '{platform}' \
             is running now.\n  Next: copy '{platform}'s current interface file to `{}`, commit it, \
             and run `kix deploy {cluster}`.",
            pinned.path
        )),
        Some(_) => None,
    })
}

/// What Kix could read about the Kubernetes cluster: its ID, the UID of its
/// `kube-system` Namespace, which `cluster.kubernetes.uid` names, and the
/// Kubernetes version it runs, which `k8sVersion` names. Each is the value
/// when it could be read, and why not when it could not.
struct KubernetesId {
    uid: Option<String>,
    uid_unread: Option<String>,
    version: Option<String>,
    version_unread: Option<String>,
}

impl KubernetesId {
    async fn read(client: &kube::Client) -> KubernetesId {
        KubernetesId::of(
            binding::live_uid(client).await,
            kubernetes_version::live_version(client).await,
        )
    }

    fn of(
        uid: Result<String, kube::Error>,
        version: Result<LiveVersion, kubernetes_version::ReadError>,
    ) -> KubernetesId {
        let (uid, uid_unread) = match uid {
            Ok(uid) => (Some(uid), None),
            Err(e) if forbidden(&e) => (
                None,
                Some("not readable with this account (get on namespaces)".to_string()),
            ),
            Err(e) => (None, Some(format!("not read: {}", api_error(&e)))),
        };
        let (version, version_unread) = match version {
            Ok(live) => (Some(live.git_version), None),
            Err(e) => (None, Some(format!("not read: {e}"))),
        };
        KubernetesId {
            uid,
            uid_unread,
            version,
            version_unread,
        }
    }

    /// Return a note for each value Kix could not read.
    fn unread_notes(&self) -> Vec<String> {
        let mut notes = Vec::new();
        if let Some(why) = &self.uid_unread {
            notes.push(format!("note: Kubernetes cluster ID {why}"));
        }
        if let Some(why) = &self.version_unread {
            notes.push(format!("note: Kubernetes version {why}"));
        }
        notes
    }
}

/// Format a chrono::Duration as a human-readable age string.
fn format_duration(d: chrono::Duration) -> String {
    let total_seconds = d.num_seconds();
    if total_seconds < 0 {
        return "0s".into();
    }

    let days = total_seconds / 86400;
    let hours = (total_seconds % 86400) / 3600;
    let minutes = (total_seconds % 3600) / 60;

    if days > 0 {
        format!("{}d{}h", days, hours)
    } else if hours > 0 {
        format!("{}h{}m", hours, minutes)
    } else if minutes > 0 {
        format!("{}m", minutes)
    } else {
        format!("{}s", total_seconds)
    }
}
