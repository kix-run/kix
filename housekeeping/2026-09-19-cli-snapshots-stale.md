# 2026-09-19 · CLI snapshots · Four example output snapshots fail on main.

`cargo test --workspace` fails in `snapshot_test` for the example YAML,
JSON, inspect, and graph output. The committed snapshots contain older
resource content and activation hashes. All four also differ when running
the CLI against a clean checkout of main at `651edd0`, before the diagnostic
wording changes. Refresh the fixtures and check whether store paths and
activation hashes need normalization to keep these tests stable.
