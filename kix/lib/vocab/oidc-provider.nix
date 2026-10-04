# The OpenID Connect provider contract: what an instance wired as an
# application's `oidcProvider` dependency publishes on root.out, so that the
# application can sign users in through it. A provider (keycloak, or a
# kix.mkImport standing in for one outside the cluster) passes its out
# through `check`; a consumer holds its `oidcProvider` dependency to the
# contract with `assertions`.
#
# Both fields are functions of a realm name, because one Keycloak serves many
# realms, each with its own issuer. A provider with one issuer ignores the
# argument (`issuerUrl = _: "https://login.example.com";`).
#
# `clientOptions` is the `oidc` option set the consumers share (grafana,
# harbor, immich), reached as `kix.options.oidc`. Packages reach this file as
# `kix.contracts.oidcProvider`.
{ lib }:
let
  isUrl = v: builtins.isString v && builtins.match "https?://[^/]+(/.*)?" v != null;

  # `check` and `assertions` call the functions with this name to test the
  # shape of what they return.
  probeRealm = "kix-contract-probe";

  callable = f: builtins.isFunction f || (builtins.isAttrs f && f ? __functor);

  endpointKeys = [
    "authorizationUrl"
    "tokenUrl"
    "userinfoUrl"
  ];

  fields = {
    # The issuer that tokens carry in `iss`. An application that discovers
    # the provider (`<issuer>/.well-known/openid-configuration`) dials it
    # and compares the issuer it finds there with this URL.
    issuerUrl = {
      required = true;
      shape = "a function from a realm name to that realm's issuer URL (scheme://host/path)";
      test = f: callable f && isUrl (f probeRealm);
    };
    # For an application that takes the endpoints instead of discovering
    # them (Grafana's generic_oauth). `authorizationUrl` is opened by the
    # browser, so it is public. `tokenUrl` and `userinfoUrl` are dialled by
    # the application's server; a provider in the cluster gives its
    # Service's address there, so that address carries the dependency and
    # the derived network policy.
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

  problemsWith =
    all: out:
    builtins.concatMap (
      field:
      let
        f = fields.${field};
      in
      if !(out ? ${field}) then
        lib.optional (all || f.required) "${field} is missing (${f.shape})"
      else if !(f.test out.${field}) then
        [ "${field} is not ${f.shape}" ]
      else
        [ ]
    ) (builtins.attrNames fields);

  here = "kix/lib/vocab/oidc-provider.nix";
in
{
  alias = "oidcProvider";
  inherit fields;

  # The problems a consumer's assertion reports for `out`.
  problems = problemsWith false;

  # For a provider: `root.out = kix.contracts.oidcProvider.check who { ... }`.
  # Returns `out`, or throws naming every missing or misshapen field.
  check =
    who: out:
    let
      found = problemsWith true out;
    in
    if found == [ ] then
      out
    else
      throw "${who}: root.out does not honour the OIDC provider contract: ${lib.concatStringsSep "; " found} (${here})";

  # For a consumer:
  # `deps.oidcProvider.assertions = dep: kix.contracts.oidcProvider.assertions who dep;`.
  # Requires `issuerUrl` and checks `endpoints` when it is present.
  assertions =
    who: dep:
    let
      found = problemsWith false (dep.out or { });
      meta = dep._meta or { };
      provider =
        if meta ? namespaceName && meta ? instanceName then
          "${meta.namespaceName}/${meta.instanceName}"
        else
          "the instance it resolved to";
    in
    lib.optional (found != [ ]) {
      assertion = false;
      message = "${who}: deps.oidcProvider resolved to ${provider}, whose out does not honour the OIDC provider contract: ${lib.concatStringsSep "; " found}. Set them on that instance's out (a kix.mkImport sets them in `out`), or wire another provider with deps.oidcProvider = ref.<ns>.<instance> (${here}).";
    };

  # The provider and the client credentials a consumer with `oidc.enabled`
  # reads, or a throw naming what is missing. `provider` and `client` are the
  # consumer's `oidcProvider` and `oidcClient` arguments; the client's keys
  # are checked by the package with kix.checkSecretKeys.
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

  # The `oidc` option of a consumer. `scopes` is the application's default
  # scope list. `autoLogin` names the setting that sends users straight to
  # the provider; an application without one passes null and gets no
  # `autoLogin` option.
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
