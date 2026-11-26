+++
kind = "error"
id = "K7426"
+++
On `gke` clusters, move any workload that uses `system-node-critical` or `system-cluster-critical` into `kube-system`, or change its `priorityClassName`. On `gke-autopilot` clusters, remove `priorityClassName` or use a custom PriorityClass instead, because Autopilot rejects user workloads in `kube-system`. If the workload's namespace has a `ResourceQuota` whose `scopeSelector` includes both classes, add that namespace to `cluster.capabilities.criticalPriorityNamespaces` instead. Kix allows both classes in every listed namespace, so the quota must allow both too. The `gke` flavor now sets `cluster.capabilities.criticalPriorityNamespaces = [ "kube-system" ]`, `gke-autopilot` sets it to `[ ]`, and Kix stops the build with `[K7426]` when a workload uses either built-in PriorityClass outside the listed namespaces. Previously, the build succeeded and `kix deploy` timed out because GKE rejects those pods in any namespace without a matching `ResourceQuota`.
