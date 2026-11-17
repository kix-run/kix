+++
kind = "note"
packages = ["experimental/loki"]
+++
`loki` runs Loki 3.7.10 instead of 3.7.8. The first deploy restarts the Loki pod once. Loki reads its data from the same claim, so logs and the index are kept. Upgrade the cluster to Kubernetes 1.25 or later before you deploy, or the deploy stops (see `[K0459]`).
