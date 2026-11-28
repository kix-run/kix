//! Reading and writing revisions on the cluster.

use std::collections::BTreeMap;

use kube::Client;
use kube::api::{Api, DeleteParams, DynamicObject, ListParams, Patch, PatchParams, PostParams};
use serde_json::json;
use thiserror::Error;

use super::spec::{ReadError, Revision};
use super::{KIND, api, crd_name};
use crate::cluster::errors::describe;
use crate::manifest::keys;

/// What [`Revisions::create`] found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Created {
    Created,
    /// A revision of that name was there already. Its name is a hash of its
    /// `spec`, so it holds the same objects.
    Exists,
}

/// What a create found under the name it wanted.
enum Existing {
    Readable,
    Gone,
    Unreadable(Box<DynamicObject>, ReadError),
}

/// Why a read or write of revisions failed.
#[derive(Debug, Error)]
pub enum RevisionError {
    #[error(
        "cannot {action} {KIND} `{name}`: {}. Check your cluster connection and verify that this account has `get`, `list`, `create`, and `delete` permissions on `{crd}` (plus `patch` on `{plural}/status` in API group `{group}`), then try again",
        describe(.source),
        crd = crd_name(),
        plural = super::PLURAL,
        group = keys::GROUP,
    )]
    Api {
        action: &'static str,
        name: String,
        #[source]
        source: kube::Error,
    },
    #[error(
        "cannot list {KIND} objects for {scope}: {}. Check your cluster connection and verify that this account has `list` permission on `{}`, then try again",
        describe(.source),
        crd_name()
    )]
    List {
        scope: String,
        #[source]
        source: kube::Error,
    },
    #[error(transparent)]
    Read(#[from] ReadError),
    #[error(
        "the Kubernetes API server stored {KIND} `{name}` with a different `spec` than Kix sent because CustomResourceDefinition `{crd}` dropped or modified fields. Check whether `{crd}` was edited outside Kix or installed by another version of Kix. Kix does not rewrite an edited `{crd}`, so revert any out-of-band changes to it before trying again",
        crd = crd_name()
    )]
    StoredDifferently { name: String },
}

/// The revisions one list request returned.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Listed {
    /// The revisions that match their names, sorted by name.
    pub readable: Vec<Revision>,
    /// The revisions that cannot be read, sorted by name.
    pub unreadable: Vec<ReadError>,
}

impl Listed {
    /// Return the name of every listed revision, readable or not.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.readable
            .iter()
            .map(|r| r.name.as_str())
            .chain(self.unreadable.iter().map(ReadError::name))
    }

    /// Return the readable revisions, or the first error when any revision
    /// cannot be read. Use it where a revision decides what Kix owns.
    pub fn all_readable(self) -> Result<Vec<Revision>, ReadError> {
        match self.unreadable.into_iter().next() {
            Some(e) => Err(e),
            None => Ok(self.readable),
        }
    }
}

/// The revisions on one Kubernetes cluster.
#[derive(Clone)]
pub struct Revisions {
    api: Api<DynamicObject>,
}

impl Revisions {
    pub fn new(client: &Client) -> Revisions {
        Revisions { api: api(client) }
    }

    /// Create `revision` with its `spec` and its cluster label. The API
    /// server drops `status` on a create, so write applied hashes with
    /// [`Revisions::write_applied`]. A readable revision of the same name
    /// counts as created, because the name is a hash of the `spec`.
    ///
    /// Repair a revision of the same name that cannot be read. The name says
    /// what its `spec` must be, and `revision` holds exactly that. One whose
    /// `spec` does not match its name or cannot be parsed is deleted and
    /// created again. One whose `spec` is right but whose `status.applied`
    /// cannot be parsed keeps its `spec` and loses its applied hashes.
    /// Refuse on a revision in a format a newer Kix wrote, which this Kix
    /// must not change, and on one still unreadable after the repair.
    ///
    /// Refuse when the server stored a `spec` other than the one sent. The
    /// definition prunes fields it does not know, and a revision whose
    /// stored `spec` no longer matches its name cannot be read. The object
    /// just created is deleted again, because a later create of the same
    /// name would find it and count the revision as created.
    pub async fn create(&self, revision: &Revision) -> Result<Created, RevisionError> {
        if self.create_once(revision).await? == Created::Created {
            return Ok(Created::Created);
        }
        match self.existing(&revision.name).await? {
            Existing::Readable => Ok(Created::Exists),
            Existing::Gone => self.create_checked(revision).await,
            Existing::Unreadable(_, ReadError::UnreadableApplied { .. }) => {
                self.clear_applied(&revision.name).await?;
                self.require_readable(&revision.name).await?;
                Ok(Created::Exists)
            }
            Existing::Unreadable(found, _) => {
                self.delete_only(&revision.name, &found).await?;
                self.create_checked(revision).await
            }
        }
    }

    /// Create `revision`, and refuse when a revision of its name that
    /// cannot be read is there instead.
    async fn create_checked(&self, revision: &Revision) -> Result<Created, RevisionError> {
        let created = self.create_once(revision).await?;
        if created == Created::Exists {
            self.require_readable(&revision.name).await?;
        }
        Ok(created)
    }

    async fn require_readable(&self, name: &str) -> Result<(), RevisionError> {
        match self.existing(name).await? {
            Existing::Readable => Ok(()),
            Existing::Unreadable(_, e) => Err(e.into()),
            Existing::Gone => Err(ReadError::Malformed {
                name: name.to_string(),
                reason: "another process deleted it while Kix was creating it; try again".into(),
            }
            .into()),
        }
    }

    /// Read the revision named `name` that a create found. Refuse on one a
    /// newer Kix wrote.
    async fn existing(&self, name: &str) -> Result<Existing, RevisionError> {
        let found = self
            .api
            .get_opt(name)
            .await
            .map_err(|source| RevisionError::Api {
                action: "read",
                name: name.to_string(),
                source,
            })?;
        let Some(found) = found else {
            return Ok(Existing::Gone);
        };
        match Revision::from_object(&found) {
            Ok(_) => Ok(Existing::Readable),
            Err(e @ ReadError::Newer { .. }) => Err(e.into()),
            Err(e) => Ok(Existing::Unreadable(Box::new(found), e)),
        }
    }

    /// Delete `found`, the object named `name`, and no object created in
    /// its place since it was read.
    async fn delete_only(&self, name: &str, found: &DynamicObject) -> Result<(), RevisionError> {
        let only_this = DeleteParams {
            preconditions: Some(kube::api::Preconditions {
                uid: found.metadata.uid.clone(),
                resource_version: None,
            }),
            ..DeleteParams::default()
        };
        match self.api.delete(name, &only_this).await {
            Ok(_) => Ok(()),
            Err(kube::Error::Api(e)) if e.code == 404 => Ok(()),
            Err(source) => Err(RevisionError::Api {
                action: "replace",
                name: name.to_string(),
                source,
            }),
        }
    }

    async fn create_once(&self, revision: &Revision) -> Result<Created, RevisionError> {
        let obj = json!({
            "apiVersion": keys::API_VERSION,
            "kind": KIND,
            "metadata": {
                "name": revision.name,
                "labels": { (keys::CLUSTER_LABEL): revision.spec.cluster },
            },
            "spec": revision.spec,
        });
        let obj: DynamicObject = serde_json::from_value(obj).expect("a revision is an object");
        match self.api.create(&PostParams::default(), &obj).await {
            Ok(stored) => {
                let sent =
                    serde_json::to_value(&revision.spec).expect("a revision spec serializes");
                if stored.data.get("spec") == Some(&sent) {
                    return Ok(Created::Created);
                }
                if let Err(e) = self.delete_only(&revision.name, &stored).await {
                    tracing::warn!(
                        name = %revision.name,
                        error = %e,
                        "could not delete PackageInstanceRevision after the API server altered its spec"
                    );
                }
                Err(RevisionError::StoredDifferently {
                    name: revision.name.clone(),
                })
            }
            Err(kube::Error::Api(e)) if e.code == 409 => Ok(Created::Exists),
            Err(source) => Err(RevisionError::Api {
                action: "create",
                name: revision.name.clone(),
                source,
            }),
        }
    }

    /// Read the revision named `name`, or `None` when there is none.
    pub async fn get(&self, name: &str) -> Result<Option<Revision>, RevisionError> {
        let found = self
            .api
            .get_opt(name)
            .await
            .map_err(|source| RevisionError::Api {
                action: "read",
                name: name.to_string(),
                source,
            })?;
        Ok(found.as_ref().map(Revision::from_object).transpose()?)
    }

    /// Read every revision of Kix cluster `cluster`.
    pub async fn list(&self, cluster: &str) -> Result<Listed, RevisionError> {
        let params = ListParams::default().labels(&format!("{}={cluster}", keys::CLUSTER_LABEL));
        self.list_with(&params, format!("Kix cluster {cluster}"))
            .await
    }

    /// Read every revision on the Kubernetes cluster, of every Kix cluster.
    pub async fn list_all(&self) -> Result<Listed, RevisionError> {
        self.list_with(&ListParams::default(), "all Kix clusters".into())
            .await
    }

    async fn list_with(&self, params: &ListParams, scope: String) -> Result<Listed, RevisionError> {
        let list = match self.api.list(params).await {
            Ok(list) => list,
            Err(source) => return Err(RevisionError::List { scope, source }),
        };
        let (mut readable, mut unreadable) = (Vec::new(), Vec::new());
        for item in &list.items {
            match Revision::from_object(item) {
                Ok(revision) => readable.push(revision),
                Err(e) => unreadable.push(e),
            }
        }
        readable.sort_by(|a, b| a.name.cmp(&b.name));
        unreadable.sort_by(|a, b| a.name().cmp(b.name()));
        Ok(Listed {
            readable,
            unreadable,
        })
    }

    /// Add `applied` to `status.applied` of revision `name`, as a merge
    /// patch on the `status` subresource. Entries that `applied` does not
    /// name keep their value.
    pub async fn write_applied(
        &self,
        name: &str,
        applied: &BTreeMap<String, String>,
    ) -> Result<(), RevisionError> {
        let patch = json!({ "status": { "applied": applied } });
        self.api
            .patch_status(name, &PatchParams::default(), &Patch::Merge(&patch))
            .await
            .map(|_| ())
            .map_err(|source| RevisionError::Api {
                action: "write the applied hashes of",
                name: name.to_string(),
                source,
            })
    }

    /// Remove every entry of `status.applied` of revision `name`.
    pub async fn clear_applied(&self, name: &str) -> Result<(), RevisionError> {
        let patch = json!({ "status": { "applied": null } });
        self.api
            .patch_status(name, &PatchParams::default(), &Patch::Merge(&patch))
            .await
            .map(|_| ())
            .map_err(|source| RevisionError::Api {
                action: "clear the applied hashes of",
                name: name.to_string(),
                source,
            })
    }

    /// Delete revision `name`. A revision that is already gone counts as
    /// deleted.
    pub async fn delete(&self, name: &str) -> Result<(), RevisionError> {
        match self.api.delete(name, &DeleteParams::default()).await {
            Ok(_) => Ok(()),
            Err(kube::Error::Api(e)) if e.code == 404 => Ok(()),
            Err(source) => Err(RevisionError::Api {
                action: "delete",
                name: name.to_string(),
                source,
            }),
        }
    }
}
