//! SLSA v1 provenance as an in-toto Statement whose predicate is a SLSA
//! `https://slsa.dev/provenance/v1` predicate.
//!
//! The activation identity hash IS the subject digest. Nix content-addressing
//! means no additional hashing is needed: two identical clusters produce the
//! same subject, and any byte-level change flips the hash.
//!
//! Two sources, one assembly. By default the statement is built from a fresh
//! evaluation, which answers "what would be deployed". With `--from-cluster`
//! it is built from the deploy receipt on the cluster's active Activation,
//! which answers "what was deployed", from a machine that never built it.
//! Both go through [`super::receipt::attestation_from_receipt`], so the two
//! cannot drift apart.
//!
//! This command emits an unsigned Statement so signing can be added
//! independently.

use miette::{IntoDiagnostic, Result, miette};
use serde_json::Value;

use kix::eval::store_graph::StoreGraph;

use crate::cli::{ComplianceAttestArgs, OutputFormat};

use super::receipt;
use crate::commands::CommandContext;

pub fn run(args: &ComplianceAttestArgs, ctx: &mut CommandContext) -> Result<()> {
    let statement = if args.from_cluster {
        let cluster = ctx.cluster_identity(&args.cluster, crate::commands::Lookup::ReadOnly)?;
        let record = ctx
            .runtime
            .block_on(fetch_receipt(&cluster, ctx.global.context.as_deref()))?;
        receipt::attestation_from_receipt(
            &record,
            args.builder_id.as_deref(),
            args.invocation_id.as_deref(),
        )
    } else {
        let (_result_path, graph) = super::shared::build_and_load(ctx, &args.cluster)?;
        build_attestation(
            &graph,
            &ctx.global.flake,
            args.builder_id.as_deref(),
            args.invocation_id.as_deref(),
        )
    };

    let text = match ctx.output_format(OutputFormat::Json) {
        OutputFormat::Yaml => serde_yml::to_string(&statement).into_diagnostic()?,
        _ => serde_json::to_string_pretty(&statement).into_diagnostic()?,
    };
    println!("{text}");
    Ok(())
}

/// Build a statement from a fresh evaluation, by way of the receipt that a
/// deploy of this same build would write.
pub fn build_attestation(
    graph: &StoreGraph,
    flake_ref: &str,
    builder_id: Option<&str>,
    invocation_id: Option<&str>,
) -> Value {
    let record = receipt::build_receipt(graph, flake_ref);
    if record["source"]["dirty"] == Value::Bool(true) {
        // Warned rather than refused. Attesting from a dirty tree is
        // sometimes the honest thing to do; doing it silently never is.
        eprintln!(
            "warning: the working tree has uncommitted changes, so the recorded commit does not fully describe this build. The attestation marks the working tree as dirty."
        );
    }
    receipt::attestation_from_receipt(&record, builder_id, invocation_id)
}

/// Read the receipt from the cluster's active Activation.
async fn fetch_receipt(cluster: &str, context: Option<&str>) -> Result<Value> {
    use kix::cluster::{activation, fetch};

    let client = fetch::make_client(context)
        .await
        .map_err(|e| miette!("failed to connect to cluster: {e}"))?;
    let discovery = fetch::discover_resources(&client)
        .await
        .map_err(|e| miette!("{e}"))?;
    let Some((ar, _)) = activation::find_activation_ar(&discovery).map_err(|e| miette!("{e}"))?
    else {
        return Err(miette!(
            "this cluster has no Activation CRD, so Kix has never deployed to it"
        ));
    };
    match activation::read_receipt(&client, ar, cluster).await {
        Ok(Some(receipt)) => Ok(receipt),
        Ok(None) => Err(miette!(
            "no deploy receipt on cluster '{cluster}'. Either nothing is deployed, or it was deployed by a kix that predates receipts. Deploy again to write one."
        )),
        Err(e) => Err(miette!("failed to read the activation: {e}")),
    }
}
