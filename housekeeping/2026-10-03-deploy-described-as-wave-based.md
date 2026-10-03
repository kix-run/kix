# 2026-10-03 · `cli/kix-cli/src/cli.rs` · `kix deploy --help` and the feature catalog still call the deploy "wave-based".

The CLI help for `deploy` reads "Wave-based deployment with confirmation", and `docs-legacy/FEATURE-CATALOG.md` says the same and lists a pipeline with "compute waves" and "apply wave-by-wave". The engine has been DAG-streaming since doc 99 (`cli/README.md` § Deploy pipeline), so the help describes an executor that no longer exists.
