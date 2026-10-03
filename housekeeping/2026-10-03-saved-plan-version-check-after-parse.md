# 2026-10-03 · `cli/kix-cli/src/commands/deploy.rs` · `kix deploy --plan` parses the whole plan before it checks `schema_version`.

`load_saved_plan` deserialises the file into `Plan`, and only then does `plan::saved::unusable` compare `schema_version`. A plan from a Kix with a different document shape usually fails the parse first, so the user sees a serde error ("is not a Kix plan document: invalid type ...") rather than "the plan has schema version X, and this Kix reads version Y".
