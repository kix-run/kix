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
