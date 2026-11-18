+++
kind = "silent"
packages = ["experimental/external-dns"]
+++
`external-dns` runs upstream v0.24.0 instead of v0.23.0, and its pod restarts once on the first deploy. With the `gateway-httproute` or `gateway-grpcroute` source, a hostname from the `external-dns.kubernetes.io/hostname` annotation or from `--fqdn-template` now replaces the hostname of the Gateway listener. With `policy = "sync"`, external-dns then deletes the records it made from the listener's hostname. If you need those records, add their hostnames to the route's `hostnames` or to the annotation before you upgrade. To see what external-dns would change, deploy once with `extraArgs = [ "--dry-run=true" ]`.
