# 2026-09-27 · `kix deploy` · The field-ownership conflict message refers to a field list it does not print.

`ApplyError::Conflict` in `cli/kix/src/cluster/apply.rs` says "another tool
owns fields that Kix is trying to change. Review the fields listed below." No
list follows. The only field names appear inside the raw Kubernetes error at
the end of the same line (`.spec.replicas`). `conflict_paths` already extracts
those names, but only the ceded-fields path uses it (the `info!` log and
`without_ceded_conflicts`), never this error.
- Hit again 2026-11-11 while rewording the deploy failure messages; the message still points at a list it does not print.
