# Refuse the names that contracts gave their helpers before Kix 0.10, with
# an error that gives the new name. A contract's own functions and values
# sit under `helpers` since 0.10. Remove this file once the refusals have
# been in a minor release.
{ lib }:
let
  inherit (import ../lib/core/error.nix { inherit lib; }) fail;
  # Old names that did not move under `helpers`, by contract.
  elsewhere = {
    oidc.clientOptions = "options";
    oidc.credentialKeys = "fields.credentials.keys";
    redis.credentialKeys = "fields.credentials.keys";
    smtp.credentialKeys = "fields.credentials.keys";
  };
  # Helpers that existed before 0.10, by contract.
  helpers = {
    gateway = [ "claims" ];
    oidc = [
      "client"
      "endpointKeys"
    ];
    redis = [
      "usesSentinel"
      "requirePlaintext"
    ];
    smtp = [
      "server"
      "settings"
      "egressPolicy"
    ];
  };
  refuse =
    name: old: new:
    fail {
      id = "K6218";
      message = "kix.contracts.${name}.${old} moved to kix.contracts.${name}.${new}.";
    };
in
# Return the refusals for the contract called `name`.
name:
lib.mapAttrs (refuse name) (
  lib.genAttrs (helpers.${name} or [ ]) (helper: "helpers.${helper}") // (elsewhere.${name} or { })
)
