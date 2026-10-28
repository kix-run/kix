# Define the OpenID Connect provider contract for `oidcProvider` dependencies
# (`kix.contracts.oidcProvider`) and the shared consumer option helper
# (`kix.options.oidc`).
#
# Both `issuerUrl` and `endpoints` take a realm name because a single Keycloak
# instance can serve multiple realms. Providers with a single issuer ignore the
# realm argument.
{ lib }:
let
  inherit (import ./contract.nix { inherit lib; }) mkContract;

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

  contract = mkContract {
    name = "OIDC provider";
    alias = "oidcProvider";
    remedyNoun = "provider";
    here = "kix/lib/vocab/oidc-provider.nix";
    inherit fields;
  };
in
{
  inherit (contract)
    alias
    fields
    problems
    check
    assertions
    ;

  # Validate that `provider`, `client`, and `oidc.realm` are present when OIDC
  # is enabled, and return the resolved `issuerUrl` and `endpoints` for that
  # realm. The caller checks `client` secret keys separately via
  # `kix.checkSecretKeys`.
  requireClient =
    {
      who,
      oidc,
      provider,
      client,
    }:
    if provider == null then
      throw "${who}: oidc.enabled is true, but no OIDC provider is wired. Wire one with deps.oidcProvider = ref.<ns>.<instance> (a keycloak instance, or a kix.mkImport whose out sets issuerUrl), or set oidc.enabled = false."
    else if client == null then
      throw "${who}: oidc.enabled is true, but no client credentials are wired. Register a client for this application at the provider, put its id and secret in a secret with keys clientId and clientSecret, and wire it with deps.oidcClient = ref.<ns>.<instance>."
    else if oidc.realm == null then
      throw "${who}: oidc.enabled is true, but oidc.realm is not set. Set it to the realm that holds this application's client, such as \"main\"."
    else
      {
        issuerUrl = provider.out.issuerUrl oidc.realm;
        endpoints =
          if provider.out ? endpoints then
            provider.out.endpoints oidc.realm
          else
            throw "${who}: deps.oidcProvider publishes no out.endpoints, the authorization, token, and userinfo URLs this application needs. Set out.endpoints on that instance (a kix.mkImport sets it in `out`).";
      };

  clientKeys = [
    "clientId"
    "clientSecret"
  ];

  # Build the `oidc` option set for a consumer package. Pass `autoLogin = null`
  # when the application has no setting to bypass its login page.
  clientOptions =
    {
      scopes,
      autoLogin ? null,
    }:
    {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Sign users in through the `oidcProvider` dependency, with the client id and secret from the `oidcClient` dependency (a secret with keys `clientId` and `clientSecret`). Register the client at the provider first, with the redirect URI the package header names.";
      };
      realm = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[^/?#[:space:]]+");
        default = null;
        example = "main";
        description = "The provider's realm that holds this application's client; the issuer is `oidcProvider`'s `out.issuerUrl realm`. Required while `enabled` is true.";
      };
      scopes = lib.mkOption {
        type =
          lib.types.addCheck (lib.types.listOf (lib.types.strMatching "[^[:space:],]+")) (
            builtins.elem "openid"
          )
          // {
            description = "list of scopes without spaces or commas that includes \"openid\"";
          };
        default = scopes;
        description = "OAuth scopes the application requests. OpenID Connect needs `openid`, so a list without it is refused.";
      };
    }
    // lib.optionalAttrs (autoLogin != null) {
      autoLogin = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Send users straight to the provider instead of showing the application's login page (${autoLogin}).";
      };
    };
}
