# 2026-11-13 · `clusters/example.nix` · The example cluster cannot deploy to a fresh kind cluster, because its CoreDNS clashes with kind's.

The cluster deploys its own CoreDNS with `clusterIP = "10.96.0.10"`. Kind already runs a `coredns` Deployment, whose selector Kubernetes does not let a deploy change, and a `kube-dns` Service that holds 10.96.0.10. The apiserver dry run in `kix plan` does not catch the IP clash, so the deploy fails partway. A kind test of 0.10.0-rc.4 had to delete both objects by hand before the deploy went through.
