+++
kind = "fixed"
+++
Each flavor's `platform-dns` import now names the platform's DNS Service, and derives `out.name` and `out.fqdn` from that one name and namespace. Before, `out.name` named the DNS Deployment while `out.fqdn` named the Service. When a workload activates `platform-dns`, `kix deploy` now waits until that Service has a ready endpoint, instead of waiting for a Deployment. On `rke2`, `out.name` and `out.fqdn` now name `rke2-coredns-rke2-coredns`, the Service RKE2 creates, instead of `coredns` and `kube-dns`, which RKE2 does not create.
