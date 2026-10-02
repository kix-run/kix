# clusters/test-auto.nix — Test auto-instantiation and optional instances.
#
# Exercises:
# 1. Auto-instantiation of valkey (required dep of test-app)
# 2. Optional instance activation
# 3. Transitive auto-instantiation (test-app → valkey)
# 4. Inactive optional not deployed
#
# Build:  nix build .#cluster-auto

{ kix, packages }:

let
  # NB: each package puts its resource under a named part with `root`
  # aliased to it. Assigning the resource straight to `root` renders NOTHING
  # but the PackageInstance marker — collectResources excludes the `root`
  # key (kixpkgs#25). These fixtures previously did exactly that, so the
  # ConfigMaps they exist to assert on were silently absent while the
  # clusters still built green.

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

  # A package that requires coredns — used to test optional activation.
  needsCorednsPackage = {
    meta.version = "0.0.0";
    build =
      {
        self,
        scope,
        coredns,
        ...
      }:
      {
        configMap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "needs-coredns";
          data.DNS_SERVICE = coredns.out.fqdn;
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

      # test-app requires valkey — should trigger auto-instantiation.
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

      # Optional instance that nobody needs — should NOT produce resources.
      instances.unused-ns = {
        unused = {
          package = unusedOptionalPackage;
          optional = true;
        };
      };

      # Optional coredns in infra ns — will be activated by needs-coredns.
      instances.infra = {
        coredns = {
          package = packages.coredns;
          optional = true;
          config.clusterIP = "10.96.0.10";
        };
      };

      # needs-coredns requires coredns — should activate the optional instance.
      instances.other = {
        needs-coredns = {
          package = needsCorednsPackage;
        };
      };
    }
  ];
}
