//! The binding of a build to one Kubernetes cluster.
//!
//! A cluster definition may set `cluster.kubernetes.uid`, the UID of the
//! target cluster's `kube-system` Namespace. That Namespace is created when
//! the cluster is bootstrapped and cannot be deleted, so its UID names the
//! Kubernetes cluster for its whole life. The build carries the UID in
//! `kix-packages.json` ([`StoreGraph::kubernetes_uid`]), and a deploy of a
//! bound build writes it onto the Activation record as the
//! `{KUBERNETES_UID}` label.
//!
//! [`check`] runs in every command that writes to a cluster from a build of
//! the definition (deploy, plan, gc, and the operator), after the command
//! connects and before it reads or writes anything else. A rollback applies
//! a build this Kix cluster deployed here before, which cannot be a
//! wrong-context mistake, so it runs only [`check_declared`]. Read-only
//! commands such as `kix diff` do not run either. The Kubernetes version
//! check ([`super::kubernetes_version::check`]) runs right after this one in
//! deploy, plan, and the operator.
//!
//! [`check_name`] runs beside [`check`] in deploy and plan. It stops a
//! cluster that Kix 0.6 deployed as `cluster` from being deployed under the
//! name `kix.lib.mkFlake` now takes from its `clusters` key.
//!
//! [`StoreGraph::kubernetes_uid`]: crate::eval::store_graph::StoreGraph::kubernetes_uid

use k8s_openapi::api::core::v1::Namespace;
use kube::api::Api;
use kube::client::Client;
use kube::config::Kubeconfig;
use thiserror::Error;

use super::activation::{self, RecordsError};
use super::errors::{api_error, forbidden};
use crate::manifest::keys::{ACTIVATIONS_CRD, DOCS_URL, KUBERNETES_UID};

/// The Namespace whose UID identifies a Kubernetes cluster.
pub const NAMESPACE: &str = "kube-system";

/// The path under [`DOCS_URL`] of the how-to page that says how to bind a
/// definition and how to lift a binding, linked from the messages.
const HOW_TO_PATH: &str =
    "how-to/operate-a-cluster/bind-a-cluster-definition-to-its-kubernetes-cluster/";

/// The name Kix 0.6 gave a cluster whose definition called
/// `kix.buildCluster` without `name`.
pub const OLD_DEFAULT_NAME: &str = "cluster";

/// The command a refusal stopped, which sets the first sentence of its
/// message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// `kix deploy`, `kix plan`, `kix rollback`, and the operator.
    Deploy,
    /// `kix gc`.
    GarbageCollect,
}

impl Action {
    /// Return the line that says the refusal changed nothing.
    fn nothing(self) -> &'static str {
        match self {
            Action::Deploy => "Nothing was applied to the cluster.",
            Action::GarbageCollect => "Nothing was deleted from the cluster.",
        }
    }
}

/// Where a command connected, for the messages that name the wrong cluster.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Connection {
    /// A kube context of this machine: `name` is the context's name and
    /// `server` its API server URL, each when the kubeconfig gives it.
    Context {
        name: Option<String>,
        server: Option<String>,
    },
    /// The API server of the cluster the operator runs on.
    InCluster,
}

impl Connection {
    /// Describe the context `context` (`None` for the kubeconfig's current
    /// one) from the kubeconfig of this machine, without connecting. A
    /// kubeconfig that cannot be read leaves both parts unknown.
    pub fn of_context(context: Option<&str>) -> Connection {
        let kubeconfig = Kubeconfig::read().ok();
        let name = context
            .map(str::to_string)
            .or_else(|| kubeconfig.as_ref()?.current_context.clone());
        let server = (|| {
            let kubeconfig = kubeconfig.as_ref()?;
            let name = name.as_deref()?;
            let context = kubeconfig.contexts.iter().find(|c| c.name == name)?;
            let cluster = &context.context.as_ref()?.cluster;
            let cluster = kubeconfig.clusters.iter().find(|c| &c.name == cluster)?;
            cluster.cluster.as_ref()?.server.clone()
        })();
        Connection::Context { name, server }
    }

    /// Return `context <name>`, with the server URL when known, or what
    /// stands for it when the name is unknown.
    pub fn describe(&self) -> String {
        match self {
            Connection::Context { name, server } => {
                let name = match name {
                    Some(name) => format!("context {name}"),
                    None => "the current context".to_string(),
                };
                match server {
                    Some(server) => format!("{name} ({server})"),
                    None => name,
                }
            }
            Connection::InCluster => "the API server the operator runs on".to_string(),
        }
    }
}

/// What a failed read of the `kube-system` Namespace was going to confirm.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Checking {
    /// That the build's `cluster.kubernetes.uid`, given here, is this
    /// cluster's.
    Declared(String),
    /// That the UID a record on this cluster carries is this cluster's.
    Locked,
}

/// Why a build may not be applied to the Kubernetes cluster a command
/// connected to. Every message says that nothing was applied or deleted.
#[derive(Error, Debug)]
pub enum BindingError {
    /// The build names a Kubernetes cluster and this is another one.
    #[error("{}", self.render())]
    Mismatch {
        action: Action,
        cluster: String,
        declared: String,
        live: String,
        connection: Connection,
    },

    /// The build names no Kubernetes cluster, and a record on this one
    /// carries the `{KUBERNETES_UID}` label with this cluster's UID.
    #[error("{}", self.render())]
    Unbound {
        action: Action,
        cluster: String,
        bound_cluster: String,
        uid: String,
        connection: Connection,
    },

    /// The build names no Kubernetes cluster, and a record on this one
    /// carries the label with another cluster's UID: the records were
    /// restored or copied from another Kubernetes cluster.
    #[error("{}", self.render())]
    UnboundRestored {
        action: Action,
        cluster: String,
        bound_cluster: String,
        label: String,
        live: String,
        connection: Connection,
    },

    /// The account may not read the `kube-system` Namespace.
    #[error("{}", self.render())]
    Forbidden {
        action: Action,
        cluster: String,
        checking: Checking,
        connection: Connection,
    },

    /// Reading the `kube-system` Namespace failed for another reason.
    #[error("{}", self.render())]
    Read {
        action: Action,
        cluster: String,
        checking: Checking,
        connection: Connection,
        #[source]
        source: kube::Error,
    },

    /// Listing the Activation records failed, so whether the Kubernetes
    /// cluster accepts an unbound build is unknown.
    #[error("{}", self.render())]
    Records {
        action: Action,
        cluster: String,
        connection: Connection,
        #[source]
        source: RecordsError,
    },

    /// `kix.lib.mkFlake` named the build after its `clusters` key, and the
    /// Kubernetes cluster has records only for a Kix cluster named
    /// [`OLD_DEFAULT_NAME`], the name Kix 0.6 gave the same definition.
    #[error("{}", self.render())]
    RenamedByFlake {
        cluster: String,
        connection: Connection,
    },

    /// Listing the Activation records failed, so whether Kix 0.6 deployed
    /// this cluster under [`OLD_DEFAULT_NAME`] is unknown.
    #[error("{}", self.render())]
    NameRecords {
        cluster: String,
        connection: Connection,
        #[source]
        source: RecordsError,
    },
}

impl BindingError {
    /// Return the message: what Kix refused, that nothing changed, why, and
    /// what to do next.
    fn render(&self) -> String {
        match self {
            BindingError::Mismatch {
                action,
                cluster,
                declared,
                live,
                connection,
            } => match connection {
                Connection::InCluster => format!(
                    "cluster '{cluster}' does not match this Kubernetes cluster\n  \
                     {}\n\n  \
                     `cluster.kubernetes.uid` in '{cluster}':  {declared}\n  \
                     `kube-system` UID on this cluster:        {live}\n\n  \
                     Next:\n    \
                     If this Kubernetes cluster was recreated and '{cluster}' belongs here, update '{cluster}'s definition to `cluster.kubernetes.uid = \"{live}\";`, build, and deploy again.",
                    action.nothing(),
                ),
                Connection::Context { .. } => {
                    let connection = connection.describe();
                    format!(
                        "cluster '{cluster}' does not match {connection}\n  \
                         {}\n\n  \
                         `cluster.kubernetes.uid` in '{cluster}':  {declared}\n  \
                         `kube-system` UID on {connection}:        {live}\n\n  \
                         Next:\n    \
                         - If Kix is connected to the wrong cluster, pass the right `--context` for '{cluster}' and run the command again.\n    \
                         - If this Kubernetes cluster was recreated and '{cluster}' belongs here, update '{cluster}'s definition and build again:\n        \
                         cluster.kubernetes.uid = \"{live}\";",
                        action.nothing(),
                    )
                }
            },
            BindingError::Unbound {
                action,
                cluster,
                bound_cluster,
                uid,
                connection,
            } => match connection {
                Connection::InCluster => format!(
                    "this Kubernetes cluster is locked to UID '{uid}' by cluster '{bound_cluster}', but '{cluster}' sets no `cluster.kubernetes.uid`\n  \
                     {}\n\n  \
                     Why:\n    \
                     A deployment record for Kix cluster '{bound_cluster}' on this cluster carries `cluster.kubernetes.uid = \"{uid}\"` (this cluster's UID), so this Kubernetes cluster accepts only definitions that set that UID.\n\n  \
                     Next:\n    \
                     - If '{cluster}' belongs on this Kubernetes cluster, add `cluster.kubernetes.uid = \"{uid}\";` to '{cluster}'s definition, build, and deploy again.\n    \
                     - If '{bound_cluster}' no longer exists, remove the `{KUBERNETES_UID}` label from its deployment records (see {DOCS_URL}{HOW_TO_PATH}).",
                    action.nothing(),
                ),
                Connection::Context { .. } => {
                    let connection = connection.describe();
                    format!(
                        "{connection} is locked to UID '{uid}' by cluster '{bound_cluster}', but '{cluster}' sets no `cluster.kubernetes.uid`\n  \
                         {}\n\n  \
                         Why:\n    \
                         A deployment record for Kix cluster '{bound_cluster}' on {connection} carries `cluster.kubernetes.uid = \"{uid}\"` (this cluster's UID), so this Kubernetes cluster accepts only definitions that set that UID.\n\n  \
                         Next:\n    \
                         - If Kix is connected to the wrong cluster, pass the right `--context` for '{cluster}' and run the command again.\n    \
                         - If '{cluster}' belongs on this Kubernetes cluster, add the UID to '{cluster}'s definition and build again:\n        \
                         cluster.kubernetes.uid = \"{uid}\";\n    \
                         - If '{bound_cluster}' no longer exists, remove the `{KUBERNETES_UID}` label from its deployment records (see {DOCS_URL}{HOW_TO_PATH}).",
                        action.nothing(),
                    )
                }
            },
            BindingError::UnboundRestored {
                action,
                cluster,
                bound_cluster,
                label,
                live,
                connection,
            } => match connection {
                Connection::InCluster => format!(
                    "this Kubernetes cluster has deployment records locked to UID '{label}' by cluster '{bound_cluster}', but '{cluster}' sets no `cluster.kubernetes.uid`\n  \
                     {}\n\n  \
                     Why:\n    \
                     Deployment records for '{bound_cluster}' on this cluster carry `{KUBERNETES_UID} = \"{label}\"`, while this cluster's `kube-system` namespace has UID '{live}' (the records were restored or copied from another Kubernetes cluster).\n\n  \
                     Next:\n    \
                     - If '{cluster}' belongs on this Kubernetes cluster, set `cluster.kubernetes.uid = \"{live}\";` in '{cluster}'s definition, build, and deploy again.\n    \
                     - To lift the lock held by the restored '{bound_cluster}' records, remove the `{KUBERNETES_UID}` label from them (see {DOCS_URL}{HOW_TO_PATH}).",
                    action.nothing(),
                ),
                Connection::Context { .. } => {
                    let connection = connection.describe();
                    format!(
                        "{connection} has deployment records locked to UID '{label}' by cluster '{bound_cluster}', but '{cluster}' sets no `cluster.kubernetes.uid`\n  \
                         {}\n\n  \
                         Why:\n    \
                         Deployment records for '{bound_cluster}' on {connection} carry `{KUBERNETES_UID} = \"{label}\"`, while this cluster's `kube-system` namespace has UID '{live}' (the records were restored or copied from another Kubernetes cluster).\n\n  \
                         Next:\n    \
                         - If Kix is connected to the wrong cluster, pass the right `--context` for '{cluster}' and run the command again.\n    \
                         - If '{cluster}' belongs on this Kubernetes cluster, set this cluster's live UID in '{cluster}'s definition and build again:\n        \
                         cluster.kubernetes.uid = \"{live}\";\n    \
                         - To lift the lock held by the restored '{bound_cluster}' records, remove the `{KUBERNETES_UID}` label from them (see {DOCS_URL}{HOW_TO_PATH}).",
                        action.nothing(),
                    )
                }
            },
            BindingError::Forbidden {
                action,
                cluster,
                checking,
                connection,
            } => {
                let (on, why_where) = match connection {
                    Connection::InCluster => (String::new(), "this cluster".to_string()),
                    Connection::Context { .. } => (
                        format!(" on {}", connection.describe()),
                        connection.describe(),
                    ),
                };
                let (headline, why) = match checking {
                    Checking::Declared(declared) => (
                        format!(
                            "cannot read namespace `kube-system`{on} (403 Forbidden) to check `cluster.kubernetes.uid` for '{cluster}'"
                        ),
                        format!(
                            "'{cluster}' sets `cluster.kubernetes.uid = \"{declared}\"`, so Kix must read the `kube-system` namespace to check the cluster's UID."
                        ),
                    ),
                    Checking::Locked => (
                        format!(
                            "cannot read namespace `kube-system`{on} (403 Forbidden) to check the cluster UID lock for '{cluster}'"
                        ),
                        format!(
                            "An earlier deploy locked {why_where} to a Kubernetes UID, and '{cluster}' sets no `cluster.kubernetes.uid`, so Kix must read the `kube-system` namespace."
                        ),
                    ),
                };
                let next = match connection {
                    Connection::InCluster => {
                        "Grant `get` permission on `namespaces` (resource name `kube-system`) to the operator's service account; the operator will retry automatically."
                    }
                    Connection::Context { .. } => {
                        "Grant `get` permission on `namespaces` (resource name `kube-system`) to this Kubernetes account, or use an account that has it, then run the command again."
                    }
                };
                format!(
                    "{headline}\n  {}\n\n  Why:\n    {why}\n\n  Next:\n    {next}",
                    action.nothing()
                )
            }
            BindingError::Read {
                action,
                cluster,
                connection,
                source,
                ..
            } => {
                let error = api_error(source);
                match connection {
                    Connection::InCluster => format!(
                        "could not read namespace `kube-system` for cluster '{cluster}'\n  \
                         {}\n\n  \
                         Kubernetes API error:\n    {error}\n\n  \
                         Next:\n    \
                         Check that the Kubernetes API server is reachable and healthy; the operator will retry automatically.",
                        action.nothing(),
                    ),
                    Connection::Context { name, .. } => {
                        let kubectl = match name {
                            Some(context) => {
                                format!("kubectl get namespace kube-system --context {context}")
                            }
                            None => "kubectl get namespace kube-system".to_string(),
                        };
                        format!(
                            "could not read namespace `kube-system` on {} for cluster '{cluster}'\n  \
                             {}\n\n  \
                             Kubernetes API error:\n    {error}\n\n  \
                             Next:\n    \
                             Check that the API server is reachable and healthy (`{kubectl}`), then run the command again.",
                            connection.describe(),
                            action.nothing(),
                        )
                    }
                }
            }
            BindingError::Records {
                action,
                cluster,
                connection,
                source,
            } => {
                let error = api_error(&source.source);
                match connection {
                    Connection::InCluster => format!(
                        "could not list deployment records for cluster '{cluster}'\n  \
                         {}\n\n  \
                         Why:\n    \
                         '{cluster}' does not set `cluster.kubernetes.uid`, so Kix lists existing deployment records to check whether this cluster is locked to a UID.\n\n  \
                         Kubernetes API error:\n    {error}\n\n  \
                         Next:\n    \
                         Check that the API server is reachable and that the operator's service account has permission to list `{ACTIVATIONS_CRD}` (the operator will retry automatically), or set `cluster.kubernetes.uid` in '{cluster}'s definition to skip this check.",
                        action.nothing(),
                    ),
                    Connection::Context { .. } => {
                        let connection = connection.describe();
                        format!(
                            "could not list deployment records on {connection} for cluster '{cluster}'\n  \
                             {}\n\n  \
                             Why:\n    \
                             '{cluster}' does not set `cluster.kubernetes.uid`, so Kix lists existing deployment records to check whether {connection} is locked to a UID.\n\n  \
                             Kubernetes API error:\n    {error}\n\n  \
                             Next:\n    \
                             Check that the API server is reachable and that this Kubernetes account has permission to list `{ACTIVATIONS_CRD}`, then run the command again.\n    \
                             Setting `cluster.kubernetes.uid` in '{cluster}'s definition also skips this deployment records check.",
                            action.nothing(),
                        )
                    }
                }
            }
            BindingError::RenamedByFlake {
                cluster,
                connection,
            } => {
                let connection = connection.describe();
                let old = OLD_DEFAULT_NAME;
                format!(
                    "cluster name changed from '{old}' to '{cluster}' on {connection}\n  \
                     Nothing was applied to the cluster.\n\n  \
                     Why:\n    \
                     {connection} has deployment records for '{old}' and none for '{cluster}'.\n    \
                     In Kix 0.6, a `kix.buildCluster` call without `name` was named '{old}'; in Kix 0.7 and later, `kix.lib.mkFlake` names it after its key in `clusters` ('{cluster}').\n    \
                     Deploying under '{cluster}' would start a separate deploy history: Kix would never delete objects that exist only in the '{old}' build, and the Kix operator (if running on the cluster) would keep repairing the '{old}' build while its deployment record remains.\n\n  \
                     Next (choose one):\n    \
                     1. Keep the existing name and deploy history (no cleanup needed): in `{cluster}`'s `kix.buildCluster` call, set:\n         \
                     name = \"{old}\";\n    \
                     2. Use the new name '{cluster}': in `{cluster}`'s `kix.buildCluster` call, set:\n         \
                     name = \"{cluster}\";\n       \
                     Then remove the old '{old}' deployment records and any objects on the cluster that exist only in the '{old}' build (Kix has no command for that cleanup)."
                )
            }
            BindingError::NameRecords {
                cluster,
                connection,
                source,
            } => {
                let old = OLD_DEFAULT_NAME;
                format!(
                    "could not list deployment records on {} to check cluster '{cluster}'\n  \
                     Nothing was applied to the cluster.\n\n  \
                     Kubernetes API error:\n    {}\n\n  \
                     Next:\n    \
                     Check that the API server is reachable and that this Kubernetes account has permission to list `{ACTIVATIONS_CRD}`, then run the command again.\n    \
                     Or set `name` explicitly in `{cluster}`'s `kix.buildCluster` call (`name = \"{cluster}\";` or `name = \"{old}\";`), which turns this check off.",
                    connection.describe(),
                    api_error(&source.source),
                )
            }
        }
    }

    /// Return `true` when the refusal is for a 403 on the `kube-system`
    /// Namespace, which a grant of permission resolves without a change to
    /// the build.
    pub fn is_forbidden(&self) -> bool {
        matches!(self, BindingError::Forbidden { .. })
    }
}

/// Return the UID of the `kube-system` Namespace, which identifies the
/// Kubernetes cluster behind `client`.
pub async fn live_uid(client: &Client) -> Result<String, kube::Error> {
    let namespace = Api::<Namespace>::all(client.clone()).get(NAMESPACE).await?;
    Ok(namespace.metadata.uid.unwrap_or_default())
}

/// Read the live UID for the check `checking` of `cluster`, turning a
/// failure into the refusal of `action` that names it.
async fn read_live_uid(
    client: &Client,
    connection: &Connection,
    action: Action,
    cluster: &str,
    checking: Checking,
) -> Result<String, BindingError> {
    match live_uid(client).await {
        Ok(live) => Ok(live),
        Err(e) if forbidden(&e) => Err(BindingError::Forbidden {
            action,
            cluster: cluster.to_string(),
            checking,
            connection: connection.clone(),
        }),
        Err(source) => Err(BindingError::Read {
            action,
            cluster: cluster.to_string(),
            checking,
            connection: connection.clone(),
            source,
        }),
    }
}

/// Refuse `action` with the build of Kix cluster `cluster`, whose
/// definition names the Kubernetes cluster `declared` (`None` when
/// unbound), on the cluster behind `client`: [`check_declared`] for a bound
/// build, [`check_unbound`] for an unbound one.
pub async fn check(
    client: &Client,
    connection: &Connection,
    action: Action,
    cluster: &str,
    declared: Option<&str>,
) -> Result<(), BindingError> {
    match declared {
        Some(declared) => check_declared(client, connection, action, cluster, declared).await,
        None => check_unbound(client, connection, action, cluster).await,
    }
}

/// Refuse the build of `cluster`, whose definition names the Kubernetes
/// cluster `declared`, unless the live `kube-system` UID is that one.
pub async fn check_declared(
    client: &Client,
    connection: &Connection,
    action: Action,
    cluster: &str,
    declared: &str,
) -> Result<(), BindingError> {
    let live = read_live_uid(
        client,
        connection,
        action,
        cluster,
        Checking::Declared(declared.to_string()),
    )
    .await?;
    if live == declared {
        return Ok(());
    }
    Err(BindingError::Mismatch {
        action,
        cluster: cluster.to_string(),
        declared: declared.to_string(),
        live,
        connection: connection.clone(),
    })
}

/// Refuse the unbound build of `cluster` when an Activation record on the
/// Kubernetes cluster, of any Kix cluster, that finished a deploy carries
/// the `{KUBERNETES_UID}` label ([`activation::bound_record`]), since
/// a deployed bound definition makes the Kubernetes cluster one that
/// accepts only definitions that name it. The live UID is read to tell a record written here from one restored
/// from another Kubernetes cluster, so the advice names this cluster's UID.
/// An unbound build on a cluster with no such record passes, as before
/// binding existed, with nothing else read.
pub async fn check_unbound(
    client: &Client,
    connection: &Connection,
    action: Action,
    cluster: &str,
) -> Result<(), BindingError> {
    let bound = activation::bound_record(client)
        .await
        .map_err(|source| BindingError::Records {
            action,
            cluster: cluster.to_string(),
            connection: connection.clone(),
            source,
        })?;
    let Some(bound) = bound else {
        return Ok(());
    };
    let live = read_live_uid(client, connection, action, cluster, Checking::Locked).await?;
    if live == bound.uid {
        return Err(BindingError::Unbound {
            action,
            cluster: cluster.to_string(),
            bound_cluster: bound.cluster,
            uid: bound.uid,
            connection: connection.clone(),
        });
    }
    Err(BindingError::UnboundRestored {
        action,
        cluster: cluster.to_string(),
        bound_cluster: bound.cluster,
        label: bound.uid,
        live,
        connection: connection.clone(),
    })
}

/// Refuse the build of `cluster` when `kix.lib.mkFlake` took its name from
/// its `clusters` key (`name_from_flake_key`), the Kubernetes cluster has no
/// Activation record for `cluster`, and it has one for
/// [`OLD_DEFAULT_NAME`]. Kix 0.6 gave that name to the same definition, so
/// deploying under the new name would leave the old records and their
/// objects behind with no error. A definition that sets `name` passes with
/// nothing read.
pub async fn check_name(
    client: &Client,
    connection: &Connection,
    cluster: &str,
    name_from_flake_key: bool,
) -> Result<(), BindingError> {
    if !name_from_flake_key || cluster == OLD_DEFAULT_NAME {
        return Ok(());
    }
    let refuse = |source| BindingError::NameRecords {
        cluster: cluster.to_string(),
        connection: connection.clone(),
        source,
    };
    if activation::records_exist(client, cluster)
        .await
        .map_err(refuse)?
    {
        return Ok(());
    }
    if !activation::records_exist(client, OLD_DEFAULT_NAME)
        .await
        .map_err(refuse)?
    {
        return Ok(());
    }
    Err(BindingError::RenamedByFlake {
        cluster: cluster.to_string(),
        connection: connection.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::{FakeApi, kube_system};
    use crate::manifest::keys;
    use crate::manifest::lifecycle::{PHASE_ACTIVE, RECORD_KIND};
    use serde_json::{Value, json};

    const HERE: &str = "9f8e7d6c-5b4a-4321-8765-0fedcba98765";
    const ELSEWHERE: &str = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";

    fn record(cluster: &str, kubernetes_uid: Option<&str>) -> Value {
        let mut labels = json!({
            "app.kubernetes.io/managed-by": "kix",
            (keys::CLUSTER_LABEL): cluster,
        });
        if let Some(uid) = kubernetes_uid {
            labels[keys::KUBERNETES_UID] = json!(uid);
        }
        json!({
            "apiVersion": keys::API_VERSION,
            "kind": RECORD_KIND,
            "metadata": { "name": format!("{cluster}-1"), "labels": labels },
            "status": { "phase": PHASE_ACTIVE },
        })
    }

    /// Return a context with no name or server, as when the kubeconfig
    /// names none. Tests use it so they never read this machine's
    /// kubeconfig.
    fn unnamed_context() -> Connection {
        Connection::Context {
            name: None,
            server: None,
        }
    }

    fn context(name: &str, server: &str) -> Connection {
        Connection::Context {
            name: Some(name.to_string()),
            server: Some(server.to_string()),
        }
    }

    /// Return the requests the fake answered that were not GETs.
    fn writes(api: &FakeApi) -> Vec<String> {
        api.requests()
            .into_iter()
            .filter(|r| !r.starts_with("GET "))
            .collect()
    }

    /// A build that names the cluster it is deployed to passes.
    #[tokio::test]
    async fn a_build_naming_this_cluster_passes() {
        let api = FakeApi::new([kube_system(HERE)]);
        let connection = context("prod", "https://prod.example:6443");
        check(
            &api.client(),
            &connection,
            Action::Deploy,
            "cluster-a",
            Some(HERE),
        )
        .await
        .unwrap();
        assert_eq!(
            api.requests(),
            vec!["GET /api/v1/namespaces/kube-system".to_string()]
        );
    }

    /// A build that names another cluster is refused after one read, and
    /// the message names both IDs, the context, and the fix.
    #[tokio::test]
    async fn a_build_naming_another_cluster_is_refused() {
        let api = FakeApi::new([kube_system(HERE), record("lab1", Some(HERE))]);
        let connection = context("cluster-b", "https://b.example:6443");
        let err = check(
            &api.client(),
            &connection,
            Action::Deploy,
            "cluster-a",
            Some(ELSEWHERE),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::Mismatch { .. }));
        let text = err.to_string();
        assert!(
            text.starts_with(
                "cluster 'cluster-a' does not match context cluster-b (https://b.example:6443)\n  Nothing was applied to the cluster."
            ),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "`cluster.kubernetes.uid` in 'cluster-a':  {ELSEWHERE}"
            )),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "`kube-system` UID on context cluster-b (https://b.example:6443):        {HERE}"
            )),
            "{text}"
        );
        assert!(
            text.contains("pass the right `--context` for 'cluster-a'"),
            "{text}"
        );
        assert!(
            text.contains(&format!("cluster.kubernetes.uid = \"{HERE}\";")),
            "{text}"
        );
        assert_eq!(
            api.requests(),
            vec!["GET /api/v1/namespaces/kube-system".to_string()]
        );
        assert!(writes(&api).is_empty());
    }

    /// The operator's message does not tell it to check `--context`.
    #[tokio::test]
    async fn the_operator_is_not_told_to_check_its_context() {
        let api = FakeApi::new([kube_system(HERE)]);
        let err = check(
            &api.client(),
            &Connection::InCluster,
            Action::Deploy,
            "cluster-a",
            Some(ELSEWHERE),
        )
        .await
        .unwrap_err()
        .to_string();
        assert!(
            err.starts_with(
                "cluster 'cluster-a' does not match this Kubernetes cluster\n  Nothing was applied to the cluster."
            ),
            "{err}"
        );
        assert!(!err.contains("--context"), "{err}");
    }

    /// A 403 on the Namespace refuses with the permission to grant.
    #[tokio::test]
    async fn a_forbidden_read_names_the_permission() {
        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next("/api/v1/namespaces/kube-system", 1, 403);
        let connection = context("prod", "https://prod.example:6443");
        let err = check(
            &api.client(),
            &connection,
            Action::Deploy,
            "cluster-a",
            Some(HERE),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::Forbidden { .. }));
        let text = err.to_string();
        assert!(
            text.starts_with(
                "cannot read namespace `kube-system` on context prod (https://prod.example:6443) (403 Forbidden) to check `cluster.kubernetes.uid` for 'cluster-a'\n  Nothing was applied to the cluster."
            ),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "'cluster-a' sets `cluster.kubernetes.uid = \"{HERE}\"`, so Kix must read"
            )),
            "{text}"
        );
        assert!(
            text.contains("to this Kubernetes account, or use an account that has it"),
            "{text}"
        );
        assert!(writes(&api).is_empty());
    }

    /// The operator's 403 advice names its service account, since it cannot
    /// deploy with another account.
    #[tokio::test]
    async fn the_operators_forbidden_read_names_its_service_account() {
        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next("/api/v1/namespaces/kube-system", 1, 403);
        let err = check(
            &api.client(),
            &Connection::InCluster,
            Action::Deploy,
            "cluster-a",
            Some(HERE),
        )
        .await
        .unwrap_err();
        assert!(err.is_forbidden());
        let text = err.to_string();
        assert!(
            text.contains("to the operator's service account; the operator will retry"),
            "{text}"
        );
        assert!(!text.contains("use an account"), "{text}");
    }

    /// Any other failure to read the Namespace is refused with its cause.
    #[tokio::test]
    async fn another_read_failure_is_refused_with_its_cause() {
        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next("/api/v1/namespaces/kube-system", 1, 503);
        let err = check(
            &api.client(),
            &Connection::Context {
                name: Some("prod".to_string()),
                server: None,
            },
            Action::Deploy,
            "cluster-a",
            Some(HERE),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::Read { .. }), "{err}");
        let text = err.to_string();
        assert!(
            text.contains("Nothing was applied to the cluster."),
            "{text}"
        );
        assert!(text.contains("HTTP 503 "), "{text}");
        assert!(
            text.contains("kubectl get namespace kube-system --context prod"),
            "{text}"
        );
    }

    /// An unbound build on a cluster whose records carry another cluster's
    /// UID is told the records were restored, and to add the live UID.
    #[tokio::test]
    async fn restored_records_name_the_live_uid() {
        let api = FakeApi::new([kube_system(HERE), record("lab1", Some(ELSEWHERE))]);
        let connection = context("prod", "https://prod.example:6443");
        let err = check(
            &api.client(),
            &connection,
            Action::Deploy,
            "cluster-a",
            None,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::UnboundRestored { .. }), "{err}");
        let text = err.to_string();
        assert!(
            text.contains(&format!(
                "carry `{KUBERNETES_UID} = \"{ELSEWHERE}\"`, while this cluster's `kube-system` namespace has UID '{HERE}' (the records were restored"
            )),
            "{text}"
        );
        assert!(
            text.contains(&format!("cluster.kubernetes.uid = \"{HERE}\";")),
            "{text}"
        );
        assert!(writes(&api).is_empty());
    }

    /// When the lock is found but the Namespace cannot be read, the refusal
    /// says what Kix was confirming.
    #[tokio::test]
    async fn a_locked_cluster_whose_uid_is_unreadable_says_so() {
        let api = FakeApi::new([kube_system(HERE), record("lab1", Some(HERE))]);
        api.fail_next("/api/v1/namespaces/kube-system", 1, 403);
        let err = check(
            &api.client(),
            &unnamed_context(),
            Action::Deploy,
            "cluster-a",
            None,
        )
        .await
        .unwrap_err();
        assert!(err.is_forbidden());
        let text = err.to_string();
        assert!(
            text.contains("to check the cluster UID lock for 'cluster-a'"),
            "{text}"
        );
        assert!(
            text.contains("An earlier deploy locked the current context to a Kubernetes UID, and 'cluster-a' sets no `cluster.kubernetes.uid`"),
            "{text}"
        );
    }

    /// An unbound build is refused on a cluster where any record, of any
    /// Kix cluster, carries the label; the message names that cluster and
    /// the UID to add.
    #[tokio::test]
    async fn an_unbound_build_is_refused_where_a_bound_build_deployed() {
        let api = FakeApi::new([
            kube_system(HERE),
            record("cluster-a", None),
            record("lab1", Some(HERE)),
        ]);
        let connection = context("prod", "https://prod.example:6443");
        let err = check(
            &api.client(),
            &connection,
            Action::Deploy,
            "cluster-a",
            None,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::Unbound { .. }));
        let text = err.to_string();
        assert!(
            text.contains(&format!(
                "is locked to UID '{HERE}' by cluster 'lab1', but 'cluster-a' sets no `cluster.kubernetes.uid`"
            )),
            "{text}"
        );
        assert!(
            text.contains(&format!("cluster.kubernetes.uid = \"{HERE}\";"))
                && text.contains(&format!(
                    "If 'lab1' no longer exists, remove the `{KUBERNETES_UID}` label"
                )),
            "{text}"
        );
        assert!(writes(&api).is_empty());
    }

    /// An unbound build passes on a cluster whose records carry no label,
    /// and on one with no Activation CRD, with nothing else read.
    #[tokio::test]
    async fn an_unbound_build_passes_where_nothing_is_bound() {
        let api = FakeApi::new([kube_system(HERE), record("cluster-a", None)]);
        let connection = unnamed_context();
        check(
            &api.client(),
            &connection,
            Action::Deploy,
            "cluster-a",
            None,
        )
        .await
        .unwrap();
        assert_eq!(api.requests().len(), 1, "{:?}", api.requests());
        assert!(
            api.requests()[0].contains(&format!(
                "labelSelector={}",
                keys::KUBERNETES_UID.replace('/', "%2F")
            )),
            "{:?}",
            api.requests()
        );

        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next(&format!("/apis/{}/activations", keys::API_VERSION), 1, 404);
        check(
            &api.client(),
            &connection,
            Action::Deploy,
            "cluster-a",
            None,
        )
        .await
        .unwrap();
    }

    /// A record the CLI submits for the operator carries the build's UID as
    /// the label, and locks the cluster once its deploy finishes; an unbound
    /// build's record carries none.
    #[tokio::test]
    async fn a_submitted_record_carries_the_label_of_a_bound_build() {
        use crate::cluster::activation::{Records, bound_record};
        use crate::cluster::discovery;
        let api = FakeApi::new([kube_system(HERE)]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        records
            .submit(
                "cluster-a-1",
                "cluster-a",
                "/nix/store/x",
                Some("h1"),
                None,
                "r1",
            )
            .await
            .unwrap();
        records
            .finalize_deploy("cluster-a", "cluster-a-1", None, false, None, &[], &[])
            .await
            .unwrap();
        assert_eq!(bound_record(&client).await.unwrap(), None);
        records
            .submit(
                "lab1-1",
                "lab1",
                "/nix/store/y",
                Some("h2"),
                Some(HERE),
                "r2",
            )
            .await
            .unwrap();
        assert_eq!(bound_record(&client).await.unwrap(), None);
        records
            .finalize_deploy("lab1", "lab1-1", None, false, None, &[], &[])
            .await
            .unwrap();
        let bound = bound_record(&client).await.unwrap().unwrap();
        assert_eq!((bound.cluster.as_str(), bound.uid.as_str()), ("lab1", HERE));
    }

    /// Return a record of `cluster` in `phase` that carries `uid` as its
    /// label, with `kix.run/deployed-at` when `deployed`.
    fn bound_in_phase(name: &str, cluster: &str, uid: &str, phase: &str, deployed: bool) -> Value {
        let mut record = record(cluster, Some(uid));
        record["metadata"]["name"] = json!(name);
        record["status"]["phase"] = json!(phase);
        if deployed {
            record["metadata"]["annotations"] =
                json!({ (keys::DEPLOYED_AT): "2026-11-01T10:00:00Z" });
        }
        record
    }

    /// A bound record that never finished a deploy does not lock the
    /// cluster: an unbound build passes beside a Failed, Queued, or
    /// Deploying record, and one superseded before it deployed.
    #[tokio::test]
    async fn a_bound_record_that_never_deployed_does_not_lock_the_cluster() {
        use crate::manifest::lifecycle::{
            PHASE_DEPLOYING, PHASE_FAILED, PHASE_QUEUED, PHASE_SUPERSEDED,
        };
        let api = FakeApi::new([
            kube_system(HERE),
            bound_in_phase("lab1-1", "lab1", ELSEWHERE, PHASE_FAILED, false),
            bound_in_phase("lab1-2", "lab1", HERE, PHASE_QUEUED, false),
            bound_in_phase("lab1-3", "lab1", HERE, PHASE_DEPLOYING, false),
            bound_in_phase("lab1-4", "lab1", HERE, PHASE_SUPERSEDED, false),
        ]);
        check(
            &api.client(),
            &unnamed_context(),
            Action::Deploy,
            "cluster-a",
            None,
        )
        .await
        .unwrap();
    }

    /// A bound record that finished a deploy locks the cluster in any phase
    /// it reaches afterwards.
    #[tokio::test]
    async fn a_bound_record_that_deployed_locks_the_cluster() {
        use crate::manifest::lifecycle::{PHASE_DEGRADED, PHASE_FAILED, PHASE_SUPERSEDED};
        for (phase, deployed) in [
            (PHASE_ACTIVE, false),
            (PHASE_DEGRADED, false),
            (PHASE_SUPERSEDED, true),
            (PHASE_FAILED, true),
        ] {
            let api = FakeApi::new([
                kube_system(HERE),
                bound_in_phase("lab1-1", "lab1", HERE, phase, deployed),
            ]);
            let err = check(
                &api.client(),
                &unnamed_context(),
                Action::Deploy,
                "cluster-a",
                None,
            )
            .await
            .unwrap_err();
            assert!(
                matches!(err, BindingError::Unbound { .. }),
                "{phase}: {err}"
            );
        }
    }

    /// `kix gc` is told that nothing was deleted, not that nothing was
    /// applied.
    #[tokio::test]
    async fn a_garbage_collection_refusal_says_nothing_was_deleted() {
        let api = FakeApi::new([kube_system(HERE)]);
        let connection = context("prod", "https://prod.example:6443");
        let err = check(
            &api.client(),
            &connection,
            Action::GarbageCollect,
            "cluster-a",
            Some(ELSEWHERE),
        )
        .await
        .unwrap_err()
        .to_string();
        assert!(
            err.starts_with(
                "cluster 'cluster-a' does not match context prod (https://prod.example:6443)\n  Nothing was deleted from the cluster."
            ),
            "{err}"
        );
        assert!(!err.contains("applied"), "{err}");

        let api = FakeApi::new([kube_system(HERE), record("lab1", Some(HERE))]);
        let err = check(
            &api.client(),
            &connection,
            Action::GarbageCollect,
            "cluster-a",
            None,
        )
        .await
        .unwrap_err()
        .to_string();
        assert!(
            err.contains("\n  Nothing was deleted from the cluster.\n"),
            "{err}"
        );
        assert!(err.contains(&format!("{DOCS_URL}{HOW_TO_PATH}")), "{err}");
    }

    /// A build that `mkFlake` named after its key is refused where only
    /// records of a Kix cluster named `cluster` exist, before anything is
    /// written, and the message gives both fixes.
    #[tokio::test]
    async fn a_key_derived_name_is_refused_over_old_default_records() {
        let api = FakeApi::new([kube_system(HERE), record(OLD_DEFAULT_NAME, None)]);
        let connection = context("prod", "https://prod.example:6443");
        let err = check_name(&api.client(), &connection, "prod", true)
            .await
            .unwrap_err();
        assert!(matches!(err, BindingError::RenamedByFlake { .. }), "{err}");
        let text = err.to_string();
        assert!(
            text.starts_with(
                "cluster name changed from 'cluster' to 'prod' on context prod (https://prod.example:6443)\n  Nothing was applied to the cluster."
            ),
            "{text}"
        );
        assert!(text.contains("name = \"cluster\";"), "{text}");
        assert!(text.contains("name = \"prod\";"), "{text}");
        assert!(writes(&api).is_empty());
    }

    /// The name check passes when the definition sets `name`, when the
    /// key-derived name already has records, when no record of `cluster`
    /// exists, and when the key is `cluster` itself.
    #[tokio::test]
    async fn a_key_derived_name_passes_otherwise() {
        let connection = unnamed_context();

        let api = FakeApi::new([kube_system(HERE), record(OLD_DEFAULT_NAME, None)]);
        check_name(&api.client(), &connection, "prod", false)
            .await
            .unwrap();
        assert!(api.requests().is_empty(), "{:?}", api.requests());

        let api = FakeApi::new([
            kube_system(HERE),
            record(OLD_DEFAULT_NAME, None),
            record("prod", None),
        ]);
        check_name(&api.client(), &connection, "prod", true)
            .await
            .unwrap();

        let api = FakeApi::new([kube_system(HERE), record("other", None)]);
        check_name(&api.client(), &connection, "prod", true)
            .await
            .unwrap();

        let api = FakeApi::new([kube_system(HERE), record(OLD_DEFAULT_NAME, None)]);
        check_name(&api.client(), &connection, OLD_DEFAULT_NAME, true)
            .await
            .unwrap();
        assert!(api.requests().is_empty(), "{:?}", api.requests());
    }

    /// A failure to list the records refuses rather than letting the name
    /// change.
    #[tokio::test]
    async fn a_failed_record_listing_refuses_a_key_derived_name() {
        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next(&format!("/apis/{}/activations", keys::API_VERSION), 1, 403);
        let err = check_name(&api.client(), &unnamed_context(), "prod", true)
            .await
            .unwrap_err();
        assert!(matches!(err, BindingError::NameRecords { .. }), "{err}");
    }

    /// A failure to list the records refuses rather than passing an
    /// unbound build.
    #[tokio::test]
    async fn a_failed_record_listing_refuses_an_unbound_build() {
        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next(&format!("/apis/{}/activations", keys::API_VERSION), 1, 403);
        let err = check(
            &api.client(),
            &unnamed_context(),
            Action::Deploy,
            "cluster-a",
            None,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::Records { .. }), "{err}");
    }
}
