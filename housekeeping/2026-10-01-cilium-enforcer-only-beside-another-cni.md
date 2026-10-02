# 2026-10-01 · `kix/packages/cilium` · Cilium cannot be declared as a policy enforcer beside another CNI.

The package always claims the `cni` role with `network-policy-enforcer`, so Cilium in chaining mode on EKS (aws-vpc-cni) or AKS (Azure CNI), where the platform owns the pod network and Cilium only enforces policy, is refused by the exclusive `cni` binding. Supporting it needs a way for the instance to claim only the enforcer role, which `meta.roles` (static) cannot express per cluster.
