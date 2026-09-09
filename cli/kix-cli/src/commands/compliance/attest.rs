//! SLSA v1 provenance generation — produces an in-toto Statement document
//! whose predicate is a SLSA `https://slsa.dev/provenance/v1` predicate.
//!
//! The activation identity hash IS the subject digest. Nix content-addressing
//! means no additional hashing is needed: two identical clusters will produce
//! the same subject, and any byte-level change flips the hash.
//!
//! Signing is designed in `v2_discussions/54_activation_signing.md` and is
//! intentionally out of scope here — this command emits the unsigned
//! Statement so that signing can be layered on independently.

use miette::{IntoDiagnostic, Result};
use serde_json::{Value, json};

use kix::eval::store_graph::StoreGraph;

use crate::cli::{ComplianceAttestArgs, OutputFormat};

use super::shared;
use crate::commands::CommandContext;
use kix::manifest::keys;

pub fn run(args: &ComplianceAttestArgs, ctx: &mut CommandContext) -> Result<()> {
    let (_result_path, graph) = shared::build_and_load(ctx, &args.cluster)?;
    let statement = build_attestation(
        &graph,
        &ctx.global.flake,
        args.builder_id.as_deref(),
        args.invocation_id.as_deref(),
    );

    let text = match ctx.output_format(OutputFormat::Json) {
        OutputFormat::Yaml => serde_yml::to_string(&statement).into_diagnostic()?,
        _ => serde_json::to_string_pretty(&statement).into_diagnostic()?,
    };
    println!("{text}");
    Ok(())
}

pub fn build_attestation(
    graph: &StoreGraph,
    flake_ref: &str,
    builder_id: Option<&str>,
    invocation_id: Option<&str>,
) -> Value {
    let activation_hash = shared::activation_identity_hash(graph);
    let flake_path = shared::resolve_flake_path(flake_ref).ok();

    // Flake lock hash: BLAKE3 of the on-disk flake.lock file so verifiers
    // can compare byte-for-byte equivalence without re-evaluating Nix.
    let flake_lock_digest = flake_path
        .as_ref()
        .and_then(|p| std::fs::read_to_string(p.join("flake.lock")).ok())
        .map(|s| shared::blake3_hex(&s));

    let git_rev = flake_path.as_ref().and_then(|p| shared::git_commit(p));
    let nix_version = shared::nix_version();

    let mut external_params = json!({
        "cluster": graph.cluster_name,
        "flakeRef": flake_ref,
    });
    if let Some(d) = &flake_lock_digest {
        external_params["flakeLock"] = json!(format!("blake3:{d}"));
    }

    let mut internal_params = json!({
        "kixVersion": env!("CARGO_PKG_VERSION"),
        "system": std::env::consts::ARCH,
    });
    if let Some(v) = &nix_version {
        internal_params["nixVersion"] = json!(v);
    }

    let mut resolved_deps: Vec<Value> = Vec::new();
    if let Some(rev) = &git_rev {
        resolved_deps.push(json!({
            "uri": flake_ref,
            "digest": { "gitCommit": rev },
        }));
    }
    // Flake inputs from flake.lock as additional resolved dependencies.
    if let Some(path) = &flake_path
        && let Some(lock) = shared::read_flake_lock(path)
        && let Some(nodes) = lock.get("nodes").and_then(|n| n.as_object())
    {
        for (name, node) in nodes {
            if name == "root" {
                continue;
            }
            let Some(locked) = node.get("locked") else {
                continue;
            };
            let rev = locked.get("rev").and_then(|v| v.as_str());
            let nar = locked.get("narHash").and_then(|v| v.as_str());
            let mut digest = serde_json::Map::new();
            if let Some(r) = rev {
                digest.insert("gitCommit".into(), json!(r));
            }
            if let Some(n) = nar {
                digest.insert("narHash".into(), json!(n));
            }
            resolved_deps.push(json!({
                "uri": format!("flake-input:{name}"),
                "digest": Value::Object(digest),
            }));
        }
    }

    let mut run_details = json!({
        "builder": {
            "id": builder_id.unwrap_or(keys::SLSA_BUILDER_ID),
        },
        "metadata": {
            "startedOn": shared::now_rfc3339(),
            "finishedOn": shared::now_rfc3339(),
        }
    });
    if let Some(id) = invocation_id {
        run_details["metadata"]["invocationId"] = json!(id);
    }

    json!({
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{
            "name": format!("cluster-{}-activation", graph.cluster_name),
            "digest": {
                // The Nix store hash (base32, first 32 chars) is the
                // canonical activation identity. We expose it under the
                // "nixStoreHash" key since it is not a raw SHA-256.
                "nixStoreHash": activation_hash,
            }
        }],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": keys::SLSA_BUILD_TYPE,
                "externalParameters": external_params,
                "internalParameters": internal_params,
                "resolvedDependencies": resolved_deps,
            },
            "runDetails": run_details,
        }
    })
}
