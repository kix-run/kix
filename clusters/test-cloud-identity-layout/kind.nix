# clusters/test-cloud-identity-layout/kind.nix: the shared external-dns
# instance on kind, which gives pods no cloud identity, so it reads AWS
# access keys from a Secret created outside Kix.
#
# Build:   kix check cloud-identity-layout-kind
{ kix, packages }:

# region:kindCluster
kix.buildCluster {
  name = "cloud-identity-layout-kind";
  specialArgs = { inherit packages; };
  modules = [
    kix.flavors.kind
    ./external-dns.nix
    (
      { ref, ... }:
      {
        # A Secret with the keys AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
        instances.external-dns.aws-keys = {
          package = packages.secret-ref;
          config.keys = [
            "AWS_ACCESS_KEY_ID"
            "AWS_SECRET_ACCESS_KEY"
          ];
        };
        instances.external-dns.route53.deps.providerCredentials = ref.external-dns.aws-keys;
      }
    )
  ];
}
# endregion:kindCluster
