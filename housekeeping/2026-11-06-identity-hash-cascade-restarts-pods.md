# 2026-11-06 · `kix/lib` identity hashes · A change to the cilium objects restarts unrelated workloads.

A change to the cilium ConfigMap alone changed the `checksum/*` pod template annotations of workloads such as Metabase (`checksum/database`) and three workloads in ludo-kind. Those annotations carry a Secret's identity hash, and that hash includes the Secret's dependencies, so a change far down the dependency graph restarts pods whose own configuration did not change. Seen when moving charts from Helm 3 to Helm 4.
