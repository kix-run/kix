# 2026-09-19 · `kix/packages/kubevirt/default.nix` · The package declares `fromKind` stubs for VirtualMachine and its siblings, which virt-operator creates itself with full schemas.

Only the KubeVirt CRD reaches the closure today. The first consumer CR
built from `out.crds.virtualMachine` would apply a preserve-unknown-fields
stub with one version, and virt-operator would rewrite it, so every deploy
after that conflicts on `spec.versions` the way cdi did. Those kinds should
be `mkCRDRef` markers (doc 146 §5.1 and §6).
