+++
kind = "changed"
packages = ["grafana"]
+++
`grafana` runs k8s-sidecar 2.14.3 (was 2.8.1) for the containers that load dashboards and data sources. Each sidecar container now requests 96Mi of memory and is limited to 256Mi (was 50Mi and 100Mi), because 2.14.3 uses about 106 MiB during its first sync. The first deploy restarts the Grafana pod.
