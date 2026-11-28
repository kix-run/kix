//! Classify soft, hard, and Activation record garbage for `kix gc`.

use std::collections::HashSet;

use miette::{Result, miette};
use serde_json::Value;

use crate::cli::GcArgs;
use crate::client;
use crate::output;
use kix::cluster::activation::{Record, Records, RetentionPolicy, Retirement, retire_plan};
use kix::cluster::discovery;
use kix::cluster::inventory;
use kix::cluster::tenancy::Tenancy;
use kix::manifest::keys;
use kix::manifest::lifecycle;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId, to_manifest_value};

/// Reason a live resource was classified as garbage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum GarbageReason {
    /// The build gc compares with does not make the resource: the Active
    /// build, or the build from the current files when the cluster has no
    /// Active record.
    NotInBuild,
    /// Superseded `Activation` record retired by the retention policy
    /// (`--keep`, `--keep-max`, `--keep-for`).
    RetiredActivation,
}

impl GarbageReason {
    /// Describe the reason, naming `compared`, the build this run compared
    /// live objects with, such as `the build of active deployment c-v2`.
    pub(super) fn label(&self, compared: &str) -> String {
        match self {
            GarbageReason::NotInBuild => format!("not in {compared}"),
            GarbageReason::RetiredActivation => {
                "activation record retired by retention".to_string()
            }
        }
    }
}

pub(super) struct GarbageEntry {
    pub(super) id: ResourceId,
    pub(super) identity_hash: Option<String>,
    pub(super) package: Option<String>,
    pub(super) package_namespace: Option<String>,
    pub(super) reason: GarbageReason,
    /// What the object waits for when it is already being deleted.
    pub(super) deleting: Option<String>,
}

/// Planned Activation record retirement paired with the [`Records`] handle used
/// to list and delete them.
pub(super) struct RecordRetirement {
    pub(super) records: Option<Records>,
    pub(super) plan: Retirement,
    /// Current Active or Degraded record for the cluster, used to inspect
    /// `orphansKeptFrom`.
    pub(super) active: Option<Record>,
    /// The cluster's deploy lock, read with the records. gc binds to its
    /// generation and checks its writer.
    pub(super) head: Option<kix::cluster::head::Head>,
}

impl RecordRetirement {
    /// Refuse gc of `cluster` when this Kix may not write to it: a newer
    /// minor of Kix wrote to it last, or gc would skip a required stop.
    pub(super) fn check_writer(&self, cluster: &str) -> Result<()> {
        let last = kix::cluster::stops::LastWrite::of(
            self.head.as_ref().and_then(|h| h.writer()),
            self.active.as_ref(),
        );
        super::super::deploy::stops::check(cluster, &last, super::super::deploy::stops::Writer::Gc)
            .map(|_| ())
    }

    /// Take the deploy lock of `cluster` through `client`, bound to the
    /// generation gc read with the records, and read and write the records
    /// through the lock's guarded client from then on.
    pub(super) async fn lock(
        &mut self,
        client: &kube::Client,
        cluster: &str,
    ) -> Result<std::sync::Arc<kix::cluster::head::Lock>> {
        let lock = super::super::lock::take(
            client,
            cluster,
            "kix gc",
            kix::cluster::head::Purpose::Gc,
            None,
            Some(kix::cluster::head::generation_of(self.head.as_ref())),
        )
        .await?;
        if let Some(records) = &self.records {
            self.records = Some(records.through(&lock.guarded(client)));
        }
        Ok(lock)
    }

    /// Return how many older deployment records gc keeps, such as `2 older
    /// deployment records kept for rollback`.
    pub(super) fn kept_note(&self) -> String {
        if self.records.is_none() {
            return "no deployment records on this cluster".to_string();
        }
        match self.plan.kept.len() {
            0 => "no older deployment records".to_string(),
            1 => "1 older deployment record kept for rollback".to_string(),
            n => format!("{n} older deployment records kept for rollback"),
        }
    }
}

/// Return manifests from `closures` (the kept orphans) whose kind,
/// namespace, and name the Active build does not make, once each.
/// `active_ids` holds the Kubernetes identities of the Active build's
/// objects.
pub(super) fn kept_garbage(closures: &[Vec<Value>], active_ids: &HashSet<String>) -> Vec<Value> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    for manifest in closures.iter().flatten() {
        if !lifecycle::lifecycle_of(manifest).prunable()
            || active_ids.contains(&k8s_identity(manifest))
        {
            continue;
        }
        if seen.insert(k8s_identity(manifest)) {
            out.push(manifest.clone());
        }
    }
    out
}

/// Return `true` when gc may clear the builds `active` lists under
/// `status.orphansKeptFrom`.
///
/// Clearing is safe only when `active` matches `build_hash` and `examined_all`
/// is true (soft GC resolved every listed build, or hard GC listed every
/// resource kind and unattributed resource).
pub(super) fn may_clear_kept(
    active: &Record,
    examined_all: bool,
    build_hash: Option<&str>,
) -> bool {
    examined_all && build_hash.is_some() && active.identity_hash.as_deref() == build_hash
}

/// What [`judge_hard`] found.
#[derive(Default)]
pub(super) struct Judged {
    pub garbage: Vec<GarbageEntry>,
    /// Orphans another Kix cluster's current record still names.
    pub shared: Vec<inventory::SharedOrphan>,
    /// Objects a pending record of this Kix cluster names.
    pub held: Vec<inventory::HeldObject>,
}

/// Classify `live` objects against `expected_ids`, the Kubernetes
/// identities of the objects of the build gc compares with. An object of
/// that build is never garbage.
///
/// An object outside that build is kept, not garbage, when a pending record
/// of this Kix cluster deploys it, such as a failed or partly deployed
/// deploy that wrote it, or when another Kix cluster deploys it. For a Kix
/// cluster read from revisions, it is garbage only when its kept-orphans
/// revision alone names it ([`Tenancy::gc_may_delete`]). Activation records
/// are skipped here and handled by the retention policy.
pub(super) fn judge_hard(
    live: &[kube::api::DynamicObject],
    expected_ids: &HashSet<String>,
    tenancy: &Tenancy,
) -> Judged {
    let mut garbage: Vec<GarbageEntry> = Vec::new();
    let mut shared: Vec<inventory::SharedOrphan> = Vec::new();
    let mut held: Vec<inventory::HeldObject> = Vec::new();
    for obj in live {
        if kix::manifest::lifecycle::lifecycle_of_live(obj)
            == kix::manifest::lifecycle::Lifecycle::Record
        {
            continue;
        }
        if expected_ids.contains(&live_identity(obj)) {
            continue;
        }

        let annotations_from_data = obj
            .data
            .pointer("/metadata/annotations")
            .and_then(|a| a.as_object());

        // An older Kix stamped these notes on the objects it applied. The
        // list shows them when an object still carries them.
        let ann_get = |key: &str| -> Option<String> {
            if let Some(map) = annotations_from_data
                && let Some(v) = map.get(key).and_then(|v| v.as_str())
            {
                return Some(v.to_string());
            }
            obj.metadata
                .annotations
                .as_ref()
                .and_then(|a| keys::get_meta(a, key))
                .map(str::to_string)
        };

        let records = tenancy.pending_records_of(obj);
        if !records.is_empty() {
            held.push(inventory::HeldObject {
                rid: kix::cluster::drift::resource_id(obj),
                records,
            });
            continue;
        }

        let others = tenancy.still_deployed_by_others(obj);
        if !others.is_empty()
            && !lifecycle::never_pruned(kix::cluster::drift::resource_id(obj).group_kind())
        {
            shared.push(inventory::SharedOrphan {
                rid: ResourceId::from_value(&to_manifest_value(obj)),
                clusters: others,
            });
            continue;
        }

        // A cluster read from revisions names what it deploys. gc deletes
        // only its kept orphans, so an object the current record names with
        // another build hash stays.
        if tenancy.gc_may_delete(obj) == Some(false) {
            continue;
        }

        // A package instance record names its instance in its spec, not in
        // its `kix.run/package` stamp.
        let (package, package_namespace) =
            match kix::eval::store_graph::instance_of_record(&to_manifest_value(obj)) {
                Some((ns, name)) => (Some(name), Some(ns)),
                None => (ann_get(keys::PACKAGE), ann_get(keys::PACKAGE_NAMESPACE)),
            };
        garbage.push(GarbageEntry {
            id: kix::cluster::drift::resource_id(obj),
            identity_hash: ann_get(keys::IDENTITY_HASH),
            package,
            package_namespace,
            reason: GarbageReason::NotInBuild,
            deleting: kix::cluster::readiness::deletion_reason(obj),
        });
    }
    Judged {
        garbage,
        shared,
        held,
    }
}

/// Collect the swept objects that hard GC evaluates against the build,
/// including `unattributed` and `copies` when their respective flags are set.
pub(super) fn judged_objects(
    sweep: inventory::ManagedSweep,
    include_unattributed: bool,
    include_copies: bool,
) -> Vec<kube::api::DynamicObject> {
    let unattributed = if include_unattributed {
        sweep.unattributed
    } else {
        Vec::new()
    };
    let copies = if include_copies {
        sweep.copies
    } else {
        Vec::new()
    };
    sweep
        .managed
        .into_iter()
        .chain(unattributed)
        .chain(copies)
        .collect()
}

/// Build a [`RetentionPolicy`] from `args`, clamping `--keep-max` to at least `--keep`.
pub(super) fn retention_policy(args: &GcArgs) -> Result<RetentionPolicy> {
    let keep_for = parse_retention_duration(&args.keep_for)?;
    if args.keep_max < args.keep && !args.yes {
        eprintln!(
            "{}",
            output::yellow(&format!(
                "Warning: `--keep-max {}` is below `--keep {}`; keeping {}.",
                args.keep_max, args.keep, args.keep
            ))
        );
    }
    if args.keep == 0 && !args.yes {
        eprintln!(
            "{}",
            output::yellow(
                "Warning: `--keep 0` is set; every rollback target older than `--keep-for` will be retired."
            )
        );
    }
    Ok(RetentionPolicy {
        keep_min: args.keep,
        keep_max: args.keep_max.max(args.keep),
        keep_for,
        now: chrono::Utc::now(),
    })
}

/// Parse a retention duration (`30d`, `12h`, `45m`, `30s`, a bare day count, or
/// `0`/`off`/`never` to disable age-based retirement).
pub(super) fn parse_retention_duration(s: &str) -> Result<Option<chrono::Duration>> {
    let s = s.trim();
    if s == "0" || s.eq_ignore_ascii_case("off") || s.eq_ignore_ascii_case("never") {
        return Ok(None);
    }
    let (digits, unit) = match s.find(|c: char| !c.is_ascii_digit()) {
        Some(i) => s.split_at(i),
        None => (s, "d"),
    };
    let n: i64 = digits
        .parse()
        .map_err(|_| miette!("--keep-for: expected a number with d, h, m or s (got '{s}')"))?;
    let d = match unit.trim() {
        "d" | "day" | "days" => chrono::Duration::days(n),
        "h" | "hour" | "hours" => chrono::Duration::hours(n),
        "m" | "min" | "minute" | "minutes" => chrono::Duration::minutes(n),
        "s" | "sec" | "second" | "seconds" => chrono::Duration::seconds(n),
        other => {
            return Err(miette!(
                "--keep-for: unknown unit '{other}' (use d, h, m or s, or 0 to disable)"
            ));
        }
    };
    Ok(Some(d))
}

/// Connect to the cluster and plan Activation record retirement for `cluster`.
pub(super) async fn plan_record_retirement(
    global: &crate::cli::GlobalArgs,
    cluster: &str,
    policy: &RetentionPolicy,
    settle: bool,
) -> Result<RecordRetirement> {
    plan_records_with(
        open_records(global, cluster, settle).await?,
        cluster,
        policy,
    )
    .await
}

/// Say which Kubernetes cluster gc targets, connect to it, and open its
/// Activation records, or return `None` when the cluster has none. With
/// `settle`, which a gc that will write passes, first refuse when an older
/// Kix operator drives a record of `cluster`, then settle a deploy lock
/// another run holds on it, so what gc reads is what a dead run's takeover
/// left.
pub(super) async fn open_records(
    global: &crate::cli::GlobalArgs,
    cluster: &str,
    settle: bool,
) -> Result<Option<Records>> {
    let (client, _) = client::connect(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    if settle {
        super::super::operator::refuse_older_operator(&client, cluster).await?;
        super::super::lock::settle(&client, cluster, "kix gc", kix::cluster::head::Purpose::Gc)
            .await?;
    }
    let discovery = discovery::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;
    Ok(Records::open(&client, &discovery)
        .map_err(|e| miette!("{e}"))?
        .into_records())
}

/// List Superseded records and compute the retirement plan for `cluster`.
pub(super) async fn plan_records_with(
    records: Option<Records>,
    cluster: &str,
    policy: &RetentionPolicy,
) -> Result<RecordRetirement> {
    let Some(records) = records else {
        return Ok(RecordRetirement {
            records: None,
            plan: Default::default(),
            active: None,
            head: None,
        });
    };
    let superseded = records
        .superseded(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;
    let plan = retire_plan(superseded, policy);
    let active = records.active(cluster).await.map_err(|e| miette!("{e}"))?;
    let head = kix::cluster::head::read(records.client(), cluster)
        .await
        .map_err(|e| {
            miette!(
                "cannot read deploy lock `ActivationHead` `{cluster}`: {}. Nothing was deleted from cluster {cluster}. Check your cluster connection and grant this account `get` on `{}` if needed, then run the command again.",
                kix::cluster::errors::describe(&e),
                kix::cluster::head::crd_name()
            )
        })?;
    Ok(RecordRetirement {
        records: Some(records),
        plan,
        active,
        head,
    })
}

/// Convert retired Activation records in `plan` into hard-mode [`GarbageEntry`] items.
pub(super) fn record_garbage(plan: &Retirement) -> Vec<GarbageEntry> {
    plan.retire
        .iter()
        .map(|retired| GarbageEntry {
            id: ResourceId {
                group: keys::GROUP.to_string(),
                kind: kix::manifest::lifecycle::RECORD_KIND.to_string(),
                namespace: CLUSTER_SCOPED.to_string(),
                name: retired.record.name.clone(),
            },
            identity_hash: retired.record.identity_hash.clone(),
            package: None,
            package_namespace: None,
            reason: GarbageReason::RetiredActivation,
            deleting: None,
        })
        .collect()
}

/// Return `kind/namespace/name` for a live object, matching [`k8s_identity`].
pub(super) fn live_identity(obj: &kube::api::DynamicObject) -> String {
    let kind = obj
        .data
        .get("kind")
        .and_then(|v| v.as_str())
        .or_else(|| obj.types.as_ref().map(|t| t.kind.as_str()))
        .unwrap_or("Unknown");
    let namespace = obj
        .metadata
        .namespace
        .as_deref()
        .unwrap_or(kix::manifest::types::CLUSTER_SCOPED);
    let name = obj.metadata.name.as_deref().unwrap_or("unknown");
    format!("{kind}/{namespace}/{name}")
}

/// Return `kind/namespace/name` for `manifest`.
pub(super) fn k8s_identity(manifest: &Value) -> String {
    let rid = ResourceId::from_value(manifest);
    format!("{}/{}/{}", rid.kind, rid.namespace, rid.name)
}
