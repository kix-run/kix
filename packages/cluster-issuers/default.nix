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
  lib,
}:

{
  options = {
    issuers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
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
    };
    mainIssuer = lib.mkOption {
      type = lib.types.str;
      default = "letsencrypt-production";
    };
  };

  build =
    { self, config, clusterConfig }:
    let
      # CRD refs for cert-manager CRDs — auto-generate .cr/.mkCR builders.
      # Uses mkCRDRef since the CRDs are managed by the cert-manager package, not us.
      certificateCRDRef = scope.mkCRDRef {
        group = "cert-manager.io";
        kind = "Certificate";
        plural = "certificates";
      };
      clusterIssuerCRDRef = scope.mkCRDRef {
        group = "cert-manager.io";
        kind = "ClusterIssuer";
        plural = "clusterissuers";
        crdScope = "Cluster";
      };
      mkCert = certificateCRDRef.out.mkCR scope;
      mkIssuerCR = clusterIssuerCRDRef.out.mkCR scope;

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
        mkIssuerCR {
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

      issuerResources = lib.mapAttrs mkIssuer config.issuers;
      mainResource = issuerResources.${config.mainIssuer};
      otherResources = lib.filterAttrs (n: _: n != config.mainIssuer) issuerResources;
    in
    issuerResources
    // {
      # mkCertificate: creates a cert-manager Certificate CR.
      # For non-Ingress TLS (gRPC, internal services, mTLS).
      mkCertificate = { name, hosts, secretName, duration ? null, renewBefore ? null }:
        mkCert {
          inherit name;
          spec = {
            secretName = secretName;
            issuerRef = {
              name = mainResource.out.name;
              kind = "ClusterIssuer";
            };
            dnsNames = if builtins.isList hosts then hosts else [ hosts ];
          }
          // lib.optionalAttrs (duration != null) { inherit duration; }
          // lib.optionalAttrs (renewBefore != null) { inherit renewBefore; };
        };

      main = {
        resource = mainResource;
        requires = lib.attrValues otherResources;

        # Package-level out extensions — exposed via DI as cluster-issuer.out.*
        out = {
          # Args transformer: adds cert-manager annotation to mkResource input args.
          # Pipe-friendly: `scope.mkResource ({ ... } |> clusterIssuer.out.withCert)`
          withCert = args: args // {
            annotations = (args.annotations or {}) // {
              "cert-manager.io/cluster-issuer" = mainResource.out.name;
            };
          };
        };
      };
    };
}
