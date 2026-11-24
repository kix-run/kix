# DNS providers the package accepts for `provider`: upstream `ProviderNames`
# in pkg/apis/externaldns/types.go at v0.24.0, without `webhook`. A webhook
# provider runs as a sidecar container, which this package does not render.
#
# `credentialKeySets` lists the environment variables the provider reads its
# API credentials from, one list per accepted combination. An instance that
# supplies no complete set is refused at evaluation. A provider without the
# attribute is not checked, because it can authenticate through variables,
# mounted files, or workload identity that Kix cannot see.
#
# `secretVariables` lists the provider's own credential variables that are
# secret. An instance that sets one of them, or the `EXTERNAL_DNS_*` form of
# a credential flag, to a literal string in `env` is refused.
#
# A provider that takes its credentials only as flags reads them from
# `EXTERNAL_DNS_<FLAG>` (kingpin DefaultEnvars), so its key sets name those
# variables.
#
# `cloud` names the cloud whose API the provider calls, as the instance's
# `cloudIdentity` names it. Such a provider authenticates with that
# identity or with the providerCredentials Secret, and an instance with
# neither or both is refused.
{
  alibabacloud = { };
  aws.cloud = "aws";
  aws-sd.cloud = "aws";
  azure.cloud = "azure";
  azure-dns.cloud = "azure";
  azure-private-dns.cloud = "azure";
  civo = { };
  # provider/cloudflare/cloudflare.go reads CF_API_TOKEN, and otherwise
  # both CF_API_KEY and CF_API_EMAIL.
  cloudflare = {
    credentialKeySets = [
      [ "CF_API_TOKEN" ]
      [
        "CF_API_KEY"
        "CF_API_EMAIL"
      ]
    ];
    secretVariables = [
      "CF_API_TOKEN"
      "CF_API_KEY"
    ];
  };
  coredns = { };
  dnsimple = { };
  exoscale = { };
  # `--godaddy-api-key` and `--godaddy-api-secret` are both required.
  godaddy.credentialKeySets = [
    [
      "EXTERNAL_DNS_GODADDY_API_KEY"
      "EXTERNAL_DNS_GODADDY_API_SECRET"
    ]
  ];
  google.cloud = "gcp";
  inmemory = { };
  linode = { };
  ns1 = { };
  oci = { };
  ovh = { };
  # `--pdns-api-key` is required.
  pdns.credentialKeySets = [ [ "EXTERNAL_DNS_PDNS_API_KEY" ] ];
  pihole = { };
  rfc2136 = { };
  scaleway = { };
  skydns = { };
}
