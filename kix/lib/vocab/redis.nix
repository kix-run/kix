# Define the Redis contract for packages that serve the Redis protocol and
# publish connection details on `root.out` (`kix.contracts.redis`). Valkey
# provides it; a `kix.mkImport` can stand in for an outside server such as
# ElastiCache. Consumers take it as their `valkey` dependency.
#
# Provider packages call `check`, which requires every field. Consumers
# validate their dependency with `assertions`, which requires only the
# `required` fields.
{ lib }:
let
  inherit (import ./contract.nix { inherit lib; }) mkContract credentialsField;

  isString = builtins.isString;
  isPort = v: isString v && builtins.match "[0-9]+" v != null;

  credentialKeys = [ "password" ];

  fields = {
    host = {
      required = true;
      shape = "the server's hostname, such as a Service FQDN or an ElastiCache endpoint";
      test = isString;
    };
    # A string, because consumers interpolate it into URLs.
    port = {
      required = true;
      shape = "the Redis port as a string of digits";
      test = isPort;
    };
    credentials = credentialsField {
      keys = credentialKeys;
      required = false;
    };
    tls = {
      required = false;
      shape = "true or false for whether the server serves TLS";
      test = builtins.isBool;
    };
    # Set when Sentinel fronts the server. Then `host` also reaches
    # read-only replicas, and a client that writes asks Sentinel for the
    # primary.
    sentinel = {
      required = false;
      shape = "null, or { port; primarySet; } with the Sentinel port as a string of digits and the name Sentinel monitors the primary under";
      test =
        v: v == null || builtins.isAttrs v && isPort (v.port or null) && isString (v.primarySet or null);
    };
  };

  contract = mkContract {
    name = "Redis";
    alias = "valkey";
    remedyNoun = "Redis server";
    here = "kix/lib/vocab/redis.nix";
    inherit fields;
  };
in
{
  inherit credentialKeys;
  inherit (contract)
    alias
    fields
    problems
    check
    assertions
    ;

  # Return whether the server behind `dep` publishes Sentinel.
  usesSentinel = dep: (dep.out.sentinel or null) != null;

  # Refuse a server with TLS for a consumer that cannot connect over it, and
  # return `dep`.
  requirePlaintext =
    who: dep:
    if dep.out.tls or false then
      throw "${who}: the valkey dependency serves TLS, which this package cannot connect to. Wire a server without TLS, or one that also listens without it."
    else
      dep;
}
