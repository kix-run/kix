+++
kind = "changed"
packages = ["kube-state-metrics"]
+++
On clusters that set `k8sVersion` below 1.36, `kube-state-metrics` now disables admission-policy collectors whose `admissionregistration.k8s.io/v1` APIs the cluster does not serve (`MutatingAdmissionPolicy` and its bindings below 1.36, and `ValidatingAdmissionPolicy` and its bindings below 1.30) and omits those resources from its ClusterRole. Those metrics are not exported on older clusters, and passing `--resources` in `extraArgs` overrides the generated `--resources` flag. `kube-state-metrics` also warns when `k8sVersion` is not Kubernetes 1.36, the only minor version kube-state-metrics 2.20.0 lists as supported, without stopping the build. Clusters that leave `k8sVersion` unset keep all default collectors and are not checked.
