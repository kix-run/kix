//! The check `kix deploy --offline` makes once it connects to a Kix cluster
//! read from revisions.
//!
//! An offline plan compares the new build with the build this machine
//! deployed last. It cannot see the live objects or the cluster's records,
//! so it misses drift, objects with no applied hash, and what a stopped
//! deploy left. When the deploy connects, [`super::Planner::recheck`] plans
//! again from the live cluster with the one planner and [`compare`] holds
//! the result to the confirmed plan: the same writes and deletes, and no
//! write that overwrites a change made on the cluster, or the deploy is
//! refused. So an offline deploy never forces an apply to take fields back
//! from another field manager. A delete the live plan leaves out because another Kix
//! cluster still deploys the object is not a difference, because the
//! offline path drops such deletes when it connects too.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use super::document::{ObjectDelete, ObjectWrite, Objects, WriteChange, WriteReason};
use crate::cluster::binding;
use crate::cluster::inventory::SharedOrphan;
use crate::manifest::types::ResourceId;

/// How many objects of each list [`OfflinePlanDiffers`] names.
const NAMED: usize = 20;

/// The plan made from the live cluster writes or deletes other objects than
/// the plan the person confirmed offline.
#[derive(Debug, PartialEq, Eq)]
pub struct OfflinePlanDiffers {
    pub cluster: String,
    /// The kube context the deploy connected through, for the command the
    /// message suggests.
    pub context: Option<String>,
    /// What the live plan writes that the confirmed plan did not.
    pub writes_added: Vec<Differing>,
    /// What the live plan deletes that the confirmed plan did not.
    pub deletes_added: Vec<Differing>,
    /// What the confirmed plan writes that the live plan does not.
    pub writes_dropped: Vec<Differing>,
    /// What the confirmed plan deletes that the live plan does not.
    pub deletes_dropped: Vec<Differing>,
}

/// One object that only one of the two plans writes or deletes.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Differing {
    /// The object, as `Kind/name@namespace`.
    pub object: String,
    /// Why that plan writes the object, or `None` for a delete.
    pub why: Option<String>,
}

/// Compare `confirmed`, the objects of the plan made offline, with
/// `connected`, the objects of the plan made from the live cluster of Kix
/// cluster `cluster` through `connection`. `shared` are the orphans the
/// live plan keeps because another Kix cluster still deploys them.
pub(crate) fn compare(
    cluster: &str,
    connection: &binding::Connection,
    confirmed: &Objects,
    connected: &Objects,
    shared: &[SharedOrphan],
) -> Result<(), Box<OfflinePlanDiffers>> {
    let shared: BTreeSet<ResourceId> = shared.iter().map(|s| s.rid.clone()).collect();
    let confirmed_deletes: Vec<&ObjectDelete> = confirmed
        .deletes
        .iter()
        .filter(|d| !shared.contains(&delete_id(d)))
        .collect();
    let (mut writes_added, writes_dropped) = differ(
        writes_by_key(&connected.writes),
        writes_by_key(&confirmed.writes),
    );
    // An offline plan cannot see drift, so the person never confirmed
    // overwriting a change made on the cluster, even when the offline plan
    // writes the same object for another reason.
    let reverts = connected
        .writes
        .iter()
        .filter(|w| matches!(w.reason, Some(WriteReason::RevertsDrift { .. })));
    for w in reverts {
        let entry = Differing {
            object: w.resource_id().display_id(),
            why: Some(why(w)),
        };
        if !writes_added.contains(&entry) {
            writes_added.push(entry);
        }
    }
    let (deletes_added, deletes_dropped) = differ(
        deletes_by_key(connected.deletes.iter()),
        deletes_by_key(confirmed_deletes.into_iter()),
    );
    if writes_added.is_empty()
        && writes_dropped.is_empty()
        && deletes_added.is_empty()
        && deletes_dropped.is_empty()
    {
        return Ok(());
    }
    let context = match connection {
        binding::Connection::Context { name, .. } => name.clone(),
        binding::Connection::InCluster => None,
    };
    Err(Box::new(OfflinePlanDiffers {
        cluster: cluster.to_string(),
        context,
        writes_added,
        deletes_added,
        writes_dropped,
        deletes_dropped,
    }))
}

/// Return the entries only `a` has and the entries only `b` has.
fn differ<K: Ord>(
    a: BTreeMap<K, Differing>,
    b: BTreeMap<K, Differing>,
) -> (Vec<Differing>, Vec<Differing>) {
    let only = |x: &BTreeMap<K, Differing>, y: &BTreeMap<K, Differing>| {
        x.iter()
            .filter(|(k, _)| !y.contains_key(*k))
            .map(|(_, v)| v.clone())
            .collect::<Vec<_>>()
    };
    (only(&a, &b), only(&b, &a))
}

/// Key each write by what [`super::objects::digest`] hashes of it: the
/// object, the store hash of its file, and its package.
fn writes_by_key(writes: &[ObjectWrite]) -> BTreeMap<(ResourceId, String, String), Differing> {
    writes
        .iter()
        .map(|w| {
            let id = w.resource_id();
            let entry = Differing {
                object: id.display_id(),
                why: Some(why(w)),
            };
            ((id, w.store_hash.clone(), w.package.clone()), entry)
        })
        .collect()
}

fn deletes_by_key<'a>(
    deletes: impl Iterator<Item = &'a ObjectDelete>,
) -> BTreeMap<ResourceId, Differing> {
    deletes
        .map(|d| {
            let id = delete_id(d);
            let entry = Differing {
                object: id.display_id(),
                why: None,
            };
            (id, entry)
        })
        .collect()
}

fn delete_id(d: &ObjectDelete) -> ResourceId {
    ResourceId::new(&d.group, &d.kind, &d.namespace, &d.name)
}

/// Return why a plan writes `write`, as the plan document's reason or
/// change gives it.
fn why(write: &ObjectWrite) -> String {
    match &write.reason {
        Some(WriteReason::AppliedByRecord { record }) => {
            format!("applied by deployment record {record} before it stopped")
        }
        Some(WriteReason::LeftByDegraded { record }) => {
            format!("not reached during degraded deployment {record}")
        }
        Some(WriteReason::AppliedHashMissing) => {
            "Kix has no recorded applied hash for this object".to_string()
        }
        Some(WriteReason::RevertsDrift { changed_by }) if changed_by.is_empty() => {
            "changed on the cluster since Kix applied it, and this deploy would overwrite that change"
                .to_string()
        }
        Some(WriteReason::RevertsDrift { changed_by }) => {
            let by: Vec<String> = changed_by
                .iter()
                .map(|o| format!("{} changed {}", o.manager, o.fields.join(", ")))
                .collect();
            format!(
                "changed on the cluster since Kix applied it ({}), and this deploy would overwrite that change",
                by.join("; ")
            )
        }
        Some(WriteReason::HeldByOtherCluster { changed_by }) => {
            let by: Vec<&str> = changed_by.iter().map(|o| o.manager.as_str()).collect();
            format!(
                "shares fields with {} (applied without force)",
                by.join(", ")
            )
        }
        None => match write.change {
            WriteChange::Added => "added by the build",
            WriteChange::Modified => "changed by the build",
            WriteChange::DepAffected => "changed by a dependency in the build",
            WriteChange::Reapplied => "unchanged in the build, reapplied",
            WriteChange::IfLastRunFailed => "a Job that runs again if its last run failed",
        }
        .to_string(),
    }
}

impl std::error::Error for OfflinePlanDiffers {}

impl fmt::Display for OfflinePlanDiffers {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(
            f,
            "[K3811] the cluster differs from what the offline plan assumed"
        )?;
        writeln!(f, "  Nothing was applied to the cluster.")?;
        writeln!(f)?;
        writeln!(
            f,
            "  After connecting, Kix planned the deploy against the live cluster and found differences from the offline plan you confirmed."
        )?;
        for (heading, list) in [
            ("The live plan also writes", &self.writes_added),
            ("The live plan also deletes", &self.deletes_added),
            ("The live plan does not write", &self.writes_dropped),
            ("The live plan does not delete", &self.deletes_dropped),
        ] {
            if list.is_empty() {
                continue;
            }
            writeln!(f)?;
            writeln!(f, "  {heading} ({}):", list.len())?;
            for d in list.iter().take(NAMED) {
                match &d.why {
                    Some(why) => writeln!(f, "    {}: {why}", d.object)?,
                    None => writeln!(f, "    {}", d.object)?,
                }
            }
            if list.len() > NAMED {
                writeln!(f, "    and {} more", list.len() - NAMED)?;
            }
        }
        writeln!(f)?;
        writeln!(f, "  Why:")?;
        writeln!(
            f,
            "    An offline plan compares the new build only against the last build cached on this machine, without reading live cluster state or deployment records. Kix refuses to apply changes that differ from the plan you confirmed."
        )?;
        writeln!(f)?;
        writeln!(f, "  Next:")?;
        let command = match &self.context {
            Some(context) => format!("kix deploy {} --context {context}", self.cluster),
            None => format!("kix deploy {}", self.cluster),
        };
        write!(
            f,
            "    Run `{command}` without `--offline` to see and confirm the full plan."
        )
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use kube::api::DynamicObject;
    use serde_json::{Value, json};

    use super::*;
    use crate::build_source::{Build, CarriedBuild, InstallableBuild, Provenance};
    use crate::cluster::fake_api::FakeApi;
    use crate::cluster::field_manager::FieldManager;
    use crate::cluster::fieldsv1::applied_content_hash;
    use crate::cluster::revision::{RevisionMap, RevisionSet, Revisions};
    use crate::eval::store_graph::StoreGraph;
    use crate::manifest::keys;
    use crate::manifest::lifecycle::{self, PHASE_ACTIVE, PHASE_FAILED, RECORD_KIND};
    use crate::plan::{PlanError, Planner};

    struct Carried;
    impl CarriedBuild for Carried {
        fn sops_files(&mut self) -> Result<std::collections::HashMap<String, Vec<u8>>, String> {
            Ok(Default::default())
        }
        fn provenance(&self) -> Provenance {
            Default::default()
        }
        fn deployed_build(&self, _identity_hash: &str) -> Result<Option<StoreGraph>, String> {
            Ok(None)
        }
        fn warnings(&self) -> Vec<crate::eval::library_record::LibraryRecord> {
            Vec::new()
        }
    }

    fn config_map(name: &str, value: &str) -> Value {
        json!({
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {
                "name": name,
                "namespace": "app",
                "labels": { "app.kubernetes.io/managed-by": "kix" },
            },
            "data": { "k": value },
        })
    }

    /// Return the build of `manifests` for Kix cluster `a`, with its
    /// deployment record `record`, stamped as a deploy stamps it.
    fn build(manifests: &[Value], record: &str) -> InstallableBuild {
        let record = json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": { "name": record, "labels": { (keys::CLUSTER_LABEL): "a" } },
            "spec": { "cluster": "a" },
        });
        let all: Vec<Value> = manifests.iter().cloned().chain([record]).collect();
        let mut graph = StoreGraph::synthesize(&all, &StoreGraph::empty("a"));
        graph.activation_path = graph
            .resources
            .iter()
            .find(|(_, r)| lifecycle::is_record(&r.manifest))
            .map(|(path, _)| path.clone())
            .unwrap();
        Build::carried(b"build".to_vec(), "a", |_| Ok((Carried, graph)))
            .unwrap()
            .installable()
            .unwrap()
    }

    fn manifests(graph: &StoreGraph) -> Vec<Value> {
        graph
            .resources
            .values()
            .map(|r| r.manifest.clone())
            .collect()
    }

    /// Return the objects of `graph` as the cluster holds them once Kix
    /// applied them, leaving out the deployment record.
    fn live_of(graph: &StoreGraph) -> Vec<Value> {
        manifests(graph)
            .into_iter()
            .filter(|m| !lifecycle::is_record(m))
            .map(applied)
            .collect()
    }

    /// Return `manifest` as Kubernetes holds it after Kix applied it.
    fn applied(mut manifest: Value) -> Value {
        manifest["metadata"]["managedFields"] = json!([{
            "manager": "kix/a",
            "operation": "Apply",
            "apiVersion": "v1",
            "fieldsV1": { "f:data": { "f:k": {} } },
        }]);
        manifest
    }

    /// Return the deployment record of `graph` as the cluster holds it in
    /// `phase`, naming the revisions of `graph`.
    fn record(graph: &StoreGraph, phase: &str) -> Value {
        let mut record = graph.resources[&graph.activation_path].manifest.clone();
        record["metadata"]["labels"]["app.kubernetes.io/managed-by"] = json!("kix");
        record["status"] = json!({
            "phase": phase,
            "revisions": RevisionMap::of(&RevisionSet::of("a", graph)).to_value(),
        });
        record
    }

    /// Put on a fake API server Kix cluster `a` read from revisions: its
    /// current record `a-cur` of `deployed`, a `Failed` record `a-failed`
    /// of `failed` when given, and the live objects `live`. The current
    /// record's revisions hold the applied hash of each object `in_sync`
    /// names, as the live object gives it, a stale one for each object
    /// `drifted` names, and none for the others.
    async fn cluster(
        deployed: &StoreGraph,
        failed: Option<&StoreGraph>,
        live: &[Value],
        in_sync: &[&str],
        drifted: &[&str],
    ) -> FakeApi {
        let set = RevisionSet::of("a", deployed);
        let head = json!({
            "apiVersion": keys::API_VERSION,
            "kind": crate::cluster::head::KIND,
            "metadata": { "name": "a" },
            "status": {
                "current": deployed.resources[&deployed.activation_path].manifest["metadata"]["name"],
                "generation": 1,
            },
        });
        let mut objects = vec![record(deployed, PHASE_ACTIVE), head];
        let failed_set = failed.map(|g| RevisionSet::of("a", g));
        if let Some(failed) = failed {
            objects.push(record(failed, PHASE_FAILED));
        }
        let api = FakeApi::new(objects.into_iter().chain(live.iter().cloned()));
        let store = Revisions::new(&api.client());
        for revision in set.all() {
            store.create(revision).await.unwrap();
        }
        // A revision both builds name is created once.
        for revision in failed_set.iter().flat_map(|s| s.all()) {
            let _ = store.create(revision).await;
        }
        for revision in set.all() {
            let entries: BTreeMap<String, String> = revision
                .spec
                .objects
                .iter()
                .filter_map(|o| {
                    let found = live
                        .iter()
                        .find(|m| ResourceId::from_value(m) == o.resource_id())?;
                    let obj: DynamicObject = serde_json::from_value(found.clone()).unwrap();
                    let hash = if in_sync.contains(&o.name.as_str()) {
                        applied_content_hash(&obj, &FieldManager::of("a")).unwrap()
                    } else if drifted.contains(&o.name.as_str()) {
                        "stale".to_string()
                    } else {
                        return None;
                    };
                    Some((o.hash.clone(), hash))
                })
                .collect();
            if !entries.is_empty() {
                store.write_applied(&revision.name, &entries).await.unwrap();
            }
        }
        api
    }

    /// Plan `build` offline against `deployed` as this machine's last
    /// build, then plan it again from the cluster on `api`.
    async fn recheck(
        api: &FakeApi,
        deployed: &StoreGraph,
        build: &InstallableBuild,
    ) -> (Result<bool, PlanError>, Vec<String>) {
        let before = api.requests().len();
        let planner = Planner::new(crate::plan::fixtures::flags(&["--prune"]), &|_| {});
        let baseline = crate::plan::baseline::Baseline {
            source: crate::plan::baseline::ActiveSource::Build(Box::new(deployed.clone())),
            active_manifests: manifests(deployed),
            ..crate::plan::baseline::Baseline::empty()
        };
        let offline = planner
            .plan(build.graph(), "a", &baseline, None)
            .await
            .unwrap();
        let connection = binding::Connection::Context {
            name: Some("ctx".into()),
            server: None,
        };
        let result = planner
            .recheck(
                &offline,
                build,
                &manifests(build.graph()),
                api.client(),
                connection,
            )
            .await
            .map(|_| true);
        let writes = api.requests()[before..]
            .iter()
            .filter(|r| !r.starts_with("GET"))
            .cloned()
            .collect();
        (result, writes)
    }

    /// Return the refusal `recheck` gave, and check that it wrote nothing
    /// to the cluster, the deploy lock included.
    fn refusal((result, writes): (Result<bool, PlanError>, Vec<String>)) -> OfflinePlanDiffers {
        assert!(writes.is_empty(), "{writes:?}");
        match result {
            Err(PlanError::OfflinePlanDiffers(differs)) => *differs,
            other => panic!("not refused: {:?}", other.map_err(|e| e.to_string())),
        }
    }

    /// The live plan of a cluster that holds the confirmed build as Kix
    /// applied it matches the confirmed plan, and the run uses it. A Kix
    /// cluster read from records is planned again from its notes.
    #[tokio::test]
    async fn an_offline_plan_the_cluster_agrees_with_runs() {
        let new = build(&[config_map("web", "1"), config_map("calm", "1")], "a-cur");
        let graph = new.graph().clone();
        let live = live_of(&graph);
        let api = cluster(&graph, None, &live, &["web", "calm"], &[]).await;
        assert!(recheck(&api, &graph, &new).await.0.unwrap());

        // A Kix cluster read from records is planned again too, from the
        // notes on its objects. These carry no `kix.run/applied-hash` note,
        // so the live plan writes them and the deploy is refused before it
        // writes anything.
        let mut current = record(&graph, PHASE_ACTIVE);
        current["status"]
            .as_object_mut()
            .unwrap()
            .remove("revisions");
        let api = FakeApi::new([current].into_iter().chain(live));
        let differs = refusal(recheck(&api, &graph, &new).await);
        assert_eq!(differs.writes_added.len(), 2, "{differs:?}");
    }

    /// A drifted object, an object with no applied hash, and the leftover
    /// of a `Failed` record each make the live plan write what the offline
    /// plan did not, and the deploy is refused before it takes the lock.
    #[tokio::test]
    async fn what_an_offline_plan_cannot_see_refuses_the_deploy() {
        let new = build(&[config_map("web", "1"), config_map("calm", "1")], "a-cur");
        let graph = new.graph().clone();
        let live = live_of(&graph);

        let api = cluster(&graph, None, &live, &["calm"], &["web"]).await;
        let differs = refusal(recheck(&api, &graph, &new).await);
        assert_eq!(
            differs.writes_added,
            [Differing {
                object: "ConfigMap/web@app".into(),
                why: Some(
                    "changed on the cluster since Kix applied it, and this deploy would overwrite that change"
                        .into()
                ),
            }]
        );
        assert!(differs.writes_dropped.is_empty() && differs.deletes_added.is_empty());
        let text = differs.to_string();
        assert!(
            text.contains("Run `kix deploy a --context ctx` without `--offline`"),
            "{text}"
        );

        let api = cluster(&graph, None, &live, &[], &[]).await;
        let mut differs = refusal(recheck(&api, &graph, &new).await);
        differs.writes_added.sort();
        let why: Vec<_> = differs
            .writes_added
            .iter()
            .map(|d| (d.object.as_str(), d.why.as_deref()))
            .collect();
        // Without applied hashes Kix cannot tell drift apart, so both are
        // applied to record one.
        assert_eq!(
            why,
            [
                (
                    "ConfigMap/calm@app",
                    Some("Kix has no recorded applied hash for this object")
                ),
                (
                    "ConfigMap/web@app",
                    Some("Kix has no recorded applied hash for this object")
                ),
            ]
        );

        let stopped = build(
            &[config_map("web", "2"), config_map("calm", "1")],
            "a-failed",
        );
        let stopped = stopped.graph().clone();
        let mut live = live_of(&graph);
        let left = manifests(&stopped)
            .into_iter()
            .find(|m| m["metadata"]["name"] == "web")
            .unwrap();
        live.retain(|m| m["metadata"]["name"] != "web");
        live.push(applied(left));
        let api = cluster(&graph, Some(&stopped), &live, &["web", "calm"], &[]).await;
        let differs = refusal(recheck(&api, &graph, &new).await);
        let record = &stopped.resources[&stopped.activation_path].manifest["metadata"]["name"];
        assert_eq!(
            differs.writes_added,
            [Differing {
                object: "ConfigMap/web@app".into(),
                why: Some(format!(
                    "applied by deployment record {} before it stopped",
                    record.as_str().unwrap()
                )),
            }]
        );
    }

    /// A deploy of `new` applied `web` and then failed, so its `Failed`
    /// record names the applied hash of `web`. Someone then changed `web`
    /// by hand. The offline plan of `new` writes `web` as a change of the
    /// build, and the live plan writes the same object to overwrite the hand
    /// change. The deploy is refused before it writes anything, because the
    /// person never saw that overwrite.
    #[tokio::test]
    async fn an_offline_deploy_refuses_to_overwrite_a_change_made_on_the_cluster() {
        let old = build(&[config_map("web", "1"), config_map("calm", "1")], "a-cur");
        let old = old.graph().clone();
        let new = build(&[config_map("web", "2"), config_map("calm", "1")], "a-new");
        let graph = new.graph().clone();
        let mut live = live_of(&old);
        let web = manifests(&graph)
            .into_iter()
            .find(|m| m["metadata"]["name"] == "web")
            .unwrap();
        live.retain(|m| m["metadata"]["name"] != "web");
        live.push(applied(web));
        let failed = build(
            &[config_map("web", "2"), config_map("calm", "2")],
            "a-failed",
        );
        let failed = failed.graph().clone();
        let api = cluster(&old, Some(&failed), &live, &["calm"], &[]).await;
        let store = Revisions::new(&api.client());
        for revision in RevisionSet::of("a", &failed).all() {
            let entries: BTreeMap<String, String> = revision
                .spec
                .objects
                .iter()
                .filter(|o| o.name == "web")
                .map(|o| (o.hash.clone(), "stale".to_string()))
                .collect();
            if !entries.is_empty() {
                store.write_applied(&revision.name, &entries).await.unwrap();
            }
        }

        let differs = refusal(recheck(&api, &old, &new).await);
        assert_eq!(
            differs.writes_added,
            [Differing {
                object: "ConfigMap/web@app".into(),
                why: Some(
                    "changed on the cluster since Kix applied it, and this deploy would overwrite that change"
                        .into()
                ),
            }]
        );
        assert!(differs.writes_dropped.is_empty(), "{differs:?}");
    }

    fn write(name: &str, reason: Option<WriteReason>) -> ObjectWrite {
        ObjectWrite {
            kind: "ConfigMap".into(),
            namespace: "app".into(),
            name: name.into(),
            store_hash: format!("h-{name}"),
            package: "app/web".into(),
            change: WriteChange::Reapplied,
            group: String::new(),
            reason,
        }
    }

    fn delete(name: &str) -> ObjectDelete {
        ObjectDelete {
            kind: "ConfigMap".into(),
            namespace: "app".into(),
            name: name.into(),
            group: String::new(),
        }
    }

    /// The plans are compared by what they write and delete, not by how
    /// they show it. A delete the live plan drops because another Kix
    /// cluster still deploys the object is not a difference. Every other
    /// write or delete only one plan makes is listed under its plan.
    #[test]
    fn plans_are_compared_by_what_they_write_and_delete() {
        let connection = binding::Connection::InCluster;
        let confirmed = Objects {
            writes: vec![write("web", None)],
            deletes: vec![delete("shared"), delete("gone")],
        };
        let mut connected = Objects {
            writes: vec![write("web", Some(WriteReason::AppliedHashMissing))],
            deletes: vec![delete("gone")],
        };
        let shared = [SharedOrphan {
            rid: delete_id(&delete("shared")),
            clusters: vec!["b".into()],
        }];
        assert_eq!(
            compare("a", &connection, &confirmed, &connected, &shared),
            Ok(())
        );

        connected.writes.push(write(
            "edited",
            Some(WriteReason::RevertsDrift {
                changed_by: vec![super::super::document::DriftOwner {
                    manager: "kubectl-edit".into(),
                    fields: vec!["data.k".into()],
                }],
            }),
        ));
        connected.deletes = vec![delete("left")];
        let differs = *compare("a", &connection, &confirmed, &connected, &shared).unwrap_err();
        assert_eq!(differs.context, None);
        assert_eq!(
            differs.writes_added[0].why.as_deref(),
            Some(
                "changed on the cluster since Kix applied it (kubectl-edit changed data.k), and this deploy would overwrite that change"
            )
        );
        let names =
            |list: &[Differing]| -> Vec<String> { list.iter().map(|d| d.object.clone()).collect() };
        assert_eq!(names(&differs.deletes_added), ["ConfigMap/left@app"]);
        assert_eq!(names(&differs.deletes_dropped), ["ConfigMap/gone@app"]);
        assert!(differs.writes_dropped.is_empty());
        let text = differs.to_string();
        assert!(
            text.contains("The live plan also deletes (1):\n    ConfigMap/left@app\n"),
            "{text}"
        );
        assert!(
            text.ends_with(
                "Run `kix deploy a` without `--offline` to see and confirm the full plan."
            ),
            "{text}"
        );
    }
}
