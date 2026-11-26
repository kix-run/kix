+++
kind = "silent"
+++
The ingress rule Kix generates for a `LoadBalancer` Service now admits traffic from outside the cluster only on that Service's target ports, and only to the workloads the Service selects. Before, every workload in an instance with a `LoadBalancer` Service accepted traffic from outside the cluster on every port, with both the `cilium` enforcer and standard `NetworkPolicy`. A workload that took outside traffic on a port no `LoadBalancer` Service names, such as the backend of a `NodePort` Service in the same instance, now needs a `meta.network.intents` ingress rule with `from = "world"` and that port.
