+++
kind = "fixed"
+++
In every built-in flavor, `platform-dns` now imports the cluster's DNS Service, so `out.name` and `out.fqdn` both refer to that Service. Previously, `platform-dns` imported the DNS Deployment and set `out.name` to the Deployment name while `out.fqdn` pointed to the Service. When `platform-dns` is active, `kix deploy` now waits until the Service has a ready endpoint before deploying dependent workloads. On `rke2`, `out.name` and `out.fqdn` now point to `rke2-coredns-rke2-coredns`, the DNS Service RKE2 installs, rather than `coredns` and `kube-dns`, which RKE2 does not create.
