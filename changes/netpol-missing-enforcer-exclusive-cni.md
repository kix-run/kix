+++
kind = "fixed"
+++
No changes are needed. When `networkPolicy.enable = true` fails on a cluster whose platform owns the pod network (`cluster.roles.cni.binding = "exclusive"`, such as on `gke`, `gke-autopilot`, `eks`, `aks`, or `k3s`), the error message now names that pod network, explains that Kix only generates Cilium network policies today, and tells you to set `networkPolicy.enable = false` instead of suggesting a `cilium` instance that the cluster would reject.
