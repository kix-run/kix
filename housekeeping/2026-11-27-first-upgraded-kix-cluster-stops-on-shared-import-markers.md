# 2026-11-27 · `cli/kix/src/cluster/apply/ssa.rs` · The first Kix cluster to upgrade stops on the import markers it shares with a Kix cluster that has not upgraded.

Two Kix clusters, `lab` and `lab2`, share one Kubernetes cluster and both use `kix.flavors.kind`. The flavor gives each of them the same two objects, `PackageInstance/platform-dns` and `PackageInstance/platform-storage` in `kube-system`. Kix 0.9.2 deployed both Kix clusters. Then this Kix deployed `lab`. The plan said "The deploy would stop on 2 writes" with "field ownership conflict: kix owns .metadata.annotations.kix.run/depends-on, .metadata.annotations.kix.run/identity-hash", and the deploy applied nothing. `kix deploy lab --force-conflicts` got past it, and `lab2` upgraded later with no conflict.

Three things are wrong here.

- The values differ only because the two Kix clusters build with different library versions. `kix.run/identity-hash` and `kix.run/depends-on` on a shared import marker change with the library, and between 0.9.2 and now `kix.run/import-kind` for `platform-dns` changed too. So two Kix clusters that stay on different versions, which a `[versions]` table in `kix.toml` allows, will conflict on these objects on every deploy.
- The refusal does not say that another Kix cluster holds the fields. The holder is the old shared manager `kix`, so `ssa.rs` prints the general conflict text and not `[K5636]`. The plan does know: the same output says "1 object(s) share fields with another Kix cluster". The advice it prints, `--force-conflicts` or `ownership.cede`, is wrong for an object the user did not write.
- `--force-conflicts` is the only way through, and it also takes every other conflicting field in the same deploy.

No change record or docs page tells a user with several Kix clusters on one Kubernetes cluster what the first upgrade does. `changes/kix-clusters-share-an-object.md` covers objects the user shares on purpose.

Options, not built:

1. Make the shared import markers the same for every Kix cluster and library version: leave `identity-hash` and `depends-on` off objects with `kix.run/mode: import` in `_cluster`, or give each Kix cluster its own marker name. This removes the cause. It changes what the library writes, so it needs a `silent` record.
2. Keep the objects, and print `[K5636]` with the other Kix cluster's name when the holder is `kix` and `kix.run/activations` lists another Kix cluster's record. This fixes the message only.
3. Document it in the upgrade notes: upgrade every Kix cluster on one Kubernetes cluster together, and pass `--force-conflicts` on the first.

Option 1 is the fix. Option 3 is needed for the release either way.
