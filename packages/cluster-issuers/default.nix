# ClusterIssuer package — cert-manager ACME issuers.
#
# Creates Let's Encrypt ClusterIssuers using Cloudflare DNS01 challenge
# validation.  ClusterIssuers are cluster-scoped cert-manager CRDs —
# certificates in any namespace can reference them.
#
# Each issuer is independently configurable (email, secret refs, DNS
# zones, etc.) via the `issuers` attrset in `config`.

{
  scope,
  config,
  lib,
}:

let
  cfg = scope.defaults config {
    issuers = {
      letsencrypt-production = {
        server = "https://acme-v02.api.letsencrypt.org/directory";
        email = "admin@example.com";
        privateKeySecretName = "tls-production";
        cloudflareSecret = {
          name = "cloudflare-api-token-secret";
          key = "api-token";
        };
        dnsZones = [ ];
      };
      letsencrypt-staging = {
        server = "https://acme-staging-v02.api.letsencrypt.org/directory";
        email = "admin@example.com";
        privateKeySecretName = "tls-staging";
        cloudflareSecret = {
          name = "cloudflare-api-token-secret";
          key = "api-token";
        };
        dnsZones = [ ];
      };
    };
    mainIssuer = "letsencrypt-production";
  };

  mkIssuer =
    name: issuerCfg:
    let
      solver = {
        dns01.cloudflare = {
          apiTokenSecretRef = {
            name = issuerCfg.cloudflareSecret.name;
            key = issuerCfg.cloudflareSecret.key;
          };
        };
      } // (
        if issuerCfg.dnsZones != [ ] then {
          selector.dnsZones = issuerCfg.dnsZones;
        } else
          { }
      );
    in
    scope.mkClusterResource {
      apiVersion = "cert-manager.io/v1";
      kind = "ClusterIssuer";
      inherit name;
      spec = {
        acme = {
          server = issuerCfg.server;
          email = issuerCfg.email;
          privateKeySecretRef.name = issuerCfg.privateKeySecretName;
          solvers = [ solver ];
        };
      };
    };

  issuerResources = lib.mapAttrs mkIssuer cfg.issuers;
  mainResource = issuerResources.${cfg.mainIssuer};
  otherResources = lib.filterAttrs (n: _: n != cfg.mainIssuer) issuerResources;
in
self:
issuerResources
// {
  main = {
    resource = mainResource;
    requires = lib.attrValues otherResources;
  };
}
