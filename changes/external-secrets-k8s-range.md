+++
kind = "error"
id = "K6770"
packages = ["experimental/external-secrets"]
+++
`external-secrets` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions External Secrets Operator v2.15 supports, which is 1.37 only. It accepted 1.25 and every later version before. If your cluster sets another `k8sVersion`, upgrade Kubernetes to 1.37 first, or stay on a Kix release with an older `external-secrets` package. A cluster that sets no `k8sVersion` is not checked.
