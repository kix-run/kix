# 2026-09-19 · `kix/packages/cilium` · With `policyEnforcementMode = "always"`, a pod in a namespace kix does not manage cannot resolve DNS.

A `busybox` pod in `default` on the harbor smoke cluster got
`Temporary failure in name resolution` for every lookup; cilium dropped
its UDP 53 to coredns because the pod has no policy and enforcement is
on for everything. kix writes DNS egress only for the workloads it
renders. Anything else on the cluster, a debug pod, an operator's own
Jobs, a `kubectl run`, is cut off, and the failure reads as a DNS
outage rather than a policy.
