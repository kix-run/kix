//! Tests verifying that the committed JSON Schemas under `kix-cli/schema/`
//! match the Rust types that produce those documents.
//!
//! Regenerate the schema files with `KIX_WRITE_SCHEMAS=1 cargo test -p kix-cli schemas`.
//! When making a backward-incompatible change, update the corresponding type's
//! `SCHEMA_VERSION` to the current date.

/// Verify that `kix-cli/schema/<file>` matches `schema`, or overwrite it when
/// `KIX_WRITE_SCHEMAS` is set.
fn check(file: &str, schema: schemars::Schema) {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("schema")
        .join(file);
    // Convert through `serde_json::Value` so object keys are sorted deterministically.
    let schema = serde_json::to_value(schema).unwrap();
    let generated = serde_json::to_string_pretty(&schema).unwrap() + "\n";
    if std::env::var_os("KIX_WRITE_SCHEMAS").is_some() {
        std::fs::write(&path, &generated).unwrap();
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        committed == generated,
        "kix-cli/schema/{file} does not match its type. Regenerate it with \
         KIX_WRITE_SCHEMAS=1 cargo test -p kix-cli schemas, and set SCHEMA_VERSION \
         to the day's date if the change is not backward compatible."
    );
}

#[test]
fn the_plan_schema_matches_the_type() {
    check(
        "plan.schema.json",
        schemars::schema_for!(kix::plan::document::Plan),
    );
}

#[test]
fn the_plan_file_header_schema_matches_the_type() {
    check(
        "kixplan.schema.json",
        schemars::schema_for!(kix::plan::file::Header),
    );
}

#[test]
fn the_deploy_log_schema_matches_the_type() {
    check(
        "deploy-log.schema.json",
        schemars::schema_for!(kix::cluster::deploy_log::Line),
    );
}

/// Return the schema of a command's output. Kix only writes these
/// documents, so a field that it leaves out when empty is not required.
fn output<T: schemars::JsonSchema>() -> schemars::Schema {
    schemars::generate::SchemaSettings::default()
        .for_serialize()
        .into_generator()
        .into_root_schema_for::<T>()
}

/// The JSON and YAML output of a command, one schema per response type.
/// `kix diff -o json` prints the plan document (`plan.schema.json`).
/// `kix compliance sbom` and `attest` print documents that published
/// standards define.
#[test]
fn the_command_output_schemas_match_their_types() {
    use crate::commands::*;
    check("build.schema.json", output::<build::BuildResponse>());
    check("check.schema.json", output::<check::CheckResponse>());
    check("graph.schema.json", output::<graph::GraphResponse>());
    check("images.schema.json", output::<images::ImagesResponse>());
    check("inspect.schema.json", output::<inspect::InspectResponse>());
    check(
        "list-clusters.schema.json",
        output::<list::ClustersResponse>(),
    );
    check(
        "list-packages.schema.json",
        output::<list::PackagesResponse>(),
    );
    check("pin-set.schema.json", output::<pin::PinSetResponse>());
    check("pin-rm.schema.json", output::<pin::PinRmResponse>());
    check("pin-check.schema.json", output::<pin::PinCheckResponse>());
    check("pin-list.schema.json", output::<pin::PinListResponse>());
    check(
        "rollback-list.schema.json",
        output::<rollback::HistoryResponse>(),
    );
    check(
        "plan-comparison.schema.json",
        output::<deploy::ComparisonResponse<'static>>(),
    );
    check("status.schema.json", output::<status::StatusResponse>());
}
