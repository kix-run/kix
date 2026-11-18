+++
kind = "error"
packages = ["experimental/spegel"]
id = "K8826"
+++
`spegel` refuses a cluster whose `k8sVersion` is outside 1.35 to 1.37, because Spegel 0.8.1 supports only those Kubernetes versions. Upgrade the cluster to a supported Kubernetes version, or keep the previous Kix release for this cluster.
