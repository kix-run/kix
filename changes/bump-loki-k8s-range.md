+++
kind = "error"
packages = ["experimental/loki"]
id = "K0459"
+++
`loki` refuses to deploy to a cluster that runs Kubernetes 1.24 or earlier, because Loki 3.7.10 requires Kubernetes 1.25 or later. Upgrade the cluster to 1.25 or later, or keep the previous Kix release for this cluster.
