# 2026-09-19 · `kix/lib/scope/validators.nix` · A pod spec can name a `priorityClassName` that nothing in the cluster creates, and the build says nothing.

The apiserver rejects every pod of such a workload at admission ("no
PriorityClass with name X was found"). `kix/packages/kubevirt` shipped
that way until the seal conversion added its `kubevirt-cluster-critical`
PriorityClass, and the ZFS and LVM drivers in `kix/packages/openebs`
named four `openebs-*-critical` classes the package never built. The
cross-resource checks in `kix/lib/eval/validate.nix` already resolve
ServiceAccounts and ConfigMaps by name, so a PriorityClass lookup
(cluster-scoped, with the `system-*` classes as builtins) fits there.
