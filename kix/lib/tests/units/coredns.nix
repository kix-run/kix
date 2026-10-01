# Tests for the kix/lib behaviour the coredns package relies on: package and
# instance config modules receive `clusterConfig` as a module argument.

{
  lib,
  mkCluster,
  ...
}:

let
  # Two options whose defaults come from the cluster: `zone` from the
  # package's own config module, `upstream` from the instance's.
  clusterFactsPackage = {
    meta.version = "test";
    options = {
      zone = lib.mkOption { type = lib.types.str; };
      upstream = lib.mkOption { type = lib.types.str; };
    };
    config =
      { clusterConfig, ... }:
      {
        zone = lib.mkDefault clusterConfig.clusterDomain;
      };
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "facts";
        };
        root = self.cm;
      };
  };
in
{
  # A package `config = { clusterConfig, ... }: ...` and an instance config
  # function both read clusterDomain "corp.internal".
  coredns-lib-cluster-config-special-arg =
    let
      cluster = mkCluster [
        {
          clusterDomain = "corp.internal";
          instances.dns.facts = {
            package = clusterFactsPackage;
            config =
              { clusterConfig, ... }:
              {
                upstream = "upstream.${clusterConfig.clusterDomain}";
              };
          };
        }
      ];
      cfg = cluster.instances.dns.facts._meta.config;
    in
    (cfg.zone == "corp.internal" && cfg.upstream == "upstream.corp.internal")
    || throw "clusterConfig module argument: zone ${builtins.toJSON cfg.zone}, upstream ${builtins.toJSON cfg.upstream}";
}
