use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;

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
use kix::eval::build_files::BuildFiles;
use kix::eval::store;
use kix::eval::store_graph::StoreGraph;
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
use crate::exit::Exit;

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
pub fn run(args: &DiffArgs, ctx: &mut CommandContext) -> Result<Exit> {
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
        let path = store::follow_into_store(Path::new(from));
        let on_disk = store::disk_path(&path).unwrap_or_else(|_| path.clone());
        let build = BuildFiles::is_build(&path);
        if !build && !on_disk.is_dir() {
            return Err(miette!("from directory does not exist: {from}"));
        }
        let spinner = output::spinner("Loading old side...");
        let loaded = if build {
            let status = |msg: &str| set_spinner(&spinner, msg);
            let old = build_source::Build::local(&path, &status).into_diagnostic()?;
            (old.into_graph(), OldSide::Build)
        } else {
            let manifests: Vec<Value> = load_manifests_from_dir(&on_disk)
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
            .runtime()?
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
        return Ok(Exit::DiffHasDifferences);
    }
    Ok(Exit::Success)
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
    let built_via = Path::new(keys::get_meta(annotations, keys::BUILT_VIA)?);
    if !BuildFiles::is_build(built_via) {
        return None;
    }
    let graph = build_source::Build::local(built_via, &|_| {})
        .ok()?
        .into_graph();
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
            "Not comparing {} object(s) that left the build because another Kix cluster still deploys them.",
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
    let manifests = owned_view::kix_owned_manifests_against(compared, &built);

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
            // `check_object` reports only on live objects, so never `Missing`.
            DriftVerdict::InSync | DriftVerdict::Missing { .. } => {}
        }
    }
    (drifted, unchecked)
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
    print!(
        "{}",
        crate::plan::migrations::diff(&crate::plan::migrations::of_pairs(pairs))
    );
    println!();
}

fn print_markdown_output(result: &DiffResult) {
    // Share the package-level Markdown renderer with the deploy modal and CI PR comments.
    print!("{}", plan::render_package_diff_markdown(&result.packages));

    if !result.migration_pairs.is_empty() {
        println!(
            "{}",
            crate::plan::migrations::diff_markdown(&crate::plan::migrations::of_pairs(
                &result.migration_pairs
            ))
        );
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
    use kube::api::DynamicObject;
    use serde_json::json;

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
            text.contains(&format!(
                "2 object(s) not checked for drift: missing `{}` annotation",
                kix::manifest::keys::APPLIED_HASH
            )),
            "{text}"
        );
        assert!(
            text.contains("ownership conflict with kubectl-edit"),
            "{text}"
        );
        let markdown = render::render_drift_markdown(&result.doc);
        assert!(
            markdown.contains("2 object(s) not checked for drift"),
            "{markdown}"
        );
        assert!(
            text.contains("\"web:2\" live, \"web:1\" in deployed build, set by kubectl-edit"),
            "{text}"
        );
    }
}
