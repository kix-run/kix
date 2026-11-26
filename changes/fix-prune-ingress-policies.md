+++
kind = "fixed"
+++
`kix deploy` now applies `NetworkPolicy`, `CiliumNetworkPolicy`, and
`CiliumClusterwideNetworkPolicy` resources before the workloads whose pods they
select, and pruning deletes them after those workloads, even when a policy's
`spec` references a workload's selector. Previously, those `spec` references
recorded a dependency on the workload. For policies such as Prometheus scrape
policies and cert-manager's webhook ingress policy, `kix deploy` created the
workload before the policy, and pruning deleted the policy while the pods were
still running. Deleting the webhook policy early blocked the Kubernetes API
server from reaching a webhook it was still configured to call. Kix no longer
records dependencies from a network policy's `spec`. If a policy must wait for
another resource, list that resource in `requires`.
