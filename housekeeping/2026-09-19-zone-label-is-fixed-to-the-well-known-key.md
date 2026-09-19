# 2026-09-19 · `kix/lib/plugins/availability/module.nix` · The zone failure domain is always the label `topology.kubernetes.io/zone`, and neither the cluster nor the flavor can name a different one.

The module hardcodes `zoneKey` and `hostKey` (lines 30 and 31) and
`cluster.topology.failureDomainKeys` is read-only. Managed clouds set the
well-known zone label through their cloud controller, so it works there.
A bare-metal or on-prem cluster whose admin labels racks or hypervisor
hosts by hand, or a Talos, RKE2 or k3s cluster with no cloud controller,
has no way to tell Kix which label is the failure domain. The `zone`
level then derives constraints that no node satisfies, and with
`DoNotSchedule` on that key the pods stay Pending. A writable zone key
that flavors may set with `mkDefault` would close it; the hostname key is
set by the kubelet and should stay fixed.
