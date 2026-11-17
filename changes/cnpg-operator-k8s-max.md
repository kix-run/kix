+++
kind = "error"
packages = ["cnpg-operator"]
id = "K4963"
+++
`cnpg-operator` supports Kubernetes 1.34 to 1.36 only, so it refuses a cluster that declares Kubernetes 1.31 to 1.33, or 1.37 or newer. The deploy stops with `[K4963]`. Before you deploy this release, move the cluster to Kubernetes 1.34, 1.35, or 1.36.
