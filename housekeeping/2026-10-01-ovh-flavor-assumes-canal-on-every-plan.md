# 2026-10-01 · `kix/lib/flavors/ovh.nix` · The OVH flavor says the CNI is Canal, but the Standard plan runs Cilium.

OVH MKS now has two plans: Free uses Canal and Standard uses Cilium (OVH docs, "Plugins, software versions and reserved resources", checked 2026-10-01). The flavor binds the `cni` role to `canal` for both, so a Standard-plan cluster gets the wrong enforcer and no CiliumNetworkPolicy support.
