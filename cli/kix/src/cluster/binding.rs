//! The binding of a build to one Kubernetes cluster.
//!
//! A cluster definition may set `cluster.kubernetes.uid`, the UID of the
//! target cluster's `kube-system` Namespace. That Namespace is created when
//! the cluster is bootstrapped and cannot be deleted, so its UID names the
//! Kubernetes cluster for its whole life. The build carries the UID in
//! `kix-packages.json` ([`StoreGraph::kubernetes_uid`]), and a deploy of a
//! bound build writes it onto the Activation record as the
//! `kix.run/kubernetes-uid` label.
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
//! [`StoreGraph::kubernetes_uid`]: crate::eval::store_graph::StoreGraph::kubernetes_uid

use k8s_openapi::api::core::v1::Namespace;
use kube::api::Api;
use kube::client::Client;
use kube::config::Kubeconfig;
use thiserror::Error;

use super::activation::{self, RecordsError};
use super::errors::{api_error, forbidden};

/// The Namespace whose UID identifies a Kubernetes cluster.
pub const NAMESPACE: &str = "kube-system";

/// The how-to page that says how to bind a definition and how to lift a
/// binding, named in the messages.
const HOW_TO: &str = "Bind a cluster definition to its Kubernetes cluster";

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

    /// Return the advice to check `--context`, which the operator cannot
    /// follow.
    fn check_context(&self) -> &'static str {
        match self {
            Connection::Context { .. } => {
                " If you targeted the wrong cluster, pass the right --context."
            }
            Connection::InCluster => "",
        }
    }

    /// Return where `--context` points, for the message that suggests
    /// checking it.
    fn otherwise_check_context(&self) -> String {
        match self {
            Connection::Context {
                server: Some(server),
                ..
            } => format!(
                " If you targeted the wrong cluster, pass the right --context \
                 (currently pointing at {server})."
            ),
            Connection::Context { .. } => {
                " If you targeted the wrong cluster, pass the right --context.".to_string()
            }
            Connection::InCluster => String::new(),
        }
    }

    /// Return the advice for a 403 on the `kube-system` Namespace: the
    /// operator cannot switch accounts, so it names its service account.
    fn grant_get_namespaces(&self) -> &'static str {
        match self {
            Connection::Context { .. } => {
                "Grant this Kubernetes account get permission on namespaces, \
                 or deploy with an account that has it."
            }
            Connection::InCluster => {
                "Grant the operator's service account get permission on namespaces, \
                 and the operator will retry."
            }
        }
    }
}

/// What a failed read of the `kube-system` Namespace was going to confirm.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Checking {
    /// That the build's `cluster.kubernetes.uid` is this cluster's.
    Declared,
    /// That the UID a record on this cluster carries is this cluster's.
    Locked,
}

impl Checking {
    /// Return the clause that says why Kix read the Namespace for `cluster`.
    fn why(self, cluster: &str) -> String {
        match self {
            Checking::Declared => format!(
                "{cluster}'s definition sets cluster.kubernetes.uid, and Kix could not read \
                 the kube-system namespace"
            ),
            Checking::Locked => format!(
                "A previous deploy locked this cluster to a cluster.kubernetes.uid, \
                 {cluster}'s definition does not set one, and Kix could not read \
                 the kube-system namespace"
            ),
        }
    }
}

/// Why a build may not be applied to the Kubernetes cluster a command
/// connected to. Every message says that nothing was applied.
#[derive(Error, Debug)]
pub enum BindingError {
    /// The build names a Kubernetes cluster and this is another one.
    #[error(
        "Kix refused to deploy {cluster} to {}. Nothing was applied. \
         {cluster}'s definition sets cluster.kubernetes.uid = \"{declared}\", \
         which locks it to the Kubernetes cluster whose kube-system namespace has that UID. \
         This cluster's kube-system namespace has UID \"{live}\".{} \
         If this Kubernetes cluster was recreated and {cluster} now belongs here, \
         set cluster.kubernetes.uid = \"{live}\"; in {cluster}'s definition.",
        connection.describe(),
        connection.check_context()
    )]
    Mismatch {
        cluster: String,
        declared: String,
        live: String,
        connection: Connection,
    },

    /// The build names no Kubernetes cluster, and a record on this one
    /// carries the `kix.run/kubernetes-uid` label with this cluster's UID.
    #[error(
        "Kix refused to deploy {cluster} to this Kubernetes cluster. Nothing was applied. \
         {bound_cluster} was deployed here with cluster.kubernetes.uid = \"{uid}\" \
         (the UID of this cluster's kube-system namespace), which locked this cluster \
         to definitions that set that UID. {cluster}'s definition does not set \
         cluster.kubernetes.uid.{} If {cluster} belongs on this cluster, \
         add cluster.kubernetes.uid = \"{uid}\"; to {cluster}'s definition. \
         If the Kix cluster that set it no longer exists, remove the label from its \
         records (see the how-to page \"{HOW_TO}\").",
        connection.otherwise_check_context()
    )]
    Unbound {
        cluster: String,
        bound_cluster: String,
        uid: String,
        connection: Connection,
    },

    /// The build names no Kubernetes cluster, and a record on this one
    /// carries the label with another cluster's UID: the records were
    /// restored or copied from another Kubernetes cluster.
    #[error(
        "Kix refused to deploy {cluster} to this Kubernetes cluster. Nothing was applied. \
         {bound_cluster}'s Activation records here carry cluster.kubernetes.uid = \"{label}\", \
         but this cluster's kube-system namespace has UID \"{live}\", so those records \
         came from another Kubernetes cluster. {cluster}'s definition does not set \
         cluster.kubernetes.uid.{} If {cluster} belongs on this cluster, \
         add cluster.kubernetes.uid = \"{live}\"; to {cluster}'s definition. \
         To lift the lock the restored records hold, remove the label from them \
         (see the how-to page \"{HOW_TO}\").",
        connection.otherwise_check_context()
    )]
    UnboundRestored {
        cluster: String,
        bound_cluster: String,
        label: String,
        live: String,
        connection: Connection,
    },

    /// The account may not read the `kube-system` Namespace.
    #[error(
        "Kix refused to deploy {cluster} to {}. Nothing was applied. \
         {} (HTTP 403 Forbidden) to check this cluster's UID. {}",
        connection.describe(),
        checking.why(cluster),
        connection.grant_get_namespaces()
    )]
    Forbidden {
        cluster: String,
        checking: Checking,
        connection: Connection,
    },

    /// Reading the `kube-system` Namespace failed for another reason.
    #[error(
        "Kix refused to deploy {cluster} to {}. Nothing was applied. \
         {} to check this cluster's UID ({}). \
         Check that the cluster's API server is reachable and healthy, then retry.",
        connection.describe(),
        checking.why(cluster),
        api_error(source)
    )]
    Read {
        cluster: String,
        checking: Checking,
        connection: Connection,
        #[source]
        source: kube::Error,
    },

    /// Listing the Activation records failed, so whether the Kubernetes
    /// cluster accepts an unbound build is unknown.
    #[error(
        "Kix refused to deploy {cluster} to {}. Nothing was applied. \
         {cluster}'s definition does not set cluster.kubernetes.uid, and Kix could not \
         read the Activation records on this cluster to check whether a previous deploy \
         locked it to a cluster.kubernetes.uid ({}). \
         Check that the API server is reachable and that this Kubernetes account has \
         list permission on activations, then retry.",
        connection.describe(),
        api_error(&source.source)
    )]
    Records {
        cluster: String,
        connection: Connection,
        #[source]
        source: RecordsError,
    },
}

impl BindingError {
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
/// failure into the refusal that names it.
async fn read_live_uid(
    client: &Client,
    connection: &Connection,
    cluster: &str,
    checking: Checking,
) -> Result<String, BindingError> {
    match live_uid(client).await {
        Ok(live) => Ok(live),
        Err(e) if forbidden(&e) => Err(BindingError::Forbidden {
            cluster: cluster.to_string(),
            checking,
            connection: connection.clone(),
        }),
        Err(source) => Err(BindingError::Read {
            cluster: cluster.to_string(),
            checking,
            connection: connection.clone(),
            source,
        }),
    }
}

/// Refuse to apply the build of Kix cluster `cluster`, whose definition
/// names the Kubernetes cluster `declared` (`None` when unbound), to the
/// cluster behind `client`: [`check_declared`] for a bound build,
/// [`check_unbound`] for an unbound one.
pub async fn check(
    client: &Client,
    connection: &Connection,
    cluster: &str,
    declared: Option<&str>,
) -> Result<(), BindingError> {
    match declared {
        Some(declared) => check_declared(client, connection, cluster, declared).await,
        None => check_unbound(client, connection, cluster).await,
    }
}

/// Refuse the build of `cluster`, whose definition names the Kubernetes
/// cluster `declared`, unless the live `kube-system` UID is that one.
pub async fn check_declared(
    client: &Client,
    connection: &Connection,
    cluster: &str,
    declared: &str,
) -> Result<(), BindingError> {
    let live = read_live_uid(client, connection, cluster, Checking::Declared).await?;
    if live == declared {
        return Ok(());
    }
    Err(BindingError::Mismatch {
        cluster: cluster.to_string(),
        declared: declared.to_string(),
        live,
        connection: connection.clone(),
    })
}

/// Refuse the unbound build of `cluster` when any Activation record on the
/// Kubernetes cluster, of any Kix cluster, carries the
/// `kix.run/kubernetes-uid` label, since the records of a bound definition
/// make the Kubernetes cluster one that accepts only definitions that name
/// it. The live UID is read to tell a record written here from one restored
/// from another Kubernetes cluster, so the advice names this cluster's UID.
/// An unbound build on a cluster with no such record passes, as before
/// binding existed, with nothing else read.
pub async fn check_unbound(
    client: &Client,
    connection: &Connection,
    cluster: &str,
) -> Result<(), BindingError> {
    let bound = activation::bound_record(client)
        .await
        .map_err(|source| BindingError::Records {
            cluster: cluster.to_string(),
            connection: connection.clone(),
            source,
        })?;
    let Some(bound) = bound else {
        return Ok(());
    };
    let live = read_live_uid(client, connection, cluster, Checking::Locked).await?;
    if live == bound.uid {
        return Err(BindingError::Unbound {
            cluster: cluster.to_string(),
            bound_cluster: bound.cluster,
            uid: bound.uid,
            connection: connection.clone(),
        });
    }
    Err(BindingError::UnboundRestored {
        cluster: cluster.to_string(),
        bound_cluster: bound.cluster,
        label: bound.uid,
        live,
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
        let mut labels = json!({ (keys::CLUSTER_LABEL): cluster });
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
        check(&api.client(), &connection, "cluster-a", Some(HERE))
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
        let err = check(&api.client(), &connection, "cluster-a", Some(ELSEWHERE))
            .await
            .unwrap_err();
        assert!(matches!(err, BindingError::Mismatch { .. }));
        let text = err.to_string();
        assert!(
            text.contains(
                "Kix refused to deploy cluster-a to context cluster-b (https://b.example:6443). Nothing was applied."
            ),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "cluster-a's definition sets cluster.kubernetes.uid = \"{ELSEWHERE}\""
            )),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "This cluster's kube-system namespace has UID \"{HERE}\"."
            )),
            "{text}"
        );
        assert!(
            text.contains("If you targeted the wrong cluster, pass the right --context."),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "set cluster.kubernetes.uid = \"{HERE}\"; in cluster-a's definition."
            )),
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
            "cluster-a",
            Some(ELSEWHERE),
        )
        .await
        .unwrap_err()
        .to_string();
        assert!(
            err.contains(
                "Kix refused to deploy cluster-a to the API server the operator runs on. Nothing was applied."
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
        let err = check(&api.client(), &connection, "cluster-a", Some(HERE))
            .await
            .unwrap_err();
        assert!(matches!(err, BindingError::Forbidden { .. }));
        let text = err.to_string();
        assert!(
            text.contains(
                "Kix refused to deploy cluster-a to context prod (https://prod.example:6443). Nothing was applied."
            ),
            "{text}"
        );
        assert!(
            text.contains(
                "Kix could not read the kube-system namespace (HTTP 403 Forbidden) to check this cluster's UID."
            ),
            "{text}"
        );
        assert!(
            text.contains("Grant this Kubernetes account get permission on namespaces"),
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
            "cluster-a",
            Some(HERE),
        )
        .await
        .unwrap_err();
        assert!(err.is_forbidden());
        let text = err.to_string();
        assert!(
            text.contains("Grant the operator's service account get permission on namespaces"),
            "{text}"
        );
        assert!(!text.contains("deploy with an account"), "{text}");
    }

    /// Any other failure to read the Namespace is refused with its cause.
    #[tokio::test]
    async fn another_read_failure_is_refused_with_its_cause() {
        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next("/api/v1/namespaces/kube-system", 1, 503);
        let err = check(
            &api.client(),
            &Connection::of_context(Some("prod")),
            "cluster-a",
            Some(HERE),
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::Read { .. }), "{err}");
        let text = err.to_string();
        assert!(text.contains("Nothing was applied"), "{text}");
        assert!(text.contains("(HTTP 503 "), "{text}");
    }

    /// An unbound build on a cluster whose records carry another cluster's
    /// UID is told the records were restored, and to add the live UID.
    #[tokio::test]
    async fn restored_records_name_the_live_uid() {
        let api = FakeApi::new([kube_system(HERE), record("lab1", Some(ELSEWHERE))]);
        let connection = context("prod", "https://prod.example:6443");
        let err = check(&api.client(), &connection, "cluster-a", None)
            .await
            .unwrap_err();
        assert!(matches!(err, BindingError::UnboundRestored { .. }), "{err}");
        let text = err.to_string();
        assert!(
            text.contains(&format!(
                "lab1's Activation records here carry cluster.kubernetes.uid = \"{ELSEWHERE}\", but this cluster's kube-system namespace has UID \"{HERE}\", so those records came from another Kubernetes cluster."
            )),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "add cluster.kubernetes.uid = \"{HERE}\"; to cluster-a's definition."
            )),
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
            &Connection::of_context(None),
            "cluster-a",
            None,
        )
        .await
        .unwrap_err();
        assert!(err.is_forbidden());
        let text = err.to_string();
        assert!(
            text.contains("A previous deploy locked this cluster to a cluster.kubernetes.uid, cluster-a's definition does not set one, and Kix could not read the kube-system namespace (HTTP 403 Forbidden)"),
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
        let err = check(&api.client(), &connection, "cluster-a", None)
            .await
            .unwrap_err();
        assert!(matches!(err, BindingError::Unbound { .. }));
        let text = err.to_string();
        assert!(
            text.contains(&format!(
                "lab1 was deployed here with cluster.kubernetes.uid = \"{HERE}\" (the UID of this cluster's kube-system namespace), which locked this cluster to definitions that set that UID. cluster-a's definition does not set cluster.kubernetes.uid."
            )),
            "{text}"
        );
        assert!(
            text.contains(&format!(
                "If you targeted the wrong cluster, pass the right --context (currently pointing at https://prod.example:6443). If cluster-a belongs on this cluster, add cluster.kubernetes.uid = \"{HERE}\"; to cluster-a's definition. If the Kix cluster that set it no longer exists, remove the label from its records"
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
        let connection = Connection::of_context(None);
        check(&api.client(), &connection, "cluster-a", None)
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
        check(&api.client(), &connection, "cluster-a", None)
            .await
            .unwrap();
    }

    /// A record the CLI submits for the operator carries the build's UID as
    /// the label, so a later unbound build finds it; an unbound build's
    /// record carries none.
    #[tokio::test]
    async fn a_submitted_record_carries_the_label_of_a_bound_build() {
        use crate::cluster::activation::{Records, bound_record};
        use crate::cluster::discovery;
        let api = FakeApi::new([kube_system(HERE)]);
        let client = api.client();
        let discovery = discovery::discover_resources(&client).await.unwrap();
        let records = Records::open_installed(&client, &discovery).unwrap();
        records
            .submit("cluster-a-1", "cluster-a", "/nix/store/x", Some("h1"), None)
            .await
            .unwrap();
        assert_eq!(bound_record(&client).await.unwrap(), None);
        records
            .submit("lab1-1", "lab1", "/nix/store/y", Some("h2"), Some(HERE))
            .await
            .unwrap();
        let bound = bound_record(&client).await.unwrap().unwrap();
        assert_eq!((bound.cluster.as_str(), bound.uid.as_str()), ("lab1", HERE));
    }

    /// A failure to list the records refuses rather than passing an
    /// unbound build.
    #[tokio::test]
    async fn a_failed_record_listing_refuses_an_unbound_build() {
        let api = FakeApi::new([kube_system(HERE)]);
        api.fail_next(&format!("/apis/{}/activations", keys::API_VERSION), 1, 403);
        let err = check(
            &api.client(),
            &Connection::of_context(None),
            "cluster-a",
            None,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, BindingError::Records { .. }), "{err}");
    }
}
