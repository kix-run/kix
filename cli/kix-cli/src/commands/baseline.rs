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
//! A deploy that keeps its orphans (warn-only, the default) leaves the same
//! kind of hole: the next plan compares against the new record only, and the
//! build that still knew about those objects is gone from the comparison. The
//! record therefore names those builds under `status.orphansKeptFrom`, and
//! [`load_kept`] resolves them the same way.
//!
//! Everything here resolves a record to a closure in the local store. Nothing
//! reads the cluster's objects: the kix invariant is that live state is
//! consulted to execute and to observe, never to decide
//! (`v2_discussions/81_deploy_as_lifecycle_engine.md`, "Closure A to closure
//! B"). Listing the records is a read of our own bookkeeping, not of the
//! objects being reasoned about.

use kix::build_source::BuildSource;
use kix::cluster::activation::{
    self, ActiveActivation, DeployingActivation, FailedActivation, KeptOrphanSource,
};
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
    /// The build behind each entry of `closures`, in the same order, for
    /// `status.orphansKeptFrom` when this plan keeps the orphans it found.
    pub sources: Vec<KeptOrphanSource>,
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
/// A record that cannot be resolved is reported without being consumed. It
/// usually means the failed deploy ran on a different
/// machine, so this one cannot know what it applied; saying so and leaving the
/// record in place is more honest than superseding it and forgetting.
pub async fn load_failed(
    client: &Client,
    ar: &ApiResource,
    source: &dyn BuildSource,
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
        let closure = match resolve_closure(source, cluster, &hash, record.built_via.as_deref()) {
            Ok(Some(closure)) => closure,
            Ok(None) => {
                out.unresolved.push(record);
                continue;
            }
            Err(e) => {
                warn_unusable_build(
                    &record.name,
                    &e,
                    "This plan leaves out what that failed deployment applied.",
                );
                out.unresolved.push(record);
                continue;
            }
        };
        if !quiet {
            crate::say!(
                "  {} including resources from failed deployment {} ({}...)",
                output::yellow("!"),
                output::bold(&record.name),
                &hash[..8.min(hash.len())],
            );
            if let Some(reason) = &record.reason {
                crate::say!("    it stopped because: {reason}");
            }
        }
        out.closures.push(closure);
        out.consumed.push(record.name.clone());
        out.sources.push(KeptOrphanSource {
            activation: record.name.clone(),
            identity_hash: hash,
            built_via: record.built_via.clone(),
        });
    }

    if !quiet {
        report_unresolved(&out.unresolved, cluster);
    }
    out
}

/// A build's result dir: `built_via` when that store path is on this
/// machine, else the local activation cache by identity hash.
fn result_dir(
    cluster: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Option<std::path::PathBuf> {
    built_via
        .map(std::path::PathBuf::from)
        .filter(|p| p.join("kix-packages.json").exists())
        .or_else(|| kix::eval::store::resolve_activation_by_hash(cluster, identity_hash))
}

/// The result dir of the build the Active record `active` names, for a plan
/// that uses it as the old state, with a warning to print when the local
/// activation cache was set aside.
///
/// The cache (`store::load_activation_path`) is keyed by cluster name alone,
/// so it can hold the build another kube context deployed under the same
/// name. It is used only when its identity hash is the Active record's.
/// Otherwise the build comes from the record (`built_via`, else the store by
/// hash). With no Active record there is no old build.
pub fn active_build_dir(
    cluster: &str,
    cached: Option<std::path::PathBuf>,
    active: Option<&ActiveActivation>,
) -> (Option<std::path::PathBuf>, Option<String>) {
    let cached_hash = cached.as_deref().and_then(kix::eval::store::build_hash_of);
    let Some(hash) = active.and_then(|a| a.identity_hash.as_deref()) else {
        let warning = cached.map(|dir| {
            format!(
                "cluster '{cluster}' has no Active record in this context, so the cached build {} is not used",
                dir.display()
            )
        });
        return (None, warning);
    };
    if cached_hash.as_deref() == Some(hash) {
        return (cached, None);
    }
    let warning = cached.map(|dir| {
        format!(
            "the cached build {} ({}) is not the Active build of cluster '{cluster}' in this context ({}); using the Active record's build",
            dir.display(),
            short(cached_hash.as_deref().unwrap_or("no identity hash")),
            short(hash),
        )
    });
    let built_via = active.and_then(|a| a.built_via.as_deref());
    (result_dir(cluster, hash, built_via), warning)
}

fn short(hash: &str) -> &str {
    &hash[..8.min(hash.len())]
}

/// The build an Activation record names, unstamped: from `source`
/// ([`BuildSource::deployed_build`]) by its identity hash, else from
/// `built_via` or the local activation cache. `Ok(None)` when this machine
/// has none of them.
///
/// A build from the store must be the build the record names. `built_via`
/// is written by whoever deployed, so a record could point at any store
/// path on this machine.
pub fn record_graph(
    source: &dyn BuildSource,
    cluster: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Result<Option<StoreGraph>, String> {
    if let Some(graph) = source.deployed_build(identity_hash)? {
        return Ok(Some(graph));
    }
    let Some(dir) = result_dir(cluster, identity_hash, built_via) else {
        return Ok(None);
    };
    let noop = |_: &str| {};
    let graph = StoreGraph::from_result_dir_with_status(&dir, &noop)
        .map_err(|e| format!("the build at {} would not load: {e}", dir.display()))?;
    let found = kix::eval::store_graph::store_hash(&graph.activation_path);
    if found != identity_hash {
        return Err(format!(
            "the build at {} is activation {}, not {}",
            dir.display(),
            short(&found),
            short(identity_hash),
        ));
    }
    Ok(Some(graph))
}

/// The stamped manifests of a build, from `source`, from `built_via` when
/// that store path is on this machine, else through the local activation
/// cache by identity hash. `Ok(None)` when none is available, and an error
/// when one is but will not load.
fn resolve_closure(
    source: &dyn BuildSource,
    cluster: &str,
    identity_hash: &str,
    built_via: Option<&str>,
) -> Result<Option<Vec<Value>>, String> {
    let Some(mut graph) = record_graph(source, cluster, identity_hash, built_via)? else {
        return Ok(None);
    };
    stamp_annotations(&mut graph);
    Ok(Some(
        graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect(),
    ))
}

/// Say, even under `--quiet`, that the build of `activation` was found but
/// will not load, and what the plan does without it. A plan made without
/// it must show why.
pub fn warn_unusable_build(activation: &str, error: &str, without_it: &str) {
    eprintln!(
        "{} cannot use the build of activation {}: {error}. {without_it}",
        output::yellow("warning:"),
        output::bold(activation),
    );
}

/// The builds an earlier deploy kept orphans from, resolved to closures.
#[derive(Debug, Default)]
pub struct KeptBaseline {
    /// One stamped manifest set per source this machine could resolve.
    pub closures: Vec<Vec<Value>>,
    /// The source behind each entry of `closures`, in the same order.
    pub sources: Vec<KeptOrphanSource>,
    /// Sources whose build is not in this machine's store. Their orphans are
    /// not in this plan, and the next record carries them forward unchanged
    /// so a machine that has the build can still prune them.
    pub unresolved: Vec<KeptOrphanSource>,
}

/// Resolve the Active record's `status.orphansKeptFrom` to closures, and say
/// how many there are so the plan's extra orphans have an explanation.
pub fn load_kept(
    active: &ActiveActivation,
    build_source: &dyn BuildSource,
    cluster: &str,
    quiet: bool,
) -> KeptBaseline {
    let mut out = KeptBaseline::default();
    for source in &active.orphans_kept_from {
        match resolve_closure(
            build_source,
            cluster,
            &source.identity_hash,
            source.built_via.as_deref(),
        ) {
            Ok(Some(closure)) => {
                out.closures.push(closure);
                out.sources.push(source.clone());
            }
            Ok(None) => out.unresolved.push(source.clone()),
            Err(e) => {
                warn_unusable_build(
                    &source.activation,
                    &e,
                    "This plan cannot list or delete the orphans an earlier deploy kept from it.",
                );
                out.unresolved.push(source.clone());
            }
        }
    }
    if quiet {
        return out;
    }
    if !out.sources.is_empty() {
        let names: Vec<&str> = out.sources.iter().map(|s| s.activation.as_str()).collect();
        crate::say!(
            "  {} including orphans kept by earlier deploys, from {}",
            output::yellow("!"),
            names.join(", "),
        );
    }
    for source in &out.unresolved {
        eprintln!(
            "{} cannot read the build of activation {} on this machine. An earlier deploy kept orphans from it.",
            output::yellow("warning:"),
            output::bold(&source.activation),
        );
        eprintln!(
            "  This plan cannot list or delete them. Deploy from the machine that built it, or \
             remove them with `kix gc --hard {cluster}`."
        );
    }
    out
}

/// What the record this plan finalizes lists under `status.orphansKeptFrom`:
/// every build the plan compared against (the Active one, folded-in failed
/// ones, kept ones) that still has something prune would delete, and every
/// kept source this machine could not resolve. See
/// [`activation::KeptOrphans`] for which of them finalize writes.
pub fn orphans_kept_from(
    new_manifests: &[Value],
    active: Option<&ActiveActivation>,
    active_manifests: &[Value],
    failed: &FailedBaseline,
    kept: &KeptBaseline,
) -> activation::KeptOrphans {
    let active_source = active.and_then(|a| {
        Some(KeptOrphanSource {
            activation: a.name.clone(),
            identity_hash: a.identity_hash.clone()?,
            built_via: a.built_via.clone(),
        })
    });
    let compared = active_source
        .map(|source| (source, active_manifests))
        .into_iter()
        .chain(
            failed
                .sources
                .iter()
                .cloned()
                .zip(failed.closures.iter().map(Vec::as_slice)),
        )
        .chain(
            kept.sources
                .iter()
                .cloned()
                .zip(kept.closures.iter().map(Vec::as_slice)),
        );

    let mut found: Vec<KeptOrphanSource> = Vec::new();
    for (source, closure) in compared {
        if kix::cluster::apply::leaves_orphans(closure, new_manifests)
            && !found
                .iter()
                .any(|s| s.identity_hash == source.identity_hash)
        {
            found.push(source);
        }
    }
    activation::KeptOrphans {
        found,
        unexamined: kept.unresolved.clone(),
        carry_current: false,
    }
}

/// Keep a Nix GC root for every build `recorded` lists that this machine
/// can resolve, and drop the roots of builds it no longer lists. A listed
/// build that loses its store path cannot be read by the next plan, so its
/// orphans would be carried unexamined until `kix gc --hard`.
pub fn sync_kept_roots(cluster: &str, recorded: &[KeptOrphanSource]) {
    let listed: Vec<(String, Option<std::path::PathBuf>)> = recorded
        .iter()
        .map(|source| {
            let dir = result_dir(cluster, &source.identity_hash, source.built_via.as_deref());
            (source.identity_hash.clone(), dir)
        })
        .collect();
    kix::eval::store::sync_kept_roots(cluster, &listed);
}

fn report_unresolved(unresolved: &[FailedActivation], cluster: &str) {
    for record in unresolved {
        eprintln!(
            "{} cannot read the build for failed deployment {} on this machine. It may have left resources on the cluster.",
            output::yellow("warning:"),
            output::bold(&record.name),
        );
        eprintln!(
            "  Kix cannot determine which resources it applied, so this plan will not clean them up. Deploy from \
             the machine that built it, or review and remove unused resources with `kix gc --hard {cluster}` and \
             then mark the failed record as superseded (hard GC does not update it):"
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
         resources from incomplete deployments unchanged.",
        output::yellow("note:"),
        output::bold(&record.name),
    );
    eprintln!(
        "  If that deployment is still running, let it finish. If its process has stopped, mark the"
    );
    eprintln!("  record as failed and rerun this command so Kix can account for its resources:");
    eprintln!(
        "    kubectl patch {}/{} --subresource=status --type=merge \\",
        kix::manifest::keys::ACTIVATIONS_CRD,
        record.name,
    );
    eprintln!(
        "      -p '{{\"status\":{{\"phase\":\"Failed\",\"failure\":{{\"reason\":\"abandoned\"}}}}}}'"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::manifest::keys;
    use serde_json::json;

    /// A `--deployed-bundle` that no longer verifies is an error for the
    /// build it holds, not a build this machine lacks: the caller says so.
    #[test]
    fn a_deployed_bundle_that_does_not_verify_is_not_taken_as_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("deployed.kixbundle");
        let mut bytes =
            include_bytes!("../../../kix/tests/fixtures/bundles/kix-enterprise-test.kixbundle")
                .to_vec();
        std::fs::write(&path, &bytes).unwrap();
        let (source, _) = crate::commands::bundle::from_flags(
            Some(&path),
            std::slice::from_ref(&path),
            "kix-enterprise-test",
            true,
        )
        .unwrap()
        .unwrap();
        let activation = crate::commands::bundle::load(&path)
            .unwrap()
            .0
            .record()
            .to_string();
        let hash = kix::eval::store_graph::store_hash(std::path::Path::new(&activation));
        let last = bytes.len() - 1;
        bytes[last] ^= 1;
        std::fs::write(&path, &bytes).unwrap();
        assert!(resolve_closure(&source, "kix-enterprise-test", &hash, None).is_err());
    }

    fn m(kind: &str, name: &str, hash: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": kind,
            "metadata": {
                "name": name,
                "namespace": "app",
                "annotations": { keys::IDENTITY_HASH: hash },
            },
        })
    }

    fn source(activation: &str) -> KeptOrphanSource {
        KeptOrphanSource {
            activation: activation.into(),
            identity_hash: format!("{activation}-hash"),
            built_via: None,
        }
    }

    fn active(name: &str, kept: Vec<KeptOrphanSource>) -> ActiveActivation {
        ActiveActivation {
            name: name.into(),
            identity_hash: Some(format!("{name}-hash")),
            built_via: None,
            orphans_kept_from: kept,
        }
    }

    fn names(sources: &[KeptOrphanSource]) -> Vec<&str> {
        sources.iter().map(|s| s.activation.as_str()).collect()
    }

    /// A warn-only deploy of v2 over v1 records v1, whose ConfigMap v2 dropped.
    #[test]
    fn the_replaced_build_is_recorded_when_it_leaves_orphans() {
        let v1 = vec![m("Deployment", "web", "h1"), m("ConfigMap", "old", "h2")];
        let v2 = vec![m("Deployment", "web", "h3")];
        let got = orphans_kept_from(
            &v2,
            Some(&active("v1", vec![])),
            &v1,
            &FailedBaseline::default(),
            &KeptBaseline::default(),
        );
        assert_eq!(names(&got.found), vec!["v1"]);
    }

    /// v3 over v2 (which kept v1's orphans) carries v1 forward while v1 still
    /// has something v3 lacks, and records v2 only if v2 does too.
    #[test]
    fn kept_sources_carry_forward_until_the_new_build_declares_their_objects() {
        let v1 = vec![m("Deployment", "web", "h1"), m("ConfigMap", "old", "h2")];
        let v2 = vec![m("Deployment", "web", "h3")];
        let kept = KeptBaseline {
            closures: vec![v1.clone()],
            sources: vec![source("v1")],
            unresolved: vec![source("elsewhere")],
        };
        let v3 = vec![m("Deployment", "web", "h4")];
        let got = orphans_kept_from(
            &v3,
            Some(&active("v2", vec![source("v1")])),
            &v2,
            &FailedBaseline::default(),
            &kept,
        );
        // v2 has nothing v3 lacks. The unresolved source is carried unread.
        assert_eq!(names(&got.found), vec!["v1"]);
        assert_eq!(names(&got.unexamined), vec!["elsewhere"]);

        // A build that declares the ConfigMap again ends v1's entry.
        let v4 = vec![m("Deployment", "web", "h4"), m("ConfigMap", "old", "h5")];
        let kept = KeptBaseline {
            closures: vec![v1],
            sources: vec![source("v1")],
            unresolved: vec![],
        };
        let got = orphans_kept_from(
            &v4,
            Some(&active("v2", vec![source("v1")])),
            &v2,
            &FailedBaseline::default(),
            &kept,
        );
        assert!(got.found.is_empty(), "{got:?}");
    }

    /// A failed deploy's leftovers that this plan keeps are recorded too:
    /// the failed record is superseded on finalize and would otherwise be
    /// the only thing that knew about them.
    #[test]
    fn a_folded_failed_build_with_orphans_is_recorded() {
        let v1 = vec![m("Deployment", "web", "h1")];
        let failed = FailedBaseline {
            closures: vec![vec![
                m("Deployment", "web", "h1"),
                m("Secret", "half", "h9"),
            ]],
            consumed: vec!["f1".into()],
            sources: vec![source("f1")],
            unresolved: vec![],
        };
        let got = orphans_kept_from(
            &v1,
            Some(&active("v1", vec![])),
            &v1,
            &failed,
            &KeptBaseline::default(),
        );
        assert_eq!(names(&got.found), vec!["f1"]);
    }

    /// A result dir whose `activation` link names build `hash`.
    fn result_dir_of(root: &std::path::Path, hash: &str) -> std::path::PathBuf {
        let dir = root.join(hash);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("kix-packages.json"), "{}").unwrap();
        let target = format!("/nix/store/{hash}-activation");
        std::os::unix::fs::symlink(target, dir.join("activation")).unwrap();
        dir
    }

    fn active_of(hash: &str, built_via: Option<&std::path::Path>) -> ActiveActivation {
        ActiveActivation {
            name: format!("rec-{hash}"),
            identity_hash: Some(hash.to_string()),
            built_via: built_via.map(|p| p.to_string_lossy().into_owned()),
            orphans_kept_from: Vec::new(),
        }
    }

    const PROD: &str = "pppppppppppppppppppppppppppppppp";
    const STAGING: &str = "ssssssssssssssssssssssssssssssss";

    /// The cache holds prod's build of a cluster staging deploys under the
    /// same name. Against staging's Active record it is set aside with a
    /// warning, and the record's own build is used.
    #[test]
    fn a_cached_build_of_another_context_is_not_the_old_build() {
        let root = tempfile::tempdir().unwrap();
        let prod = result_dir_of(root.path(), PROD);
        let staging = result_dir_of(root.path(), STAGING);

        let (dir, warning) = active_build_dir(
            "web",
            Some(prod.clone()),
            Some(&active_of(STAGING, Some(&staging))),
        );
        assert_eq!(dir, Some(staging));
        assert!(warning.unwrap().contains("is not the Active build"));

        let (dir, warning) = active_build_dir("web", Some(prod.clone()), None);
        assert_eq!(dir, None);
        assert!(warning.unwrap().contains("no Active record"));

        let (dir, warning) =
            active_build_dir("web", Some(prod.clone()), Some(&active_of(PROD, None)));
        assert_eq!(dir, Some(prod));
        assert_eq!(warning, None);
    }
}
