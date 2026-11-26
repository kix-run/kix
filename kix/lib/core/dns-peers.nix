# The DNS endpoints of the cluster's `dns` role provider (`meta.dnsPeers`),
# which the network policy enforcer builds its DNS egress rule from.
#
# A peer is `{ namespace; podSelector; }` (pods by label in one namespace)
# or `{ cidr; }` (an address range). A pod peer without `namespace` means
# the namespace of the provider's instance. Kix reads the peers from the
# provider's metadata, which it can read without evaluating the instance.
# The provider's `out` cannot serve: evaluating the instance evaluates its
# own policies, and those need the peers.

{ lib }:

let
  inherit (import ./error.nix { inherit lib; }) fail;
in
rec {
  # The DNS peers when the `dns` role provider publishes none: the
  # `kube-dns` pods in `kube-system`, as on kubeadm, kind, k3s, RKE2, and EKS.
  defaultDnsPeers = [
    {
      namespace = "kube-system";
      podSelector."k8s-app" = "kube-dns";
    }
  ];

  # Return `peers` when each is `{ namespace; podSelector; }` (pods by label
  # in one namespace) or `{ cidr; }` (an address range), or fail naming the
  # `dns` role provider.
  checkDnsPeers =
    provider: peers:
    let
      isPodPeer =
        p:
        builtins.attrNames p == [
          "namespace"
          "podSelector"
        ]
        && builtins.isString p.namespace
        && builtins.isAttrs p.podSelector;
      isCidrPeer = p: builtins.attrNames p == [ "cidr" ] && builtins.isString p.cidr;
      bad = builtins.filter (p: !(builtins.isAttrs p && (isPodPeer p || isCidrPeer p))) peers;
    in
    if !(builtins.isList peers) || peers == [ ] then
      fail {
        message = "DNS provider `${provider}` sets `dnsPeers` (`meta.dnsPeers`) to ${builtins.toJSON peers}, which is not a non-empty list. Kix could not build DNS egress network policies.";
        fix = "On `${provider}`, set `dnsPeers` on `kix.mkImport` (or `meta.dnsPeers` in a package) to a non-empty list of `{ namespace = \"<namespace>\"; podSelector = { ... }; }` (`namespace` is optional) or `{ cidr = \"<cidr>\"; }` entries. Remove the setting (or set `dnsPeers = null`) to allow pods labeled `k8s-app = \"kube-dns\"` in `kube-system`.";
      }
    else if bad != [ ] then
      fail {
        message = "DNS provider `${provider}` has invalid entries in `dnsPeers` (`meta.dnsPeers`): ${builtins.toJSON bad}. Kix could not build DNS egress network policies.";
        fix = "Write each entry in `dnsPeers` on `kix.mkImport` (or `meta.dnsPeers` in a package) as `{ namespace = \"<namespace>\"; podSelector = { ... }; }` (`namespace` is optional and defaults to the provider's namespace) or `{ cidr = \"<cidr>\"; }`, with no extra fields.";
      }
    else
      peers;

  # Return the DNS peers of the cluster's `dns` role provider
  # (`{ ns; inst; meta; }` from `findRoleProvider`), with a pod peer's
  # missing `namespace` set to the provider's, or `defaultDnsPeers` when no
  # instance claims the role or the provider declares none.
  dnsPeersOf =
    findRoleProvider:
    let
      provider = findRoleProvider "dns";
      declared = if provider == null then null else provider.meta.dnsPeers or null;
      withNamespace =
        p:
        if builtins.isAttrs p && p ? podSelector && !(p ? namespace) then
          p // { namespace = provider.ns; }
        else
          p;
    in
    if declared == null then
      defaultDnsPeers
    else
      checkDnsPeers "${provider.ns}/${provider.inst}" (
        if builtins.isList declared then map withNamespace declared else declared
      );

  # Return the enforcer's `out` with its rules built for the cluster's DNS
  # peers (`dnsPeersOf`), or null for a null `enforcerOut`. Every reader of
  # the enforcer (package scopes and the netpol plugin) goes through this,
  # so all of them see one DNS rule.
  bindDnsPeers =
    findRoleProvider: enforcerOut:
    if enforcerOut == null || !(enforcerOut.netpol ? withDnsPeers) then
      enforcerOut
    else
      enforcerOut
      // {
        netpol = enforcerOut.netpol.withDnsPeers (dnsPeersOf findRoleProvider);
      };
}
