# 2026-10-04 · `clusters/test-keycloak.nix` and others · Test clusters say a second StackGres instance never schedules on kind, which no longer follows from the package.

test-keycloak, test-metabase, test-harbor, and test-monitoring-netpol set
`instances = 1` with the comment "kind has one node and the pods
anti-affine, so a second instance never schedules". stackgres-cluster turns
StackGres's one-pod-per-node anti-affinity off when
`cluster.topology.failureDomainKeys` is empty, and the kind flavor sets
`multiNode = false`, which empties it. The comment may still hold for CPU or
memory on a small kind node, but then it names the wrong cause.
