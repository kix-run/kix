+++
kind = "error"
id = "K1243"
+++
If a cluster has no load balancer, change any `LoadBalancer` Service on it to `ClusterIP` or `NodePort`, and set `cluster.roles.loadBalancer.binding = "absent"` in the cluster definition so the build rejects `LoadBalancer` Services. `kix deploy` and `kix rollback` now wait for a `LoadBalancer` Service to receive an address in `status.loadBalancer.ingress` before deploying objects that depend on it, and `kix status` reports the Service as `not ready` until then. On a cluster without a load balancer where `cluster.roles.loadBalancer.binding` is unset (which the build already warns about), the deploy now times out and fails with `[K1243]`. When the Service sets `spec.loadBalancerClass`, the message names the class instead, because only a controller for that class gives the Service an address. Previously, Kix counted every Service as ready at once, so dependent objects deployed and `kix status` reported `ok` while the address was still pending.
