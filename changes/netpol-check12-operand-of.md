+++
kind = "fixed"
+++
No changes are needed for existing clusters. If a `NetworkPolicy` resource selects pods created at runtime by an operator, add the `kix.run/operand-of` annotation (`"<group>/<Kind>/<name>"`), as on a `Service` or `PodDisruptionBudget`. Build validation now accepts the policy's `podSelector` when that custom resource is in the same namespace in the build. Previously, Kix rejected these policies because no workload pod template in the build matched `podSelector`.
