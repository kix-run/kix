+++
kind = "error"
id = "K7426"
+++
The new capability `cluster.capabilities.criticalPriorityNamespaces` lists the namespaces where the platform admits pods that use the built-in `system-node-critical` or `system-cluster-critical` PriorityClass. The `gke` flavor sets it to `[ "kube-system" ]`, because GKE refuses these pods in any namespace without a ResourceQuota for these classes. On a `gke` cluster, a workload that uses one of these classes outside `kube-system` now fails evaluation with `[K7426]`. Before, it built, and its deploy waited until it timed out because the API server refused every pod. Move the instance to `kube-system`, or if you created such a ResourceQuota in the namespace, add the namespace to the list.
