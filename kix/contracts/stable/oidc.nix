# Define the OpenID Connect client contract for `oidc` dependencies
# (`kix.contracts.oidc`), the helper consumers call on it, and the `oidc`
# option set a consumer adds to its options.
#
# An `oidc` instance is one application's client at an identity provider:
# the issuer, the endpoints, and the client id and secret. Two kinds of
# instance answer it:
# - an `oidc-client` instance, which pairs a provider that serves several
#   realms (`kix.contracts.experimental.oidcProvider`, such as keycloak) with a realm and
#   the client's secret;
# - a `kix.mkImport` in the application's namespace whose out sets
#   `issuerUrl` and `credentials = ref.<namespace>.<secret>`.
# Single sign-on is on when the application has an `oidc` dependency.
{
  lib,
  mkContract,
  credentialsField,
  ...
}:
let
  inherit (import ../../lib/core/error.nix { inherit lib; }) fail;

  isUrl = v: builtins.isString v && builtins.match "https?://[^/]+(/.*)?" v != null;

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
      shape = "the issuer URL (scheme://host/path)";
      test = isUrl;
    };
    # Explicit OAuth endpoints for applications that do not use OIDC
    # discovery. Browsers open `authorizationUrl`, so it must be public. The
    # application dials `tokenUrl` and `userinfoUrl`.
    endpoints = {
      required = false;
      shape = "{ ${lib.concatStringsSep "; " endpointKeys}; }, each a URL";
      test = e: builtins.isAttrs e && lib.all (k: isUrl (e.${k} or null)) endpointKeys;
    };
    credentials = credentialsField {
      keys = [
        "clientId"
        "clientSecret"
      ];
    };
  };

  contract = mkContract {
    name = "OIDC client";
    alias = "oidc";
    remedyNoun = "OIDC client";
    inherit fields;

    helpers = {
      inherit endpointKeys;

      # Validate the `oidc` dependency and return `{ issuerUrl; endpoints;
      # credentials; }`, or null when none is wired. `endpoints` throws when
      # read on a client that publishes none. `options` is the instance's
      # `oidc` option set, checked for the removed `enabled` and `realm`.
      client =
        {
          who,
          oidc,
          options,
        }:
        if (options.enabled or null) != null || (options.realm or null) != null then
          removedOptionsError who
        else if oidc == null then
          null
        else
          let
            out = (contract.require who oidc).out;
          in
          {
            inherit (out) issuerUrl credentials;
            endpoints =
              out.endpoints or (fail {
                message = "${who}: deps.oidc publishes no out.endpoints, the authorization, token, and userinfo URLs this application needs.";
                fix = "Set out.endpoints on that instance (an oidc-client on keycloak sets them, and a kix.mkImport sets them in `out`).";
              });
          };
    };

    # Build the `oidc` option set for a consumer package. Pass `autoLogin =
    # null` when the application has no setting to bypass its login page.
    options =
      {
        scopes,
        autoLogin ? null,
      }:
      let
        removed = lib.mkOption {
          type = lib.types.unspecified;
          default = null;
          visible = false;
          description = "Removed. Single sign-on is on when the instance has an `oidc` dependency, and the realm is set on that dependency.";
        };
      in
      {
        enabled = removed;
        realm = removed;
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
  };

  removedOptionsError =
    who:
    fail {
      message = "${who}: oidc.enabled and oidc.realm were removed. Single sign-on is on when this instance has an `oidc` dependency.";
      fix = "In this namespace, add an oidc-client instance with config.realm set to the realm, deps.oidcProvider naming the provider, and the client secret (keys clientId and clientSecret) as its oidcClient dependency. For a provider outside the cluster, a kix.mkImport whose out sets issuerUrl and credentials = ref.<namespace>.<secret> also works. Then remove oidc.enabled and oidc.realm.";
    };
in
contract
