+++
kind = "error"
id = "K8826"
packages = ["experimental/spegel"]
+++
`spegel` now refuses a cluster whose `k8sVersion` is older than 1.34. Its registry Service sets `trafficDistribution: PreferSameNode`, which Kubernetes 1.33 and older do not accept. If your cluster sets an older `k8sVersion`, move it to Kubernetes 1.34 or newer first, or stay on a Kix release with an older `spegel` package. On a `k8sVersion` outside 1.35 to 1.37, which Spegel 0.8.1 states support for, the build passes with a warning. A cluster that sets no `k8sVersion` is not checked.
