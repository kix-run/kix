# Return the `platform-dns` instance for a platform's built-in DNS Service.
#
# A flavour names the Service once, by `name` and `namespace`, and the import
# derives `out.name` and `out.fqdn` from them. The import marker names the
# Service, so `kix deploy` checks that it exists in the namespace of the
# import instance before it applies the workloads that depend on DNS.
#
# `peers` becomes the import's `meta.dnsPeers`: where pods send DNS queries,
# which the network policy enforcer opens on port 53 for every workload.
# Leave it null for the `kube-dns` pods in `kube-system`
# (`core/dns-peers.nix`).

{
  lib,
  kix,
  clusterDomain,
}:
{
  name,
  namespace,
  optional ? true,
  peers ? null,
}:
{
  package = kix.mkImport {
    kind = "Service";
    apiVersion = "v1";
    roles = [ "dns" ];
    out = {
      inherit name;
      fqdn = "${name}.${namespace}.svc.${clusterDomain}";
    };
    dnsPeers = peers;
  };
  # The flavour's choice is a default, so a cluster definition can set
  # `optional` either way without `lib.mkForce`.
  optional = lib.mkDefault optional;
}
