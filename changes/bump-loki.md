+++
kind = "note"
packages = ["experimental/loki"]
+++
`loki` runs Loki 3.7.10 instead of 3.7.8. The first deploy restarts the Loki pod once. Loki keeps its logs and index on the same claim, so they carry over. Upgrade the cluster to Kubernetes 1.25 or later before you deploy, or the deploy stops (see `[K0459]`). Upstream documents no way back to an older version. In our test, Loki 3.7.8 started on data that 3.7.10 wrote and read its logs, so to go back, deploy the previous Kix release.
