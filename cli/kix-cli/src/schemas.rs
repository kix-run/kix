//! The JSON Schemas committed under `kix-cli/schema/`, each the schema of
//! the type that prints the document it describes. Regenerate them with
//! `KIX_WRITE_SCHEMAS=1 cargo test -p kix-cli schemas`, and when a change is
//! not backward compatible, set the type's `SCHEMA_VERSION` to the day's
//! date.

/// Fail unless `kix-cli/schema/<file>` is `schema`, or write it there
/// under `KIX_WRITE_SCHEMAS`.
fn check(file: &str, schema: schemars::Schema) {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("schema")
        .join(file);
    // Through a `Value`, whose keys are sorted, so the file is stable.
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
fn the_deploy_log_schema_matches_the_type() {
    check(
        "deploy-log.schema.json",
        schemars::schema_for!(kix::cluster::deploy_log::Line),
    );
}
