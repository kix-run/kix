# The DNS endpoints of the cluster's `dns` role provider (`out.dnsPeers`),
# which the network policy enforcer builds its DNS egress rule from.
#
# A peer is `{ namespace; podSelector; }` (pods by label in one namespace)
# or `{ cidr; }` (an address range).

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
        message = "The dns role provider ${provider} sets out.dnsPeers to ${builtins.toJSON peers}, and it must be a non-empty list.";
        fix = "List the DNS endpoints as { namespace; podSelector; } or { cidr; }, or leave out.dnsPeers unset for the kube-dns pods in kube-system.";
      }
    else if bad != [ ] then
      fail {
        message = "The dns role provider ${provider} lists DNS peers that are neither { namespace; podSelector; } nor { cidr; }: ${builtins.toJSON bad}.";
        fix = "Give each peer either `namespace` and `podSelector`, or `cidr`.";
      }
    else
      peers;

  # Return the DNS peers of the cluster's `dns` role provider, or
  # `defaultDnsPeers` when no instance claims the role or the provider sets
  # none. Kix reads `out.dnsPeers` of an import only (`kix.mkImport`, such as
  # a flavour's `platform-dns`), whose `out` is fixed data. Reading a managed
  # package's `out` evaluates the whole instance, whose own network policies
  # read these peers, so a managed provider gets the default.
  dnsPeersOf =
    findRoleProvider:
    let
      provider = findRoleProvider "dns";
    in
    if provider == null || !(provider.isImport or false) || !(provider.out ? dnsPeers) then
      defaultDnsPeers
    else
      checkDnsPeers "${provider.ns}/${provider.inst}" provider.out.dnsPeers;

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
