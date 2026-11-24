# region:sharedExternalDns
# clusters/test-cloud-identity-layout/external-dns.nix: the external-dns
# instance both clusters run. It names the DNS provider, which is the
# software's own setting, and no credential: each cluster file gives
# `deps.providerCredentials` its own value.
{ packages, ... }:
{
  instances.external-dns.route53 = {
    package = packages.experimental.external-dns;
    config = {
      provider = "aws";
      policy = "upsert-only";
      txtOwnerId = "cloud-identity-layout/route53";
      extraArgs = [ "--domain-filter=example.com" ];
    };
  };
}
# endregion:sharedExternalDns
