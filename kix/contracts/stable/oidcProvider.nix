# Define the OpenID Connect provider contract for `oidcProvider` dependencies
# (`kix.contracts.oidcProvider`): an identity provider that can serve several
# realms, such as keycloak. Applications do not take it directly. An
# `oidc-client` instance pairs it with a realm and a client secret, and
# answers the application's `oidc` dependency (`kix.contracts.oidc`).
#
# Both `issuerUrl` and `endpoints` take a realm name because a single Keycloak
# instance can serve multiple realms. Providers with a single issuer ignore the
# realm argument.
{
  lib,
  mkContract,
  ...
}:
let

  isUrl = v: builtins.isString v && builtins.match "https?://[^/]+(/.*)?" v != null;

  # Passed to `issuerUrl` and `endpoints` during validation to check their
  # return values.
  probeRealm = "kix-contract-probe";

  callable = f: builtins.isFunction f || (builtins.isAttrs f && f ? __functor);

  endpointKeys = [
    "authorizationUrl"
    "tokenUrl"
    "userinfoUrl"
  ];

  fields = {
    # Expected `iss` claim in ID tokens and base URL for
    # `/.well-known/openid-configuration` discovery.
    issuerUrl = {
      required = true;
      shape = "a function from a realm name to that realm's issuer URL (scheme://host/path)";
      test = f: callable f && isUrl (f probeRealm);
    };
    # Explicit OAuth endpoints for applications that do not use OIDC discovery.
    # Browsers open `authorizationUrl` directly, so it must be public. The
    # application backend dials `tokenUrl` and `userinfoUrl`. In-cluster
    # providers use their Service URL so Kix derives the dependency and
    # network policy.
    endpoints = {
      required = false;
      shape = "a function from a realm name to { ${lib.concatStringsSep "; " endpointKeys}; }, each a URL";
      test =
        f:
        callable f
        && (
          let
            e = f probeRealm;
          in
          builtins.isAttrs e && lib.all (k: isUrl (e.${k} or null)) endpointKeys
        );
    };
  };
in
mkContract {
  name = "OIDC provider";
  alias = "oidcProvider";
  remedyNoun = "provider";
  inherit fields;
}
