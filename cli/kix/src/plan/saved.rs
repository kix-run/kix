//! Saved plans: whether a plan made now still matches a reviewed one.
//!
//! `kix deploy --plan plan.kixplan` rebuilds, plans again, and refuses when
//! [`compare`] finds a mismatch. A saved plan only restricts a deploy; the
//! deploy never applies anything read from it.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;
use serde_json::Value;

use super::document::{Checked, MadeBy, Plan, PlanFlags, PruneFate};
use crate::cluster::scheduler::PrunePolicy;

/// One comparison rule between a reviewed plan and a fresh plan.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Rule {
    Cluster,
    NewBuild,
    Objects,
    DeployedBuild,
    Generation,
    Flags,
    NewRefusal,
    NewRevertedDrift,
    NewPruneDelete,
    NewlyUnchecked,
}

impl Rule {
    /// Return the display label for this rule.
    pub fn label(self) -> &'static str {
        match self {
            Rule::Cluster => "cluster",
            Rule::NewBuild => "new build",
            Rule::Objects => "objects",
            Rule::DeployedBuild => "deployed build",
            Rule::Generation => "lock generation",
            Rule::Flags => "flags",
            Rule::NewRefusal => "new refusal",
            Rule::NewRevertedDrift => "new drift",
            Rule::NewPruneDelete => "new prune delete",
            Rule::NewlyUnchecked => "not checked now",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, schemars::JsonSchema)]
pub struct Mismatch {
    pub rule: Rule,
    /// What differs, one line each.
    pub items: Vec<String>,
}

/// The result of comparing a fresh plan with a reviewed one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, schemars::JsonSchema)]
pub struct Comparison {
    /// `sha256:<hex>` of the reviewed plan file, so an approval system can
    /// check the deploy used the file it approved. Set by the caller.
    pub plan_sha256: Option<String>,
    pub matches: bool,
    pub mismatches: Vec<Mismatch>,
    /// Rules the reviewed plan could not be held to, because it did not
    /// make that check (a plan from `kix diff` or `kix plan --read-only` checks
    /// no refusals or prune).
    pub skipped: Vec<Rule>,
    /// The two Kix binaries, reviewed then fresh, when they differ. Reported
    /// and not refused: the objects digest already holds the deploy to the
    /// objects and build files that were reviewed, and the binary is chosen
    /// by whoever runs the deploy.
    pub kix_differs: Option<(String, String)>,
}

/// Return a reason why `reviewed`, read from `file`, cannot be used to gate
/// a deploy of `cluster`, or `None` when it is valid.
pub fn unusable(reviewed: &Plan, file: &str, cluster: &str) -> Option<String> {
    let fresh = format!(
        "Nothing was applied to the cluster. Next: save a fresh plan with `kix plan {cluster} --out {file}`."
    );
    let against = format!(
        "Nothing was applied to the cluster. Next: save a plan against the cluster with `kix plan {cluster} --out {file}` or `kix plan {cluster} --read-only --out {file}`."
    );
    // A plan's sections follow from how it was made. One that reads
    // otherwise was edited, and an edit can only loosen the comparison:
    // a section marked not checked is skipped, and flags are taken as given.
    let consistent = match reviewed.made_by {
        MadeBy::DryRun => {
            reviewed.flags.is_some()
                && matches!(reviewed.conflicts, Checked::Checked { .. })
                && matches!(reviewed.admission, Checked::Checked { .. })
                && matches!(reviewed.prune, Checked::Checked { .. })
        }
        MadeBy::LiveRead => reviewed.flags.is_none(),
        MadeBy::Builds => true,
    };
    if !consistent {
        return Some(format!(
            "the file's sections do not match how it says it was made, so it was edited \
             after `kix plan` or `kix diff` wrote it. {fresh}"
        ));
    }
    if reviewed.made_by == MadeBy::LiveRead && !matches!(reviewed.drift, Checked::Checked { .. }) {
        return Some(format!(
            "the plan is a `kix diff` against a snapshot or export, so it did not check \
             live cluster drift that the deploy would overwrite. {against}"
        ));
    }
    // The digest is what holds a deploy to the reviewed objects, so a plan
    // without one, or whose list does not give it, cannot be used.
    match (&reviewed.objects_digest, &reviewed.objects) {
        (Some(digest), Some(objects)) if *digest == super::objects::digest(objects) => {}
        (Some(_), Some(_)) => {
            return Some(format!(
                "the objects in the file do not match its recorded object digest, so it was \
                 edited after `kix plan` wrote it. {fresh}"
            ));
        }
        _ => {
            return Some(format!(
                "the file does not list the exact objects a deploy writes and deletes, which \
                 only `kix plan` records. Nothing was applied to the cluster. Next: save a \
                 plan with `kix plan {cluster} --out {file}`."
            ));
        }
    }
    if reviewed.made_by == MadeBy::Builds {
        return Some(format!(
            "the plan compared two builds without reading the cluster, so it did not check \
             the cluster's current deployment or drift. {against}"
        ));
    }
    None
}

/// Return the planning flags for a deploy of `cluster` gated by `reviewed`,
/// read from `file`, or an error when `given` contradicts the plan.
pub fn flags_for(
    reviewed: &Plan,
    given: &PlanFlags,
    file: &str,
    cluster: &str,
) -> Result<PlanFlags, String> {
    let Some(planned) = reviewed.flags.clone() else {
        // A plan from `kix diff` or `kix plan --read-only`: no reviewer saw
        // what these flags would do.
        let refused: Vec<&str> = [
            (given.prune == PrunePolicy::Delete, "--prune"),
            (given.force_conflicts, "--force-conflicts"),
            (given.reconcile, "--reconcile"),
            (given.accept_migrations, "--accept-migrations"),
            (!given.only.is_empty(), "--only"),
            (given.operator_removed, "--operator-removed"),
        ]
        .into_iter()
        .filter_map(|(set, flag)| set.then_some(flag))
        .collect();
        if !refused.is_empty() {
            return Err(format!(
                "the plan was saved by `kix diff` or `kix plan --read-only`, which do not check what {} would do. \
                 Nothing was applied to the cluster. Next: save and review a plan with \
                 `kix plan {cluster} {} --out {file}`.",
                refused.join(", "),
                refused.join(" ")
            ));
        }
        return Ok(given.clone());
    };
    // A saved plan of part of a build deploys that part, and one of the
    // whole build deploys all of it, so `--only` must name what the plan
    // names, or nothing on both sides.
    if given.only != planned.only {
        let only = |names: &[String]| {
            names
                .iter()
                .map(|n| format!("--only {n}"))
                .collect::<Vec<_>>()
                .join(" ")
        };
        let (mismatch, next) = if planned.only.is_empty() {
            let asked = only(&given.only);
            (
                format!(
                    "the plan was saved without `--only` (for the full build), so it cannot be deployed with `{asked}`"
                ),
                format!(
                    "remove `--only` to deploy the full plan, or save and review a new plan with \
                     `kix plan {cluster} {asked} --out {file}`"
                ),
            )
        } else if given.only.is_empty() {
            let saved_flags = only(&planned.only);
            (
                format!("the plan was saved with `{saved_flags}`, so `--only` must match"),
                format!(
                    "pass `{saved_flags}` to deploy this plan, or save and review a full plan with \
                     `kix plan {cluster} --out {file}`"
                ),
            )
        } else {
            let saved_flags = only(&planned.only);
            let asked = only(&given.only);
            (
                format!("the plan was saved with `{saved_flags}`, which does not match `{asked}`"),
                format!(
                    "pass `{saved_flags}` to deploy this plan, or save and review a new plan with \
                     `kix plan {cluster} {asked} --out {file}`"
                ),
            )
        };
        return Err(format!(
            "{mismatch}. Nothing was applied to the cluster. Next: {next}."
        ));
    }
    let mut contradicted = Vec::new();
    // The default policy takes the plan's. A policy asked for on the
    // command line must be the plan's.
    if let Some(flag) = PlanFlags::prune_flag(given.prune)
        && given.prune != planned.prune
    {
        contradicted.push(flag.to_string());
    }
    for (set, in_plan, flag) in [
        (given.reconcile, planned.reconcile, "--reconcile"),
        (
            given.force_conflicts,
            planned.force_conflicts,
            "--force-conflicts",
        ),
        (
            given.accept_migrations,
            planned.accept_migrations,
            "--accept-migrations",
        ),
        (
            given.operator_removed,
            planned.operator_removed,
            "--operator-removed",
        ),
    ] {
        if set && !in_plan {
            contradicted.push(flag.to_string());
        }
    }
    if !contradicted.is_empty() {
        return Err(format!(
            "the plan was saved without {}. Nothing was applied to the cluster. Next: save \
             and review a plan with `kix plan {cluster} {} --out {file}`.",
            contradicted.join(", "),
            contradicted.join(" ")
        ));
    }
    Ok(planned)
}

/// Compare `fresh`, the plan made now, with `reviewed`.
pub fn compare(reviewed: &Plan, fresh: &Plan) -> Comparison {
    let mut mismatches = Vec::new();
    let mut skipped = Vec::new();
    let mut mismatch = |rule, items: Vec<String>| {
        if !items.is_empty() {
            mismatches.push(Mismatch { rule, items });
        }
    };

    if reviewed.cluster != fresh.cluster {
        mismatch(
            Rule::Cluster,
            vec![format!(
                "the plan is for {}, this deploy is of {}",
                reviewed.cluster, fresh.cluster
            )],
        );
    }

    let (r, f) = (&reviewed.build.identity_hash, &fresh.build.identity_hash);
    if r.is_none() || r != f {
        mismatch(
            Rule::NewBuild,
            vec![format!(
                "the plan is for build {} ({}), this deploy builds {} ({})",
                or_unknown(r),
                reviewed.build.store_path,
                or_unknown(f),
                fresh.build.store_path
            )],
        );
    }

    if reviewed.objects_digest.is_none() || reviewed.objects_digest != fresh.objects_digest {
        mismatch(Rule::Objects, objects_differ(reviewed, fresh));
    }

    // A record without an identity hash (written by an older Kix) is
    // matched by its name, which carries a prefix of the hash.
    let same_deployed = match (&reviewed.deployed, &fresh.deployed) {
        (None, None) => true,
        (Some(r), Some(f)) => match (&r.identity_hash, &f.identity_hash) {
            (Some(rh), Some(fh)) => rh == fh,
            _ => r.activation == f.activation && r.identity_hash == f.identity_hash,
        },
        _ => false,
    };
    if !same_deployed {
        let name = |p: &Plan| match &p.deployed {
            Some(d) => format!(
                "{} (identity {})",
                d.activation,
                or_unknown(&d.identity_hash)
            ),
            None => "no build".into(),
        };
        mismatch(
            Rule::DeployedBuild,
            vec![format!(
                "the cluster now runs {}, the plan was made against {}",
                name(fresh),
                name(reviewed)
            )],
        );
    }

    // The generation rises each time a run that wrote to the cluster ends,
    // so a plan saved before another run is stale even when the deployed
    // record is the same, as after a deploy with `--only` or a gc. A plan
    // saved without it (`--offline`, or by an older Kix) is not held to it.
    match (&reviewed.head, &fresh.head) {
        (Some(r), Some(f)) => {
            if r.generation != f.generation {
                mismatch(
                    Rule::Generation,
                    vec![format!(
                        "the cluster is at deploy lock generation {}, while the saved plan was made at generation {} (another run changed the cluster after the plan was saved)",
                        f.generation, r.generation
                    )],
                );
            }
        }
        _ => skipped.push(Rule::Generation),
    }

    let flags_differ = match (&reviewed.flags, &fresh.flags) {
        (Some(r), Some(f)) => r != f,
        (None, Some(f)) => f.prune == PrunePolicy::Delete || f.force_conflicts || f.reconcile,
        (_, None) => false,
    };
    if flags_differ {
        mismatch(
            Rule::Flags,
            vec![format!(
                "the plan was made with {}, this deploy uses {}",
                describe_flags(reviewed.flags.as_ref()),
                describe_flags(fresh.flags.as_ref())
            )],
        );
    }

    match (&reviewed.conflicts, &reviewed.admission) {
        (Checked::Checked { items: rc }, Checked::Checked { items: ra }) => {
            let known: BTreeSet<String> = rc
                .iter()
                .map(|c| c.resource.clone())
                .chain(ra.iter().map(|a| refusal_key(&a.resource, a.reason)))
                .collect();
            let mut new: Vec<String> = Vec::new();
            for c in fresh.conflicts.items() {
                if !known.contains(&c.resource) {
                    let managers: Vec<&str> = c.owners.iter().map(|o| o.manager.as_str()).collect();
                    new.push(format!(
                        "{}: field ownership conflict with {}",
                        c.resource,
                        managers.join(", ")
                    ));
                }
            }
            for a in fresh.admission.items() {
                if !known.contains(&refusal_key(&a.resource, a.reason)) {
                    new.push(format!("{}: {}", a.resource, reason_name(a.reason)));
                }
            }
            mismatch(Rule::NewRefusal, new);
        }
        _ => skipped.push(Rule::NewRefusal),
    }

    match &reviewed.drift {
        Checked::Checked { items } => {
            // A reverted field the reviewed plan showed, with the live value
            // it showed. A plan saved before drift entries carried values
            // compares fields only.
            let known: BTreeMap<(&str, &str), Option<&Value>> = items
                .iter()
                .filter(|d| d.reverted)
                .map(|d| ((d.resource.as_str(), d.path.as_str()), d.live.as_ref()))
                .collect();
            let new = fresh
                .drift
                .items()
                .iter()
                .filter(|d| d.reverted)
                .filter_map(|d| {
                    let by = if d.managers.is_empty() {
                        String::new()
                    } else {
                        format!(": changed by {}", d.managers.join(", "))
                    };
                    match known.get(&(d.resource.as_str(), d.path.as_str())) {
                        None => Some(format!("{} {}{by}", d.resource, d.path)),
                        Some(Some(shown)) if d.live.as_ref() != Some(*shown) => Some(format!(
                            "{} {}{by}: the live value is now {}, and the plan showed {shown}",
                            d.resource,
                            d.path,
                            d.live
                                .as_ref()
                                .map_or("absent".to_string(), Value::to_string),
                        )),
                        Some(_) => None,
                    }
                })
                .collect();
            mismatch(Rule::NewRevertedDrift, new);
        }
        Checked::NotChecked { .. } => skipped.push(Rule::NewRevertedDrift),
    }

    match &reviewed.prune {
        Checked::Checked { items } => {
            let known: BTreeSet<&str> = items
                .iter()
                .filter(|p| p.fate == PruneFate::Delete)
                .map(|p| p.resource.as_str())
                .collect();
            let new = fresh
                .prune
                .items()
                .iter()
                .filter(|p| p.fate == PruneFate::Delete && !known.contains(p.resource.as_str()))
                .map(|p| format!("{} would be deleted", p.resource))
                .collect();
            mismatch(Rule::NewPruneDelete, new);
        }
        Checked::NotChecked { .. } => skipped.push(Rule::NewPruneDelete),
    }

    // An object the fresh dry run could not check shows no refusal and no
    // drift, so one that the reviewed plan checked hides what rules 5 and 6
    // would have caught.
    if reviewed.made_by == MadeBy::DryRun {
        let known: BTreeSet<&str> = reviewed
            .not_checked
            .iter()
            .map(|o| o.resource.as_str())
            .collect();
        let new = fresh
            .not_checked
            .iter()
            .filter(|o| !known.contains(o.resource.as_str()))
            .map(|o| format!("{}: {}", o.resource, o.detail))
            .collect();
        mismatch(Rule::NewlyUnchecked, new);
    }

    let kix = |p: &Plan| {
        p.kix
            .store_path
            .clone()
            .unwrap_or_else(|| format!("kix {}", p.kix.version))
    };
    let kix_differs = (kix(reviewed) != kix(fresh)).then(|| (kix(reviewed), kix(fresh)));

    Comparison {
        plan_sha256: None,
        matches: mismatches.is_empty(),
        mismatches,
        skipped,
        kix_differs,
    }
}

/// How many differing objects a mismatch names.
const NAMED_OBJECTS: usize = 20;

/// Format the objects that `fresh` writes or deletes that `reviewed` does
/// not, and vice versa, one line each.
fn objects_differ(reviewed: &Plan, fresh: &Plan) -> Vec<String> {
    let (Some(r), Some(f)) = (&reviewed.objects, &fresh.objects) else {
        return vec!["one of the plans lists no objects, so they cannot be compared".into()];
    };
    let write = |w: &super::document::ObjectWrite| {
        format!(
            "{} (store hash {}, package {})",
            object_id(&w.kind, &w.namespace, &w.name),
            w.store_hash,
            w.package
        )
    };
    // The digest covers a delete's group, so two deletes that differ only in
    // their group must read differently here.
    let delete = |d: &super::document::ObjectDelete| {
        let kind = crate::manifest::types::qualified_kind(&d.group, &d.kind);
        object_id(&kind, &d.namespace, &d.name)
    };
    let sets = |p: &super::document::Objects| -> (BTreeSet<String>, BTreeSet<String>) {
        (
            p.writes.iter().map(write).collect(),
            p.deletes.iter().map(delete).collect(),
        )
    };
    let ((rw, rd), (fw, fd)) = (sets(r), sets(f));
    let mut items: Vec<String> = Vec::new();
    items.extend(fw.difference(&rw).map(|w| format!("{w} would be written")));
    items.extend(
        rw.difference(&fw)
            .map(|w| format!("{w} is no longer written")),
    );
    items.extend(fd.difference(&rd).map(|d| format!("{d} would be deleted")));
    items.extend(
        rd.difference(&fd)
            .map(|d| format!("{d} is no longer deleted")),
    );
    if items.is_empty() {
        items.push(format!(
            "the plan's objects digest is {}, this deploy's is {}",
            reviewed.objects_digest.as_deref().unwrap_or("none"),
            fresh.objects_digest.as_deref().unwrap_or("none")
        ));
    }
    if items.len() > NAMED_OBJECTS {
        let more = items.len() - NAMED_OBJECTS;
        items.truncate(NAMED_OBJECTS);
        items.push(format!("and {more} more"));
    }
    items
}

/// Format an object's display ID with build-supplied text escaped.
fn object_id(kind: &str, namespace: &str, name: &str) -> String {
    let id = crate::manifest::types::ResourceId {
        group: String::new(),
        kind: kind.to_string(),
        namespace: namespace.to_string(),
        name: name.to_string(),
    };
    crate::text::printable_up_to(&id.display_id(), 300)
}

fn or_unknown(hash: &Option<String>) -> &str {
    hash.as_deref().unwrap_or("with no identity hash")
}

fn refusal_key(resource: &str, reason: super::document::RefusalReason) -> String {
    format!("{resource}\u{0}{}", reason_name(reason))
}

fn reason_name(reason: super::document::RefusalReason) -> String {
    serde_json::to_value(reason)
        .ok()
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_default()
}

fn describe_flags(flags: Option<&PlanFlags>) -> String {
    let Some(f) = flags else {
        return "no planning flags (a kix diff or kix plan --read-only)".into();
    };
    let set: Vec<String> = PlanFlags::prune_flag(f.prune)
        .into_iter()
        .chain(
            [
                (f.reconcile, "--reconcile"),
                (f.force_conflicts, "--force-conflicts"),
                (f.accept_migrations, "--accept-migrations"),
            ]
            .into_iter()
            .filter_map(|(on, flag)| on.then_some(flag)),
        )
        .map(str::to_string)
        .chain(f.only.iter().map(|n| format!("--only {n}")))
        .collect();
    if set.is_empty() {
        "no planning flags".into()
    } else {
        set.join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::super::document::{
        AdmissionRefusal, Build, Conflict, ConflictOwner, DeployedBuild, DriftChange, KixBuild,
        NotCheckedReason, ObjectDelete, ObjectWrite, Objects, PruneEntry, RefusalReason,
        UncheckedObject, UncheckedReason, WriteChange,
    };
    use super::*;

    fn plan() -> Plan {
        let empty = super::super::diff_graphs(
            &crate::eval::store_graph::StoreGraph::empty("c"),
            &crate::eval::store_graph::StoreGraph::empty("c"),
        );
        let mut p = Plan::new(
            KixBuild::current(&crate::version::running().to_string()),
            MadeBy::DryRun,
            "c",
            Build {
                store_path: "/nix/store/new-cluster-c".into(),
                identity_hash: Some("new".into()),
            },
            &empty,
            super::super::document::Detail::Plain,
            &[],
            NotCheckedReason::BuildsOnly,
        );
        p.kix = KixBuild {
            version: "0.1.0".into(),
            store_path: Some("/nix/store/kix-a".into()),
        };
        p.head = Some(super::super::document::PlanHead {
            generation: 1,
            current: None,
            lock: None,
        });
        p.deployed = Some(DeployedBuild {
            activation: "c-old".into(),
            identity_hash: Some("old".into()),
            store_path: None,
        });
        p.flags = Some(PlanFlags {
            prune: PrunePolicy::WarnOnly,
            reconcile: false,
            force_conflicts: false,
            accept_migrations: false,
            operator_removed: false,
            only: Vec::new(),
        });
        p.conflicts = Checked::found(Vec::new());
        p.admission = Checked::found(Vec::new());
        p.drift = Checked::found(Vec::new());
        p.prune = Checked::found(Vec::new());
        with_objects(p, objects())
    }

    fn objects() -> Objects {
        Objects {
            writes: vec![ObjectWrite {
                kind: "ConfigMap".into(),
                namespace: "app".into(),
                name: "x".into(),
                store_hash: "a".repeat(32),
                package: "app/web".into(),
                change: WriteChange::Added,
                group: String::new(),
                reason: None,
            }],
            deletes: vec![ObjectDelete {
                kind: "ConfigMap".into(),
                namespace: "app".into(),
                name: "old".into(),
                group: String::new(),
            }],
        }
    }

    fn with_objects(mut p: Plan, objects: Objects) -> Plan {
        p.objects_digest = Some(super::super::objects::digest(&objects));
        p.objects = Some(objects);
        p
    }

    fn rules(c: &Comparison) -> Vec<Rule> {
        c.mismatches.iter().map(|m| m.rule).collect()
    }

    #[test]
    fn the_same_plan_matches() {
        let c = compare(&plan(), &plan());
        assert!(c.matches, "{c:?}");
        assert!(c.skipped.is_empty());
        assert_eq!(c.kix_differs, None);
    }

    /// The identity hashes decide; a store path that moved does not.
    #[test]
    fn builds_are_compared_by_identity_hash() {
        let mut moved = plan();
        moved.build.store_path = "/nix/store/elsewhere-cluster-c".into();
        assert!(compare(&plan(), &moved).matches);

        let mut rebuilt = plan();
        rebuilt.build.identity_hash = Some("other".into());
        assert_eq!(rules(&compare(&plan(), &rebuilt)), vec![Rule::NewBuild]);

        let mut redeployed = plan();
        redeployed.deployed.as_mut().unwrap().identity_hash = Some("between".into());
        assert_eq!(
            rules(&compare(&plan(), &redeployed)),
            vec![Rule::DeployedBuild]
        );

        let mut first = plan();
        first.deployed = None;
        assert_eq!(rules(&compare(&first, &plan())), vec![Rule::DeployedBuild]);
    }

    #[test]
    fn a_different_cluster_or_flags_refuse() {
        let mut other = plan();
        other.cluster = "d".into();
        assert!(rules(&compare(&plan(), &other)).contains(&Rule::Cluster));

        let mut pruned = plan();
        pruned.flags.as_mut().unwrap().prune = PrunePolicy::Delete;
        assert_eq!(rules(&compare(&plan(), &pruned)), vec![Rule::Flags]);
    }

    /// Only what is new refuses: a refusal the review saw, or one gone
    /// since, does not.
    #[test]
    fn only_new_refusals_drift_and_deletes_refuse() {
        let mut reviewed = plan();
        reviewed.conflicts = Checked::found(vec![Conflict {
            resource: "Deployment/a@app".into(),
            owners: vec![ConflictOwner {
                manager: "kubectl".into(),
                fields: vec!["spec.replicas".into()],
            }],
            message: "old wording".into(),
        }]);
        let mut fresh = reviewed.clone();
        if let Checked::Checked { items } = &mut fresh.conflicts {
            items[0].message = "new wording".into();
            items[0].owners[0].fields.push("spec.paused".into());
        }
        assert!(compare(&reviewed, &fresh).matches);
        assert!(compare(&fresh, &plan()).matches);

        let mut refused = plan();
        refused.admission = Checked::found(vec![AdmissionRefusal {
            resource: "Deployment/a@app".into(),
            reason: RefusalReason::WebhookDenied,
            webhook: Some("w".into()),
            message: "no".into(),
        }]);
        assert_eq!(rules(&compare(&reviewed, &refused)), vec![Rule::NewRefusal]);

        let drift = |path: &str, live: &str| DriftChange {
            resource: "Deployment/a@app".into(),
            path: path.into(),
            deployed: Some(serde_json::json!(2)),
            live: Some(serde_json::json!(live)),
            managers: vec!["kubectl-scale".into()],
            reverted: true,
        };
        let mut drifted = plan();
        drifted.drift = Checked::found(vec![drift("$.spec.replicas", "5")]);
        // The same field and manager with another live value is a new
        // revert: the deploy would overwrite a value the reviewer did not
        // see.
        let mut redrifted = plan();
        redrifted.drift = Checked::found(vec![drift("$.spec.replicas", "7")]);
        let differs = compare(&drifted, &redrifted);
        assert_eq!(rules(&differs), vec![Rule::NewRevertedDrift]);
        assert_eq!(
            differs.mismatches[0].items,
            [
                "Deployment/a@app $.spec.replicas: changed by kubectl-scale: the live value is now \"7\", and the plan showed \"5\""
            ]
        );
        assert!(compare(&drifted, &drifted).matches);
        // A plan saved before drift entries carried values compares fields
        // only.
        let mut older = plan();
        older.drift = Checked::found(vec![DriftChange {
            live: None,
            ..drift("$.spec.replicas", "5")
        }]);
        assert!(compare(&older, &redrifted).matches);
        assert_eq!(
            rules(&compare(&plan(), &drifted)),
            vec![Rule::NewRevertedDrift]
        );

        let mut deleting = plan();
        deleting.prune = Checked::found(vec![PruneEntry::new(
            "ConfigMap/x@app".into(),
            PruneFate::Delete,
            None,
        )]);
        assert_eq!(
            rules(&compare(&plan(), &deleting)),
            vec![Rule::NewPruneDelete]
        );
    }

    /// A `kix diff` plan holds the deploy to builds and drift, and names the
    /// checks it did not make.
    #[test]
    fn a_diff_plan_skips_the_checks_a_diff_does_not_make() {
        let mut diff = plan();
        diff.made_by = MadeBy::LiveRead;
        diff.flags = None;
        diff.conflicts = Checked::not_checked(NotCheckedReason::ReadOnly);
        diff.admission = Checked::not_checked(NotCheckedReason::ReadOnly);
        diff.prune = Checked::not_checked(NotCheckedReason::ReadOnly);
        let c = compare(&diff, &plan());
        assert!(c.matches, "{c:?}");
        assert_eq!(c.skipped, vec![Rule::NewRefusal, Rule::NewPruneDelete]);
        assert!(unusable(&diff, "p.kixplan", "c").is_none());

        // A diff of a snapshot shows no drift, so it cannot hold rule 6.
        let mut snapshot = diff.clone();
        snapshot.drift = Checked::not_checked(NotCheckedReason::DeployedBuildUnavailable);
        assert!(unusable(&snapshot, "p.kixplan", "c").is_some());

        let accepting = PlanFlags {
            accept_migrations: true,
            operator_removed: false,
            ..plan().flags.unwrap()
        };
        assert!(flags_for(&diff, &accepting, "p.kixplan", "c").is_err());

        let given = PlanFlags {
            prune: PrunePolicy::Delete,
            ..plan().flags.unwrap()
        };
        assert!(flags_for(&diff, &given, "p.kixplan", "c").is_err());
    }

    #[test]
    fn command_line_flags_must_agree_with_the_plan() {
        let none = plan().flags.unwrap();
        assert_eq!(
            flags_for(&plan(), &none, "p.kixplan", "c"),
            Ok(none.clone())
        );

        let mut with_prune = plan();
        with_prune.flags.as_mut().unwrap().prune = PrunePolicy::Delete;
        let taken = flags_for(&with_prune, &none, "p.kixplan", "c").unwrap();
        assert_eq!(
            taken.prune,
            PrunePolicy::Delete,
            "the plan's flags are used"
        );

        let given = PlanFlags {
            reconcile: true,
            ..none
        };
        let err = flags_for(&plan(), &given, "p.kixplan", "c").unwrap_err();
        assert!(err.contains("--reconcile"), "{err}");
    }

    /// A plan saved without `--operator-removed` cannot be deployed with it,
    /// and one saved with it deploys with the flag, given or not.
    #[test]
    fn operator_removed_must_agree_with_the_plan() {
        let none = plan().flags.unwrap();
        let removed = PlanFlags {
            operator_removed: true,
            ..none.clone()
        };
        let err = flags_for(&plan(), &removed, "p.kixplan", "c").unwrap_err();
        assert!(err.contains("--operator-removed"), "{err}");
        let mut saved = plan();
        saved.flags = Some(removed.clone());
        assert_eq!(
            flags_for(&saved, &none, "p.kixplan", "c"),
            Ok(removed.clone())
        );
        assert_eq!(
            flags_for(&saved, &removed, "p.kixplan", "c"),
            Ok(removed.clone())
        );
        let mut diff = plan();
        diff.flags = None;
        assert!(flags_for(&diff, &removed, "p.kixplan", "c").is_err());
        // Left out of a saved plan when not set, as older plans have it.
        let text = serde_json::to_string(&none).unwrap();
        assert!(!text.contains("operatorRemoved"), "{text}");
        let read: PlanFlags =
            serde_json::from_str(&serde_json::to_string(&removed).unwrap()).unwrap();
        assert!(read.operator_removed);
    }

    /// A saved plan of part of a build deploys only with the same `--only`,
    /// and a saved plan of the whole build only without it.
    #[test]
    fn only_must_name_what_the_plan_names() {
        let whole = plan().flags.unwrap();
        let only = |names: &[&str]| PlanFlags {
            only: names.iter().map(|n| n.to_string()).collect(),
            ..whole.clone()
        };
        let mut partial = plan();
        partial.flags = Some(only(&["app/web"]));

        assert_eq!(
            flags_for(&partial, &only(&["app/web"]), "p.kixplan", "c"),
            Ok(only(&["app/web"]))
        );
        let err = flags_for(&partial, &whole, "p.kixplan", "c").unwrap_err();
        assert!(err.contains("saved with `--only app/web`"), "{err}");
        let err = flags_for(&partial, &only(&["app/db"]), "p.kixplan", "c").unwrap_err();
        assert!(
            err.contains("`kix plan c --only app/db --out p.kixplan`"),
            "{err}"
        );
        let err = flags_for(&plan(), &only(&["app/web"]), "p.kixplan", "c").unwrap_err();
        assert!(
            err.contains("the plan was saved without `--only` (for the full build)"),
            "{err}"
        );

        let mut diff = plan();
        diff.flags = None;
        let err = flags_for(&diff, &only(&["app/web"]), "p.kixplan", "c").unwrap_err();
        assert!(err.contains("--only"), "{err}");
    }

    /// A prune policy given on the command line must be the plan's, and the
    /// default takes the plan's.
    #[test]
    fn a_prune_policy_given_must_be_the_plans() {
        let with = |prune| {
            let mut p = plan();
            p.flags.as_mut().unwrap().prune = prune;
            p
        };
        let given = |prune| PlanFlags {
            prune,
            ..plan().flags.unwrap()
        };
        for (planned, asked, refused) in [
            (PrunePolicy::Skip, PrunePolicy::WarnOnly, None),
            (PrunePolicy::Skip, PrunePolicy::Skip, None),
            (PrunePolicy::Delete, PrunePolicy::Delete, None),
            (
                PrunePolicy::WarnOnly,
                PrunePolicy::Skip,
                Some("--skip-orphan-check"),
            ),
            (PrunePolicy::Skip, PrunePolicy::Delete, Some("--prune")),
            (
                PrunePolicy::Delete,
                PrunePolicy::Skip,
                Some("--skip-orphan-check"),
            ),
        ] {
            let got = flags_for(&with(planned), &given(asked), "p.kixplan", "c");
            match refused {
                None => assert_eq!(got.map(|f| f.prune), Ok(planned), "{planned:?} {asked:?}"),
                Some(flag) => {
                    let err = got.unwrap_err();
                    assert!(err.contains(flag), "{planned:?} {asked:?}: {err}");
                }
            }
        }
        let skipped = with(PrunePolicy::Skip);
        let c = compare(&plan(), &skipped);
        assert_eq!(
            c.mismatches[0].items[0],
            "the plan was made with no planning flags, this deploy uses --skip-orphan-check"
        );
    }

    /// A saved plan stores the generation of the deploy lock it read, and a
    /// deploy refuses it once another run changed the cluster. A plan saved
    /// without it is not held to it.
    #[test]
    fn a_saved_plan_of_another_generation_is_stale() {
        use super::super::document::PlanHead;
        let at = |generation| {
            let mut p = plan();
            p.head = Some(PlanHead {
                generation,
                current: None,
                lock: None,
            });
            p
        };
        assert!(compare(&at(3), &at(3)).matches);
        let stale = compare(&at(3), &at(4));
        assert_eq!(rules(&stale), vec![Rule::Generation]);
        assert!(
            stale.mismatches[0].items[0]
                .contains("generation 4, while the saved plan was made at generation 3"),
            "{:?}",
            stale.mismatches
        );
        let mut saved_without = plan();
        saved_without.head = None;
        let unbound = compare(&saved_without, &at(4));
        assert!(unbound.matches);
        assert!(unbound.skipped.contains(&Rule::Generation));
    }

    #[test]
    fn a_different_kix_is_reported_not_refused() {
        let mut other = plan();
        other.kix.store_path = Some("/nix/store/kix-b".into());
        let c = compare(&plan(), &other);
        assert!(c.matches);
        assert_eq!(
            c.kix_differs,
            Some(("/nix/store/kix-a".into(), "/nix/store/kix-b".into()))
        );
    }

    /// A dry-run plan whose sections say they were not checked, or that has
    /// no flags, was edited: either would loosen the comparison.
    #[test]
    fn an_edited_plan_is_unusable() {
        let mut unpruned = plan();
        unpruned.prune = Checked::not_checked(NotCheckedReason::ReadOnly);
        assert!(unusable(&unpruned, "p.kixplan", "c").is_some());
        let mut flagless = plan();
        flagless.flags = None;
        assert!(unusable(&flagless, "p.kixplan", "c").is_some());
        let mut diff_with_flags = plan();
        diff_with_flags.made_by = MadeBy::LiveRead;
        assert!(unusable(&diff_with_flags, "p.kixplan", "c").is_some());
    }

    /// Records without an identity hash are matched by name.
    #[test]
    fn a_deployed_record_without_a_hash_is_matched_by_name() {
        let unhashed = |name: &str| {
            let mut p = plan();
            p.deployed = Some(DeployedBuild {
                activation: name.into(),
                identity_hash: None,
                store_path: None,
            });
            p
        };
        assert!(compare(&unhashed("c-1"), &unhashed("c-1")).matches);
        assert_eq!(
            rules(&compare(&unhashed("c-1"), &unhashed("c-2"))),
            vec![Rule::DeployedBuild]
        );
        assert_eq!(
            rules(&compare(&plan(), &unhashed("c-old"))),
            vec![Rule::DeployedBuild]
        );
    }

    /// An object the reviewed plan checked and the fresh one could not hides
    /// its refusals and drift, so it refuses.
    #[test]
    fn an_object_no_longer_checked_refuses() {
        let unchecked = UncheckedObject {
            resource: "Deployment/a@app".into(),
            reason: UncheckedReason::WebhookNoDryRun,
            because: None,
            detail: "webhook w does not support dry run".into(),
        };
        let mut fresh = plan();
        fresh.not_checked = vec![unchecked.clone()];
        assert_eq!(rules(&compare(&plan(), &fresh)), vec![Rule::NewlyUnchecked]);
        let mut reviewed = plan();
        reviewed.not_checked = vec![unchecked];
        assert!(compare(&reviewed, &fresh).matches);
    }

    #[test]
    fn a_plan_from_two_builds_is_unusable() {
        let mut builds = plan();
        builds.made_by = MadeBy::Builds;
        assert!(unusable(&builds, "p.kixplan", "c").is_some());
        assert!(unusable(&plan(), "p.kixplan", "c").is_none());
    }

    /// A deploy writes and deletes the objects the reviewed plan lists, by
    /// their digest; the lines name what differs.
    #[test]
    fn other_objects_refuse() {
        let mut more = objects();
        more.writes.push(ObjectWrite {
            kind: "ClusterRoleBinding".into(),
            namespace: "_cluster".into(),
            name: "admin".into(),
            store_hash: "b".repeat(32),
            package: "app/web".into(),
            change: WriteChange::Added,
            group: String::new(),
            reason: None,
        });
        let c = compare(&plan(), &with_objects(plan(), more));
        assert_eq!(rules(&c), vec![Rule::Objects]);
        assert_eq!(
            c.mismatches[0].items,
            vec![format!(
                "ClusterRoleBinding/admin (store hash {}, package app/web) would be written",
                "b".repeat(32)
            )]
        );

        // Another owner is another object.
        let mut moved = objects();
        moved.writes[0].package = "app/other".into();
        let c = compare(&plan(), &with_objects(plan(), moved));
        assert_eq!(rules(&c), vec![Rule::Objects]);
        assert_eq!(c.mismatches[0].items.len(), 2);

        let mut kept = objects();
        kept.deletes.clear();
        let c = compare(&plan(), &with_objects(plan(), kept));
        assert_eq!(
            c.mismatches[0].items,
            vec!["ConfigMap/old@app is no longer deleted".to_string()]
        );

        // How the plan shows a write is not part of it.
        let mut reapplied = objects();
        reapplied.writes[0].change = WriteChange::Reapplied;
        assert!(compare(&plan(), &with_objects(plan(), reapplied)).matches);
    }

    /// A plan without the objects, or whose list does not give its digest,
    /// cannot hold a deploy to them.
    #[test]
    fn a_plan_without_its_objects_is_unusable() {
        let mut unlisted = plan();
        unlisted.objects = None;
        unlisted.objects_digest = None;
        assert!(unusable(&unlisted, "p.kixplan", "c").is_some());
        let mut undigested = plan();
        undigested.objects_digest = None;
        assert!(unusable(&undigested, "p.kixplan", "c").is_some());
        let mut edited = plan();
        edited.objects.as_mut().unwrap().deletes.clear();
        assert!(unusable(&edited, "p.kixplan", "c").is_some());
        // And a fresh plan without them does not match.
        let mut fresh = plan();
        fresh.objects_digest = None;
        assert_eq!(rules(&compare(&plan(), &fresh)), vec![Rule::Objects]);
    }
}
