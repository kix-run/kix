//! Install and update Kix's own CustomResourceDefinitions on a cluster.

use std::time::Duration;

use kube::Client;
use kube::api::{Api, DynamicObject, PostParams};
use kube::discovery::ApiResource;
use serde_json::Value;

use super::OwnCrd;
use crate::cluster::errors::describe;
use crate::cluster::readiness::served_crd_versions;
use crate::manifest::keys;

/// How long [`ensure_all`] waits for the definitions it wrote to be served.
const ESTABLISH_WAIT: Duration = Duration::from_secs(30);

/// The label a build put on the Activation and PackageInstance definitions.
const MANAGED_BY: &str = "app.kubernetes.io/managed-by";

/// What a cluster's CustomResourceDefinition holds, as [`decide`] needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Live {
    /// The number of the definition the CRD holds. It is 1 when the CRD
    /// carries no number, or when its `metadata.generation` moved since Kix
    /// wrote the number.
    pub number: u32,
    /// Whether the CRD serves every version the program's definition serves.
    pub serves: bool,
}

impl Live {
    /// Read `found`, measured against the program's definition `mine`.
    pub fn of(found: &DynamicObject, mine: &Value) -> Live {
        let served = served_crd_versions(&found.data);
        Live {
            number: number_of(found),
            serves: served_crd_versions(mine).iter().all(|v| served.contains(v)),
        }
    }
}

fn number_of(found: &DynamicObject) -> u32 {
    let stamp = found
        .metadata
        .annotations
        .as_ref()
        .and_then(|a| keys::get_meta(a, keys::DEFINITION));
    let Some((number, generation)) = stamp.and_then(|s| s.split_once('/')) else {
        return 1;
    };
    match (number.parse::<u32>(), generation.parse::<i64>()) {
        (Ok(number), Ok(generation)) if Some(generation) == found.metadata.generation => number,
        _ => 1,
    }
}

fn stamp(number: u32, generation: i64) -> String {
    format!("{number}/{generation}")
}

/// What [`ensure_all`] does with one definition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// The cluster has no such CRD. Create it.
    Create,
    /// The cluster holds a lower number. Replace its `spec`.
    Replace,
    /// The cluster holds this number or a higher one, and serves the
    /// version this program uses. Leave it.
    Leave,
    /// The cluster holds this number or a higher one, but does not serve the
    /// version this program uses.
    NotServed,
}

/// Decide what to do with the cluster's definition `live` of a kind whose
/// definition in this program has number `mine`.
pub fn decide(mine: u32, live: Option<&Live>) -> Action {
    match live {
        None => Action::Create,
        Some(live) if live.number < mine => Action::Replace,
        Some(live) if !live.serves => Action::NotServed,
        Some(_) => Action::Leave,
    }
}

/// Why [`ensure_all`] could not make Kix's kinds available.
#[derive(Debug, thiserror::Error)]
pub enum CrdError {
    #[error(
        "[K9557] cannot read CustomResourceDefinition `{name}` ({holds}): {}. Nothing was changed on the cluster. Check your cluster connection and verify that this account has `get` permission on `{name}`, then run the command again",
        describe(.source)
    )]
    Read {
        name: String,
        holds: &'static str,
        #[source]
        source: kube::Error,
    },
    #[error(
        "[K9557] cannot {action} CustomResourceDefinition `{name}` ({holds}): {}. No workloads or deployment records were changed. Grant this account `create` and `update` permissions on `customresourcedefinitions`, or ask a cluster administrator to run this command once (this account still needs `get` on `{name}` and {verbs} on its objects)",
        describe(.source)
    )]
    Write {
        name: String,
        action: &'static str,
        holds: &'static str,
        verbs: &'static str,
        #[source]
        source: kube::Error,
    },
    #[error(
        "CustomResourceDefinition `{name}` on this cluster was installed by a newer version of Kix and does not serve API version {}, which Kix {version} requires. Nothing was changed on the cluster. Upgrade Kix to match or exceed the version that last deployed this cluster",
        .versions.join(", "),
        version = crate::version::running()
    )]
    NotServed { name: String, versions: Vec<String> },
    #[error(
        "wrote CustomResourceDefinition `{name}`, but the Kubernetes API server did not start serving it within {} seconds. No workloads or deployment records were changed. Wait a moment and run the command again",
        ESTABLISH_WAIT.as_secs()
    )]
    NotEstablished { name: String },
}

pub(super) fn crds(client: &Client) -> Api<DynamicObject> {
    let resource = ApiResource::from_gvk_with_plural(
        &kube::api::GroupVersionKind::gvk("apiextensions.k8s.io", "v1", "CustomResourceDefinition"),
        "customresourcedefinitions",
    );
    Api::all_with(client.clone(), &resource)
}

fn established(crd: &DynamicObject) -> bool {
    crd.data
        .pointer("/status/conditions")
        .and_then(Value::as_array)
        .is_some_and(|conditions| {
            conditions
                .iter()
                .any(|c| c["type"] == "Established" && c["status"] == "True")
        })
}

fn conflict(e: &kube::Error) -> bool {
    matches!(e, kube::Error::Api(e) if e.code == 409)
}

/// Install or update every definition [`super::all`] lists, and wait until
/// Kubernetes serves each kind.
///
/// It reads all four first, so a run that may not read them changes
/// nothing. It then creates the absent ones and replaces those that hold a
/// lower number, and waits once for all of them. A replace keeps the CRD's
/// annotations, except the marks a build left on it.
pub async fn ensure_all(client: &Client) -> Result<(), CrdError> {
    let api = crds(client);
    let own = super::all();
    let mut found = Vec::with_capacity(own.len());
    for crd in &own {
        found.push(
            api.get_opt(&crd.name)
                .await
                .map_err(|source| CrdError::Read {
                    name: crd.name.clone(),
                    holds: crd.holds,
                    source,
                })?,
        );
    }
    let mut waiting = Vec::new();
    for (crd, found) in own.iter().zip(found) {
        if ensure(&api, crd, found).await? {
            waiting.push(crd);
        }
    }
    wait_established(&api, &waiting).await
}

/// Bring one definition up to `crd`, starting from what the cluster held at
/// the first read. Return whether the kind may not be served yet.
///
/// A write that loses to another writer reads the CRD again and decides
/// again. That ends, because every writer only raises numbers.
pub(super) async fn ensure(
    api: &Api<DynamicObject>,
    crd: &OwnCrd,
    mut found: Option<DynamicObject>,
) -> Result<bool, CrdError> {
    let read = |source| CrdError::Read {
        name: crd.name.clone(),
        holds: crd.holds,
        source,
    };
    let write = |action, source| CrdError::Write {
        name: crd.name.clone(),
        action,
        holds: crd.holds,
        verbs: crd.verbs,
        source,
    };
    loop {
        let live = found.as_ref().map(|f| Live::of(f, &crd.definition));
        match decide(crd.number, live.as_ref()) {
            Action::Leave => {
                return Ok(!found.as_ref().is_some_and(established));
            }
            Action::NotServed => {
                return Err(CrdError::NotServed {
                    name: crd.name.clone(),
                    versions: served_crd_versions(&crd.definition),
                });
            }
            Action::Create => match create(api, crd).await {
                Ok(()) => return Ok(true),
                Err(e) if conflict(&e) => {}
                Err(e) => return Err(write("create", e)),
            },
            Action::Replace => {
                let current = found.take().expect("a replace has a live definition");
                match replace(api, crd, current).await {
                    Ok(()) => return Ok(true),
                    Err(e) if conflict(&e) => {}
                    Err(e) => return Err(write("update", e)),
                }
            }
        }
        found = api.get_opt(&crd.name).await.map_err(read)?;
    }
}

async fn create(api: &Api<DynamicObject>, crd: &OwnCrd) -> Result<(), kube::Error> {
    let mut definition: DynamicObject = serde_json::from_value(crd.definition.clone())
        .expect("a definition Kix carries is an object");
    // Kubernetes gives a new object generation 1.
    definition
        .metadata
        .annotations
        .get_or_insert_default()
        .insert(keys::DEFINITION.to_string(), stamp(crd.number, 1));
    api.create(&PostParams::default(), &definition).await?;
    Ok(())
}

/// Replace the `spec` of `current` with the program's, then stamp the number
/// with the generation Kubernetes gave the new `spec`.
///
/// Both writes are PUTs that carry the `resourceVersion` just read, so they
/// replace `spec` exactly, keep every annotation another writer set (such as
/// the operator's features), and lose to any write in between.
async fn replace(
    api: &Api<DynamicObject>,
    crd: &OwnCrd,
    mut current: DynamicObject,
) -> Result<(), kube::Error> {
    current.data["spec"] = crd.definition["spec"].clone();
    if let Some(labels) = current.metadata.labels.as_mut()
        && labels.get(MANAGED_BY).map(String::as_str) == Some("kix")
    {
        labels.remove(MANAGED_BY);
    }
    if let Some(annotations) = current.metadata.annotations.as_mut() {
        annotations.retain(|k, _| {
            !keys::is_kix_key(k) || k == keys::OPERATOR_FEATURES || k == keys::DEFINITION
        });
    }
    let mut written = api
        .replace(&crd.name, &PostParams::default(), &current)
        .await?;
    let generation = written.metadata.generation.unwrap_or(1);
    written
        .metadata
        .annotations
        .get_or_insert_default()
        .insert(keys::DEFINITION.to_string(), stamp(crd.number, generation));
    api.replace(&crd.name, &PostParams::default(), &written)
        .await?;
    Ok(())
}

async fn wait_established(api: &Api<DynamicObject>, crds: &[&OwnCrd]) -> Result<(), CrdError> {
    let start = tokio::time::Instant::now();
    for crd in crds {
        loop {
            let found = api
                .get_opt(&crd.name)
                .await
                .map_err(|source| CrdError::Read {
                    name: crd.name.clone(),
                    holds: crd.holds,
                    source,
                })?;
            if found.as_ref().is_some_and(established) {
                break;
            }
            if start.elapsed() >= ESTABLISH_WAIT {
                return Err(CrdError::NotEstablished {
                    name: crd.name.clone(),
                });
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
    Ok(())
}
