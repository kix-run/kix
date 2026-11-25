+++
kind = "error"
id = "K1243"
+++
`kix deploy` and `kix rollback` now wait for a Service of type `LoadBalancer` until its load balancer gives it an address in `status.loadBalancer.ingress`, and `kix status` reports such a Service as not ready until then. Before, Kix counted the Service as ready at once, so the objects that depend on it were deployed, and `kix status` reported ok, while the address was still pending. On a cluster with no load balancer whose definition does not set `cluster.roles.loadBalancer.binding` (the build warns about this), the deploy now fails after its timeout with `[K1243]`. Change the Service's type to `ClusterIP` or `NodePort`, and set the binding to `"absent"` so that the build refuses a `LoadBalancer` Service.
