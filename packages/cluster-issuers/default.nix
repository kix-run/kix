# ClusterIssuer package — NW1 cert-manager issuers.
#
# Creates Let's Encrypt ClusterIssuers for production and staging using
# Cloudflare DNS01 challenge validation. ClusterIssuers are cluster-scoped
# cert-manager CRDs — certificates in any namespace can reference them.
#
# The `northwind` issuer is the primary production issuer for the northwind.net
# domain. `letsencrypt-production` and `letsencrypt-staging` are
# general-purpose issuers.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    email = "adam@adamcharnock.com";
    cloudflareSecret = {
      name = "cloudflare-api-token-secret";
      key = "api-token";
    };
  };

  cloudflareRef = {
    apiTokenSecretRef = {
      name = cfg.cloudflareSecret.name;
      key = cfg.cloudflareSecret.key;
    };
  };

  mkIssuer =
    {
      name,
      server,
      privateKeySecretName,
    }:
    scope.mkClusterResource {
      apiVersion = "cert-manager.io/v1";
      kind = "ClusterIssuer";
      inherit name;
      spec = {
        acme = {
          inherit server;
          email = cfg.email;
          privateKeySecretRef.name = privateKeySecretName;
          solvers = [
            {
              dns01.cloudflare = cloudflareRef;
            }
          ];
        };
      };
    };

in
self: {
  northwind = mkIssuer {
    name = "northwind";
    server = "https://acme-v02.api.letsencrypt.org/directory";
    privateKeySecretName = "letsencrypt-northwind";
  };

  letsencrypt-production = mkIssuer {
    name = "letsencrypt-production";
    server = "https://acme-v02.api.letsencrypt.org/directory";
    privateKeySecretName = "letsencrypt-production";
  };

  letsencrypt-staging = mkIssuer {
    name = "letsencrypt-staging";
    server = "https://acme-staging-v02.api.letsencrypt.org/directory";
    privateKeySecretName = "letsencrypt-staging";
  };

  main = {
    resource = self.northwind;
    requires = [
      self.letsencrypt-production
      self.letsencrypt-staging
    ];
  };
}
