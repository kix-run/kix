//! Unit tests for graph diffs, secret redaction, and prune splitting.

use super::*;

mod diff_graph_tests {
    use super::fixtures::*;
    use super::*;
    use crate::manifest::keys;
    use serde_json::{Value, json};

    /// Serialize the `packages` section of the plan document for `diff`.
    fn packages_json(diff: &PackageDiff, detail: document::Detail) -> Value {
        serde_json::to_value(document::Packages::of(diff, detail)).expect("packages serialize")
    }

    /// An annotation whose key begins with a propagated one is content:
    /// the plan shows its change.
    #[test]
    fn an_annotation_named_after_a_propagated_one_is_a_real_change() {
        let path = |key: &str| format!("$.metadata.annotations.{key}");
        assert!(is_propagation_path(&path(keys::IDENTITY_HASH)));
        for key in [
            format!("{}.x", keys::IDENTITY_HASH),
            format!("{}.extra", keys::DEPENDS_ON),
        ] {
            assert!(!is_propagation_path(&path(&key)), "{key}");
        }
    }

    /// The reported difference has to read old-to-new: the value the
    /// cluster has now on the `old` side, the value the build wants on
    /// the `new` side. Rendering them the other way round tells the
    /// reader to expect the opposite of what a deploy would do.
    #[test]
    fn a_changed_value_is_reported_from_old_to_new() {
        let mut new = baseline();
        new[0] = record("c-new", &h("rec2"));
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        let d = diff_of(&baseline(), &new);

        let change = d
            .changed
            .iter()
            .find(|c| c.key == "app/web")
            .expect("web package changed");
        let (_, diffs) = change
            .resource_diffs
            .iter()
            .find(|(id, _)| id.kind == "ConfigMap")
            .expect("ConfigMap diff");
        let d0 = diffs.iter().find(|d| d.path == "$.spec.k").expect("spec.k");

        assert_eq!(
            d0.a_value.as_ref().and_then(|v| v.as_str()),
            Some("v"),
            "side a is labelled `old`, so it must carry what the old side had"
        );
        assert_eq!(
            d0.b_value.as_ref().and_then(|v| v.as_str()),
            Some("wanted"),
            "side b is labelled `new`, so it must carry what the build wants"
        );
    }

    /// A field only the build has is an addition, not a removal.
    #[test]
    fn a_field_only_the_new_side_has_is_an_addition() {
        let mut new = baseline();
        new[0] = record("c-new", &h("rec2"));
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "v", "added": "yes"}),
        );
        let d = diff_of(&baseline(), &new);
        let change = d.changed.iter().find(|c| c.key == "app/web").unwrap();
        let (_, diffs) = change
            .resource_diffs
            .iter()
            .find(|(id, _)| id.kind == "ConfigMap")
            .unwrap();
        let d0 = diffs
            .iter()
            .find(|d| d.path == "$.spec.added")
            .expect("spec.added");
        assert_eq!(
            d0.kind,
            crate::manifest::diff::DiffKind::ExtraInB,
            "a field the build adds must read as extra on the new side"
        );
    }

    /// The spellings `kix diff` reported on a converged kind cluster when
    /// the live objects carried no applied-hash stamp to compare by: a
    /// package whose live objects differ from its build only in them reads
    /// unchanged.
    #[test]
    fn server_spellings_of_the_built_objects_read_unchanged() {
        let pod = |live: bool| {
            let mut container = json!({
                "name": "app",
                "image": "app:1",
                "env": [{"name": "POD", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}}],
                "resources": {"limits": {"cpu": 1}},
                "readinessProbe": {"httpGet": {"path": "/"}, "failureThreshold": null},
                "volumeMounts": [{"name": "s", "mountPath": "/s", "readOnly": false}],
                "envFrom": [],
            });
            if live {
                container["env"][0]["valueFrom"]["fieldRef"]["apiVersion"] = json!("v1");
                container["resources"]["limits"]["cpu"] = json!("1");
                container["readinessProbe"]["failureThreshold"] = json!(3);
                let c = container.as_object_mut().unwrap();
                c.remove("envFrom");
                c["volumeMounts"][0]
                    .as_object_mut()
                    .unwrap()
                    .remove("readOnly");
            }
            let mut template =
                json!({"metadata": {"annotations": null}, "spec": {"containers": [container]}});
            if live {
                template["metadata"] = json!({});
            }
            template
        };
        let claim = |live: bool| {
            let mut claim = json!({
                "metadata": {"name": "data"},
                "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "8Gi"}}},
            });
            if live {
                claim["apiVersion"] = json!("v1");
                claim["kind"] = json!("PersistentVolumeClaim");
                claim["spec"]["volumeMode"] = json!("Filesystem");
                claim["status"] = json!({"phase": "Pending"});
            }
            claim
        };
        let side = |live: bool| {
            vec![
                record("c-1", &h("rec")),
                package_instance("app", "web", "1.0.0", &h("pi")),
                stamped(
                    "StatefulSet",
                    "app",
                    "web",
                    ("app", "web"),
                    &h("sts"),
                    json!({"template": pod(live), "volumeClaimTemplates": [claim(live)]}),
                ),
            ]
        };
        // A build names each store path by the resource's identity hash,
        // which is how a live object finds the manifest it came from.
        let synthetic = StoreGraph::synthesize(&side(false), &StoreGraph::empty("c"));
        let rename = |p: &std::path::PathBuf| {
            let manifest = &synthetic.resources[p].manifest;
            let hash = keys::get(manifest, keys::IDENTITY_HASH).unwrap();
            std::path::PathBuf::from(format!("/nix/store/{hash}-k8s"))
        };
        let mut build = StoreGraph::empty("c");
        for (path, node) in &synthetic.resources {
            let mut node = node.clone();
            node.store_path = rename(path);
            build.resources.insert(rename(path), node);
        }
        for (path, owner) in &synthetic.resource_owner {
            build.resource_owner.insert(rename(path), rename(owner));
        }
        for (path, pkg) in &synthetic.packages {
            let mut pkg = pkg.clone();
            pkg.store_path = rename(path);
            pkg.resource_paths = pkg.resource_paths.iter().map(&rename).collect();
            build.packages.insert(rename(path), pkg);
        }
        let live = StoreGraph::synthesize(&side(true), &build);

        let d = diff_graphs(&live, &build);
        let changed: Vec<&str> = d.changed.iter().map(|c| c.key.as_str()).collect();
        assert!(!d.has_changes(), "unexpected changes: {changed:?}");
        assert_eq!(d.unchanged, 1);
    }

    #[test]
    fn identical_sides_have_nothing_to_report() {
        let d = diff_of(&baseline(), &baseline());
        assert!(!d.has_changes(), "unexpected changes");
        assert_eq!(d.unchanged, 1);
        assert_eq!(d.activation, None);
    }

    #[test]
    fn a_content_change_is_modified_and_its_dependants_are_dep_affected() {
        let mut new = baseline();
        new[0] = record("c-new", &h("rec2"));
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "v2"}),
        );
        // The Deployment only saw its dependency's hash move.
        new[4]["metadata"]["annotations"][keys::DEPENDS_ON] = json!(h("cm2"));
        new[4]["metadata"]["annotations"][keys::IDENTITY_HASH] = json!(h("dep2"));

        let d = diff_of(&baseline(), &new);
        assert_eq!(d.changed.len(), 1);
        let c = &d.changed[0];
        let modified: Vec<String> = c
            .resource_diffs
            .iter()
            .map(|(id, _)| id.to_string())
            .collect();
        assert_eq!(modified, vec!["ConfigMap/web@app"]);
        let dep: Vec<String> = c
            .dep_affected_resources
            .iter()
            .map(|id| id.to_string())
            .collect();
        assert_eq!(dep, vec!["Deployment/web@app"]);
        assert!(d.cluster_level.is_none());
        assert_eq!(
            d.activation,
            Some(RecordChange {
                old: Some("c-old".into()),
                new: Some("c-new".into())
            })
        );
    }

    #[test]
    fn a_reordered_list_is_modified_and_shows_the_new_order() {
        // The last `--auth` flag wins, so the order is the setting.
        let deployment = |hash: &str, args: Value, app_first: bool| {
            let app = json!({"name": "app", "args": args});
            let proxy = json!({"name": "proxy"});
            let containers = if app_first {
                json!([app, proxy])
            } else {
                json!([proxy, app])
            };
            let spec = json!({"template": {"spec": {"containers": containers}}});
            stamped("Deployment", "app", "web", ("app", "web"), hash, spec)
        };
        let mut old = baseline();
        old[4] = deployment(&h("dep"), json!(["--auth=off", "--auth=on"]), true);
        let cases = [
            (
                json!(["--auth=on", "--auth=off"]),
                true,
                "$.spec.template.spec.containers[app].args",
            ),
            (
                json!(["--auth=off", "--auth=on"]),
                false,
                "$.spec.template.spec.containers",
            ),
        ];
        for (args, app_first, path) in cases {
            let mut new = baseline();
            new[4] = deployment(&h("dep2"), args, app_first);
            let d = diff_of(&old, &new);
            let c = &d.changed[0];
            assert!(c.dep_affected_resources.is_empty(), "{path}");
            let (id, diffs) = &c.resource_diffs[0];
            assert_eq!(id.to_string(), "Deployment/web@app");
            let paths: Vec<&str> = diffs.iter().map(|d| d.path.as_str()).collect();
            assert_eq!(paths, [path]);
        }
    }

    #[test]
    fn drift_under_the_same_stamp_is_a_content_change() {
        // Old side: the live object, replicas changed externally, stamp intact.
        let mut old = baseline();
        old[4] = stamped(
            "Deployment",
            "app",
            "web",
            ("app", "web"),
            &h("dep"),
            json!({"replicas": 3}),
        );
        let d = diff_of(&old, &baseline());
        assert_eq!(d.changed.len(), 1);
        let (id, diffs) = &d.changed[0].resource_diffs[0];
        assert_eq!(id.to_string(), "Deployment/web@app");
        assert_eq!(diffs[0].path, "$.spec.replicas");
    }

    #[test]
    fn cluster_level_resources_are_compared_outside_any_package() {
        let mut new = baseline();
        new[1] = cluster_level("Namespace", "app", &h("ns2"), json!({"finalizers": ["x"]}));
        new.push(cluster_level(
            "CustomResourceDefinition",
            "things.example.com",
            &h("crd"),
            json!({}),
        ));

        let d = diff_of(&baseline(), &new);
        assert!(d.changed.is_empty());
        let cl = d.cluster_level.expect("cluster-level section");
        assert_eq!(cl.key, CLUSTER_LEVEL_KEY);
        assert_eq!(cl.resource_diffs.len(), 1);
        assert_eq!(cl.resource_diffs[0].0.to_string(), "Namespace/app");
        assert_eq!(
            cl.added_resources[0].to_string(),
            "CustomResourceDefinition/things.example.com"
        );
    }

    #[test]
    fn an_empty_old_side_is_a_first_deploy() {
        let d = diff_of(&[], &baseline());
        assert_eq!(d.added.len(), 1);
        assert_eq!(d.added[0].key, "app/web");
        // Namespace and record show up too: nothing is hidden on a first deploy.
        assert!(d.cluster_level.is_some());
        assert_eq!(
            d.activation.as_ref().and_then(|a| a.new.as_deref()),
            Some("c-old")
        );
    }

    /// Added and removed packages share one JSON shape.
    #[test]
    fn an_added_package_has_an_empty_kept_list() {
        let mut new = baseline();
        new.push(package_instance("app", "api", "2.0.0", &h("pi2")));
        let json = packages_json(&diff_of(&baseline(), &new), document::Detail::Plain);
        assert_eq!(json["added"][0]["kept_resources"], json!([]));
    }

    /// Return the `changes` array of the modified `resource` in `app/web`.
    fn json_changes(d: &PackageDiff, resource: &str) -> Value {
        let json = packages_json(d, document::Detail::Fields);
        let web = json["changed"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["key"] == "app/web")
            .expect("web changed")
            .clone();
        let modified = web["modified_resources"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["resource"] == resource)
            .unwrap_or_else(|| panic!("{resource} modified: {web}"))
            .clone();
        assert_eq!(
            modified["diff_count"].as_u64(),
            Some(modified["changes"].as_array().unwrap().len() as u64)
        );
        modified["changes"].clone()
    }

    /// Each field change reads old to new, with an absent side left out.
    #[test]
    fn json_lists_each_field_change() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted", "extra": 1}),
        );
        let changes = json_changes(&diff_of(&baseline(), &new), "ConfigMap/web@app");
        assert_eq!(
            changes,
            json!([
                {"path": "$.spec.extra", "change": "added", "new": 1},
                {"path": "$.spec.k", "change": "changed", "old": "v", "new": "wanted"},
            ])
        );
    }

    /// No Secret value, and no hash of one, reaches the JSON.
    #[test]
    fn json_hides_secret_values_and_their_hashes() {
        let secret = |hash: &str, fields: Value| web_resource("Secret", hash, fields);
        let mut old = baseline();
        old.push(secret(
            &h("s1"),
            json!({"data": {"password": "b2xkLXBhc3M="}, "type": "Opaque"}),
        ));
        let mut new = baseline();
        let mut s = secret(
            &h("s2"),
            json!({
                "data": {"password": "bmV3LXBhc3M="},
                "stringData": {"token": "plain-token"},
                "type": "kubernetes.io/basic-auth",
            }),
        );
        s["metadata"]["annotations"][keys::CONTENT_HASH] = json!("content-hash-value");
        new.push(s);
        new[4] = stamped(
            "Deployment",
            "app",
            "web",
            ("app", "web"),
            &h("dep2"),
            json!({"template": {"metadata": {"annotations": {"checksum/secret": "abc123"}}}}),
        );
        let d = diff_of(&old, &new);
        let text = packages_json(&d, document::Detail::Fields).to_string();
        for leaked in [
            "b2xkLXBhc3M=",
            "bmV3LXBhc3M=",
            "plain-token",
            "content-hash-value",
            "abc123",
        ] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }

        let changes = json_changes(&d, "Secret/web@app");
        let by_path = |p: &str| {
            changes
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["path"] == p)
                .unwrap_or_else(|| panic!("{p} in {changes}"))
                .clone()
        };
        assert_eq!(
            by_path("$.data.password"),
            json!({"path": "$.data.password", "change": "changed",
                   "old": SECRET_NOT_SHOWN, "new": SECRET_CHANGED_NOT_SHOWN})
        );
        assert_eq!(
            by_path("$.stringData")["new"],
            json!({"token": SECRET_NOT_SHOWN})
        );
        assert_eq!(by_path("$.type")["new"], json!("kubernetes.io/basic-auth"));

        let changes = json_changes(&d, "Deployment/web@app");
        assert!(changes.to_string().contains(HASH_NOT_SHOWN), "{changes}");
    }

    /// A value too large to show is replaced by its size.
    #[test]
    fn json_leaves_out_a_large_value() {
        let big = "x".repeat(MAX_SHOWN_VALUE_BYTES + 1);
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": big}),
        );
        let changes = json_changes(&diff_of(&baseline(), &new), "ConfigMap/web@app");
        assert_eq!(changes[0]["old"], json!("v"));
        assert_eq!(
            changes[0]["new"],
            json!(format!("({} bytes, not shown)", MAX_SHOWN_VALUE_BYTES + 3))
        );
    }

    /// The default level names the changes and counts the fields, but does
    /// not list them.
    #[test]
    fn json_plain_counts_fields_without_listing_them() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        let json = packages_json(&diff_of(&baseline(), &new), document::Detail::Plain);
        let modified = &json["changed"][0]["modified_resources"][0];
        assert_eq!(modified["diff_count"], json!(1));
        assert!(modified.get("changes").is_none(), "{modified}");
        assert!(json["changed"][0].get("manifests").is_none(), "{json}");
    }

    /// The manifests level adds the old and new manifest of every modified,
    /// added, and removed resource, and of an added package's resources.
    #[test]
    fn json_manifests_carry_each_side_that_exists() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        new.remove(4);
        new.push(stamped(
            "Service",
            "app",
            "web",
            ("app", "web"),
            &h("svc"),
            json!({"port": 80}),
        ));
        new.push(package_instance("app", "api", "2.0.0", &h("pi2")));
        new.push(stamped(
            "ConfigMap",
            "app",
            "api",
            ("app", "api"),
            &h("api-cm"),
            json!({"a": "b"}),
        ));
        let (old_graph, new_graph) = graphs_of(&baseline(), &new);
        let d = diff_graphs(&old_graph, &new_graph);
        let json = packages_json(
            &d,
            document::Detail::Manifests(&ManifestIndex::new(&old_graph, &new_graph)),
        );
        let web = json["changed"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["key"] == "app/web")
            .expect("web changed");
        assert!(
            web["modified_resources"][0].get("changes").is_some(),
            "fields come with manifests: {web}"
        );
        let manifests = &web["manifests"];
        let cm = &manifests["ConfigMap/web@app"];
        assert_eq!(cm["old"]["spec"]["k"], json!("v"));
        assert_eq!(cm["new"]["spec"]["k"], json!("wanted"));
        let svc = &manifests["Service/web@app"];
        assert!(svc.get("old").is_none(), "{svc}");
        assert_eq!(svc["new"]["spec"]["port"], json!(80));
        let dep = &manifests["Deployment/web@app"];
        assert_eq!(dep["old"]["spec"]["replicas"], json!(2));
        assert!(dep.get("new").is_none(), "{dep}");

        let api = &json["added"][0];
        assert_eq!(api["key"], json!("app/api"));
        assert_eq!(
            api["manifests"]["ConfigMap/api@app"]["new"]["spec"]["a"],
            json!("b")
        );
        assert!(
            api["manifests"]["PackageInstance/api@app"]
                .get("new")
                .is_some(),
            "{api}"
        );
    }

    /// No Secret value or hash of one reaches the manifests, and a hidden
    /// value that changed reads differently on the new side, so a line diff
    /// of the two manifests shows it.
    #[test]
    fn json_manifests_hide_secrets_and_mark_the_changed_ones() {
        let secret = |hash: &str, fields: Value| web_resource("Secret", hash, fields);
        let mut old = baseline();
        old.push(secret(
            &h("s1"),
            json!({"data": {"password": "b2xkLXBhc3M=", "user": "YWRtaW4="}}),
        ));
        let mut new = baseline();
        let mut s = secret(
            &h("s2"),
            json!({
                "data": {"password": "bmV3LXBhc3M=", "user": "YWRtaW4="},
                "stringData": {"token": "plain-token"},
            }),
        );
        s["metadata"]["annotations"][keys::CONTENT_HASH] = json!("content-hash-value");
        new.push(s);
        new[4] = stamped(
            "Deployment",
            "app",
            "web",
            ("app", "web"),
            &h("dep2"),
            json!({"template": {"metadata": {"annotations": {"checksum/secret": "abc123"}}}}),
        );
        let (old_graph, new_graph) = graphs_of(&old, &new);
        let d = diff_graphs(&old_graph, &new_graph);
        let json = packages_json(
            &d,
            document::Detail::Manifests(&ManifestIndex::new(&old_graph, &new_graph)),
        );
        let text = json.to_string();
        for leaked in [
            "b2xkLXBhc3M=",
            "bmV3LXBhc3M=",
            "YWRtaW4=",
            "plain-token",
            "content-hash-value",
            "abc123",
        ] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }
        let secret = &json["changed"][0]["manifests"]["Secret/web@app"];
        assert_eq!(secret["old"]["data"]["password"], json!(SECRET_NOT_SHOWN));
        assert_eq!(
            secret["new"]["data"]["password"],
            json!(SECRET_CHANGED_NOT_SHOWN)
        );
        assert_eq!(secret["new"]["data"]["user"], json!(SECRET_NOT_SHOWN));
        assert_eq!(
            secret["new"]["stringData"]["token"],
            json!(SECRET_NOT_SHOWN)
        );
        assert_eq!(
            secret["new"]["metadata"]["annotations"][keys::CONTENT_HASH],
            json!(HASH_NOT_SHOWN)
        );
        let dep = &json["changed"][0]["manifests"]["Deployment/web@app"];
        assert_eq!(
            dep["new"]["spec"]["template"]["metadata"]["annotations"]["checksum/secret"],
            json!(HASH_NOT_SHOWN)
        );
    }

    /// An answered object's sides replace the graphs' manifests: a live
    /// object and a dry-run result, or no old side when nothing is live.
    #[test]
    fn answered_objects_show_the_live_object_and_the_dry_run_result() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "wanted"}),
        );
        let (old_graph, new_graph) = graphs_of(&baseline(), &new);
        let mut index = ManifestIndex::new(&old_graph, &new_graph);
        let cm = ResourceId::from_value(&new[3]);
        let dep = ResourceId::from_value(&new[4]);
        index.answered(
            &cm,
            Some(json!({"spec": {"k": "live"}})),
            Some(json!({"spec": {"k": "server"}})),
        );
        index.answered(&dep, None, Some(json!({"spec": {"replicas": 5}})));
        let shown = index.render([&cm, &dep]);
        let cm = &shown["ConfigMap/web@app"];
        assert_eq!(cm.old, Some(json!({"spec": {"k": "live"}})));
        assert_eq!(cm.new, Some(json!({"spec": {"k": "server"}})));
        let dep = &shown["Deployment/web@app"];
        assert_eq!(dep.old, None);
        assert_eq!(dep.new, Some(json!({"spec": {"replicas": 5}})));
    }

    /// A Secret once applied with kubectl carries its whole data in
    /// `last-applied-configuration`; the manifests hide it, under the
    /// retired domain's hash spellings too.
    #[test]
    fn manifests_hide_a_secret_in_last_applied_and_legacy_hashes() {
        let (old_graph, new_graph) = graphs_of(&baseline(), &baseline());
        let mut index = ManifestIndex::new(&old_graph, &new_graph);
        let rid = ResourceId {
            kind: "Secret".into(),
            namespace: "app".into(),
            name: "s".into(),
        };
        let legacy = crate::legacy_domain::legacy_spellings(keys::CONTENT_HASH)
            .pop()
            .expect("a retired domain");
        let live = json!({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "s", "annotations": {
            LAST_APPLIED: "{\"data\":{\"p\":\"cGxhaW4=\"}}",
            legacy.clone(): "sha256-legacy-hash"}},
            "data": {"p": "b2xk"}});
        index.answered(&rid, Some(live.clone()), Some(live));
        let text = serde_json::to_string(&index.render([&rid])).unwrap();
        for leaked in ["cGxhaW4=", "b2xk", "sha256-legacy-hash"] {
            assert!(!text.contains(leaked), "{leaked} in {text}");
        }
    }

    /// A manifest too large to show is replaced by its size.
    #[test]
    fn json_manifests_leave_out_a_large_manifest() {
        let mut new = baseline();
        new[3] = stamped(
            "ConfigMap",
            "app",
            "web",
            ("app", "web"),
            &h("cm2"),
            json!({"k": "x".repeat(MAX_SHOWN_MANIFEST_BYTES)}),
        );
        let (old_graph, new_graph) = graphs_of(&baseline(), &new);
        let d = diff_graphs(&old_graph, &new_graph);
        let json = packages_json(
            &d,
            document::Detail::Manifests(&ManifestIndex::new(&old_graph, &new_graph)),
        );
        let cm = &json["changed"][0]["manifests"]["ConfigMap/web@app"];
        assert_eq!(cm["old"]["spec"]["k"], json!("v"));
        let note = cm["new"].as_str().expect("a size note");
        assert!(
            note.starts_with('(') && note.ends_with(" bytes, not shown)"),
            "{note}"
        );
    }
}

mod never_pruned_tests {
    use super::*;
    use crate::manifest::types::CLUSTER_SCOPED;

    fn rid(kind: &str, name: &str) -> ResourceId {
        ResourceId {
            kind: kind.into(),
            name: name.into(),
            namespace: CLUSTER_SCOPED.into(),
        }
    }

    /// A CRD or Namespace dropped from the build is kept; everything else,
    /// including custom resources of a kept CRD, is deleted in the given order.
    #[test]
    fn crds_and_namespaces_are_kept() {
        let garbage = vec![
            rid("Widget", "w1"),
            rid("CustomResourceDefinition", "widgets.example.com"),
            rid("ConfigMap", "old"),
            rid("Namespace", "gone"),
        ];
        let (delete, kept) = split_never_pruned(garbage);
        assert_eq!(delete, vec![rid("Widget", "w1"), rid("ConfigMap", "old")]);
        assert_eq!(
            kept,
            vec![
                rid("CustomResourceDefinition", "widgets.example.com"),
                rid("Namespace", "gone"),
            ]
        );
    }
}
