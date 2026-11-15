+++
kind = "silent"
packages = ["experimental/cilium", "experimental/ingress-nginx", "experimental/traefik"]
+++
A network intent can now name `to = "pods"`, which reaches every pod in the
cluster and nothing else. `ingress-nginx` and `traefik` use it for their
backends in place of `all-pods`, which Cilium renders as its `cluster` entity
and which also reaches the nodes, the kubelet, and the Kubernetes API server.
Under network policy, an Ingress or HTTPRoute whose backend runs on the host
network, or points at a node address, no longer gets through; give such a
backend a pod network address or a policy of its own.
