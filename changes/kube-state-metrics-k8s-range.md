+++
kind = "changed"
packages = ["kube-state-metrics"]
+++
`kube-state-metrics` now chooses its collectors from the cluster's `k8sVersion`. kube-state-metrics 2.20.0 reads MutatingAdmissionPolicy and ValidatingAdmissionPolicy objects through `admissionregistration.k8s.io/v1`, which Kubernetes serves from 1.36 and 1.30. On an older `k8sVersion` the package leaves those collectors out of `--resources` and their kinds out of its ClusterRole, so the series for them are absent. It also warns when `k8sVersion` is not 1.36, the one version kube-state-metrics 2.20.0 states support for. A cluster that sets no `k8sVersion` keeps every collector, and `--resources` in `extraArgs` replaces the package's choice.
