+++
kind = "error"
id = "K2763"
packages = ["experimental/tempo"]
+++
`tempo` refuses to deploy to a cluster that runs Kubernetes 1.24 or earlier, because Tempo's documentation requires Kubernetes 1.25 or later. It accepted every version before. Upgrade the cluster to 1.25 or later, or keep the previous Kix release for this cluster. A cluster that sets no `k8sVersion` is not checked.
