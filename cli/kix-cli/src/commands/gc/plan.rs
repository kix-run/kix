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
use kix::manifest::keys;
use kix::manifest::lifecycle;
use kix::manifest::types::{CLUSTER_SCOPED, ResourceId, to_manifest_value};

/// Reason a live resource was classified as garbage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum GarbageReason {
    /// Resource carries a `kix.run/identity-hash` that is absent from the
    /// build gc compares with: the Active build, or the build from the current
    /// files when the cluster has no Active record.
    HashNotExpected,
    /// Resource carries the Kix label but no `kix.run/identity-hash` annotation.
    NoIdentityHash,
    /// Superseded `Activation` record retired by the retention policy
    /// (`--keep`, `--keep-max`, `--keep-for`).
    RetiredActivation,
}

impl GarbageReason {
    /// Describe the reason, naming `compared`, the build this run compared
    /// live objects with, such as `the build of active deployment c-v2`.
    pub(super) fn label(&self, compared: &str) -> String {
        match self {
            GarbageReason::HashNotExpected => format!("not in {compared}"),
            GarbageReason::NoIdentityHash => {
                "carries Kix's label but no Kix build annotation".to_string()
            }
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
    pub(super) activations: Option<String>,
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
}

impl RecordRetirement {
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

/// Return manifests from `closures` (`status.orphansKeptFrom`) that the
/// Active build does not contain, once each. `active_hashes` and `active_ids`
/// are the Active build's store hashes and Kubernetes identities.
pub(super) fn kept_garbage(
    closures: &[Vec<Value>],
    active_hashes: &HashSet<String>,
    active_ids: &HashSet<String>,
) -> Vec<Value> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    for manifest in closures.iter().flatten() {
        let Some(hash) = keys::get(manifest, keys::IDENTITY_HASH) else {
            continue;
        };
        if !lifecycle::lifecycle_of(manifest).prunable()
            || active_hashes.contains(hash)
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

/// Return `true` when `clear_kept` may clear `orphansKeptFrom` on `active`.
///
/// Clearing is safe only when `active` matches `build_hash` and `examined_all`
/// is true (soft GC resolved every listed build, or hard GC listed every
/// resource kind and unattributed resource).
pub(super) fn may_clear_kept(
    active: &Record,
    examined_all: bool,
    build_hash: Option<&str>,
) -> bool {
    !active.orphans_kept_from.is_empty()
        && examined_all
        && build_hash.is_some()
        && active.identity_hash.as_deref() == build_hash
}

/// Classify `live` objects against `expected_hashes` and `expected_ids`,
/// returning garbage entries and orphans shared with other Kix clusters.
///
/// Activation records are skipped here and handled by the retention policy.
pub(super) fn judge_hard(
    live: &[kube::api::DynamicObject],
    expected_hashes: &HashSet<String>,
    expected_ids: &HashSet<String>,
    tenancy: &kix::cluster::tenancy::Tenancy,
) -> (Vec<GarbageEntry>, Vec<inventory::SharedOrphan>) {
    let mut garbage: Vec<GarbageEntry> = Vec::new();
    let mut shared: Vec<inventory::SharedOrphan> = Vec::new();
    for obj in live {
        if kix::manifest::lifecycle::lifecycle_of_live(obj)
            == kix::manifest::lifecycle::Lifecycle::Record
        {
            continue;
        }

        let annotations_from_data = obj
            .data
            .pointer("/metadata/annotations")
            .and_then(|a| a.as_object());

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

        let identity_hash = ann_get(keys::IDENTITY_HASH);

        let reason = match &identity_hash {
            Some(hash) if expected_hashes.contains(hash) => continue,
            // Objects stamped before the domain migration carry hashes computed
            // from store paths under the retired domain, so compare them by
            // Kubernetes identity instead.
            Some(_)
                if kix::legacy_domain::stamped_before_move(|key| has_key(obj, key))
                    && expected_ids.contains(&live_identity(obj)) =>
            {
                continue;
            }
            Some(_) => GarbageReason::HashNotExpected,
            None => GarbageReason::NoIdentityHash,
        };

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

        // A package instance record names its instance in its spec, not in
        // its `kix.run/package` stamp.
        let (package, package_namespace) =
            match kix::eval::store_graph::instance_of_record(&to_manifest_value(obj)) {
                Some((ns, name)) => (Some(name), Some(ns)),
                None => (ann_get(keys::PACKAGE), ann_get(keys::PACKAGE_NAMESPACE)),
            };
        garbage.push(GarbageEntry {
            id: kix::cluster::drift::resource_id(obj),
            identity_hash,
            package,
            package_namespace,
            activations: ann_get(keys::ACTIVATIONS),
            reason,
            deleting: kix::cluster::readiness::deletion_reason(obj),
        });
    }
    (garbage, shared)
}

/// Split out the unstamped objects that `--include unstamped` covers, unless
/// `include_unstamped` is set, and return them with the rest of `garbage`.
///
/// An unstamped object is one Kix wrote without `kix.run/identity-hash`. A
/// copy has no hash either, but the sweep already set it apart and
/// `--include copies` judges it, so `copies` (the ids of the sweep's copies)
/// stay in the rest. Protected kinds stay in the rest too, so the plan lists
/// them as kept.
pub(super) fn hold_back_unstamped(
    garbage: Vec<GarbageEntry>,
    copies: &HashSet<ResourceId>,
    include_unstamped: bool,
) -> (Vec<GarbageEntry>, Vec<GarbageEntry>) {
    garbage.into_iter().partition(|g| {
        g.reason == GarbageReason::NoIdentityHash
            && !include_unstamped
            && !copies.contains(&g.id)
            && !lifecycle::never_pruned(g.id.group_kind())
    })
}

/// Return `true` if `obj` carries annotation `key` in its raw data or typed metadata.
pub(super) fn has_key(obj: &kube::api::DynamicObject, key: &str) -> bool {
    obj.data
        .pointer("/metadata/annotations")
        .and_then(|a| a.as_object())
        .is_some_and(|m| m.contains_key(key))
        || obj
            .metadata
            .annotations
            .as_ref()
            .is_some_and(|a| a.contains_key(key))
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
        .chain(sweep.unstamped)
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
) -> Result<RecordRetirement> {
    plan_records_with(open_records(global).await?, cluster, policy).await
}

/// Say which Kubernetes cluster gc targets, connect to it, and open its
/// Activation records, or return `None` when the cluster has none.
pub(super) async fn open_records(global: &crate::cli::GlobalArgs) -> Result<Option<Records>> {
    let (client, _) = client::connect(global.context.as_deref())
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
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
        });
    };
    let superseded = records
        .superseded(cluster)
        .await
        .map_err(|e| miette!("{e}"))?;
    let plan = retire_plan(superseded, policy);
    let active = records.active(cluster).await.map_err(|e| miette!("{e}"))?;
    Ok(RecordRetirement {
        records: Some(records),
        plan,
        active,
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
            activations: None,
            reason: GarbageReason::RetiredActivation,
            deleting: None,
        })
        .collect()
}

/// Return `kind/namespace/name` for a live object, matching [`k8s_identity`].
fn live_identity(obj: &kube::api::DynamicObject) -> String {
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
