+++
kind = "error"
id = "K7426"
+++
On `gke` clusters, move any workload that uses `system-node-critical` or `system-cluster-critical` into `kube-system`, or change its `priorityClassName`. If the workload's namespace already has a `ResourceQuota` for those classes, add that namespace to `cluster.capabilities.criticalPriorityNamespaces` instead. The `gke` flavor now sets `cluster.capabilities.criticalPriorityNamespaces = [ "kube-system" ]`, and Kix stops the build with `[K7426]` when a workload uses either built-in PriorityClass outside the listed namespaces. Previously, the build succeeded and `kix deploy` timed out because GKE rejects those pods in any namespace without a matching `ResourceQuota`.
