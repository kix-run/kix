# 2026-11-25 · `cli/kix/src/cluster/` (plan diff) · `kix plan` shows a Service's `nodePort` that the dry run allocated, not the one the cluster will assign.

A new `LoadBalancer` or `NodePort` Service plans as `+ $.spec.ports[http].nodePort: 32769`, and the real apply then gets another port (31101 on GKE, 2026-11-25). The same goes for `clusterIP` and `healthCheckNodePort`. The API server allocates these on create, and the dry run allocates a throwaway value. A reader takes the plan's number as the result. The plan could mark fields the server allocates on create as "assigned by the cluster".
