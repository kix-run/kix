+++
kind = "fixed"
+++
When `networkPolicy.enable = true` finds no network policy enforcer on a cluster whose platform owns the pod network (`cluster.roles.cni.binding = "exclusive"`, as on the `gke`, `gke-autopilot`, `eks`, `aks`, and `k3s` flavors), the error no longer tells you to declare a `cilium` instance, which that binding refuses. It now names the pod network, says that Kix cannot generate policy for it yet, and suggests `networkPolicy.enable = false`.
