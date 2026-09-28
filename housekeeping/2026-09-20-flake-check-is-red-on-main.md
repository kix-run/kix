# 2026-09-20 · `nix flake check` · The check suite fails on main.

`nix flake check` stops on
`cluster 'cluster-full' has invalid package dependencies: package
dependencies do not include all resources:
'PackageInstance/secret-ref-valkey-valkey-auth' in 'valkey' is not
referenced by its PackageInstance or its dependencies`. It fails the
same way at `origin/main`, so it is not new, but it means nobody can run
the suite to find out whether their own change broke something: the run
stops at the first failure and everything after it goes unchecked.
`nix build` of the same cluster succeeds, so only the `pi-wiring` check
sees it.
- Narrowed 2026-09-27: the pi-wiring checks now read every part of an instance, which fixed `cluster-full` and `cluster-clickhouse`. The one remaining failure is `pi-wiring-cluster-example-import`, which waits on the decision in `2026-09-27-stackgres-database-root-misses-bootstrap-job.md`.
