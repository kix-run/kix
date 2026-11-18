+++
kind = "silent"
packages = ["experimental/cilium", "experimental/ingress-nginx", "experimental/traefik"]
+++
If you use `ingress-nginx` or `traefik` with `networkPolicy.enable = true` and
an `Ingress` or `HTTPRoute` targets a host-network pod or a node address, move
that backend onto the pod network, or add an egress policy (such as a
`networkPolicy.platformIntents` entry) allowing `ingress-nginx` or `traefik` to
reach it. Both packages now set `to = "pods"` instead of `to = "all-pods"` for
backend egress. In `cilium`, egress rules in `networkPolicy.platformIntents` and
`meta.network.intents` can now set `to = "pods"` to allow traffic only to pods.
The existing `to = "all-pods"` target maps to Cilium's `cluster` entity, which
also reaches cluster nodes, the kubelet, and the Kubernetes API server.
