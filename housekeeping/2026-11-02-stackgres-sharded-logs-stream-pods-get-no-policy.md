# 2026-11-02 · `kix/packages/stackgres-operator` · The pods of an SGShardedCluster, SGDistributedLogs, or SGStream get no network policy.

No package builds these kinds, so a cluster that writes one from `stackgres-operator`'s `out.crds` gets pods with no policy. Under the namespace default deny they cannot reach DNS, the API server, or each other, and the resource never becomes ready. stackgres-cluster covers only SGCluster pods and the SGDbOps and SGBackup Job pods. The operator header says so; nothing warns at build time.
