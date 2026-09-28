# Redis: wraps the upstream Bitnami `redis` Helm chart directly.
#
# We have a separate `valkey` package for new deployments; this exists so
# clusters that originally rolled out the Bitnami `redis` chart can be
# migrated 1:1 (no name drift) until they're switched over.
#
# Chart:   oci://registry-1.docker.io/bitnamicharts
# Name:    redis
# Version: 19.1.0
#
# Note: no `defaultAliases = ["redis"]`: the `valkey` package already
# claims that alias, and both can legitimately coexist in a cluster.
# Wire instances explicitly with `package = packages.redis;`.

{ scope, lib }:
let
  chart = scope.helm.fetchHelmChart {
    repo = "oci://registry-1.docker.io/bitnamicharts";
    name = "redis";
    version = "19.1.0";
    hash = "sha256-8CL2KWtWKiBwkr8w+2q8H98AhKPK5aRpDy2xljZ2jZo=";
  };

  defaultValues = {
    # Bitnami charts refuse non-Bitnami image registries (e.g. bitnamilegacy)
    # unless this flag is set. importChart only takes values, no CLI flags,
    # so we pass it as a value.
    global.security.allowInsecureImages = true;
  };
in
{
  meta = {
    version = "19.1.0";
    description = "Redis from the upstream Bitnami Helm chart, for clusters that already run that release; new deployments use valkey";
    owner = "platform";
    isHelm = true;
  };

  options.values = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Helm values to deep-merge with the chart's package-level values.";
  };

  build =
    { config, scope, ... }:
    let
      resources = scope.helm.importChart {
        inherit chart scope;
        values = lib.recursiveUpdate defaultValues (config.values or { });
        releaseName = scope.instanceName;
      };
    in
    resources.mkParts {
      root = builtins.head (resources.byKind "StatefulSet");
    };
}
