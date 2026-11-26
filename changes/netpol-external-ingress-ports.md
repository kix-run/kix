+++
kind = "silent"
+++
Generated external ingress rules for `LoadBalancer` Services now apply only to the workloads each Service selects, on that Service's target ports. Previously, a `LoadBalancer` Service opened every workload in its instance to outside traffic on every port under both Cilium and standard `NetworkPolicy`. If a workload in that instance accepts outside traffic on other ports, such as the backend of a `NodePort` Service, add an ingress rule with `from = "world"` and those ports under `meta.network.intents`.
