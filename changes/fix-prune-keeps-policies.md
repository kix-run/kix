+++
kind = "fixed"
+++
Pruning custom resources together with their operator no longer deletes the
operator's network policies while the operator is still removing finalizers.
Previously, Kix could delete the operator's API server egress policy while
other policies still isolated its pods. The operator lost access to the API
server, and deletion timed out with `[K2794]`. Kix now makes every workload
(except pods with `hostNetwork: true`) depend on each generated or
package-defined `NetworkPolicy`, `CiliumNetworkPolicy`, and
`CiliumClusterwideNetworkPolicy` whose selector matches its pods, unless the
policy already depends on the workload. Kix applies those policies before the
workload during deployment and deletes them after the workload when pruning.
