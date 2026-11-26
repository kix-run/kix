+++
kind = "fixed"
+++
Pruning custom resources together with their operator no longer deletes the
operator's RBAC roles and bindings while the operator still needs them to
remove finalizers. Kix now makes every workload depend on the `RoleBinding` and
`ClusterRoleBinding` objects for its `ServiceAccount`, unless a binding already
depends on the workload. In Helm charts, bindings now also depend on the `Role`
or `ClusterRole` they reference. Kix applies those RBAC objects before the
workload during deployment and deletes them after the workload when pruning. If
deleting a custom resource times out (`[K2794]`) while its controller has ready
pods, Kix now reports pod readiness instead of calling the controller ready,
and tells you to check its logs for errors such as missing permissions.
