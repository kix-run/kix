+++
kind = "fixed"
+++
A prune that removes custom resources and their operator in the same run no
longer deletes network policies that select the operator's pods while the
operator still has to remove the resources' finalizers. Before, Kix could
delete the operator's API-server egress policy and the namespace's default
deny while other policies still isolated its pods, so the operator lost its
API server access and the prune failed with `[K2794]`. Kix now treats every
workload as depending on each NetworkPolicy, CiliumNetworkPolicy, or
CiliumClusterwideNetworkPolicy whose selector matches its pods, whether Kix
generated the policy or a package wrote it. Deploy creates those policies
before the pods start, and prune deletes them after the pods are gone.
