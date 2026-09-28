# 2026-09-28 · `kix/lib/eval/instance.nix` · `kix.run/inverse-deps` names a dependency's PackageInstance.

The `immich-db` PackageInstance in `cluster-ludo-kind` carries `kix.run/inverse-deps: PackageInstance/postgres`. The only PackageInstance named `postgres` is the stackgres-cluster instance that `immich-db` depends on (`data/postgres-packageinstance.yaml`), so the annotation lists a forward dependency as an inverse one. The same shape appears for `harbor-db` in `cluster-harbor`.
