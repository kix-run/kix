# Return the `platform-network-policy` instance for a platform that enforces
# the standard Kubernetes NetworkPolicy itself, such as GKE Dataplane V2 or
# the Amazon VPC CNI with network policy turned on.
#
# The import claims the `network-policy-enforcer` role, so the netpol plugin
# writes NetworkPolicy objects through the standard renderer
# (`plugins/netpol/standard.nix`). The flavour passes how the platform
# matches an ipBlock, which decides whether each rule allows the same
# traffic as Cilium, allows more, or stops the build:
#
# - `ipBlockSelectsPods`: an ipBlock matches pod addresses.
# - `ipBlockSelectsNodes`: an ipBlock matches node addresses.
# - `ipBlockSeesServiceAddress`: an ipBlock egress peer is matched against
#   the Service address and Service port, before the platform translates it
#   to a pod.
# - `podRangeHoldsOnlyPods`: the pod range (`cluster.network.podCidr`) holds
#   nothing but pods, so a `world` rule can leave it out.
# - `nodeRangeHoldsOnlyNodes`: the node range (`cluster.network.nodeCidrs`)
#   holds nothing but nodes, so a `world` rule can leave it out.
# - `podStartsBeforePolicy`: a new pod runs for a moment before the platform
#   applies its egress policy.
#
# `network` is the cluster's `cluster.network`.

{
  lib,
  kix,
  network,
}:
{
  provider,
  ipBlockSelectsPods,
  ipBlockSelectsNodes,
  ipBlockSeesServiceAddress,
  podRangeHoldsOnlyPods,
  nodeRangeHoldsOnlyNodes,
  podStartsBeforePolicy ? false,
}:
{
  package = kix.mkImport {
    roles = [ "network-policy-enforcer" ];
    out.netpol = (import ../plugins/netpol/standard.nix { inherit lib; }).mkNetpol {
      platform = {
        inherit
          provider
          ipBlockSelectsPods
          ipBlockSelectsNodes
          ipBlockSeesServiceAddress
          podRangeHoldsOnlyPods
          nodeRangeHoldsOnlyNodes
          podStartsBeforePolicy
          ;
      };
      inherit network;
    };
  };
}
