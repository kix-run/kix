//! Saved plans: whether a plan made now still matches a reviewed one.
//!
//! `kix deploy --plan plan.json` rebuilds, plans again, and refuses when
//! [`compare`] finds a mismatch. The rules and their keys are in
//! `v2_discussions/158_saved_plans.md`. A saved plan only restricts a
//! deploy: the deploy never applies anything read from it.

use std::collections::BTreeSet;

use serde::Serialize;

use super::document::{Checked, MadeBy, Plan, PlanFlags, PruneFate};

/// One comparison rule, numbered as in doc 158.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Rule {
    Cluster,
    NewBuild,
    Objects,
    DeployedBuild,
    Flags,
    NewRefusal,
    NewRevertedDrift,
    NewPruneDelete,
    NewlyUnchecked,
}

impl Rule {
    /// The rule as a deploy names it.
    pub fn label(self) -> &'static str {
        match self {
            Rule::Cluster => "cluster",
            Rule::NewBuild => "new build",
            Rule::Objects => "objects",
            Rule::DeployedBuild => "deployed build",
            Rule::Flags => "flags",
            Rule::NewRefusal => "new refusal",
            Rule::NewRevertedDrift => "new drift",
            Rule::NewPruneDelete => "new prune delete",
            Rule::NewlyUnchecked => "not checked now",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Mismatch {
    pub rule: Rule,
    /// What differs, one line each.
    pub items: Vec<String>,
}

/// The result of comparing a fresh plan with a reviewed one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Comparison {
    /// [`digest`] of the reviewed plan file, set by the caller.
    pub plan_sha256: Option<String>,
    pub matches: bool,
    pub mismatches: Vec<Mismatch>,
    /// Rules the reviewed plan could not be held to, because it did not
    /// make that check (a `kix diff` plan checks no refusals or prune).
    pub skipped: Vec<Rule>,
    /// The two Kix binaries, reviewed then fresh, when they differ. Reported
    /// and not refused: the objects digest already holds the deploy to the
    /// objects and build files that were reviewed, and the binary is chosen
    /// by whoever runs the deploy.
    pub kix_differs: Option<(String, String)>,
}

/// The SHA-256 of a saved plan file, so an approval system can check the
/// deploy used the file it approved.
pub fn digest(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("sha256:{:x}", Sha256::digest(bytes))
}

/// Why a saved plan cannot be used at all, before any build.
pub fn unusable(reviewed: &Plan) -> Option<String> {
    if reviewed.schema_version != super::document::SCHEMA_VERSION {
        return Some(format!(
            "the plan has schema version {}, and this Kix reads version {}",
            reviewed.schema_version,
            super::document::SCHEMA_VERSION
        ));
    }
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
        return Some(
            "its sections do not match how it says it was made, so it was edited after \
             `kix plan` or `kix diff` wrote it"
                .into(),
        );
    }
    if reviewed.made_by == MadeBy::LiveRead && !matches!(reviewed.drift, Checked::Checked { .. }) {
        return Some(
            "the plan is a `kix diff` that did not compare with the deployed build (a diff \
             of a snapshot or export, or one made without the deployed build), so it shows \
             no drift the deploy would revert; save a `kix diff` against the cluster with the \
             deployed build available, or a `kix plan`"
                .into(),
        );
    }
    // The digest is what holds a deploy to the reviewed objects, so a plan
    // without one, or whose list does not give it, cannot be used.
    match (&reviewed.objects_digest, &reviewed.objects) {
        (Some(digest), Some(objects)) if *digest == super::objects::digest(objects) => {}
        (Some(_), Some(_)) => {
            return Some(
                "the objects it lists do not give its objects_digest, so it was edited after \
                 `kix plan` wrote it"
                    .into(),
            );
        }
        _ => {
            return Some(
                "the plan does not list the objects a deploy writes and deletes, which only \
                 `kix plan` does; save a plan from `kix plan`"
                    .into(),
            );
        }
    }
    if reviewed.made_by == MadeBy::Builds {
        return Some(
            "the plan compared two builds without reading the cluster, so it says nothing \
             about the cluster's current build or its drift; save a plan from `kix plan` or \
             `kix diff` against the cluster"
                .into(),
        );
    }
    None
}

/// The planning flags a deploy from `reviewed` uses, or why the command
/// line contradicts them. `given` are the flags on the command line; a flag
/// the command line sets must agree with the plan.
pub fn flags_for(reviewed: &Plan, given: &PlanFlags) -> Result<PlanFlags, String> {
    let Some(planned) = reviewed.flags else {
        // A `kix diff` plan: no reviewer saw what these flags would do.
        let refused: Vec<&str> = [
            (given.prune, "--prune"),
            (given.force_conflicts, "--force-conflicts"),
            (given.reconcile, "--reconcile"),
            (given.accept_migrations, "--accept-migrations"),
        ]
        .into_iter()
        .filter_map(|(set, flag)| set.then_some(flag))
        .collect();
        if !refused.is_empty() {
            return Err(format!(
                "the plan is a `kix diff`, which does not show what {} would do",
                refused.join(", ")
            ));
        }
        return Ok(*given);
    };
    let mut contradicted = Vec::new();
    for (set, in_plan, flag) in [
        (given.prune, planned.prune, "--prune"),
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
    ] {
        if set && !in_plan {
            contradicted.push(flag.to_string());
        }
    }
    if given.prune_mode.is_some() && given.prune_mode != planned.prune_mode {
        contradicted.push("--prune-mode".into());
    }
    if !contradicted.is_empty() {
        return Err(format!(
            "the plan was made without {}; make and review a plan with it",
            contradicted.join(", ")
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

    let flags_differ = match (&reviewed.flags, &fresh.flags) {
        (Some(r), Some(f)) => r != f,
        (None, Some(f)) => f.prune || f.force_conflicts || f.reconcile,
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
            let known: BTreeSet<(&str, &str)> = items
                .iter()
                .filter(|d| d.reverted)
                .map(|d| (d.resource.as_str(), d.path.as_str()))
                .collect();
            let new = fresh
                .drift
                .items()
                .iter()
                .filter(|d| d.reverted && !known.contains(&(d.resource.as_str(), d.path.as_str())))
                .map(|d| {
                    let by = if d.managers.is_empty() {
                        String::new()
                    } else {
                        format!(": changed by {}", d.managers.join(", "))
                    };
                    format!("{} {}{by}", d.resource, d.path)
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

/// The objects the fresh plan writes or deletes that the reviewed one does
/// not, and the other way round, one line each.
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
    let delete = |d: &super::document::ObjectDelete| object_id(&d.kind, &d.namespace, &d.name);
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

/// An object's id as the plan shows it, its build-supplied text escaped.
fn object_id(kind: &str, namespace: &str, name: &str) -> String {
    let id = crate::manifest::types::ResourceId {
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
        return "no planning flags (a kix diff)".into();
    };
    let mut set: Vec<String> = [
        (f.prune, "--prune"),
        (f.reconcile, "--reconcile"),
        (f.force_conflicts, "--force-conflicts"),
        (f.accept_migrations, "--accept-migrations"),
    ]
    .into_iter()
    .filter(|(on, _)| *on)
    .map(|(_, flag)| flag.to_string())
    .collect();
    if let Some(mode) = f.prune_mode {
        let mode = serde_json::to_value(mode)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        set.push(format!("--prune-mode {mode}"));
    }
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
        p.deployed = Some(DeployedBuild {
            activation: "c-old".into(),
            identity_hash: Some("old".into()),
            store_path: None,
        });
        p.flags = Some(PlanFlags {
            prune: false,
            prune_mode: None,
            reconcile: false,
            force_conflicts: false,
            accept_migrations: false,
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
            }],
            deletes: vec![ObjectDelete {
                kind: "ConfigMap".into(),
                namespace: "app".into(),
                name: "old".into(),
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
        pruned.flags.as_mut().unwrap().prune = true;
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
        let mut redrifted = plan();
        redrifted.drift = Checked::found(vec![drift("$.spec.replicas", "7")]);
        assert!(
            compare(&drifted, &redrifted).matches,
            "the live value is not compared"
        );
        assert_eq!(
            rules(&compare(&plan(), &drifted)),
            vec![Rule::NewRevertedDrift]
        );

        let mut deleting = plan();
        deleting.prune = Checked::found(vec![PruneEntry {
            resource: "ConfigMap/x@app".into(),
            fate: PruneFate::Delete,
            detail: None,
        }]);
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
        assert!(unusable(&diff).is_none());

        // A diff of a snapshot shows no drift, so it cannot hold rule 6.
        let mut snapshot = diff.clone();
        snapshot.drift = Checked::not_checked(NotCheckedReason::DeployedBuildUnavailable);
        assert!(unusable(&snapshot).is_some());

        let accepting = PlanFlags {
            accept_migrations: true,
            ..plan().flags.unwrap()
        };
        assert!(flags_for(&diff, &accepting).is_err());

        let given = PlanFlags {
            prune: true,
            ..plan().flags.unwrap()
        };
        assert!(flags_for(&diff, &given).is_err());
    }

    #[test]
    fn command_line_flags_must_agree_with_the_plan() {
        let none = plan().flags.unwrap();
        assert_eq!(flags_for(&plan(), &none), Ok(none));

        let mut with_prune = plan();
        with_prune.flags.as_mut().unwrap().prune = true;
        let taken = flags_for(&with_prune, &none).unwrap();
        assert!(taken.prune, "the plan's flags are used");

        let given = PlanFlags {
            reconcile: true,
            ..none
        };
        let err = flags_for(&plan(), &given).unwrap_err();
        assert!(err.contains("--reconcile"), "{err}");
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
        assert!(unusable(&unpruned).is_some());
        let mut flagless = plan();
        flagless.flags = None;
        assert!(unusable(&flagless).is_some());
        let mut diff_with_flags = plan();
        diff_with_flags.made_by = MadeBy::LiveRead;
        assert!(unusable(&diff_with_flags).is_some());
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
        assert!(unusable(&builds).is_some());
        assert!(unusable(&plan()).is_none());
        let mut future = plan();
        future.schema_version = "2099-01-01".into();
        assert!(unusable(&future).is_some());
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
        assert!(unusable(&unlisted).is_some());
        let mut undigested = plan();
        undigested.objects_digest = None;
        assert!(unusable(&undigested).is_some());
        let mut edited = plan();
        edited.objects.as_mut().unwrap().deletes.clear();
        assert!(unusable(&edited).is_some());
        // And a fresh plan without them does not match.
        let mut fresh = plan();
        fresh.objects_digest = None;
        assert_eq!(rules(&compare(&plan(), &fresh)), vec![Rule::Objects]);
    }
}
