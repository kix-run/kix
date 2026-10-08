//! The deploy receipt: what was deployed, written down where the deploy
//! happened.
//!
//! Kix already computed all of this. `kix compliance attest` assembled the
//! flake reference, the git revision, a hash of `flake.lock`, every input's
//! revision and narHash, and the kix and Nix versions, printed the lot to
//! stdout and threw it away. Meanwhile an Activation record on the cluster
//! held a cluster name, a list of instances, and a `built-via` annotation
//! naming a `/nix/store` path on whichever machine ran the deploy.
//!
//! So the cluster could not answer "what is running here, and where did it
//! come from" without the machine that deployed it, and that is the same
//! failure Argo CD users hit when their repository is unreachable and a
//! rollback fails with "repository not accessible". Storing pointers is fine
//! until the thing pointed at is gone.
//!
//! The fix is small because the parts already exist. The receipt goes into
//! the Activation's `status` subresource, which the CRD already declares and
//! the CLI already writes. Status rather than spec on purpose: a status
//! subresource is untouched by an apply of the main resource, so re-applying
//! an Activation during a rollback cannot erase the record of what happened.
//! It is also the correct half by Kubernetes convention, where spec is intent
//! and status is observation, and a receipt is an observation.
//!
//! Manifests are excluded. Helm stores rendered
//! manifests in cluster Secrets and pays for it twice, once at the 1 MiB
//! object limit and once because those records become a readable archive of
//! every credential the release ever held. Kix's built manifests carry secret
//! values inline too, so the same store would be the same archive. The
//! receipt records provenance, and rollback stays tied to the source.
//!
//! Design: `v2_discussions/archive/138_values_that_vary_per_deploy.md` section 5.2.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use kix::build_source::{Build, Provenance};
use kix::eval::store_graph::StoreGraph;
use kix::manifest::keys;

use super::shared;

/// The receipt for a build about to be deployed: for a build made here,
/// from the flake at `flake_ref` ([`build_receipt`]), and otherwise from
/// what the machine that made it recorded ([`from_provenance`]).
pub fn of_build(build: &Build, flake_ref: &str) -> Value {
    match build.carried_provenance() {
        None => build_receipt(build.graph(), flake_ref),
        Some((made, sha256)) => from_provenance(build.graph(), made, sha256),
    }
}

/// Assemble the receipt for a build that is about to be deployed.
pub fn build_receipt(graph: &StoreGraph, flake_ref: &str) -> Value {
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
        "kixVersion": env!("CARGO_PKG_VERSION"),
        "arch": std::env::consts::ARCH,
        "os": std::env::consts::OS,
    });
    if let Some(v) = shared::nix_version() {
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

/// The receipt for a deploy of a build made on another machine.
///
/// The source, inputs and builder are what that machine recorded; this
/// machine has no source tree to read them from. They are claims by whoever
/// made the build. `source.bundle.sha256` is not: it is `sha256`, of the
/// bytes this machine read, so it names exactly what was deployed.
pub fn from_provenance(graph: &StoreGraph, made: Provenance, sha256: &str) -> Value {
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
            "kixVersion": env!("CARGO_PKG_VERSION"),
            "arch": std::env::consts::ARCH,
            "os": std::env::consts::OS,
        },
        "inputs": made.inputs,
        "images": images(graph),
    })
}

/// Every container image the build renders, sorted and deduplicated.
///
/// Tags can move after they are read. Pin-file references carry digests, so
/// the receipt names exactly what the cluster was told to pull.
fn images(graph: &StoreGraph) -> Value {
    let mut found: BTreeSet<String> = BTreeSet::new();
    for resource in graph.resources.values() {
        // A ConfigMap's `data` and a Secret's `stringData` are opaque
        // payloads. A config file that happens to have an `image:` line is
        // not a container this cluster runs, and putting it in the receipt
        // would be a claim about the cluster that is not true.
        let kind = resource
            .manifest
            .get("kind")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        if kind == "ConfigMap" || kind == "Secret" {
            continue;
        }
        collect_images(&resource.manifest, &mut found);
    }
    json!(found.into_iter().collect::<Vec<_>>())
}

/// Walk a manifest for `image` fields. Walking rather than reading the known
/// pod-spec paths, because a CustomResource carries containers wherever its
/// operator decided and an operator will happily run them. The cost of
/// walking is that `image` is not a reserved word, so the value has to look
/// like an image reference before it is believed.
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

/// A cheap shape test, not a parser. An image reference has no whitespace and
/// is not a paragraph; that rules out the prose and config blobs that share
/// the field name without rejecting anything a kubelet would accept.
fn looks_like_an_image(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 512
        && !s.chars().any(char::is_whitespace)
        && kix::registry::Reference::parse(s).is_ok()
}

fn flake_inputs(lock: &Value) -> Value {
    let Some(nodes) = lock.get("nodes").and_then(|n| n.as_object()) else {
        return json!([]);
    };
    let mut inputs = Vec::new();
    for (name, node) in nodes {
        if name == "root" {
            continue;
        }
        let Some(locked) = node.get("locked") else {
            continue;
        };
        let mut entry = serde_json::Map::new();
        entry.insert("name".into(), json!(name));
        if let Some(r) = locked.get("rev").and_then(|v| v.as_str()) {
            entry.insert("rev".into(), json!(r));
        }
        if let Some(n) = locked.get("narHash").and_then(|v| v.as_str()) {
            entry.insert("narHash".into(), json!(n));
        }
        // A `path:` input has neither, because Nix does not lock a local
        // directory. Record what it is instead of an entry that is only a
        // name: "this input was a path on the deploying machine" is a real
        // answer, and a more honest one than an empty digest.
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

/// Turn a receipt into a SLSA v1 provenance statement.
///
/// This is the inversion that makes the receipt worth writing. Attestation
/// used to require the machine that built the cluster, because the facts only
/// existed there. Reading them from the record instead means a deploy can be
/// attested from anywhere that can reach the cluster, by someone who never
/// built it, which is what an auditor actually needs.
///
/// SLSA's own split is followed: `externalParameters` is what was asked for
/// and `resolvedDependencies` is what it resolved to. Argo CD shows what goes
/// wrong when only the request is recorded, where a multi-source Application's
/// status holds the target revision and not the resolved one, so users cannot
/// tell what was deployed.
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

    /// A deploy from a bundle records the bytes it deployed, and repeats
    /// what the bundle's maker recorded about the source.
    #[test]
    fn a_bundle_receipt_names_the_bundle_and_keeps_its_makers_record() {
        use kix::eval::bundle::Bundle;

        let fixture: &[u8] =
            include_bytes!("../../../../kix/tests/fixtures/bundles/kix-enterprise-test.kixbundle");
        let mut contents = Bundle::read(std::io::Cursor::new(fixture))
            .unwrap()
            .0
            .contents()
            .unwrap();
        contents.receipt = Some(
            serde_json::from_value(json!({
                "source": {"revision": "abc", "dirty": false},
                "inputs": [{"name": "nixpkgs"}],
                "builder": {"kixVersion": "0.0.1"},
            }))
            .unwrap(),
        );
        let file = tempfile::NamedTempFile::new().unwrap();
        contents.write(file.as_file()).unwrap();
        let build =
            crate::commands::bundle::read(file.path(), &[], "kix-enterprise-test", true).unwrap();
        let r = of_build(&build, "unused");
        let bytes = std::fs::read(file.path()).unwrap();
        let digest = format!("{:x}", <sha2::Sha256 as sha2::Digest>::digest(&bytes));
        assert_eq!(r["source"]["revision"], "abc");
        assert_eq!(r["source"]["bundle"]["sha256"], json!(digest));
        assert_eq!(r["source"]["bundle"]["kixRev"], json!(contents.kix_rev));
        assert_eq!(r["inputs"][0]["name"], "nixpkgs");
        assert_eq!(r["builder"]["kixVersion"], "0.0.1");
        assert_eq!(r["deployer"]["kixVersion"], env!("CARGO_PKG_VERSION"));
        assert_eq!(
            r["activationHash"],
            json!(kix::eval::store_graph::store_hash(
                &build.graph().activation_path
            ))
        );
    }

    /// The digest in the receipt is the one this machine computed. A
    /// source that claims another is not believed.
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
