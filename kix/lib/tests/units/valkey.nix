# Tests for the kix/lib behaviour the valkey rework relies on: an import of a
# package whose `build` is a list, and resolution errors that name the
# instance asking for the dependency.

{
  eval,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  # A package shaped like valkey: a main build entry with a Deployment and
  # its Service, and a kix.monitor entry.
  listBuildPackage =
    { scope, kix, ... }:
    {
      meta.version = "test";
      options.metrics = kix.options.monitor;
      build = [
        (
          { self, scope, ... }:
          {
            deployment = scope.mkDeployment {
              name = "cache";
              spec = {
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                template = {
                  metadata.labels = scope.selectorLabels;
                  spec.containers = [
                    {
                      name = "cache";
                      image = "cache:1";
                      ports = [
                        {
                          name = "tcp";
                          containerPort = 6379;
                        }
                      ];
                    }
                  ];
                };
              };
            };
            service = self.deployment |> kix.service.fromWorkload { name = "cache"; } |> scope.mkResource;
            root = self.service;
          }
        )
        (kix.monitor { service = "service"; })
      ];
    };

  # Writes the address of its `cache` dependency into a ConfigMap.
  cacheConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        cache,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "cache-consumer";
          extra.data = {
            host = cache.out.fqdn;
            port = cache.out.port;
          };
        };
        root = self.cm;
      };
  };

  # Requires `secretValue`, which nothing in the cluster provides.
  secretConsumer = {
    meta = {
      version = "test";
      defaultAliases = [ "cache" ];
    };
    build =
      {
        self,
        scope,
        secretValue,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "secret-consumer";
        };
        root = self.cm;
      };
  };
in
{
  # `kix.mkImport { from = listBuildPackage; }` runs both build entries; a
  # consumer reads the imported Service's fqdn and port.
  valkey-import-list-build =
    let
      cluster = mkCluster [
        {
          instances.cache.cache.package = eval.mkImport { from = listBuildPackage; };
          instances.app.consumer.package = cacheConsumer;
        }
      ];
      cm = byName "cache-consumer" (ofKind "ConfigMap" (manifests cluster));
      data = if cm == null then { } else cm.data;
    in
    (data.host or null == "cache.cache.svc.cluster.local" && data.port or null == "6379")
    || throw "import of a list build: consumer data ${builtins.toJSON data}";

  # The not-found error names the requester as "<ns>/<instance>", and adds
  # "(auto-instantiated)" when the requester came from availablePackages.
  # tryEval drops the message, so the test checks the failures and
  # describeRequester's text; the full message was confirmed by hand.
  valkey-missing-dep-names-requester =
    let
      direct = mkCluster [ { instances.app.cache.package = secretConsumer; } ];
      auto = mkCluster [
        {
          availablePackages.cache.package = secretConsumer;
          instances.app.consumer.package = cacheConsumer;
        }
      ];
      described = [
        (eval.describeRequester "app" "cache" { })
        (eval.describeRequester "app" "cache" { _autoInstantiated = true; })
      ];
    in
    (
      evalFails direct
      && evalFails auto
      &&
        described == [
          "app/cache"
          "app/cache (auto-instantiated)"
        ]
    )
    || throw "requester in resolution errors: ${builtins.toJSON described}";
}
