+++
kind = "fixed"
+++
A network policy no longer depends on the pods it names. Before, a policy
that read a workload's selector, such as the policies that let Prometheus
scrape a target or let the API server call cert-manager's webhook, recorded
the workload as a dependency. Deploy then created the pods before that
policy, and prune deleted the policy while the pods still ran, so the API
server could not reach a webhook it was still configured to call. Kix now
ignores the references in a NetworkPolicy's, CiliumNetworkPolicy's, or
CiliumClusterwideNetworkPolicy's `spec` when it orders them, creates every
policy that selects a workload's pods before the workload, and deletes it
after. A dependency a policy really needs can still be given with `requires`.
The first deploy after the upgrade applies those policies again, because
their recorded dependencies change.
