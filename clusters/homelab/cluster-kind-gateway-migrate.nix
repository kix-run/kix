# homelab-kind-gateway-migrate: homelab-kind moved from ingress-nginx to
# Gateway API.
#
# The cluster name is `homelab-kind`, the same as cluster-kind.nix, so Kix
# treats a deploy of this cluster over a `homelab-kind` activation as an
# upgrade of that activation, not a new cluster.
# scripts/kix-rollback-check.sh builds it as the second desired state.

{ kix, packages }:

kix.buildCluster {
  name = "homelab-kind";
  specialArgs = { inherit packages kix; };
  modules = (import ./_kind-gateway-modules.nix { inherit kix packages; }).modules;
}
