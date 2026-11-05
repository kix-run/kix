use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use crate::client;
use kix::build_source;
use kix::cluster::activation::{self, Records};
use kix::cluster::apply::ApplyError;
use kix::cluster::drift::{self, DriftReport, DriftVerdict};
use kix::cluster::migrate::{MigrationPair, detect_migration_pairs};
use kix::cluster::owned_view;
use kix::cluster::{discovery, inventory};
use kix::eval::store_graph::{KixPackageIndex, StoreGraph, store_hash};
use kix::manifest::keys;
use kix::manifest::lifecycle::{self, Lifecycle};
use kix::manifest::serialize::load_manifests_from_dir;
use kix::manifest::types::{ResourceId, to_manifest_value};

use crate::cli::{Detail as DetailArg, DiffArgs, OutputFormat};
use crate::output;
use crate::plan::{self, render};
use kix::plan::document::{Build, Checked, DeployedBuild, Detail, MadeBy, NotCheckedReason, Plan};
use kix::plan::origin::{self, Sides};
use kix::plan::{ManifestIndex, PackageDiff};
use kube::api::DynamicObject;

use super::CommandContext;

struct DiffResult {
    packages: PackageDiff,
    /// Stateful migration pairs detected between the old and new manifests.
    migration_pairs: Vec<MigrationPair>,
    /// Plan document rendered by `-o json` and `-o yaml`.
    doc: Plan,
}

impl DiffResult {
    fn has_diff(&self) -> bool {
        self.packages.has_changes() || !self.migration_pairs.is_empty()
    }
}

/// Source of the old side of a diff, which determines which sections the plan
/// document can populate.
enum OldSide {
    /// A build result, where every difference comes from the new build.
    Build,
    /// A directory of rendered manifests (such as a snapshot or export).
    Manifests,
    /// The live cluster's Kix-owned view.
    Live(Box<LiveSide>),
}

/// Compare two store graphs and render the diff using the deploy plan format.
///
/// The new side is built from the flake or loaded from `--bundle`. The old side
/// is loaded from `--from` or `--from-bundle`, empty when `--bundle` is passed
/// alone, or synthesized from a manifest directory or the live cluster's
/// Kix-owned view.
pub fn run(args: &DiffArgs, ctx: &mut CommandContext) -> Result<()> {
    let new_graph = match &args.bundle {
        Some(path) => kix_bundle::read_build(path, &[], &args.cluster)
            .map_err(|e| miette!("{e}"))?
            .into_graph(),
        None => {
            let spinner = output::spinner(format!("Building cluster '{}'...", args.cluster));
            let status = |msg: &str| set_spinner(&spinner, msg);
            let build = super::build_flake(
                &ctx.global,
                &args.cluster,
                &status,
                super::ACTIVATION_BUILD_FAILED,
            )?;
            clear_spinner(&spinner);
            build.into_graph()
        }
    };

    let (old_graph, side) = if let Some(path) = &args.from_bundle {
        let old = kix_bundle::read_build(path, &[], &args.cluster).map_err(|e| miette!("{e}"))?;
        (old.into_graph(), OldSide::Build)
    } else if args.bundle.is_some() && args.from.is_none() {
        (StoreGraph::empty(&args.cluster), OldSide::Build)
    } else if let Some(from) = &args.from {
        let path = PathBuf::from(from);
        if !path.is_dir() {
            return Err(miette!("from directory does not exist: {from}"));
        }
        let spinner = output::spinner("Loading old side...");
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
        let spinner = output::spinner("Fetching live cluster state...");
        let global = ctx.global.clone();
        let live = ctx
            .runtime
            .block_on(fetch_live_manifests(&global, &new_graph))?;
        clear_spinner(&spinner);
        // The current record's package index places each live object where
        // the deployed build put it. Without one, the new build does.
        let deployed = live
            .current
            .as_ref()
            .and_then(|record| activation::Record::of(record).package_index);
        (
            StoreGraph::synthesize_placed(&live.manifests, &new_graph, &Vec::from_iter(&deployed)),
            OldSide::Live(Box::new(live)),
        )
    };

    // Plan files always store full manifests, so `--save` builds the document at
    // `Detail::Manifests` before trimming it to the requested `--detail` level.
    let index = ManifestIndex::new(&old_graph, &new_graph);
    let detail = match (args.detail, &args.save) {
        (_, Some(_)) | (DetailArg::Manifests, None) => Detail::Manifests(&index),
        (DetailArg::Fields, None) => Detail::Fields,
        (DetailArg::Plain, None) => Detail::Plain,
    };
    let mut result = diff_graphs(&old_graph, &new_graph, &side, detail);
    if let Some(path) = &args.save {
        let sha256 = plan::save(result.doc.clone(), &new_graph, path)?;
        crate::esay!(
            "Saved the comparison to {} (sha256:{sha256})",
            path.display()
        );
        match args.detail {
            DetailArg::Manifests => {}
            DetailArg::Fields => drop(result.doc.packages.take_manifests()),
            DetailArg::Plain => {
                drop(result.doc.packages.take_manifests());
                result.doc.packages.drop_field_changes();
            }
        }
    }

    match output::format() {
        OutputFormat::Json => println!("{}", result.doc.to_json()),
        OutputFormat::Yaml => print!("{}", result.doc.to_yaml().into_diagnostic()?),
        OutputFormat::Markdown => print_markdown_output(&result),
        OutputFormat::Text => print_text_output(&result),
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
    // Live objects that predate the lifecycle stamp carry no `kix.run/lifecycle`,
    // so `detect_migration_pairs` produces no pairs for them.
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
            let deployed_by_rid = deployed.as_ref().map(|d| d.by_rid(new));
            let new_by_rid = manifests_by_rid(new);
            if let Some(deployed_by_rid) = &deployed_by_rid {
                let drifted: BTreeSet<ResourceId> =
                    live.drifted.iter().map(|(r, _)| r.rid.clone()).collect();
                let sides = Sides {
                    deployed: deployed_by_rid,
                    live: manifests_by_rid(old),
                    new: new_by_rid.clone(),
                    managed: &live.managed,
                    drifted: &drifted,
                };
                origin::label_live(&mut packages, &sides);
            }
            let drift = origin::live_drift(&live.drifted, &new_by_rid, deployed_by_rid.as_ref());
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
            doc.drift = Checked::found(drift);
            doc.drift_unchecked = live.drift_unchecked;
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

/// The deployed build referenced by the current Activation record.
enum Deployed {
    /// The current record matches the build being compared.
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

/// Load the store graph for the build referenced by `current`, returning
/// [`Deployed::New`] when its identity hash matches `new_graph` or loading
/// `kix.run/built-via` when that store path still exists locally.
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

/// Live cluster state collected for a cluster diff.
struct LiveSide {
    /// Kix-owned view of each compared object.
    manifests: Vec<Value>,
    /// Build resources that `kix deploy` would reject with [`ApplyError::NoNamespace`].
    namespaceless: Vec<ResourceId>,
    /// Current Activation record (newest Active or Degraded).
    current: Option<kube::api::DynamicObject>,
    /// Full live objects including `managedFields`, used to attribute drift to
    /// field managers.
    managed: HashMap<ResourceId, Value>,
    /// Each compared object [`drift::check_object`] finds drifted, with its
    /// report.
    drifted: Vec<(DriftReport, DynamicObject)>,
    /// How many compared objects the drift check cannot judge
    /// ([`DriftVerdict::Unstamped`] or [`DriftVerdict::NoFieldset`]).
    drift_unchecked: usize,
}

/// Fetch the live cluster's Kix-owned view for `new_graph`'s cluster.
async fn fetch_live_manifests(
    global: &crate::cli::GlobalArgs,
    new_graph: &StoreGraph,
) -> Result<LiveSide> {
    let client = client::make_client(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;

    crate::esay!("Discovering API resources...");

    let discovery = discovery::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;

    // Open `Records` to run the domain migration gate. Because live objects are
    // upgraded to the current domain before comparison, skipping the gate on an
    // unmigrated cluster would rename the live `activations.<retired>` CRD to
    // the new domain and falsely report it as in sync.
    let records = Records::open(&client, &discovery).map_err(|e| miette!("{e}"))?;

    crate::esay!(
        "Fetching managed resources ({} resource types)...",
        discovery.len()
    );

    // Scope the sweep to this Kix cluster so resources belonging to another Kix
    // cluster on the same Kubernetes cluster do not appear as removals.
    let sweep = inventory::sweep_managed(
        &client,
        &discovery,
        &records,
        inventory::SweepScope::Cluster(&new_graph.cluster_name),
    )
    .await
    .map_err(|e| miette!("failed to fetch resources: {e}"))?;

    crate::esay!(
        "Fetched {} resources across {} resource types{}",
        sweep.managed.len(),
        discovery.len() - sweep.forbidden.len(),
        crate::output::forbidden_note(&sweep.forbidden),
    );
    for note in sweep.scope_notes() {
        crate::esay!("{note}");
    }

    // Exclude resources that this build drops when another Kix cluster still
    // deploys them, matching `kix deploy --prune`.
    let in_build: HashSet<ResourceId> = new_graph
        .resources
        .values()
        .map(|r| ResourceId::from_value(&r.manifest))
        .collect();
    let mut namespaceless = kix::cluster::apply::namespaceless(&discovery, &in_build);
    namespaceless.sort();
    let tenancy = &sweep.tenancy;
    let (elsewhere, mut compared): (Vec<_>, Vec<_>) = sweep.managed.into_iter().partition(|obj| {
        !in_build.contains(&ResourceId::from_value(&to_manifest_value(obj)))
            && !tenancy.still_deployed_by_others(obj).is_empty()
    });
    if !elsewhere.is_empty() {
        crate::esay!(
            "Not comparing {} objects this build drops that another Kix cluster still deploys.",
            elsewhere.len()
        );
    }

    // Keep only the current Activation record alongside non-record resources so
    // Superseded and Failed records do not appear in the diff.
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

    let (drifted, drift_unchecked) = check_drift(&compared);
    let built = new_graph.manifests_by_hash();
    let managed: HashMap<ResourceId, Value> = compared
        .iter()
        .filter_map(|obj| {
            let rid = ResourceId::from_value(&to_manifest_value(obj));
            serde_json::to_value(obj).ok().map(|v| (rid, v))
        })
        .collect();
    let mut manifests = owned_view::kix_owned_manifests_against(compared, &built);

    let reaped = reaped_since_deploy(new_graph, current.as_ref(), &manifests);
    if !reaped.is_empty() {
        crate::esay!(
            "Not comparing {} run-once resources that the deployed build ran and that were deleted after finishing, as their manifests ask.",
            reaped.len()
        );
    }
    // Include reaped run-once manifests as built so they compare as unchanged.
    manifests.extend(reaped);

    Ok(LiveSide {
        manifests,
        namespaceless,
        current,
        managed,
        drifted,
        drift_unchecked,
    })
}

/// Run [`drift::check_object`] on each of `objects`. Return the drifted ones
/// with their reports, and how many the check cannot judge because they carry
/// no applied-hash stamp or no Kix `managedFields` entry.
fn check_drift(objects: &[DynamicObject]) -> (Vec<(DriftReport, DynamicObject)>, usize) {
    let mut drifted = Vec::new();
    let mut unchecked = 0;
    for obj in objects {
        let report = drift::check_object(obj);
        match report.verdict {
            DriftVerdict::Drifted { .. } => drifted.push((report, obj.clone())),
            DriftVerdict::Unstamped | DriftVerdict::NoFieldset => unchecked += 1,
            DriftVerdict::InSync => {}
        }
    }
    (drifted, unchecked)
}

/// Return build manifests that declare their own deletion (such as a Job with
/// `ttlSecondsAfterFinished` or a `hook-succeeded` delete policy), are absent
/// from `live`, and have not changed since `current` was deployed.
///
/// Because `kix deploy` skips unchanged run-once resources, their absence from
/// the cluster is not a pending addition when the deployed build is known
/// (either because `current` matches `new_graph` or its `kix.run/built-via`
/// directory still exists locally).
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

/// Return the resource identity hashes recorded in `current`'s build.
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

fn clear_spinner(spinner: &Option<indicatif::ProgressBar>) {
    if let Some(sp) = spinner {
        sp.finish_and_clear();
    }
}

fn print_text_output(result: &DiffResult) {
    let pkg = &result.packages;

    let total_pkgs = pkg.added.len() + pkg.removed.len() + pkg.changed.len() + pkg.unchanged;
    if total_pkgs > 0 {
        crate::say!(
            "{} packages: {} unchanged, {} changed, {} added, {} removed",
            total_pkgs,
            pkg.unchanged,
            pkg.changed.len(),
            pkg.added.len(),
            pkg.removed.len(),
        );
    }

    // Always render resource-level detail in `kix diff`.
    print!("{}", plan::render_package_plan(pkg, true));

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
        print!("{}", render::render_drift_text(&result.doc));
    }
}

/// Print detected stateful migration pairs without executing them.
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
    // Share the package-level Markdown renderer with the deploy modal and CI PR comments.
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
        let drift = render::render_drift_markdown(&result.doc);
        if !drift.is_empty() {
            println!();
            print!("{drift}");
        }
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

    /// Build a test store graph with a TTL-reaped Job and an Activation record.
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

    /// Against the live cluster, an object the build does not change shows no
    /// change although the API server dropped its `value: ""`. An edit made
    /// with `kubectl edit` shows under drift, in the text output too, with
    /// no deployed build on this machine.
    #[test]
    fn a_live_diff_shows_an_unchanged_object_only_as_drift() {
        let hash = "d".repeat(32);
        let path = format!("/nix/store/{hash}-k8s-Deployment-web");
        let container = |image: &str, value: bool| {
            let mut env = json!({"name": "EXAMPLE_PULL_SECRET"});
            if value {
                env["value"] = json!("");
            }
            json!({"name": "web", "image": image, "env": [env]})
        };
        let mut new = StoreGraph::empty("c");
        new.resources.insert(
            path.clone().into(),
            ResourceNode {
                store_path: path.into(),
                manifest: json!({
                    "apiVersion": "apps/v1", "kind": "Deployment",
                    "metadata": {"name": "web", "namespace": "app",
                                 "annotations": {keys::IDENTITY_HASH: hash}},
                    "spec": {"template": {"spec": {"containers": [container("web:1", true)]}}},
                }),
            },
        );
        let mut live: DynamicObject = serde_json::from_value(json!({
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {
                "name": "web", "namespace": "app",
                "annotations": {keys::IDENTITY_HASH: hash, keys::APPLIED_HASH: "stamp"},
                "managedFields": [
                    {"manager": "kix", "operation": "Apply", "fieldsV1": {
                        "f:metadata": {"f:annotations": {format!("f:{}", keys::IDENTITY_HASH): {}}},
                        "f:spec": {"f:template": {"f:spec": {"f:containers": {
                            "k:{\"name\":\"web\"}": {".": {}, "f:name": {}, "f:env": {
                                "k:{\"name\":\"EXAMPLE_PULL_SECRET\"}": {
                                    ".": {}, "f:name": {}, "f:value": {}
                                }
                            }}
                        }}}}
                    }},
                    {"manager": "kubectl-edit", "operation": "Update", "fieldsV1": {
                        "f:spec": {"f:template": {"f:spec": {"f:containers": {
                            "k:{\"name\":\"web\"}": {"f:image": {}}
                        }}}}
                    }},
                ],
            },
            "spec": {"template": {"spec": {"containers": [container("web:2", false)]}}},
        }))
        .unwrap();
        // The sweep puts `kind` and `apiVersion` back into the data, as here.
        live.data["kind"] = json!("Deployment");
        live.data["apiVersion"] = json!("apps/v1");

        let manifests =
            owned_view::kix_owned_manifests_against([live.clone()], &new.manifests_by_hash());
        let old = StoreGraph::synthesize(&manifests, &new);
        let unstamped = {
            let mut o = live.clone();
            o.metadata.annotations = None;
            o
        };
        let no_fieldset = {
            let mut o = live.clone();
            o.metadata.managed_fields = None;
            o
        };
        let (drifted, drift_unchecked) = check_drift(&[live, unstamped, no_fieldset]);
        assert_eq!((drifted.len(), drift_unchecked), (1, 2));
        let side = OldSide::Live(Box::new(LiveSide {
            manifests,
            namespaceless: Vec::new(),
            current: None,
            managed: HashMap::new(),
            drifted,
            drift_unchecked,
        }));
        let result = diff_graphs(&old, &new, &side, Detail::Plain);

        assert!(!result.has_diff(), "{}", result.doc.to_json());
        let drift = result.doc.drift.items();
        assert_eq!(drift.len(), 1);
        assert_eq!(drift[0].path, "$.spec.template.spec.containers[web].image");
        let text = render::render_drift_text(&result.doc);
        assert!(text.contains("Deployment/web@app"), "{text}");
        assert!(
            text.contains(
                "2 objects not checked for drift: they have no Kix stamp or no field records."
            ),
            "{text}"
        );
        assert!(
            text.contains("ownership conflict with kubectl-edit"),
            "{text}"
        );
        let markdown = render::render_drift_markdown(&result.doc);
        assert!(
            markdown.contains("2 objects not checked for drift"),
            "{markdown}"
        );
        assert!(
            text.contains("\"web:2\" live, \"web:1\" deployed, set by kubectl-edit"),
            "{text}"
        );
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
