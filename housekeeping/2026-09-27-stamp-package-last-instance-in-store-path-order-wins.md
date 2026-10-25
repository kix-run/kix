# 2026-09-27 · `cli/kix/src/eval/stamp.rs`, `packageIndex` · A resource that two package instances emit gets `kix.run/package` from the last instance in store-path order, so unrelated hash changes move its owner.

In the example cluster, `postgres` and `immich-db` both emit
`PackageInstance/secret-ref-postgres-postgres` and
`service-ref-postgres-postgres` in namespace `immich`, and each is one
store path listed under both instances. `packageIndex` in
`kix/lib/eval/cluster.nix` writes `kix-packages.json` with
`builtins.toJSON`, which sorts the instances by PackageInstance store
path. `stamp_annotations` stamps in that order, so the last instance
overwrites the others. Any change that alters either instance's hash
can reorder them and move the markers to the other owner, which churns
manifests and snapshots
(`cli/kix-cli/tests/snapshots/snapshot_test__build_example_yaml.snap`)
and can misattribute the object.

- Hit again 2026-10-02 while regenerating the CLI snapshots after the W8
  merges: both markers moved from `postgres` to `immich-db`.
