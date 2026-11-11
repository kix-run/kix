# oidc-client: one application's OpenID Connect client at an identity
# provider that serves several realms, such as keycloak.
#
# Renders nothing. It pairs the provider's realm with the client's secret
# and answers the application's `oidc` dependency
# (`kix.contracts.oidc`). Its root is a marker that waits for the secret,
# so the application starts after the secret exists. Register the client at
# the provider first; each application's package header names the redirect
# URI to register.
#
# The instance sits in the application's namespace, because the
# application's pods read the client secret, and a pod reads Secrets only
# from its own namespace. The provider can sit anywhere.
#
# Dependencies:
#   oidcProvider (required)  a provider honouring kix.contracts.oidcProvider:
#                            a keycloak instance, or a kix.mkImport whose out
#                            sets issuerUrl (and endpoints) as functions of
#                            the realm. Keycloak answers no alias, so wire it
#                            with deps.oidcProvider = ref.<ns>.<instance>.
#   oidcClient (required)    a secret with keys `clientId` and
#                            `clientSecret`: a `secret`, or a `secret-ref`
#                            for a Secret that ESO, Vault, or Infisical
#                            writes.
#
# Minimal instances, beside a grafana that takes deps.oidc:
#
#   instances.monitoring = {
#     oidc = {
#       package = packages.oidc-client;
#       deps.oidcProvider = ref.auth.keycloak;
#       config.realm = "main";
#     };
#     grafana-oidc = {
#       package = packages.secret;
#       aliases = [ "oidcClient" ];
#       config.source = ./secrets/grafana-oidc.sops.yaml;
#       config.keys = [ "clientId" "clientSecret" ];
#     };
#   };
#
# For a provider outside the cluster with one issuer, a kix.mkImport in the
# application's namespace can answer `oidc` directly:
#
#   instances.monitoring.oidc.package = kix.mkImport {
#     scope = "namespace";
#     out = {
#       issuerUrl = "https://login.example.com";
#       credentials = ref.monitoring.grafana-oidc;
#     };
#   };
#
# `out`, checked by `kix.contracts.oidc`:
#   issuerUrl    the realm's issuer.
#   endpoints    the realm's authorization, token, and userinfo URLs, when
#                the provider publishes them.
#   credentials  the oidcClient secret.

{
  scope,
  lib,
  kix,
}:

let
  name = scope.instanceName;
  who = "oidc-client ${scope.namespaceName}/${name}";
in
{
  meta = {
    description = "One application's OpenID Connect client at a multi-realm identity provider";
    owner = "platform";
    scope = "namespace";
    defaultAliases = [ "oidc" ];
  };

  deps.oidcProvider.assertions = dep: kix.contracts.oidcProvider.assertions who dep;

  options.realm = lib.mkOption {
    type = lib.types.strMatching "[^/?#[:space:]]+";
    example = "main";
    description = "The provider's realm that holds this client.";
  };

  build =
    {
      self,
      config,
      oidcProvider,
      oidcClient,
      ...
    }:
    let
      # Order the marker after the secret instance's root resource. A
      # dependency's own `root` is its PackageInstance record, which a
      # resource must not depend on.
      credentials = kix.checkSecretKeys {
        inherit who;
        arg = "oidcClient";
        dep = oidcClient;
        keys = kix.contracts.oidc.fields.credentials.keys;
      };
    in
    {
      ready = scope.mkSecretRef {
        name = credentials.out.name;
        keys = kix.contracts.oidc.fields.credentials.keys;
        requires = lib.optional (credentials ? raw) (credentials.raw.root.resource or credentials.raw.root);
      };

      root = {
        resource = self.ready;
        out = kix.contracts.oidc.check who (
          {
            issuerUrl = oidcProvider.out.issuerUrl config.realm;
            inherit credentials;
          }
          // lib.optionalAttrs (oidcProvider.out ? endpoints) {
            endpoints = oidcProvider.out.endpoints config.realm;
          }
        );
      };
    };
}
