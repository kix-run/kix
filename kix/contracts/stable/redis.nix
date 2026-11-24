# Define the Redis contract for packages that serve the Redis protocol and
# publish connection details on `root.out` (`kix.contracts.redis`). Valkey
# provides it; a `kix.mkImport` can stand in for an outside server such as
# ElastiCache. Consumers take it as their `redis` dependency.
#
# Provider packages call `check`, which requires every field. Consumers
# validate their dependency with `assertions`, which requires only the
# `required` fields.
{
  lib,
  mkContract,
  credentialsField,
  ...
}:
let
  inherit (import ../../lib/core/error.nix { inherit lib; }) refuseWho;

  isString = builtins.isString;
  isPort = v: isString v && builtins.match "[0-9]+" v != null;

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
      keys = [ "password" ];
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
in
mkContract {
  name = "Redis";
  alias = "redis";
  remedyNoun = "Redis server";
  inherit fields;

  helpers = {
    # The name consumers took this contract under before `redis`, for a
    # consumer's `deps.redis.renamedFrom`.
    renamedFrom = {
      name = "valkey";
      id = "K9191";
    };

    # Return whether the server behind `dep` publishes Sentinel.
    usesSentinel = dep: (dep.out.sentinel or null) != null;

    # Refuse a server with TLS for the consumer in `scope`, which cannot
    # connect over it, and return `dep`.
    requirePlaintext =
      scope: dep:
      if builtins.isString scope then
        refuseWho {
          helper = "contracts.redis.helpers.requirePlaintext";
          fix = "Pass `scope` in place of the text.";
        }
      else if dep.out.tls or false then
        scope.fail {
          dependency = "redis";
          message = "The redis dependency serves TLS, which this package cannot connect to.";
          fix = "Wire a server without TLS, or one that also listens without it.";
        }
      else
        dep;
  };
}
