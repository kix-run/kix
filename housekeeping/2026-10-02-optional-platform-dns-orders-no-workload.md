# 2026-10-02 · `kix/lib/flavors/*.nix` · On every flavour except kind, no workload waits for DNS.

The flavours declare `platform-dns` with `optional = true`, and an inactive
optional import answers no dependency, so the implicit `dns` dependency in
`eval/instance.nix` finds nothing and adds no `kix.run/depends-on` entry.
Making the import non-optional would make `kix deploy` wait for the
Deployment it names, which is wrong on RKE2 (`rke2-coredns-rke2-coredns`) and
OpenShift (`dns-default` in `openshift-dns`), see
2026-10-01-flavor-dns-imports-hand-copy-service-name.md.
- 2026-11-23: the flavours now import the DNS Service, and RKE2's import names `rke2-coredns-rke2-coredns`, so the wait is right on RKE2. It stays wrong on GKE Autopilot and OpenShift, see 2026-11-23-platform-dns-marker-outside-service-namespace.md.
