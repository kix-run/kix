# 2026-09-19 · `kix/packages/{coredns,velero,arc,cdi,kubevirt,infisical-operator,openebs}` · Deployments and StatefulSets built with raw `scope.mkResource` never pass through `sealWorkload`, so they get no derived spread, no interceptor edges and no pod-spec validators.

`sealWorkload` (edge analysis, netpol and availability interceptors,
`checkSpreadFeasible`, selector checks) runs only for `scope.mkDeployment`,
`mkStatefulSet` and `mkHelmWorkload`. Around twenty workloads in the
packages above are `scope.mkResource { kind = "Deployment"; ... }` and are
invisible to all of it. Seen in `clusters/example.nix`: coredns at two
replicas gets a PodDisruptionBudget (the instance processor scans every
manifest) but no `topologySpreadConstraints`. Either route workload kinds
through the seal inside `mkResource`, or convert the packages; the first
changes ludo-kind's output for every one of them (netpol edges appear), so
it is a deliberate change, not a fix-up.
