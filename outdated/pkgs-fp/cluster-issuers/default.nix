# ClusterIssuer package — fixpoint pattern.
#
# Migrated from Ansible cert-manager.yml playbook.
# Creates Let's Encrypt ClusterIssuers for staging and production
# using Cloudflare DNS01 challenge validation.
#
# This is a simple package with no workloads — just two cluster-scoped
# custom resources (ClusterIssuers). The production issuer is the `main`
# resource, with the staging issuer pulled in via `withRequires`.
#
# Why both issuers in one package?
# They share identical configuration (domain, Cloudflare credentials,
# email) and are always deployed together. Having them in the same
# fixpoint makes it easy to gate staging on/off without a separate
# package.
#
# Why cluster-scoped (namespace = null)?
# ClusterIssuer is a cluster-wide cert-manager CRD — it has no namespace.
# Certificates in any namespace can reference these issuers.

{ k8s, lib }:

k8s.mkPackage (
  {
    # --- Package arguments ---
    #
    # email: The ACME registration email. Let's Encrypt sends expiry
    # warnings here. Using a personal email is fine for homelab; for
    # production you'd want a team alias.
    email ? "adam@adamcharnock.com",

    # domain: The DNS zone to validate against. Passed to the solver's
    # dnsZones selector so cert-manager knows which domains this issuer
    # can handle. This should be the apex domain (e.g., "example.com"),
    # not a subdomain — cert-manager will match subdomains automatically.
    # Default "example.com" is a placeholder — override in cluster definition.
    domain ? "example.com",

    # cloudflareTokenSecretName / cloudflareTokenSecretKey:
    # Reference to the pre-existing Secret containing a Cloudflare API
    # token with Zone:DNS:Edit and Zone:Zone:Read permissions.
    # This secret must be created separately (e.g., via external-secrets
    # or sealed-secrets) in the cert-manager namespace.
    cloudflareTokenSecretName ? "cloudflare-credentials-acme",
    cloudflareTokenSecretKey ? "api-token",

    # enableStaging / enableProduction: Gates for which issuers to
    # include. Both default to true because you almost always want both
    # (staging for testing cert workflows, production for real certs).
    enableStaging ? true,
    enableProduction ? true,

    # Standard label / identity args — every kix package has these.
    clusterLabels ? { },
    instance ? "release-name",
  }:
  self:
  let
    # --- Labels ---
    #
    # ClusterIssuers are not workloads, so selectorLabels aren't used for
    # pod selection. We still follow the standard label convention for
    # consistency and so that `managed-by = kix` cross-resource validation
    # passes.
    selectorLabels = {
      "app.kubernetes.io/instance" = instance;
      "app.kubernetes.io/name" = "cluster-issuers";
    };

    allLabels =
      clusterLabels
      // selectorLabels
      // {
        "app.kubernetes.io/managed-by" = "kix";
      };

    # --- Shared solver config ---
    #
    # Both staging and production use the exact same solver — the only
    # difference between the two issuers is the ACME server URL and the
    # private key secret name. Extracting the solver avoids duplication.
    solver = {
      selector = {
        dnsZones = [ domain ];
      };
      dns01 = {
        cloudflare = {
          apiTokenSecretRef = {
            name = cloudflareTokenSecretName;
            key = cloudflareTokenSecretKey;
          };
        };
      };
    };

  in
  {
    # ── Staging Issuer ────────────────────────────────────────────
    #
    # Uses Let's Encrypt staging server. Certs issued by this are not
    # trusted by browsers, but the rate limits are much more generous.
    # Useful for testing cert-manager configuration without burning
    # through production rate limits.

    stagingIssuer = k8s.mkResource {
      apiVersion = "cert-manager.io/v1";
      kind = "ClusterIssuer";
      name = "letsencrypt-staging";
      # ClusterIssuer is cluster-scoped — no namespace.
      namespace = null;
      labels = allLabels // {
        "app.kubernetes.io/component" = "staging";
      };
      spec = {
        acme = {
          inherit email;
          server = "https://acme-staging-v02.api.letsencrypt.org/directory";
          privateKeySecretRef = {
            name = "tls-staging";
          };
          solvers = [ solver ];
        };
      };
    };

    # ── Production Issuer ─────────────────────────────────────────
    #
    # Uses the real Let's Encrypt server. Certs are browser-trusted.
    # Rate limits apply: https://letsencrypt.org/docs/rate-limits/
    # Always test with staging first before switching to production.

    productionIssuer = k8s.mkResource {
      apiVersion = "cert-manager.io/v1";
      kind = "ClusterIssuer";
      name = "letsencrypt-production";
      namespace = null;
      labels = allLabels // {
        "app.kubernetes.io/component" = "production";
      };
      spec = {
        acme = {
          inherit email;
          server = "https://acme-v02.api.letsencrypt.org/directory";
          privateKeySecretRef = {
            name = "tls-production";
          };
          solvers = [ solver ];
        };
      };
    };

    # ── Main: the public interface ────────────────────────────────
    #
    # The production issuer is the primary resource — it's what consumers
    # care about (e.g., Ingress annotations reference "letsencrypt-production").
    # The staging issuer is pulled in via withRequires so that deploying
    # this package gives you both issuers.
    #
    # When enableProduction is false but enableStaging is true, main is
    # the staging issuer alone. When both are disabled... well, don't do
    # that — but the package still evaluates cleanly, main just has no
    # requires.

    main = k8s.withRequires (lib.optional enableStaging self.stagingIssuer) self.productionIssuer;
  }
) { }
