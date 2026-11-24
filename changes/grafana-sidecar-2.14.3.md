+++
kind = "silent"
packages = ["grafana"]
+++
`grafana` needs no configuration changes unless you set `sidecar.resources.limits.memory`. If your limit cannot cover about 106 MiB during the first sync, remove that setting to use the new default, or raise it. The sidecar containers that load dashboards and data sources now run k8s-sidecar 2.14.3 instead of 2.8.1 (`sidecar.image`). Each sidecar container now defaults to a `96Mi` memory request (`sidecar.resources.requests.memory`, was `50Mi`) and a `256Mi` memory limit (`sidecar.resources.limits.memory`, was `100Mi`). The first deploy after upgrading restarts the Grafana pod.
