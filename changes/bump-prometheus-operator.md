+++
kind = "changed"
packages = ["experimental/prometheus-operator"]
+++
`prometheus-operator` now runs v0.95.2 (was v0.92.1), with its CRDs and
ClusterRole from that release. The first deploy restarts each Prometheus and
Alertmanager pod once, because the operator gives them a new config-reloader
image. The new CRDs refuse negative values in fields such as `sampleLimit`,
`labelLimit`, and `modulus`. Fix any monitor that sets one, or Kubernetes
can refuse its next update. The operator's ClusterRole now lists the
verbs it needs in place of `*`. To go back, run `kix rollback` or deploy the
previous Kix version.
