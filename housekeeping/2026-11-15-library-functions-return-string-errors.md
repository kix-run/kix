# 2026-11-15 · `cli/` · About 80 library functions still return `Result<_, String>`.

A caller cannot match on a string, and each `map_err(|e| e.to_string())` drops the error's type and source. The largest groups left: `kix/src/legacy_domain/` (21, the `MigrationOps` trait and its fake, due to go when the retired-domain layer is removed), `kix/src/pins/mod.rs` (8), `kix-bundle/src/file.rs` (9), `kix-core/src/build_source.rs` (7), `kix-core/src/eval/derivation.rs` (6), and `kix/src/plan/planner.rs` (4). `grep -rn "Result<[^;{]*, String>" --include=*.rs cli/*/src | grep "fn "` lists them.
