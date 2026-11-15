//! Build and format deploy provenance receipts.
//!
//! A deploy receipt records the flake reference, Git revision and dirty state,
//! `flake.lock` digest, locked input revisions and NAR hashes, container image
//! references, and builder versions for a deployed activation.
//!
//! Receipts are written to the `Activation` resource's `status` subresource so
//! that re-applying the `Activation` spec during a rollback does not overwrite
//! the historical provenance record. Rendered manifests are omitted from the
//! receipt to avoid hitting the Kubernetes object size limit or storing inline
//! Secret values on the `Activation` resource.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use kix::build_source::{Build, Provenance};
use kix::eval::store_graph::StoreGraph;
use kix::manifest::keys;

use super::shared;
use crate::commands::ReceiptMaker;
use crate::output;

/// Builds deploy provenance receipts for `kix deploy` and `kix bundle`.
pub struct ComplianceReceipts;

impl ReceiptMaker for ComplianceReceipts {
    fn of_build(&self, build: &Build, flake_ref: &str) -> Value {
        of_build(build, flake_ref)
    }

    fn warnings(&self, receipt: &Value) -> Vec<String> {
        dirty_source_warning(receipt)
    }
}

/// Build the deploy receipt for `build`, either from the local flake at
/// `flake_ref` ([`build_receipt`]) or from provenance carried inside a bundle
/// ([`from_provenance`]).
fn of_build(build: &Build, flake_ref: &str) -> Value {
    match build.carried_provenance() {
        None => build_receipt(build.graph(), flake_ref),
        Some((made, sha256)) => from_provenance(build.graph(), made, sha256),
    }
}

/// Assemble the receipt for a build that is about to be deployed.
pub(super) fn build_receipt(graph: &StoreGraph, flake_ref: &str) -> Value {
    let flake_path = crate::commands::resolve_flake_path(flake_ref).ok();

    let git = flake_path.as_ref().and_then(|p| shared::git_state(p));
    let flake_lock_digest = flake_path
        .as_ref()
        .and_then(|p| std::fs::read_to_string(p.join("flake.lock")).ok())
        .map(|s| shared::blake3_hex(&s));

    let mut source = json!({ "flakeRef": flake_ref });
    if let Some(git) = &git {
        source["gitCommit"] = json!(git.rev);
        source["dirty"] = json!(git.dirty);
        // Use Nix's spelling so direct comparisons agree.
        source["revision"] = json!(git.dirty_rev());
    }
    if let Some(d) = &flake_lock_digest {
        source["flakeLock"] = json!(format!("blake3:{d}"));
    }

    let mut builder = json!({
        "kixVersion": kix::version::running().to_string(),
        "arch": std::env::consts::ARCH,
        "os": std::env::consts::OS,
    });
    if let Some(v) = kix::eval::nix::version() {
        builder["nixVersion"] = json!(v);
    }

    json!({
        "schema": keys::RECEIPT_SCHEMA,
        "cluster": graph.cluster_name,
        "activationHash": shared::activation_identity_hash(graph),
        "deployedAt": shared::now_rfc3339(),
        "source": source,
        "builder": builder,
        "inputs": flake_path
            .as_ref()
            .and_then(|p| shared::read_flake_lock(p))
            .map(|lock| flake_inputs(&lock))
            .unwrap_or_else(|| json!([])),
        "images": images(graph),
    })
}

/// Assemble a deploy receipt from bundle provenance `made` and the bundle digest `sha256`.
///
/// The `source`, `inputs`, and `builder` fields come from the machine that
/// created the bundle, while `source.bundle.sha256` is always set to the digest
/// of the bundle bytes read by the deploying machine.
fn from_provenance(graph: &StoreGraph, made: Provenance, sha256: &str) -> Value {
    let mut source = made.source;
    let mut bundle = serde_json::Map::from_iter([("sha256".to_string(), json!(sha256))]);
    if let Some(Value::Object(claimed)) = source.remove("bundle") {
        for (key, value) in claimed {
            bundle.entry(key).or_insert(value);
        }
    }
    source.insert("bundle".to_string(), Value::Object(bundle));
    json!({
        "schema": keys::RECEIPT_SCHEMA,
        "cluster": graph.cluster_name,
        "activationHash": shared::activation_identity_hash(graph),
        "deployedAt": shared::now_rfc3339(),
        "source": source,
        "builder": made.builder,
        "deployer": {
            "kixVersion": kix::version::running().to_string(),
            "arch": std::env::consts::ARCH,
            "os": std::env::consts::OS,
        },
        "inputs": made.inputs,
        "images": images(graph),
    })
}

/// Build warning lines for a receipt whose source tree had uncommitted changes.
///
/// Escapes control characters in the recorded revision because bundle receipts
/// originate on another machine.
fn dirty_source_warning(receipt: &Value) -> Vec<String> {
    if receipt["source"]["dirty"] != Value::Bool(true) {
        return Vec::new();
    }
    let warning = if receipt["source"].get("bundle").is_some() {
        [
            "The build was made from a source tree with uncommitted changes, so the commit it",
            "records does not contain what is about to be applied. The record will say so.",
        ]
    } else {
        [
            "The working tree has uncommitted changes, so the commit recorded for this deploy",
            "does not contain what is about to be applied. The record will say so.",
        ]
    };
    let mut lines: Vec<String> = warning
        .iter()
        .map(|l| output::yellow(l).into_owned())
        .collect();
    if let Some(rev) = receipt["source"]["revision"].as_str() {
        lines.push(format!("  {}", output::dim(&output::printable(rev))));
    }
    lines
}

/// Collect all container image references rendered by `graph`, sorted and
/// deduplicated.
fn images(graph: &StoreGraph) -> Value {
    let mut found: BTreeSet<String> = BTreeSet::new();
    for resource in graph.resources.values() {
        // Skip ConfigMap and Secret manifests so `image` keys inside opaque
        // configuration data are not mistaken for container images.
        use kix::manifest::kinds::{self, GroupKind};
        if matches!(
            GroupKind::of_manifest(&resource.manifest),
            kinds::CONFIG_MAP | kinds::SECRET
        ) {
            continue;
        }
        collect_images(&resource.manifest, &mut found);
    }
    json!(found.into_iter().collect::<Vec<_>>())
}

/// Recursively scan a manifest JSON value for `image` fields that parse as
/// container image references.
///
/// Walks the entire JSON tree rather than only standard PodSpec paths so images
/// declared inside custom resources are also captured.
fn collect_images(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if key == "image"
                    && let Some(s) = child.as_str()
                    && looks_like_an_image(s)
                {
                    out.insert(s.to_string());
                }
                collect_images(child, out);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_images(item, out);
            }
        }
        _ => {}
    }
}

/// Return `true` if `s` has the shape of a valid container image reference.
fn looks_like_an_image(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 512
        && !s.chars().any(char::is_whitespace)
        && kix::registry::Reference::parse(s).is_ok()
}

fn flake_inputs(lock: &Value) -> Value {
    let mut inputs = Vec::new();
    for (name, locked) in kix::flake_lock::locked_inputs(lock) {
        let mut entry = serde_json::Map::new();
        entry.insert("name".into(), json!(name));
        if let Some(r) = locked.get("rev").and_then(|v| v.as_str()) {
            entry.insert("rev".into(), json!(r));
        }
        if let Some(n) = locked.get("narHash").and_then(|v| v.as_str()) {
            entry.insert("narHash".into(), json!(n));
        }
        // Local `path:` inputs have neither `rev` nor `narHash`; record their
        // type and path with `locked: false` instead of an empty entry.
        if !entry.contains_key("rev") && !entry.contains_key("narHash") {
            if let Some(t) = locked.get("type").and_then(|v| v.as_str()) {
                entry.insert("type".into(), json!(t));
            }
            for field in ["path", "url"] {
                if let Some(v) = locked.get(field).and_then(|v| v.as_str()) {
                    entry.insert(field.into(), json!(v));
                }
            }
            entry.insert("locked".into(), json!(false));
        }
        inputs.push(Value::Object(entry));
    }
    json!(inputs)
}

/// Convert a deploy receipt into an in-toto SLSA v1 provenance statement.
///
/// Maps requested build inputs (`cluster`, `flakeRef`, `flakeLock`) to
/// `externalParameters` and resolved Git commits, NAR hashes, and image digests
/// to `resolvedDependencies`.
pub fn attestation_from_receipt(
    receipt: &Value,
    builder_id: Option<&str>,
    invocation_id: Option<&str>,
) -> Value {
    let cluster = receipt
        .get("cluster")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");
    let activation_hash = receipt
        .get("activationHash")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let source = receipt.get("source").cloned().unwrap_or_else(|| json!({}));
    let flake_ref = source
        .get("flakeRef")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    let mut external_params = json!({
        "cluster": cluster,
        "flakeRef": flake_ref,
    });
    if let Some(lock) = source.get("flakeLock") {
        external_params["flakeLock"] = lock.clone();
    }

    let mut internal_params = json!({});
    if let Some(builder) = receipt.get("builder").and_then(|v| v.as_object()) {
        for (k, v) in builder {
            internal_params[k] = v.clone();
        }
    }

    let mut resolved: Vec<Value> = Vec::new();
    if let Some(rev) = source.get("gitCommit").and_then(|v| v.as_str()) {
        let dirty = source
            .get("dirty")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let mut entry = json!({
            "uri": flake_ref,
            "digest": { "gitCommit": rev },
        });
        if dirty {
            // Said out loud rather than left to be inferred. A statement that
            // names a commit whose tree was not what got built is a statement
            // that will be believed, so the qualification travels with it.
            entry["annotations"] = json!({
                "dirty": true,
                "revision": source.get("revision").cloned().unwrap_or(json!(null)),
                "note": "the working tree had uncommitted changes, so this commit does not contain what was deployed",
            });
        }
        resolved.push(entry);
    }
    if let Some(inputs) = receipt.get("inputs").and_then(|v| v.as_array()) {
        for input in inputs {
            let name = input
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("input");
            let mut digest = serde_json::Map::new();
            if let Some(r) = input.get("rev") {
                digest.insert("gitCommit".into(), r.clone());
            }
            if let Some(n) = input.get("narHash") {
                digest.insert("narHash".into(), n.clone());
            }
            let mut entry = json!({ "uri": format!("flake-input:{name}") });
            if digest.is_empty() {
                // An unlocked input has nothing to put in a digest, and an
                // empty digest object claims a resolution that did not
                // happen. Say what it was instead.
                let mut annotations = serde_json::Map::new();
                annotations.insert("locked".into(), json!(false));
                for field in ["type", "path", "url"] {
                    if let Some(v) = input.get(field) {
                        annotations.insert(field.into(), v.clone());
                    }
                }
                entry["annotations"] = Value::Object(annotations);
            } else {
                entry["digest"] = Value::Object(digest);
            }
            resolved.push(entry);
        }
    }
    if let Some(images) = receipt.get("images").and_then(|v| v.as_array()) {
        for image in images.iter().filter_map(|v| v.as_str()) {
            let mut entry = json!({ "uri": format!("container-image:{image}") });
            // Only a reference carrying a digest gets one recorded. A tag is
            // a request, not a resolution, and putting it in a digest field
            // would be a well-formed false statement.
            if let Some((_, digest)) = image.split_once('@')
                && kix::registry::is_sha256_digest(digest)
            {
                let hex = digest.trim_start_matches("sha256:");
                entry["digest"] = json!({ "sha256": hex });
            }
            resolved.push(entry);
        }
    }

    let deployed_at = receipt
        .get("deployedAt")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(shared::now_rfc3339);

    let mut run_details = json!({
        "builder": { "id": builder_id.unwrap_or(keys::SLSA_BUILDER_ID) },
        "metadata": {
            "startedOn": deployed_at,
            "finishedOn": deployed_at,
        }
    });
    if let Some(id) = invocation_id {
        run_details["metadata"]["invocationId"] = json!(id);
    }

    json!({
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{
            "name": format!("cluster-{cluster}-activation"),
            "digest": {
                // The Nix store hash (base32, first 32 chars) is the
                // canonical activation identity, and is not a raw SHA-256.
                "nixStoreHash": activation_hash,
            }
        }],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": keys::SLSA_BUILD_TYPE,
                "externalParameters": external_params,
                "internalParameters": internal_params,
                "resolvedDependencies": resolved,
            },
            "runDetails": run_details,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt() -> Value {
        json!({
            "schema": keys::RECEIPT_SCHEMA,
            "cluster": "stage2",
            "activationHash": "abcdefghijklmnopqrstuvwxyz012345",
            "deployedAt": "2026-09-09T12:00:00Z",
            "source": {
                "flakeRef": "/repo",
                "gitCommit": "c1b8d5e0000000000000000000000000000000aa",
                "dirty": false,
                "revision": "c1b8d5e0000000000000000000000000000000aa",
                "flakeLock": "blake3:00ff",
            },
            "builder": { "kixVersion": "0.1.0", "nixVersion": "nix 2.28" },
            "inputs": [ { "name": "nixpkgs", "rev": "deadbeef", "narHash": "sha256-x" } ],
            "images": [
                "docker.io/library/nginx:1.27@sha256:00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
                "reg.example/app:v1",
            ],
        })
    }

    #[test]
    fn a_receipt_makes_a_statement_about_the_activation_it_names() {
        let s = attestation_from_receipt(&receipt(), None, None);
        assert_eq!(s["subject"][0]["name"], "cluster-stage2-activation");
        assert_eq!(
            s["subject"][0]["digest"]["nixStoreHash"],
            "abcdefghijklmnopqrstuvwxyz012345"
        );
        // The deploy time is carried through rather than restamped to now.
        assert_eq!(
            s["predicate"]["runDetails"]["metadata"]["startedOn"],
            "2026-09-09T12:00:00Z"
        );
    }

    #[test]
    fn only_an_image_with_a_digest_gets_a_digest_recorded() {
        let s = attestation_from_receipt(&receipt(), None, None);
        let deps = s["predicate"]["buildDefinition"]["resolvedDependencies"]
            .as_array()
            .unwrap()
            .clone();
        let pinned = deps
            .iter()
            .find(|d| d["uri"].as_str().unwrap().contains("nginx"))
            .unwrap();
        assert_eq!(
            pinned["digest"]["sha256"],
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        );
        let loose = deps
            .iter()
            .find(|d| d["uri"].as_str().unwrap().contains("reg.example/app"))
            .unwrap();
        assert!(loose.get("digest").is_none(), "a tag is not a resolution");
    }

    #[test]
    fn a_dirty_tree_is_stated_on_the_statement_rather_than_left_to_be_inferred() {
        let mut r = receipt();
        r["source"]["dirty"] = json!(true);
        r["source"]["revision"] = json!("c1b8d5e0000000000000000000000000000000aa-dirty");
        let s = attestation_from_receipt(&r, None, None);
        let dep = &s["predicate"]["buildDefinition"]["resolvedDependencies"][0];
        assert_eq!(dep["annotations"]["dirty"], true);
        assert!(
            dep["annotations"]["revision"]
                .as_str()
                .unwrap()
                .ends_with("-dirty")
        );
    }

    #[test]
    fn images_are_found_wherever_they_sit_in_a_manifest() {
        let mut found = BTreeSet::new();
        collect_images(
            &json!({
                "kind": "Deployment",
                "spec": { "template": { "spec": {
                    "containers": [{ "image": "a/b:1" }],
                    "initContainers": [{ "image": "a/c:2" }],
                }}},
            }),
            &mut found,
        );
        // A CustomResource can carry an image at a path nobody enumerated.
        collect_images(
            &json!({ "kind": "VMCluster", "spec": { "vmselect": { "image": "a/d:3" } } }),
            &mut found,
        );
        assert_eq!(
            found.into_iter().collect::<Vec<_>>(),
            vec!["a/b:1", "a/c:2", "a/d:3"]
        );
    }

    #[test]
    fn an_unlocked_input_says_so_instead_of_claiming_an_empty_digest() {
        let mut r = receipt();
        r["inputs"] = json!([{ "name": "kix", "type": "path", "path": "../kix", "locked": false }]);
        let s = attestation_from_receipt(&r, None, None);
        let dep = s["predicate"]["buildDefinition"]["resolvedDependencies"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["uri"] == "flake-input:kix")
            .unwrap()
            .clone();
        assert!(dep.get("digest").is_none());
        assert_eq!(dep["annotations"]["locked"], false);
        assert_eq!(dep["annotations"]["path"], "../kix");
    }

    #[test]
    fn a_value_that_is_not_an_image_reference_is_not_recorded() {
        let mut found = BTreeSet::new();
        collect_images(&json!({ "image": "" }), &mut found);
        // A config blob that happens to use the same field name.
        collect_images(
            &json!({ "image": "see the operator docs for how to set this" }),
            &mut found,
        );
        // A malformed digest is a reference Kix will not vouch for.
        collect_images(&json!({ "image": "reg/app@sha256:short" }), &mut found);
        assert!(found.is_empty(), "{found:?}");
    }

    /// Build a fixture bundle carrying `made` as its receipt, returning the
    /// loaded [`Build`], raw bundle bytes, and `kix_rev`.
    fn carried_build(made: Value) -> (Build, Vec<u8>, String) {
        use kix_bundle::Bundle;

        let fixture: &[u8] =
            include_bytes!("../../../../kix-bundle/tests/fixtures/kix-enterprise-test.kixbundle");
        let mut contents = Bundle::read(std::io::Cursor::new(fixture))
            .unwrap()
            .0
            .contents()
            .unwrap();
        contents.receipt = Some(serde_json::from_value(made).unwrap());
        let file = tempfile::NamedTempFile::new().unwrap();
        contents.write(file.as_file()).unwrap();
        let build = kix_bundle::read_build(file.path(), &[], "kix-enterprise-test").unwrap();
        (build, std::fs::read(file.path()).unwrap(), contents.kix_rev)
    }

    /// Verify that a bundle receipt records the bundle's SHA-256 digest while
    /// preserving the builder's source provenance.
    #[test]
    fn a_bundle_receipt_names_the_bundle_and_keeps_its_makers_record() {
        let (build, bytes, kix_rev) = carried_build(json!({
            "source": {"revision": "abc", "dirty": false},
            "inputs": [{"name": "nixpkgs"}],
            "builder": {"kixVersion": "0.0.1"},
        }));
        let r = ComplianceReceipts.of_build(&build, "unused");
        let digest = format!("{:x}", <sha2::Sha256 as sha2::Digest>::digest(&bytes));
        assert_eq!(r["source"]["revision"], "abc");
        assert_eq!(r["source"]["bundle"]["sha256"], json!(digest));
        assert_eq!(r["source"]["bundle"]["kixRev"], json!(kix_rev));
        assert_eq!(r["inputs"][0]["name"], "nixpkgs");
        assert_eq!(r["builder"]["kixVersion"], "0.0.1");
        assert_eq!(
            r["deployer"]["kixVersion"],
            kix::version::running().to_string()
        );
        assert_eq!(
            r["activationHash"],
            json!(kix::eval::store_graph::store_hash(
                &build.graph().activation_path
            ))
        );
        assert!(ComplianceReceipts.warnings(&r).is_empty());
    }

    /// Verify that dirty-source warnings for a bundle attribute the dirty tree
    /// to the bundle and strip control characters from the revision.
    #[test]
    fn a_dirty_bundle_source_is_named_as_the_bundles_and_escaped() {
        let (build, _, _) = carried_build(json!({"source": {
            "dirty": true, "revision": "abc\u{1b}[2J\u{202e}-dirty"}}));
        let receipt = ComplianceReceipts.of_build(&build, "unused");
        let lines = ComplianceReceipts.warnings(&receipt);
        assert_eq!(
            lines[..2],
            [
                "The build was made from a source tree with uncommitted changes, so the commit it",
                "records does not contain what is about to be applied. The record will say so.",
            ]
        );
        assert_eq!(lines.len(), 3, "{lines:?}");
        assert!(lines[2].starts_with("  abc"), "{lines:?}");
        assert!(
            !lines[2].chars().any(|c| c.is_control() || c == '\u{202e}'),
            "{lines:?}"
        );
    }

    /// Verify that dirty-source warnings for a local build name the working tree.
    #[test]
    fn a_dirty_working_tree_is_named_as_such() {
        let receipt = json!({"source": {"dirty": true, "revision": "abc-dirty"}});
        assert_eq!(
            ComplianceReceipts.warnings(&receipt),
            [
                "The working tree has uncommitted changes, so the commit recorded for this deploy",
                "does not contain what is about to be applied. The record will say so.",
                "  abc-dirty",
            ]
        );
        let clean = json!({"source": {"dirty": false, "revision": "abc"}});
        assert!(ComplianceReceipts.warnings(&clean).is_empty());
    }

    /// Verify that `source.bundle.sha256` always uses the locally computed
    /// digest rather than a value claimed inside the bundle's provenance.
    #[test]
    fn a_source_cannot_supply_the_receipts_digest() {
        let made = Provenance {
            source: serde_json::from_value(json!({"bundle": {"sha256": "forged", "kixRev": "r"}}))
                .unwrap(),
            ..Default::default()
        };
        let r = from_provenance(&StoreGraph::empty("c"), made, "read");
        assert_eq!(
            r["source"]["bundle"],
            json!({"sha256": "read", "kixRev": "r"})
        );
    }
}
