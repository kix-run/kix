# ClusterIssuer package: cert-manager ACME issuers.
#
# Creates Let's Encrypt ClusterIssuers using Cloudflare DNS01 challenge
# validation.  ClusterIssuers are cluster-scoped cert-manager CRDs;
# certificates in any namespace can reference them.
#
# Each issuer is independently configurable (email, secret refs, DNS
# zones, etc.) via the `issuers` attrset in `config`.

{
  scope,
  lib,
}:

{
  meta = {
    version = "1.0.0";
    description = "cert-manager ClusterIssuers: the TLS issuers `kix.expose` stamps onto Ingresses";
    owner = "platform";
    # Auto-wire as `clusterIssuer` DI dep so any instance in the cluster
    # activates TLS on packages using `kix.expose` without per-app deps.
    defaultAliases = [ "clusterIssuer" ];
  };

  options = {
    # Each issuer has a `kind` discriminator:
    #   - "acme"       → ACME (Let's Encrypt, pebble, etc.) via DNS01 solver
    #   - "selfSigned" → cert-manager SelfSigned issuer (no spec args). Good
    #                    for local dev / kind demos where a padlock is
    #                    useful but certificate chain is not.
    # New kinds (ca, vault, venafi) slot in by extending this branch.
    issuers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {
        letsencrypt-production = {
          kind = "acme";
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
          kind = "acme";
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
    {
      self,
      config,
      clusterConfig,
      certManager,
    }:
    let
      mkCert = scope.mkCR certManager.out.crds.Certificate;
      mkIssuerCR = scope.mkCR certManager.out.crds.ClusterIssuer;

      mkAcmeIssuer =
        name: issuerCfg:
        let
          solver = {
            dns01.cloudflare = {
              apiTokenSecretRef = {
                name = issuerCfg.cloudflareSecret.name;
                key = issuerCfg.cloudflareSecret.key;
              };
            };
          }
          // (
            if issuerCfg.dnsZones != [ ] then
              {
                selector.dnsZones = issuerCfg.dnsZones;
              }
            else
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

      mkSelfSignedIssuer =
        name: _issuerCfg:
        mkIssuerCR {
          inherit name;
          spec = {
            selfSigned = { };
          };
        };

      mkIssuer =
        name: issuerCfg:
        let
          kind = issuerCfg.kind or "acme";
        in
        if kind == "acme" then
          mkAcmeIssuer name issuerCfg
        else if kind == "selfSigned" then
          mkSelfSignedIssuer name issuerCfg
        else
          throw "cluster-issuers (${name}): unknown issuer kind \"${kind}\"; expected acme | selfSigned";

      issuerResources = lib.mapAttrs mkIssuer config.issuers;
      mainResource = issuerResources.${config.mainIssuer};
      otherResources = lib.filterAttrs (n: _: n != config.mainIssuer) issuerResources;
    in
    issuerResources
    // {
      # mkCertificate: creates a cert-manager Certificate CR.
      # For non-Ingress TLS (gRPC, internal services, mTLS).
      mkCertificate =
        {
          name,
          hosts,
          secretName,
          duration ? null,
          renewBefore ? null,
        }:
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

      root = {
        resource = mainResource;
        requires = lib.attrValues otherResources;

        # Package-level out extensions, exposed via DI as cluster-issuer.out.*
        out = {
          # Args transformer: adds cert-manager annotation to mkResource input args.
          # Pipe-friendly: `scope.mkResource ({ ... } |> clusterIssuer.out.withCert)`
          withCert =
            args:
            args
            // {
              annotations = (args.annotations or { }) // {
                "cert-manager.io/cluster-issuer" = mainResource.out.name;
              };
            };
        };
      };
    };
}
