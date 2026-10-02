# 2026-10-02 · `cli/` · CLI unit tests use private site names as fixture data.

`cli/kix/src/cluster/fetch.rs:1299-1338` and `cli/kix-cli/src/commands/deploy.rs:1966-1968` name a `lithus-secret-operator` Deployment in `lithus-system`, and `cli/kix/src/registry/reference.rs:196-233` parses images under `registry.example.com/lithus/`. The public hygiene grep in the package rework covers `kix clusters ludo docs scripts .claude/skills` and not `cli/`, so nothing reports these. They need neutral names before the repository is published.
