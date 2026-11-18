+++
kind = "error"
id = "K6643"
packages = ["experimental/cdi"]
+++
`cdi` now refuses a cluster whose `k8sVersion` is outside the Kubernetes versions CDI v1.66.1 is tested on, 1.35 and 1.36. It accepted every version before. If your cluster sets an older or newer `k8sVersion`, move Kubernetes into that range first, or stay on a Kix release with an older `cdi` package. A cluster that sets no `k8sVersion` is not checked.
