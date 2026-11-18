+++
kind = "error"
id = "K9973"
packages = ["kube-state-metrics"]
+++
If your cluster uses `kube-state-metrics` and sets `k8sVersion` below 1.36, upgrade the cluster to Kubernetes 1.36 or newer and update `k8sVersion` before upgrading Kix, or stay on an older version of Kix. `kube-state-metrics` previously accepted Kubernetes 1.25 and newer, and now fails the build below 1.36 because kube-state-metrics 2.20.0 reads `MutatingAdmissionPolicy` resources from `admissionregistration.k8s.io/v1`, which Kubernetes added in 1.36. On a `k8sVersion` newer than 1.36, the build succeeds with a warning because the upstream project lists support for 1.36 only. Clusters that leave `k8sVersion` unset are not checked.
