# Cilium (externally managed) — CNP CRD ref marker only.
#
# Inline package for clusters where cilium is installed out-of-band
# (e.g. k3s with cilium helm-installed by a bootstrap script, or kind
# with deploy-ludo-kind.sh). Emits only the CiliumNetworkPolicy CRD ref
# marker so kix/lib/netpol.nix can route generated CNPs through it.
#
# Does NOT deploy cilium itself. The CLI deploy engine polls for the
# externally-installed CRD and waits for `Established=True` before any
# dependent CNP wave runs.
#
# Usage:
#   instances.kube-system.cilium = {
#     package = import ./kix/packages/cilium/external.nix;
#   };

{
  meta = {
    description = "Cilium (externally managed) — CNP CRD ref marker only";
    provides = [
      "network-policy-enforcer"
      "cilium"
    ];
  };

  build =
    { scope, ... }:
    let
      crdRef = scope.mkCRDRef {
        group = "cilium.io";
        kind = "CiliumNetworkPolicy";
        plural = "ciliumnetworkpolicies";
        version = "v2";
        crdScope = "Namespaced";
      };
    in
    {
      cnpCrdRef = crdRef;

      root = {
        resource = crdRef;
        requires = [ ];
        out = {
          cnpCrdRef = crdRef;
        };
      };
    };
}
