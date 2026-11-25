# Return the `platform-dns` instance for a platform's built-in DNS Service.
#
# A flavour names the Service once, by `name` and `namespace`, and the import
# derives `out.name` and `out.fqdn` from them. The import marker names the
# Service, so `kix deploy` checks that it exists in the namespace of the
# import instance before it applies the workloads that depend on DNS.

{
  lib,
  kix,
  clusterDomain,
}:
{
  name,
  namespace,
  optional ? true,
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
  };
  # The flavour's choice is a default, so a cluster definition can set
  # `optional` either way without `lib.mkForce`.
  optional = lib.mkDefault optional;
}
