use super::*;
use crate::cli::StatusCheck;
use document::{Kubernetes, Problem, build, selected};
use kix::cluster::drift::{DriftVerdict, ForeignOwner};
use kix::cluster::observe::{ClusterView, ExpectedFrom, ObjectView, Presence, Readiness};
use kix::manifest::types::ResourceId;

fn pinned(sha256: &str) -> PinnedInterface {
    PinnedInterface {
        consumer: "acme".into(),
        path: "kix-interface/prod.json".into(),
        sha256: sha256.into(),
    }
}

fn publishing(sha256: &str) -> Record {
    Record {
        published_interfaces: [("acme".to_string(), sha256.to_string())].into(),
        ..Record::default()
    }
}

fn note(live: Result<Option<Record>, RecordsError>) -> Option<String> {
    interface_note("acme-prod", "prod", &pinned("aa"), live).unwrap()
}

fn refused(code: u16) -> RecordsError {
    RecordsError {
        op: "list",
        name: None,
        source: kube::Error::Api(
            kube::core::Status::failure("refused", "Forbidden")
                .with_code(code)
                .boxed(),
        ),
    }
}

fn live(git_version: &str) -> Result<LiveVersion, kubernetes_version::ReadError> {
    Ok(LiveVersion {
        git_version: git_version.to_string(),
        version: kubernetes_version::Version::parse(git_version).unwrap(),
    })
}

/// A value Kix could not read gives a note that says why, and the
/// document carries `null` for it.
#[test]
fn an_unread_kubernetes_id_or_version_gives_a_note() {
    let id = KubernetesId::of(
        Ok("4d7b1c2e-9f3a-4b8e-a1c5-6d2e8f0a9b3c".into()),
        live("v1.31.4+k3s1"),
    );
    assert_eq!(
        id.uid.as_deref(),
        Some("4d7b1c2e-9f3a-4b8e-a1c5-6d2e8f0a9b3c")
    );
    assert_eq!(id.version.as_deref(), Some("v1.31.4+k3s1"));
    assert!(id.unread_notes().is_empty());

    let id = KubernetesId::of(
        Err(refused(403).source),
        Err(kubernetes_version::ReadError::Api(refused(503).source)),
    );
    assert_eq!((id.uid.as_deref(), id.version.as_deref()), (None, None));
    let notes = id.unread_notes();
    assert!(notes[0].contains("get on namespaces"), "{notes:?}");
    assert!(notes[1].contains("not read: HTTP 503"), "{notes:?}");
}

#[test]
fn the_same_interface_says_nothing() {
    assert_eq!(note(Ok(Some(publishing("aa")))), None);
}

#[test]
fn a_new_interface_says_to_commit_it() {
    assert_eq!(
        note(Ok(Some(publishing("bb")))).as_deref(),
        Some(
            "warning: 'acme-prod' was built with an older interface file than platform \
             'prod' is running now.\n  Next: copy 'prod's current interface file to \
             `kix-interface/prod.json`, commit it, and run `kix deploy acme-prod`."
        )
    );
}

#[test]
fn a_withdrawn_interface_says_so() {
    assert_eq!(
        note(Ok(Some(Record::default()))).as_deref(),
        Some(
            "warning: platform 'prod' no longer publishes an interface for consumer 'acme', \
             which 'acme-prod' was built with.\n  Next: ask the 'prod' platform team to \
             restore `consumers.acme`, or update 'acme-prod's `kix.interface` file and \
             redeploy 'acme-prod'."
        )
    );
}

#[test]
fn no_live_platform_says_so() {
    assert_eq!(
        note(Ok(None)).as_deref(),
        Some(
            "note: cannot verify whether 'acme-prod' matches platform 'prod': 'prod' has no \
             active deploy on this Kubernetes cluster."
        )
    );
}

#[test]
fn a_forbidden_read_says_so_and_another_failure_is_raised() {
    assert_eq!(
        note(Err(refused(403))).as_deref(),
        Some(
            "note: cannot verify whether 'acme-prod' matches platform 'prod': this \
             Kubernetes account is not allowed to read 'prod's deploy record (HTTP 403)."
        )
    );
    assert!(interface_note("acme-prod", "prod", &pinned("aa"), Err(refused(500))).is_err());
}

fn h(c: char) -> String {
    c.to_string().repeat(32)
}

fn object(
    c: char,
    kind: &str,
    ns: &str,
    name: &str,
    package: Option<&str>,
    presence: Presence,
) -> ObjectView {
    let present = matches!(presence, Presence::Present | Presence::External);
    ObjectView {
        identity_hash: h(c),
        rid: ResourceId {
            group: String::new(),
            kind: kind.into(),
            namespace: ns.into(),
            name: name.into(),
        },
        named: true,
        package: package.map(str::to_string),
        presence,
        content: present.then_some(DriftVerdict::InSync),
        readiness: Readiness::NotApplicable,
        depends_on: vec![],
    }
}

/// A cluster `shop` with one package of each kind of problem, one healthy
/// package, an object of a kind the account may not list, and a
/// cluster-level Namespace.
fn shop() -> Observation {
    let mut pg_config = object(
        'c',
        "ConfigMap",
        "db",
        "pg-config",
        Some("db/postgres"),
        Presence::Present,
    );
    pg_config.content = Some(DriftVerdict::Drifted {
        foreign: vec![ForeignOwner {
            manager: "kubectl-edit".into(),
            operation: "Update".into(),
            subresource: None,
            time: Some("2026-11-12T09:00:00+00:00".into()),
            paths: vec!["data.max_connections".into()],
            unshared_paths: vec!["data.max_connections".into()],
        }],
        unrecorded_scale: None,
    });
    let mut vault = object(
        'v',
        "Deployment",
        "vault",
        "vaultwarden",
        Some("vault/vaultwarden"),
        Presence::Present,
    );
    vault.readiness = Readiness::NotReady("0/1 ready, 0/1 updated".into());
    vault.depends_on = vec![h('s')];
    let mut stamped_later = object(
        'u',
        "ConfigMap",
        "vault",
        "vaultwarden-env",
        Some("vault/vaultwarden"),
        Presence::Present,
    );
    stamped_later.content = Some(DriftVerdict::Unstamped);
    let objects = vec![
        object(
            'i',
            "Deployment",
            "ingress",
            "ingress-nginx",
            Some("ingress/ingress-nginx"),
            Presence::Present,
        ),
        pg_config,
        object(
            'p',
            "StatefulSet",
            "db",
            "postgres",
            Some("db/postgres"),
            Presence::Present,
        ),
        vault,
        stamped_later,
        object(
            's',
            "Secret",
            "vault",
            "vaultwarden-db",
            Some("vault/vaultwarden"),
            Presence::Missing,
        ),
        object(
            'k',
            "Secret",
            "vault",
            "vaultwarden-admin",
            Some("vault/vaultwarden"),
            Presence::Unknown,
        ),
        object(
            'n',
            "Namespace",
            "_cluster",
            "vault",
            None,
            Presence::Present,
        ),
    ];
    Observation {
        clusters: vec![ClusterView {
            cluster: "shop".into(),
            record: Record {
                name: "shop-7f3a2b1c0d9e".into(),
                phase: "Active".into(),
                identity_hash: Some(h('r')),
                deployed_at: Some("2026-11-11T10:00:00Z".into()),
                ..Record::default()
            },
            expected_from: ExpectedFrom::Index,
            objects,
        }],
        unreadable: vec!["secrets".into()],
    }
}

fn kubernetes() -> Kubernetes {
    Kubernetes {
        context: Some("prod".into()),
        uid: Some("4d7b1c2e".into()),
        version: Some("v1.33.1".into()),
    }
}

fn document(checks: &[StatusCheck], package: Option<&str>) -> StatusDocument {
    build(
        &shop(),
        kubernetes(),
        &BTreeMap::new(),
        &selected(checks),
        package,
    )
    .unwrap()
}

fn two_days_ago(_: &str) -> String {
    "2d0h ago".into()
}

/// Every check runs by default. A missing object, a changed one, and one
/// that is not ready each count, and the command exits 2.
#[test]
fn every_check_runs_and_a_problem_exits_2() {
    let doc = document(&[], None);
    assert_eq!(
        doc.checks,
        [
            StatusCheck::Presence,
            StatusCheck::Drift,
            StatusCheck::Readiness
        ]
    );
    let s = doc.summary;
    assert_eq!(
        (s.resources, s.ok, s.missing, s.changed, s.not_ready),
        (8, 3, 1, 1, 1)
    );
    assert_eq!(s.not_checked, 2);
    assert_eq!(doc.exit(), Exit::StatusFoundProblem);

    let vault = &doc.clusters[0].packages[2];
    assert_eq!(vault.name.as_deref(), Some("vault/vaultwarden"));
    let secret = vault
        .resources
        .iter()
        .find(|r| r.name == "vaultwarden-db")
        .unwrap();
    assert_eq!(secret.problems, [Problem::Missing]);
    assert_eq!(secret.needed_by, ["Deployment vault/vaultwarden"]);
    let admin = vault
        .resources
        .iter()
        .find(|r| r.name == "vaultwarden-admin")
        .unwrap();
    assert!(admin.problems.is_empty() && admin.not_checked);
    assert_eq!(doc.clusters[0].packages.last().unwrap().name, None);
}

/// Only the selected checks count. A missing object counts under every
/// check, because none can run on it.
#[test]
fn only_the_selected_checks_count() {
    let doc = document(&[StatusCheck::Drift], None);
    let s = doc.summary;
    assert_eq!((s.missing, s.changed, s.not_ready), (1, 1, 0));
    let vault = &doc.clusters[0].packages[2].resources;
    assert!(vault.iter().all(|r| r.ready.is_none()));

    let doc = document(&[StatusCheck::Readiness, StatusCheck::Readiness], None);
    assert_eq!(doc.checks, [StatusCheck::Readiness]);
    let s = doc.summary;
    assert_eq!((s.missing, s.changed, s.not_ready), (1, 0, 1));
    assert!(
        doc.clusters[0]
            .packages
            .iter()
            .flat_map(|p| &p.resources)
            .all(|r| r.drift.is_none())
    );
}

/// Objects of a kind the account may not list are not checked, and pass.
#[test]
fn objects_the_account_cannot_see_pass_as_not_checked() {
    let doc = document(&[], Some("ingress-nginx"));
    assert_eq!(doc.exit(), Exit::Success);
    let mut seen = shop();
    seen.clusters[0]
        .objects
        .retain(|o| o.presence != Presence::Missing && o.package.as_deref() != Some("db/postgres"));
    seen.clusters[0]
        .objects
        .iter_mut()
        .for_each(|o| o.readiness = Readiness::NotApplicable);
    let doc = build(&seen, kubernetes(), &BTreeMap::new(), &selected(&[]), None).unwrap();
    assert_eq!(doc.summary.not_checked, 2);
    assert_eq!(doc.exit(), Exit::Success);
}

/// `--package` takes the instance name or `namespace/instance`, and names
/// the packages when none matches.
#[test]
fn package_narrows_to_one_package() {
    for name in ["postgres", "db/postgres"] {
        let doc = document(&[], Some(name));
        let packages: Vec<_> = doc.clusters[0]
            .packages
            .iter()
            .map(|p| p.name.clone())
            .collect();
        assert_eq!(packages, [Some("db/postgres".to_string())]);
        assert_eq!(doc.summary.resources, 2);
    }
    let err = build(
        &shop(),
        kubernetes(),
        &BTreeMap::new(),
        &selected(&[]),
        Some("redis"),
    )
    .unwrap_err();
    assert_eq!(
        err,
        "No package 'redis' in the current deploy. Packages: db/postgres, \
         ingress/ingress-nginx, vault/vaultwarden."
    );
}

/// With many packages, a `--package` that matches none names the closest.
#[test]
fn an_unknown_package_names_the_closest_of_many() {
    let mut seen = shop();
    let template = seen.clusters[0].objects[0].clone();
    for (i, name) in ["redis", "redis-cache", "rabbitmq", "minio", "loki", "tempo"]
        .iter()
        .chain(&["mimir", "grafana", "alloy", "cilium", "kyverno"])
        .enumerate()
    {
        let mut o = template.clone();
        o.identity_hash = format!("{i:032}");
        o.rid.name = name.to_string();
        o.package = Some(format!("apps/{name}"));
        seen.clusters[0].objects.push(o);
    }
    let err = build(
        &seen,
        kubernetes(),
        &BTreeMap::new(),
        &selected(&[]),
        Some("rediss"),
    )
    .unwrap_err();
    assert!(
        err.starts_with(
            "No package 'rediss' in the current deploy. It has 14 packages. \
             The closest names: apps/redis, apps/redis-cache,"
        ),
        "{err}"
    );
}

/// The next step adds `--force-conflicts` only when another manager owns
/// fields of a changed object that Kix does not also own, because a deploy
/// stops only on those fields.
#[test]
fn the_next_step_forces_conflicts_only_for_another_manager() {
    let text = |seen: &Observation| {
        let doc = build(seen, kubernetes(), &BTreeMap::new(), &selected(&[]), None).unwrap();
        text::render(&doc, text::Detail::Packages, &two_days_ago)
    };
    let changed = text(&shop());
    assert!(
        changed.contains(
            "Next: run `kix deploy shop --reconcile --force-conflicts` to put back what is \
             missing or changed and take back the fields that kubectl-edit owns."
        ),
        "{changed}"
    );

    // kubeadm owned `data` before Kix took the object and shares it with
    // Kix, so it changed nothing and cannot conflict.
    let mut shared = shop();
    for o in &mut shared.clusters[0].objects {
        if o.rid.name == "pg-config" {
            o.content = Some(DriftVerdict::Drifted {
                foreign: vec![ForeignOwner {
                    manager: "kubeadm".into(),
                    operation: "Update".into(),
                    subresource: None,
                    time: None,
                    paths: vec!["data.max_connections".into()],
                    unshared_paths: vec![],
                }],
                unrecorded_scale: None,
            });
        }
    }
    let shared = text(&shared);
    assert!(
        shared.contains("Next: run `kix deploy shop --reconcile` to put back"),
        "{shared}"
    );

    let mut scaled = shop();
    for o in &mut scaled.clusters[0].objects {
        if o.rid.name == "pg-config" {
            o.content = Some(DriftVerdict::Drifted {
                foreign: vec![],
                unrecorded_scale: None,
            });
        }
    }
    let scaled = text(&scaled);
    assert!(
        scaled.contains("Next: run `kix deploy shop --reconcile` to put back"),
        "{scaled}"
    );
}

/// A record that lists no objects, with its own object gone, cannot be
/// answered.
#[test]
fn a_deploy_with_no_list_of_objects_exits_1() {
    let mut seen = shop();
    seen.clusters[0].expected_from = ExpectedFrom::Nothing;
    seen.clusters[0].objects.clear();
    let doc = build(&seen, kubernetes(), &BTreeMap::new(), &selected(&[]), None).unwrap();
    assert_eq!(doc.exit(), Exit::Failure);
}

#[test]
fn the_text_output() {
    let doc = document(&[], None);
    insta::assert_snapshot!(
        "status_text",
        text::render(&doc, text::Detail::Packages, &two_days_ago)
    );
    insta::assert_snapshot!(
        "status_text_quiet",
        text::render(&doc, text::Detail::Problems, &two_days_ago)
    );
    insta::assert_snapshot!(
        "status_text_verbose",
        text::render(&doc, text::Detail::Everything, &two_days_ago)
    );
}

#[test]
fn the_json_output() {
    let doc = document(&[], Some("vaultwarden"));
    insta::assert_snapshot!("status_json", serde_json::to_string_pretty(&doc).unwrap());
}
