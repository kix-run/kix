# 2026-11-04 · `cli/kix-cli/tests/snapshots/snapshot_test__build_example_*.snap` · `snapshot_build_example_yaml` and `snapshot_build_example_json` fail on main.

The build output now stamps `kix.run/built-via` on the example cluster's Activation record, and the stored snapshots have no such line. The value is a store path, so accepting the new output as it is would make the snapshot depend on the store path of the build. Seen on main at 9f35d2a4.
