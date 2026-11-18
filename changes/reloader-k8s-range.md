+++
kind = "error"
packages = ["experimental/reloader"]
id = "K8986"
+++
`reloader` now refuses a cluster that runs Kubernetes older than 1.19, which reloader does not support. The build fails with `[K8986]` until the cluster runs Kubernetes 1.19 or later. Upgrade the cluster first, or deploy a Kix release whose `reloader` package still accepts the older version.
