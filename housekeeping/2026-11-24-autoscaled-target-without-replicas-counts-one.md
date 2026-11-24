# 2026-11-24 · `kix/lib/plugins/availability/module.nix` · A workload an autoscaler scales, written without `spec.replicas`, counts as one replica.

An autoscaled target must leave `spec.replicas` out, so a deploy does not
reset the count. The availability plugin then sees one replica and adds no
spread constraints and no PodDisruptionBudget (module.nix:48, 262, 300), and
the quota check counts one pod (`kix/lib/vocab/quota-use.nix:278-300`),
even when a KEDA ScaledObject sets `minReplicaCount = 3`. quota-use already
reads a raw HPA's `minReplicas`. A CRD declaration that says "this kind
scales the workload its spec names, from at least N" would cover KEDA and
any other autoscaler.
