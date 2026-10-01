# DNS providers the package accepts for `provider`: upstream `ProviderNames`
# in pkg/apis/externaldns/types.go at v0.23.0, without `webhook`. A webhook
# provider runs as a sidecar container, which this package does not render.
#
# `credentialKeySets` lists the environment variables the provider reads its
# API credentials from, one list per accepted combination. An instance that
# supplies no complete set is refused at evaluation. A provider without the
# attribute is not checked, because it can authenticate through variables,
# mounted files, or workload identity that Kix cannot see.
{
  alibabacloud = { };
  aws = { };
  aws-sd = { };
  azure = { };
  azure-dns = { };
  azure-private-dns = { };
  civo = { };
  # provider/cloudflare/cloudflare.go reads CF_API_TOKEN, and otherwise
  # both CF_API_KEY and CF_API_EMAIL.
  cloudflare.credentialKeySets = [
    [ "CF_API_TOKEN" ]
    [
      "CF_API_KEY"
      "CF_API_EMAIL"
    ]
  ];
  coredns = { };
  dnsimple = { };
  exoscale = { };
  godaddy = { };
  google = { };
  inmemory = { };
  linode = { };
  ns1 = { };
  oci = { };
  ovh = { };
  pdns = { };
  pihole = { };
  rfc2136 = { };
  scaleway = { };
  skydns = { };
}
