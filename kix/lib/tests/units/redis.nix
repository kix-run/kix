# Tests for the Redis contract (kix/contracts/stable/redis.nix): the fields it
# accepts, the refusal of TLS for a consumer that cannot use it, and the
# `out` valkey publishes with and without Sentinel. The consumers are
# tested in units/n8n.nix and units/immich.nix.

{
  lib,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  ...
}:

let
  contract = kixlib.contracts.redis;
  valkeyPackage = import ../../../packages/stable/valkey;
  secretPackage = import ../../../packages/stable/secret;

  plain = {
    host = "valkey.example.net";
    port = "6379";
  };
  secretWith = keys: {
    out = {
      inherit keys;
      keyRef = key: { secretKeyRef = { inherit key; }; };
    };
  };

  # Writes what its `valkey` dependency publishes into a ConfigMap.
  consumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        valkey,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "redis-out";
          extra.data = {
            inherit (valkey.out) host port;
            tls = builtins.toJSON valkey.out.tls;
            sentinel = builtins.toJSON valkey.out.sentinel;
            passwordKey =
              let
                ref = valkey.out.credentials.out.keyRef "password";
              in
              (ref.valueFrom or ref).secretKeyRef.key;
          };
        };
        root = self.cm;
      };
  };

  outOf =
    config:
    (byName "redis-out" (
      ofKind "ConfigMap" (
        manifests (mkCluster [
          {
            instances.cache = {
              valkey-password = {
                package = secretPackage;
                aliases = [ "valkeyPassword" ];
                config.stringData.password = "pw";
              };
              valkey = {
                package = valkeyPackage;
                inherit config;
              };
              app.package = consumer;
            };
          }
        ])
      )
    )).data;
in
{
  redis-contract-fields =
    contract.problems plain == [ ]
    && contract.problems (plain // { credentials = secretWith [ "password" ]; }) == [ ]
    && contract.problems (plain // { credentials = secretWith [ "username" ]; }) != [ ]
    && contract.problems (plain // { port = 6379; }) != [ ]
    && contract.problems (plain // { tls = "yes"; }) != [ ]
    && contract.problems (plain // { sentinel = null; }) == [ ]
    && contract.problems (plain // { sentinel.port = "26379"; }) != [ ]
    && contract.problems (removeAttrs plain [ "host" ]) != [ ]
    && !contract.helpers.usesSentinel {
      out = plain // {
        sentinel = null;
      };
    }
    && contract.helpers.usesSentinel {
      out = plain // {
        sentinel = {
          port = "26379";
          primarySet = "primary";
        };
      };
    };

  redis-require-plaintext =
    let
      dep = tls: {
        out = plain // {
          inherit tls;
        };
      };
    in
    contract.helpers.requirePlaintext "app" (dep false) == dep false
    && !(builtins.tryEval (contract.helpers.requirePlaintext "app" (dep true))).success;

  # Standalone valkey publishes `sentinel = null`; with Sentinel, its port
  # and primary set. Both publish the password secret as credentials.
  redis-valkey-publishes-contract =
    let
      standalone = outOf {
        sentinel.enabled = false;
        replicas = 1;
      };
      sentinel = outOf {
        sentinel.enabled = true;
        replicas = 3;
      };
    in
    (
      lib.hasPrefix "valkey.cache.svc." standalone.host
      && standalone.port == "6379"
      && standalone.tls == "false"
      && standalone.sentinel == "null"
      && standalone.passwordKey == "password"
      &&
        builtins.fromJSON sentinel.sentinel == {
          port = "26379";
          primarySet = "primary";
        }
    )
    || throw "redis valkey out: standalone ${builtins.toJSON standalone}, sentinel ${builtins.toJSON sentinel}";
}
