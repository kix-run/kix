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
  # Minimal test package that requires valkey as a hard dependency.
  testAppPackage =
    {
      scope,
      lib,
      valkey,
    }:
    {
      options = { };

      build =
        { self, config, ... }:
        {
          main = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "test-app";
            data = {
              REDIS_HOST = valkey.out.fqdn;
            };
          };
        };
    };

  # A package with no deps, used to test that optional instances
  # that are NOT needed don't produce resources.
  unusedOptionalPackage =
    { scope, lib }:
    {
      options = { };
      build =
        { ... }:
        {
          main = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "unused";
            data.placeholder = "true";
          };
        };
    };

  # A package that requires coredns — used to test optional activation.
  needsCorednsPackage =
    {
      scope,
      lib,
      coredns,
    }:
    {
      options = { };
      build =
        { ... }:
        {
          main = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "needs-coredns";
            data.DNS_SERVICE = coredns.out.fqdn;
          };
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
        };
      };
    }
  ];
}
