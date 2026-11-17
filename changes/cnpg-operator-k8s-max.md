+++
kind = "error"
packages = ["cnpg-operator"]
id = "K4963"
+++
`cnpg-operator` supports Kubernetes 1.34 to 1.36 and is tested on 1.31 to 1.37, so it refuses a cluster that declares Kubernetes 1.38 or newer. The deploy stops with `[K4963]`. Move the cluster to a Kubernetes version from 1.31 to 1.37 before you deploy this release.
