# 2026-09-27 · `cli/kix-cli/src/cli.rs` · `kix deploy --show-refs` is accepted and documented in `--help` but changes nothing.

`DeployArgs.show_refs` is read nowhere outside `cli.rs`, yet the help describes `refs` and `full` rendering modes for the graph view. The `--accept-migrations` help in the same struct points users at `v2_discussions/67_stateful_migration_orchestration.md`, an internal design doc they cannot see. Remove the flag or wire it up, and drop the internal path from the help.
