+++
kind = "fixed"
+++
A prune that removes custom resources and their operator in the same run no
longer deletes the operator's RoleBindings, ClusterRoleBindings, and the roles
they bind while the operator still has to remove the resources' finalizers.
Kix now treats a workload as depending on every binding that grants rights to
the ServiceAccount its pods run as. Deploy creates those bindings before the
workload, and prune deletes them after it. When a delete times out and the
operator's pods are ready, the `[K2794]` message no longer says the operator
is ready to act. It says only that its pods are ready and asks you to check
its logs.
