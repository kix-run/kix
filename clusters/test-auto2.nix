# clusters/test-auto2.nix: the second build of test-auto.nix, without the
# needs-coredns instance.
#
# It keeps the cluster name "test-auto", so a deploy or diff of this build
# over test-auto shows what happens when the last consumer of an optional
# instance goes: the optional coredns instance is no longer activated and
# its resources are removed.
#
# Build:  kix build auto2

{ kix, packages }:

let
  # Each package puts its resource under a named part with `root` aliased to it.
  # collectResources excludes the `root` key, so assigning a resource directly
  # to `root` renders only the PackageInstance marker.

  # Minimal test package that requires valkey as a hard dependency.
  testAppPackage = {
    meta.version = "0.0.0";
    build =
      {
        self,
        scope,
        valkey,
        ...
      }:
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "test-app";
          data.REDIS_HOST = valkey.out.fqdn;
        };
        root = self.configMap;
      };
  };

  # A package with no deps, used to test that optional instances
  # that are NOT needed don't produce resources.
  unusedOptionalPackage = {
    build =
      { self, scope, ... }:
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "unused";
          data.placeholder = "true";
        };
        root = self.configMap;
      };
  };
in
kix.buildCluster {
  name = "test-auto";
  modules = [
    {
      # Valkey is available for auto-instantiation.
      availablePackages = {
        inherit (packages) valkey;
      };

      namespaces.app = { };

      # test-app requires valkey, which triggers auto-instantiation.
      instances.app = {
        test-app = {
          package = testAppPackage;
        };
        # Required by the auto-instantiated valkey, which lands in `app`.
        valkey-password = {
          package = packages.secret;
          aliases = [ "valkeyPassword" ];
          config.stringData.password = "test-password";
        };
      };

      # Optional instance that nobody needs; must not produce resources.
      instances.unused-ns = {
        unused = {
          package = unusedOptionalPackage;
          optional = true;
        };
      };

      # Optional coredns in infra. Nothing here needs it, so it stays
      # inactive.
      instances.infra = {
        coredns = {
          package = packages.experimental.coredns;
          optional = true;
          config.clusterIP = "10.96.0.10";
        };
      };
    }
  ];
}
