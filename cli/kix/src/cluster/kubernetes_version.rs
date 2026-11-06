//! The Kubernetes version a build was checked against.
//!
//! A cluster definition may set `k8sVersion`, and the build checks every
//! package's `meta.k8s.minVersion` and `maxVersion` against it. The build
//! carries the value in `kix-packages.json`
//! ([`StoreGraph::kubernetes_version`]). [`check`] compares it with the
//! version the API server reports at `/version`, as precisely as the
//! definition writes it: `"1.31"` matches any 1.31.x, `"1.31.4"` matches only
//! 1.31.4. A vendor suffix on either side (`v1.31.4+k3s1`,
//! `v1.31.2-gke.1209000`) is ignored.
//!
//! [`check`] runs beside [`binding::check`] in deploy, plan, and the
//! operator's Queued branch, after the command connects and before it reads
//! or writes anything else. A rollback goes ahead on a mismatch and prints
//! [`note`], because a Kubernetes upgrade must not block a rollback during
//! an incident. The operator keeps repairing an Active record on a mismatch
//! for the same reason. Read-only commands such as `kix diff` do not check.
//! A definition that leaves `k8sVersion` unset is not checked and gets no
//! message.
//!
//! [`StoreGraph::kubernetes_version`]: crate::eval::store_graph::StoreGraph::kubernetes_version
//! [`binding::check`]: super::binding::check

use std::fmt;

use kube::client::Client;
use serde::Deserialize;
use thiserror::Error;

use super::binding::Connection;
use super::errors::api_error;

/// The numbers of a Kubernetes version: `[1, 31, 4]` for `v1.31.4+k3s1`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version(Vec<u64>);

impl Version {
    /// Parse the numbers of `text`: an optional leading `v`, then numbers
    /// separated by dots, up to the `-` or `+` that starts a vendor suffix.
    /// Returns `None` when there is no number before the suffix, a part is
    /// not a number, or every part is zero, which is what a development
    /// build reports (`v0.0.0-master+$Format:%H$`).
    pub fn parse(text: &str) -> Option<Version> {
        let text = text.trim();
        let text = text.strip_prefix(['v', 'V']).unwrap_or(text);
        let core = text.split(['-', '+']).next().unwrap_or("");
        if core.is_empty() {
            return None;
        }
        let parts = core
            .split('.')
            .map(|part| part.parse::<u64>().ok())
            .collect::<Option<Vec<u64>>>()?;
        if parts.iter().all(|&n| n == 0) {
            return None;
        }
        Some(Version(parts))
    }

    /// Return whether `live` is this version, compared over the parts this
    /// version writes. When `live` is known less precisely than this version
    /// (the server reported only `major` and `minor`), the comparison stops
    /// at the parts it knows.
    pub fn accepts(&self, live: &Version) -> bool {
        let n = self.0.len().min(live.0.len());
        self.0[..n] == live.0[..n]
    }

    /// Return `live` written with as many parts as this version, which is
    /// the value to set in the definition.
    pub fn suggest(&self, live: &Version) -> String {
        let n = self.0.len().min(live.0.len());
        Version(live.0[..n].to_vec()).to_string()
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let parts: Vec<String> = self.0.iter().map(u64::to_string).collect();
        f.write_str(&parts.join("."))
    }
}

/// What the API server reports at `/version`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveVersion {
    /// `gitVersion` as reported, such as `v1.31.4+k3s1`.
    pub git_version: String,
    /// The numbers of `gitVersion`, or of `major` and `minor` (a trailing
    /// `+` on `minor` removed, as EKS and GKE write it) when `gitVersion`
    /// does not parse or is all zeros.
    pub version: Version,
}

/// The fields of `/version` the check reads. The server sends more, and a
/// field it leaves out reads as empty.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VersionInfo {
    #[serde(default)]
    git_version: String,
    #[serde(default)]
    major: String,
    #[serde(default)]
    minor: String,
}

/// Why the live version could not be read.
#[derive(Error, Debug)]
pub enum ReadError {
    /// The request failed.
    #[error("{}", api_error(.0))]
    Api(#[source] kube::Error),
    /// The server answered, and no field held a version.
    #[error(
        "the API server answered, but its gitVersion \"{git_version}\", major \"{major}\", \
         and minor \"{minor}\" fields do not contain a version Kix can read"
    )]
    Unparsed {
        git_version: String,
        major: String,
        minor: String,
    },
}

/// Return the Kubernetes version the API server behind `client` reports.
pub async fn live_version(client: &Client) -> Result<LiveVersion, ReadError> {
    let request = http::Request::builder()
        .uri("/version")
        .body(Vec::new())
        .map_err(|e| ReadError::Api(kube::Error::HttpError(e)))?;
    let info: VersionInfo = client.request(request).await.map_err(ReadError::Api)?;
    let version = Version::parse(&info.git_version).or_else(|| {
        let minor = info.minor.trim_end_matches('+');
        Version::parse(&format!("{}.{minor}", info.major))
    });
    match version {
        Some(version) => Ok(LiveVersion {
            git_version: info.git_version,
            version,
        }),
        None => Err(ReadError::Unparsed {
            git_version: info.git_version,
            major: info.major,
            minor: info.minor,
        }),
    }
}

/// Why a build may not be applied to the Kubernetes cluster a command
/// connected to. Every message says that nothing was applied.
#[derive(Error, Debug)]
pub enum VersionError {
    /// The cluster runs a version the definition does not name.
    #[error(
        "Kix refused to deploy {cluster} to {}. Nothing was applied. \
         {cluster}'s definition sets k8sVersion = \"{declared}\", but this cluster runs {}. \
         Package version checks used {declared}, so some packages in this build may not work \
         on this cluster. Set k8sVersion = \"{suggested}\"; in {cluster}'s definition, build \
         again, and deploy again. If you are upgrading Kubernetes, make this change after the \
         upgrade finishes.",
        connection.describe(),
        live.git_version
    )]
    Mismatch {
        cluster: String,
        declared: String,
        live: LiveVersion,
        /// The live version written as precisely as `declared`.
        suggested: String,
        connection: Connection,
    },

    /// The cluster runs a version the platform's interface file does not
    /// name. The definition sets no `k8sVersion` of its own.
    #[error(
        "Kix refused to deploy {cluster} to {}. Nothing was applied. \
         {cluster} loads its interface file from {platform} with kix.interface, which sets \
         k8sVersion = \"{declared}\", but this cluster runs {}. Package version checks used \
         {declared}, so some packages in this build may not work on this cluster. Export a \
         new interface file from {platform}, build {cluster} against it, and deploy again. \
         Or set k8sVersion = \"{suggested}\"; in {cluster}'s definition to override the \
         interface file, build again, and deploy again. If you are upgrading Kubernetes, \
         make this change after the upgrade finishes.",
        connection.describe(),
        live.git_version
    )]
    MismatchInherited {
        cluster: String,
        declared: String,
        live: LiveVersion,
        /// The live version written as precisely as `declared`.
        suggested: String,
        /// The platform whose interface file supplied `declared`.
        platform: String,
        connection: Connection,
    },

    /// Reading `/version` failed.
    #[error(
        "Kix refused to deploy {cluster} to {} because it could not read the cluster's \
         Kubernetes version ({source}). Nothing was applied. Kix checks this version because \
         {cluster}'s definition sets k8sVersion = \"{declared}\". Check that the API server \
         is reachable and healthy, then try again.",
        connection.describe()
    )]
    Read {
        cluster: String,
        declared: String,
        connection: Connection,
        #[source]
        source: ReadError,
    },
}

/// Refuse the build of Kix cluster `cluster`, whose definition sets
/// `k8sVersion = declared` (`None` when unset), unless the cluster behind
/// `client` runs that version. `platform` names the platform whose interface
/// file supplied the value through `kix.interface`, or is `None` when the
/// definition writes it, which decides which fix the refusal gives. An unset
/// version passes without a request.
pub async fn check(
    client: &Client,
    connection: &Connection,
    cluster: &str,
    declared: Option<&str>,
    platform: Option<&str>,
) -> Result<(), VersionError> {
    let Some(declared) = declared else {
        return Ok(());
    };
    // The definition's option type admits only strings this parses, so an
    // index that holds something else was edited by hand.
    let Some(wanted) = Version::parse(declared) else {
        return Ok(());
    };
    let live = live_version(client)
        .await
        .map_err(|source| VersionError::Read {
            cluster: cluster.to_string(),
            declared: declared.to_string(),
            connection: connection.clone(),
            source,
        })?;
    if wanted.accepts(&live.version) {
        return Ok(());
    }
    let suggested = wanted.suggest(&live.version);
    Err(match platform {
        Some(platform) => VersionError::MismatchInherited {
            cluster: cluster.to_string(),
            declared: declared.to_string(),
            suggested,
            live,
            platform: platform.to_string(),
            connection: connection.clone(),
        },
        None => VersionError::Mismatch {
            cluster: cluster.to_string(),
            declared: declared.to_string(),
            suggested,
            live,
            connection: connection.clone(),
        },
    })
}

impl VersionError {
    /// Return `true` when the refusal is for a version the cluster does not
    /// run, which a change to the build resolves. A failed read is not one.
    pub fn is_mismatch(&self) -> bool {
        matches!(
            self,
            VersionError::Mismatch { .. } | VersionError::MismatchInherited { .. }
        )
    }
}

/// Return the one line a rollback prints when the target build of `cluster`
/// was made for a version (`declared`, `None` when unset) the cluster behind
/// `client` does not run, and `None` otherwise. A version that cannot be
/// read gives no line either: the rollback goes ahead in every case.
pub async fn note(client: &Client, cluster: &str, declared: Option<&str>) -> Option<String> {
    let declared = declared?;
    let wanted = Version::parse(declared)?;
    let live = live_version(client).await.ok()?;
    if wanted.accepts(&live.version) {
        return None;
    }
    Some(format!(
        "This rollback build was made for Kubernetes {declared}, but this cluster runs {}. \
         Kix is rolling back anyway so an incident recovery is not blocked. After the \
         incident, set k8sVersion = \"{}\"; in {cluster}'s definition, build again, and \
         deploy again.",
        live.git_version,
        wanted.suggest(&live.version)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::fake_api::FakeApi;

    fn parts(text: &str) -> Option<Vec<u64>> {
        Version::parse(text).map(|v| v.0)
    }

    /// `gitVersion` as each distribution writes it parses to its numbers.
    #[test]
    fn git_version_forms_parse_to_their_numbers() {
        let cases = [
            ("v1.31.4", vec![1, 31, 4]),             // kind, kubeadm
            ("v1.31.4+k3s1", vec![1, 31, 4]),        // k3s
            ("v1.31.4+rke2r1", vec![1, 31, 4]),      // rke2
            ("v1.31.4-eks-2d5f260", vec![1, 31, 4]), // EKS
            ("v1.31.2-gke.1209000", vec![1, 31, 2]), // GKE
            ("v1.31.3", vec![1, 31, 3]),             // AKS
            ("1.31", vec![1, 31]),                   // a definition's k8sVersion
            ("V1.31.0-rc.1", vec![1, 31, 0]),        // a prerelease
            ("1.31.4", vec![1, 31, 4]),
        ];
        for (text, want) in cases {
            assert_eq!(parts(text), Some(want), "{text}");
        }
        for text in [
            "",
            "v",
            "latest",
            "1.x",
            "v-k3s1",
            "+k3s1",
            "v0.0.0-master+$Format:%H$", // a development build
        ] {
            assert_eq!(parts(text), None, "{text:?}");
        }
    }

    /// A trailing `+` on `minor`, as EKS and GKE report it, is dropped when
    /// `gitVersion` is unusable.
    #[tokio::test]
    async fn major_and_minor_stand_in_when_git_version_does_not_parse() {
        let api = FakeApi::new([]);
        api.serve_version("unknown", "1", "31+");
        let live = live_version(&api.client()).await.unwrap();
        assert_eq!(live.version, Version(vec![1, 31]));
        assert_eq!(live.git_version, "unknown");

        // A development build's gitVersion is all zeros, so major and
        // minor stand in for it too.
        let api = FakeApi::new([]);
        api.serve_version("v0.0.0-master+$Format:%H$", "1", "32");
        let live = live_version(&api.client()).await.unwrap();
        assert_eq!(live.version, Version(vec![1, 32]));

        let api = FakeApi::new([]);
        api.serve_version("", "", "");
        let err = live_version(&api.client()).await.unwrap_err();
        assert!(matches!(err, ReadError::Unparsed { .. }), "{err}");
    }

    /// A declared version is compared only as precisely as it is written.
    #[test]
    fn a_declared_version_is_compared_as_precisely_as_it_is_written() {
        let v = |t: &str| Version::parse(t).unwrap();
        assert!(v("1.31").accepts(&v("v1.31.4+k3s1")));
        assert!(v("1.31").accepts(&v("v1.31.0")));
        assert!(!v("1.31").accepts(&v("v1.32.0")));
        assert!(!v("1.31").accepts(&v("v1.30.9")));
        assert!(v("1.31.4").accepts(&v("v1.31.4-eks-2d5f260")));
        assert!(!v("1.31.4").accepts(&v("v1.31.5")));
        assert!(v("v1.31.2-gke.1209000").accepts(&v("v1.31.2-gke.1300000")));
        assert!(!v("v1.31.2-gke.1209000").accepts(&v("v1.31.3-gke.1209000")));
        // A live version known only to the minor cannot contradict a patch.
        assert!(v("1.31.4").accepts(&v("1.31")));
        assert!(!v("1.31.4").accepts(&v("1.30")));
    }

    /// The suggested value keeps the precision the definition wrote.
    #[test]
    fn the_suggestion_keeps_the_declared_precision() {
        let v = |t: &str| Version::parse(t).unwrap();
        assert_eq!(v("1.30").suggest(&v("v1.31.4+k3s1")), "1.31");
        assert_eq!(v("1.30.2").suggest(&v("v1.31.4+k3s1")), "1.31.4");
        assert_eq!(v("v1.30.2-gke.1").suggest(&v("v1.31.4-gke.2")), "1.31.4");
        assert_eq!(v("1.30.2").suggest(&v("1.31")), "1.31");
    }

    /// A matching cluster passes after the one read of `/version`.
    #[tokio::test]
    async fn a_matching_cluster_passes() {
        let api = FakeApi::new([]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        let connection = Connection::of_context(Some("prod"));
        check(&api.client(), &connection, "cluster-a", Some("1.31"), None)
            .await
            .unwrap();
        assert_eq!(api.requests(), vec!["GET /version".to_string()]);
    }

    /// An unset version makes no request and no message.
    #[tokio::test]
    async fn an_unset_version_is_not_checked() {
        let api = FakeApi::new([]);
        let connection = Connection::of_context(Some("prod"));
        check(&api.client(), &connection, "cluster-a", None, None)
            .await
            .unwrap();
        assert!(api.requests().is_empty(), "{:?}", api.requests());
        assert_eq!(note(&api.client(), "cluster-a", None).await, None);
        assert!(api.requests().is_empty(), "{:?}", api.requests());
    }

    /// A mismatch is refused with both versions, the context, and the value
    /// to set, written as precisely as the definition wrote it.
    #[tokio::test]
    async fn a_mismatch_is_refused_with_the_value_to_set() {
        let api = FakeApi::new([]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        let connection = Connection::Context {
            name: Some("prod".to_string()),
            server: Some("https://prod.example:6443".to_string()),
        };
        let err = check(&api.client(), &connection, "cluster-a", Some("1.30"), None)
            .await
            .unwrap_err();
        assert!(matches!(err, VersionError::Mismatch { .. }), "{err}");
        assert!(err.is_mismatch());
        assert_eq!(
            err.to_string(),
            "Kix refused to deploy cluster-a to context prod (https://prod.example:6443). \
             Nothing was applied. cluster-a's definition sets k8sVersion = \"1.30\", but this \
             cluster runs v1.31.4+k3s1. Package version checks used 1.30, so some packages in \
             this build may not work on this cluster. Set k8sVersion = \"1.31\"; in \
             cluster-a's definition, build again, and deploy again. If you are upgrading \
             Kubernetes, make this change after the upgrade finishes."
        );

        let err = check(
            &api.client(),
            &Connection::InCluster,
            "cluster-a",
            Some("1.30.2"),
            None,
        )
        .await
        .unwrap_err()
        .to_string();
        assert!(
            err.starts_with(
                "Kix refused to deploy cluster-a to the API server the operator runs on. Nothing was applied."
            ),
            "{err}"
        );
        assert!(
            err.contains("Set k8sVersion = \"1.31.4\"; in cluster-a's definition"),
            "{err}"
        );
    }

    /// A version that came from a platform's interface file is refused with
    /// both fixes: a new interface file, or an override in the definition.
    #[tokio::test]
    async fn an_inherited_mismatch_names_the_platform_and_both_fixes() {
        let api = FakeApi::new([]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        let connection = Connection::Context {
            name: Some("acme".to_string()),
            server: Some("https://acme.example:6443".to_string()),
        };
        let err = check(
            &api.client(),
            &connection,
            "acme-prod",
            Some("1.30"),
            Some("prod"),
        )
        .await
        .unwrap_err();
        assert!(
            matches!(err, VersionError::MismatchInherited { .. }),
            "{err}"
        );
        assert!(err.is_mismatch());
        assert_eq!(
            err.to_string(),
            "Kix refused to deploy acme-prod to context acme (https://acme.example:6443). \
             Nothing was applied. acme-prod loads its interface file from prod with \
             kix.interface, which sets k8sVersion = \"1.30\", but this cluster runs \
             v1.31.4+k3s1. Package version checks used 1.30, so some packages in this build \
             may not work on this cluster. Export a new interface file from prod, build \
             acme-prod against it, and deploy again. Or set k8sVersion = \"1.31\"; in \
             acme-prod's definition to override the interface file, build again, and deploy \
             again. If you are upgrading Kubernetes, make this change after the upgrade \
             finishes."
        );
        // The platform is not named when the version matches.
        check(
            &api.client(),
            &connection,
            "acme-prod",
            Some("1.31"),
            Some("prod"),
        )
        .await
        .unwrap();
    }

    /// A failed read of `/version` refuses with its cause.
    #[tokio::test]
    async fn a_failed_read_is_refused_with_its_cause() {
        let api = FakeApi::new([]);
        api.fail_next("/version", 1, 503);
        let err = check(
            &api.client(),
            &Connection::of_context(Some("prod")),
            "cluster-a",
            Some("1.31"),
            None,
        )
        .await
        .unwrap_err();
        assert!(matches!(err, VersionError::Read { .. }), "{err}");
        assert!(!err.is_mismatch());
        let text = err.to_string();
        assert!(text.contains("Nothing was applied"), "{text}");
        assert!(
            text.contains("could not read the cluster's Kubernetes version (HTTP 503 "),
            "{text}"
        );
    }

    /// A rollback gets one line on a mismatch and none otherwise, including
    /// when the version cannot be read.
    #[tokio::test]
    async fn a_rollback_gets_one_line_on_a_mismatch_only() {
        let api = FakeApi::new([]);
        api.serve_version("v1.31.4+k3s1", "1", "31");
        let line = note(&api.client(), "cluster-a", Some("1.30"))
            .await
            .unwrap();
        assert_eq!(
            line,
            "This rollback build was made for Kubernetes 1.30, but this cluster runs \
             v1.31.4+k3s1. Kix is rolling back anyway so an incident recovery is not blocked. \
             After the incident, set k8sVersion = \"1.31\"; in cluster-a's definition, build \
             again, and deploy again."
        );
        assert_eq!(note(&api.client(), "cluster-a", Some("1.31")).await, None);

        let api = FakeApi::new([]);
        api.fail_next("/version", 1, 503);
        assert_eq!(note(&api.client(), "cluster-a", Some("1.30")).await, None);
    }
}
