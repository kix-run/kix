use std::collections::{HashMap, HashSet};
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::build_source;
use kix::cluster::activation::{self, Records};
use kix::cluster::apply::ApplyError;
use kix::cluster::fetch;
use kix::cluster::migrate::{MigrationPair, detect_migration_pairs};
use kix::eval::store_graph::{KixPackageIndex, StoreGraph, store_hash};
use kix::manifest::keys;
use kix::manifest::lifecycle::{self, Lifecycle};
use kix::manifest::serialize::load_manifests_from_dir;
use kix::manifest::types::ResourceId;

use crate::cli::{Detail as DetailArg, DiffArgs, OutputFormat};
use crate::output;
use crate::plan::{self, render};
use kix::plan::document::{Build, Checked, DeployedBuild, Detail, MadeBy, NotCheckedReason, Plan};
use kix::plan::origin::{self, Sides};
use kix::plan::{ManifestIndex, PackageDiff};

use super::CommandContext;

struct DiffResult {
    packages: PackageDiff,
    /// Detected stateful migration pairs, reported without execution.
    migration_pairs: Vec<MigrationPair>,
    /// The document `-o json` and `-o yaml` print, made from the two above.
    doc: Plan,
}

impl DiffResult {
    fn has_diff(&self) -> bool {
        self.packages.has_changes() || !self.migration_pairs.is_empty()
    }
}

/// What the old side of the comparison is, which bounds what the document
/// can say.
enum OldSide {
    /// A build result: every difference is the new build's.
    Build,
    /// A manifest directory: a snapshot or an export.
    Manifests,
    /// The live cluster's kix-owned view.
    Live(Box<LiveSide>),
}

/// Every mode is one comparison of two store graphs. The new side is
/// always a build. The old side is a build result when `--from` names one,
/// and otherwise a graph synthesized from stamped manifests: a manifest
/// directory (`--from` a snapshot or export), or the live cluster's
/// kix-owned view. Same renderers as the deploy plan, so what `kix diff`
/// shows is what `kix deploy` will show.
pub fn run(args: &DiffArgs, ctx: &mut CommandContext) -> Result<()> {
    let spinner = make_spinner(ctx, &format!("Building cluster '{}'...", args.cluster));
    let status = |msg: &str| set_spinner(&spinner, msg);
    let new_graph = super::build_flake(
        &ctx.global,
        &args.cluster,
        &status,
        super::ACTIVATION_BUILD_FAILED,
    )?
    .into_graph();
    clear_spinner(&spinner);

    let (old_graph, side) = if let Some(from) = &args.from {
        let path = PathBuf::from(from);
        if !path.is_dir() {
            return Err(miette!("from directory does not exist: {from}"));
        }
        let spinner = make_spinner(ctx, "Loading old side...");
        let loaded = if path.join("kix-packages.json").is_file() {
            let status = |msg: &str| set_spinner(&spinner, msg);
            let old = build_source::Build::local(&path, &status).into_diagnostic()?;
            (old.into_graph(), OldSide::Build)
        } else {
            let manifests: Vec<Value> = load_manifests_from_dir(&path)
                .map_err(|e| miette!("failed to load manifest directory {from}: {e}"))?
                .into_iter()
                .map(|(_, v)| v)
                .collect();
            (
                StoreGraph::synthesize(&manifests, &new_graph),
                OldSide::Manifests,
            )
        };
        clear_spinner(&spinner);
        loaded
    } else {
        let spinner = make_spinner(ctx, "Fetching live cluster state...");
        let global = ctx.global.clone();
        let live = ctx
            .runtime
            .block_on(fetch_live_manifests(&global, &new_graph))?;
        clear_spinner(&spinner);
        (
            StoreGraph::synthesize(&live.manifests, &new_graph),
            OldSide::Live(Box::new(live)),
        )
    };

    let index = ManifestIndex::new(&old_graph, &new_graph);
    let detail = match args.detail {
        DetailArg::Plain => Detail::Plain,
        DetailArg::Fields => Detail::Fields,
        DetailArg::Manifests => Detail::Manifests(&index),
    };
    let result = diff_graphs(&old_graph, &new_graph, &side, detail);

    match ctx.output_format(OutputFormat::Text) {
        OutputFormat::Json => println!("{}", result.doc.to_json()),
        OutputFormat::Yaml => print!("{}", result.doc.to_yaml().into_diagnostic()?),
        OutputFormat::Markdown => print_markdown_output(&result),
        OutputFormat::Text => print_text_output(&result, &ctx.global),
    }
    if let OldSide::Live(live) = &side {
        for rid in &live.namespaceless {
            eprintln!(
                "{} {}",
                output::red("error:"),
                ApplyError::NoNamespace {
                    resource: rid.display_id()
                }
            );
        }
    }

    if result.has_diff() {
        std::process::exit(2);
    }

    Ok(())
}

fn set_spinner(spinner: &Option<indicatif::ProgressBar>, msg: &str) {
    if let Some(sp) = spinner {
        sp.set_message(msg.to_string());
    }
}

fn diff_graphs(old: &StoreGraph, new: &StoreGraph, side: &OldSide, detail: Detail) -> DiffResult {
    let new_manifests: Vec<Value> = new.resources.values().map(|n| n.manifest.clone()).collect();
    let old_manifests: Vec<Value> = old.resources.values().map(|n| n.manifest.clone()).collect();
    // Fail-closed: live objects that predate the lifecycle stamp carry no
    // `kix.run/lifecycle`, and then no pairs fire.
    let migration_pairs = detect_migration_pairs(&new_manifests, &old_manifests);
    let mut packages = kix::plan::diff_graphs(old, new);
    let cluster = &new.cluster_name;

    let doc = match side {
        OldSide::Build => {
            origin::label_builds(&mut packages);
            let mut doc = Plan::new(
                plan::kix_build(),
                MadeBy::Builds,
                cluster,
                Build::of(new),
                &packages,
                detail,
                &migration_pairs,
                NotCheckedReason::BuildsOnly,
            );
            doc.deployed = DeployedBuild::of_manifests(&old_manifests);
            doc
        }
        OldSide::Manifests => {
            let mut doc = Plan::new(
                plan::kix_build(),
                MadeBy::LiveRead,
                cluster,
                Build::of(new),
                &packages,
                detail,
                &migration_pairs,
                NotCheckedReason::ReadOnly,
            );
            doc.drift = Checked::not_checked(NotCheckedReason::DeployedBuildUnavailable);
            doc.deployed = DeployedBuild::of_manifests(&old_manifests);
            doc
        }
        OldSide::Live(live) => {
            let deployed = deployed_build(new, live.current.as_ref());
            let drift = deployed.as_ref().map(|deployed| {
                let deployed_by_rid = deployed.by_rid(new);
                let sides = Sides {
                    deployed: &deployed_by_rid,
                    live: manifests_by_rid(old),
                    new: manifests_by_rid(new),
                    managed: &live.managed,
                };
                origin::label_live(&mut packages, &sides)
            });
            let mut doc = Plan::new(
                plan::kix_build(),
                MadeBy::LiveRead,
                cluster,
                Build::of(new),
                &packages,
                detail,
                &migration_pairs,
                NotCheckedReason::ReadOnly,
            );
            doc.deployed = live
                .current
                .as_ref()
                .and_then(|r| serde_json::to_value(r).ok())
                .and_then(|r| DeployedBuild::of_record(&r));
            doc.drift = match drift {
                Some(items) => Checked::found(items),
                None => Checked::not_checked(NotCheckedReason::DeployedBuildUnavailable),
            };
            doc
        }
    };
    DiffResult {
        packages,
        migration_pairs,
        doc,
    }
}

fn manifests_by_rid(graph: &StoreGraph) -> HashMap<ResourceId, &Value> {
    graph
        .resources
        .values()
        .map(|n| (ResourceId::from_value(&n.manifest), &n.manifest))
        .collect()
}

/// The deployed build, as the current record names it.
enum Deployed {
    /// The current record names the build being compared.
    New,
    Loaded(Box<StoreGraph>),
}

impl Deployed {
    fn by_rid<'a>(&'a self, new: &'a StoreGraph) -> HashMap<ResourceId, &'a Value> {
        manifests_by_rid(match self {
            Deployed::New => new,
            Deployed::Loaded(g) => g,
        })
    }
}

/// The build the current record says the cluster runs: the new build when
/// the record's identity hash is the new build's record hash, otherwise the
/// result directory its `kix.run/built-via` names, when it is still on this
/// machine.
fn deployed_build(
    new_graph: &StoreGraph,
    current: Option<&kube::api::DynamicObject>,
) -> Option<Deployed> {
    let annotations = current.and_then(|r| r.metadata.annotations.as_ref())?;
    let new_record_hash = new_graph
        .resources
        .values()
        .find(|node| lifecycle::is_record(&node.manifest))
        .and_then(|node| keys::get(&node.manifest, keys::IDENTITY_HASH));
    if new_record_hash.is_some()
        && new_record_hash == keys::get_meta(annotations, keys::IDENTITY_HASH)
    {
        return Some(Deployed::New);
    }
    let dir = Path::new(keys::get_meta(annotations, keys::BUILT_VIA)?);
    if !dir.join("kix-packages.json").is_file() {
        return None;
    }
    let graph = build_source::Build::local(dir, &|_| {}).ok()?.into_graph();
    Some(Deployed::Loaded(Box::new(graph)))
}

/// The live side of a comparison with the cluster.
struct LiveSide {
    /// The kix-owned view of each compared object.
    manifests: Vec<Value>,
    /// Resources of the build that `kix deploy` would refuse as
    /// [`ApplyError::NoNamespace`].
    namespaceless: Vec<ResourceId>,
    /// The current record: Active or Degraded, newest.
    current: Option<kube::api::DynamicObject>,
    /// Each compared object as served, `managedFields` included, for naming
    /// who made a drift change.
    managed: HashMap<ResourceId, Value>,
}

/// The live cluster's kix-owned view of `new_graph`'s Kix cluster.
async fn fetch_live_manifests(
    global: &crate::cli::GlobalArgs,
    new_graph: &StoreGraph,
) -> Result<LiveSide> {
    let client = fetch::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    if !global.quiet {
        eprintln!("Discovering API resources...");
    }

    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    // The gate, which opening the records runs. Beyond the records the sweep
    // reads, `kix diff` needs it because the live objects below are upgraded
    // to the current domain before they are compared, which on an
    // unmigrated cluster renames the live `activations.<retired>` CRD to the
    // name the build uses and reports it as matching. The answer would be
    // "in sync" about a resource that does not exist under that name.
    let records = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;

    if !global.quiet {
        eprintln!(
            "Fetching managed resources ({} resource types)...",
            discovery.len()
        );
    }

    // Only this Kix cluster's objects: another cluster sharing the
    // Kubernetes cluster is not a removal.
    let sweep = fetch::sweep_managed(
        &client,
        &discovery,
        &records,
        fetch::SweepScope::Cluster(&new_graph.cluster_name),
    )
    .await
    .map_err(|e| miette!("failed to fetch resources: {e}"))?;

    if !global.quiet {
        eprintln!(
            "Fetched {} resources across {} resource types{}",
            sweep.managed.len(),
            discovery.len() - sweep.forbidden.len(),
            crate::output::forbidden_note(&sweep.forbidden),
        );
        for note in sweep.scope_notes() {
            eprintln!("{note}");
        }
    }

    // An object this build drops but another Kix cluster still deploys is
    // kept by `kix deploy --prune`, so it is not a removal either.
    let in_build: HashSet<ResourceId> = new_graph
        .resources
        .values()
        .map(|r| ResourceId::from_value(&r.manifest))
        .collect();
    let mut namespaceless = kix::cluster::apply::namespaceless(&discovery, &in_build);
    namespaceless.sort();
    let tenancy = &sweep.tenancy;
    let (elsewhere, mut compared): (Vec<_>, Vec<_>) = sweep.managed.into_iter().partition(|obj| {
        !in_build.contains(&ResourceId::from_value(&fetch::to_manifest_value(obj)))
            && !tenancy.still_deployed_by_others(obj).is_empty()
    });
    if !global.quiet && !elsewhere.is_empty() {
        eprintln!(
            "Not comparing {} objects this build drops that another Kix cluster still deploys.",
            elsewhere.len()
        );
    }

    // The cluster keeps Superseded and Failed records beside the current one.
    // Only the current one says which build the cluster runs.
    let current = activation::current_record(
        compared
            .iter()
            .filter(|obj| lifecycle::lifecycle_of_live(obj) == Lifecycle::Record),
    )
    .cloned();
    compared.retain(|obj| {
        lifecycle::lifecycle_of_live(obj) != Lifecycle::Record
            || current
                .as_ref()
                .is_some_and(|c| c.metadata.name == obj.metadata.name)
    });

    // Only the fields kix's server-side apply owns, so server defaults and
    // kix's own bookkeeping never enter the comparison. An object nothing
    // has changed since kix applied it compares as the manifest it was
    // applied from, so what the server filled in on that apply does not show.
    let built: HashMap<String, &Value> = new_graph
        .resources
        .iter()
        .map(|(path, node)| (store_hash(path), &node.manifest))
        .collect();
    let managed: HashMap<ResourceId, Value> = compared
        .iter()
        .filter_map(|obj| {
            let rid = ResourceId::from_value(&fetch::to_manifest_value(obj));
            serde_json::to_value(obj).ok().map(|v| (rid, v))
        })
        .collect();
    let mut manifests = fetch::kix_owned_manifests_against(compared, &built);

    let reaped = reaped_since_deploy(new_graph, current.as_ref(), &manifests);
    if !global.quiet && !reaped.is_empty() {
        eprintln!(
            "Not comparing {} run-once resources that the deployed build ran and that were deleted after finishing, as their manifests ask.",
            reaped.len()
        );
    }
    // Added as they were built, so each compares as unchanged.
    manifests.extend(reaped);

    Ok(LiveSide {
        manifests,
        namespaceless,
        current,
        managed,
    })
}

/// Build manifests that declare their own deletion (a Job's
/// `ttlSecondsAfterFinished`, or a `hook-succeeded` delete policy), are
/// absent from `live`, and are unchanged from the build `current` records.
/// A deploy leaves such a resource alone because its identity hash did not
/// change, so its absence is not a resource `kix deploy` would add.
///
/// The deployed build is known when `current` names the same build as
/// `new_graph`, or when the activation directory its `kix.run/built-via`
/// names is still on this machine. Otherwise nothing is returned and each
/// such resource shows as added.
fn reaped_since_deploy(
    new_graph: &StoreGraph,
    current: Option<&kube::api::DynamicObject>,
    live: &[Value],
) -> Vec<Value> {
    let deployed = deployed_hashes(new_graph, current);
    if deployed.is_empty() {
        return Vec::new();
    }
    let live_ids: HashSet<ResourceId> = live.iter().map(ResourceId::from_value).collect();
    new_graph
        .resources
        .iter()
        .filter(|(path, node)| {
            lifecycle::declares_own_deletion(&node.manifest)
                && deployed.contains(&store_hash(path))
                && !live_ids.contains(&ResourceId::from_value(&node.manifest))
        })
        .map(|(_, node)| node.manifest.clone())
        .collect()
}

/// Identity hashes of the resources in the build `current` records.
fn deployed_hashes(
    new_graph: &StoreGraph,
    current: Option<&kube::api::DynamicObject>,
) -> HashSet<String> {
    let Some(annotations) = current.and_then(|r| r.metadata.annotations.as_ref()) else {
        return HashSet::new();
    };
    let new_record_hash = new_graph
        .resources
        .values()
        .find(|node| lifecycle::is_record(&node.manifest))
        .and_then(|node| keys::get(&node.manifest, keys::IDENTITY_HASH));
    if new_record_hash.is_some()
        && new_record_hash == keys::get_meta(annotations, keys::IDENTITY_HASH)
    {
        return new_graph.resources.keys().map(|p| store_hash(p)).collect();
    }
    let Some(built_via) = keys::get_meta(annotations, keys::BUILT_VIA) else {
        return HashSet::new();
    };
    std::fs::read_to_string(Path::new(built_via).join("kix-packages.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<KixPackageIndex>(&text).ok())
        .map(|index| {
            index
                .packages
                .values()
                .flatten()
                .map(|p| store_hash(p))
                .collect()
        })
        .unwrap_or_default()
}

fn make_spinner(ctx: &CommandContext, msg: &str) -> Option<indicatif::ProgressBar> {
    if std::io::stderr().is_terminal() && !ctx.global.quiet {
        let sp = indicatif::ProgressBar::new_spinner();
        sp.set_style(
            indicatif::ProgressStyle::default_spinner()
                .template("{spinner:.cyan} {msg}")
                .expect("valid template"),
        );
        sp.set_message(msg.to_string());
        sp.enable_steady_tick(std::time::Duration::from_millis(80));
        Some(sp)
    } else {
        None
    }
}

fn clear_spinner(spinner: &Option<indicatif::ProgressBar>) {
    if let Some(sp) = spinner {
        sp.finish_and_clear();
    }
}

fn print_text_output(result: &DiffResult, global: &crate::cli::GlobalArgs) {
    let pkg = &result.packages;

    let total_pkgs = pkg.added.len() + pkg.removed.len() + pkg.changed.len() + pkg.unchanged;
    if !global.quiet && total_pkgs > 0 {
        println!(
            "{} packages: {} unchanged, {} changed, {} added, {} removed",
            total_pkgs,
            pkg.unchanged,
            pkg.changed.len(),
            pkg.added.len(),
            pkg.removed.len(),
        );
    }

    // The deploy plan renderer, always with resource-level detail: a diff
    // exists to be read.
    plan::print_package_plan(pkg, true);

    if let Some(a) = &pkg.activation {
        println!();
        println!(
            "  {} {} -> {}",
            output::bold("Activation:"),
            output::dim(a.old.as_deref().unwrap_or("(none)")),
            output::green(a.new.as_deref().unwrap_or("(none)")),
        );
    }

    if pkg.has_changes() {
        println!();
    }

    print_migration_pairs(&result.migration_pairs);

    if result.has_diff() {
        print!("{}", render::render_text(&result.doc));
    } else {
        println!("{}", output::green("No differences found."));
    }
}

/// Render detected stateful migration pairs without executing them.
fn print_migration_pairs(pairs: &[MigrationPair]) {
    if pairs.is_empty() {
        return;
    }
    println!(
        "{}",
        output::bold(&format!("Stateful migrations detected ({}):", pairs.len()))
    );
    for p in pairs {
        println!("  {} {}", output::yellow("~"), output::yellow(&p.summary()));
        println!(
            "      source: {}/{}/{}",
            p.source.kind, p.source.namespace, p.source.name
        );
        println!(
            "      target: {}/{}/{}",
            p.target.kind, p.target.namespace, p.target.name
        );
    }
    println!();
    println!(
        "{}",
        output::yellow(
            "Data migration is not automated. Review the source and target resources above and migrate the data before deploying with --accept-migrations."
        )
    );
    println!();
}

fn print_markdown_output(result: &DiffResult) {
    // Shared package-level renderer. Same producer used by the deploy
    // modal and the CI PR-comment GitHub Action so they stay in sync.
    print!("{}", plan::render_package_diff_markdown(&result.packages));

    if !result.migration_pairs.is_empty() {
        println!(
            "#### Stateful migrations detected ({})",
            result.migration_pairs.len()
        );
        println!();
        for p in &result.migration_pairs {
            println!("- **{}**", p.summary());
            println!(
                "  - source: `{}/{}/{}`",
                p.source.kind, p.source.namespace, p.source.name
            );
            println!(
                "  - target: `{}/{}/{}`",
                p.target.kind, p.target.namespace, p.target.name
            );
        }
        println!();
        println!(
            "> :warning: Data migration is not automated. Review the source and target resources above and migrate the data before deploying with `--accept-migrations`."
        );
        println!();
    }

    if result.has_diff() {
        print!("{}", render::render_markdown(&result.doc));
    } else {
        println!("No differences found.");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kix::eval::store_graph::ResourceNode;
    use kube::api::{DynamicObject, ObjectMeta};
    use serde_json::json;

    const JOB_PATH: &str = "/nix/store/jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj-k8s-Job-admission";
    const RECORD_PATH: &str = "/nix/store/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr-k8s-Activation-c";

    /// A build holding a Job its TTL removes after it finishes, and the
    /// build's record.
    fn build() -> StoreGraph {
        let mut graph = StoreGraph::empty("c");
        let job = json!({
            "apiVersion": "batch/v1",
            "kind": "Job",
            "metadata": {"name": "admission", "namespace": "ingress"},
            "spec": {"ttlSecondsAfterFinished": 3600},
        });
        let record = json!({
            "apiVersion": keys::API_VERSION,
            "kind": "Activation",
            "metadata": {"name": "c-rrrrrrrrrrrr",
                         "annotations": {keys::IDENTITY_HASH: "r".repeat(32)}},
        });
        for (path, manifest) in [(JOB_PATH, job), (RECORD_PATH, record)] {
            graph.resources.insert(
                path.into(),
                ResourceNode {
                    store_path: path.into(),
                    manifest,
                },
            );
        }
        graph
    }

    fn live_record(identity_hash: &str, built_via: Option<&Path>) -> DynamicObject {
        let mut annotations: std::collections::BTreeMap<String, String> =
            [(keys::IDENTITY_HASH.to_string(), identity_hash.to_string())].into();
        if let Some(dir) = built_via {
            annotations.insert(keys::BUILT_VIA.to_string(), dir.display().to_string());
        }
        DynamicObject {
            metadata: ObjectMeta {
                name: Some("c-current".into()),
                annotations: Some(annotations),
                ..Default::default()
            },
            types: None,
            data: json!({"status": {"phase": "Active"}}),
        }
    }

    #[test]
    fn a_job_the_running_build_ran_and_its_ttl_removed_is_not_an_addition() {
        let graph = build();
        let current = live_record(&"r".repeat(32), None);
        let reaped = reaped_since_deploy(&graph, Some(&current), &[]);
        assert_eq!(reaped.len(), 1);
        assert_eq!(reaped[0]["metadata"]["name"], json!("admission"));

        // Still on the cluster: compared like any other object.
        let live_job = graph.resources[Path::new(JOB_PATH)].manifest.clone();
        assert!(reaped_since_deploy(&graph, Some(&current), &[live_job]).is_empty());

        // No current record: nothing is known to have run.
        assert!(reaped_since_deploy(&graph, None, &[]).is_empty());
    }

    #[test]
    fn a_job_is_matched_against_the_deployed_build_when_the_build_changed() {
        let graph = build();

        // The running build's activation directory is gone: unknown, so
        // the Job shows as added.
        let gone = live_record("older-build", Some(Path::new("/nonexistent/kix-result")));
        assert!(reaped_since_deploy(&graph, Some(&gone), &[]).is_empty());

        // The running build's index lists the same Job store path.
        let dir = tempfile::tempdir().unwrap();
        let index = json!({
            "cluster": "c",
            "packages": {"/nix/store/pppppppppppppppppppppppppppppppp-k8s-PackageInstance-ingress": [JOB_PATH]},
        });
        std::fs::write(dir.path().join("kix-packages.json"), index.to_string()).unwrap();
        let older = live_record("older-build", Some(dir.path()));
        assert_eq!(reaped_since_deploy(&graph, Some(&older), &[]).len(), 1);

        // An index without that store path: the Job changed, and a deploy
        // would run it.
        let index = json!({"cluster": "c", "packages": {}});
        std::fs::write(dir.path().join("kix-packages.json"), index.to_string()).unwrap();
        assert!(reaped_since_deploy(&graph, Some(&older), &[]).is_empty());
    }
}
