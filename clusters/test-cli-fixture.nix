# clusters/test-cli-fixture.nix: the cluster the CLI's tests build.
#
# The tests under cli/ check what each command prints, so they need a
# cluster whose output changes only when the library or the CLI changes.
# Both packages are defined in this file for that reason. The cluster takes
# nothing from Kix's package set, and the unit tests in
# kix/lib/tests/units/cli-fixture.nix fail when it does.
#
# What the tests rely on:
# - `store` has a ConfigMap, a Deployment, and a Service.
# - `web` depends on `store`, which gives `kix graph` an edge to draw.
# - `web` declares `meta.availability.max = "none"` while the cluster asks
#   for "node", so every build carries a warning from the library.
#
# Build:  kix build cli-fixture

{ kix, ... }:

let
  image = {
    repository = "registry.example.com/fixture/server";
    tag = "1.0.0";
    digest = "sha256:0000000000000000000000000000000000000000000000000000000000000001";
  };

  container =
    {
      kix,
      config,
      env,
    }:
    {
      name = "server";
      image = kix.image.ref config.image;
      imagePullPolicy = config.image.pullPolicy;
      inherit env;
      securityContext = {
        runAsNonRoot = true;
        readOnlyRootFilesystem = true;
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        seccompProfile.type = "RuntimeDefault";
      };
      ports = [ (kix.port "http" 8080) ];
      livenessProbe.httpGet = {
        path = "/healthz";
        port = 8080;
      };
      readinessProbe.httpGet = {
        path = "/healthz";
        port = 8080;
      };
      resources = {
        requests = {
          cpu = "50m";
          memory = "32Mi";
        };
        limits = {
          cpu = "100m";
          memory = "64Mi";
        };
      };
    };

  storePackage =
    { scope, kix, ... }:
    let
      name = scope.instanceName;
    in
    {
      meta = {
        version = "1.0.0";
        description = "Fixture store: a ConfigMap, a Deployment, and a Service";
        owner = "fixture-team";
      };

      options.image = kix.options.image image;

      build =
        { self, config, ... }:
        {
          configmap = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            inherit name;
            data.greeting = "hello from the fixture store";
          };

          deployment =
            {
              inherit name;
              spec = {
                replicas = 2;
                selector.matchLabels = scope.selectorLabels;
                template.metadata.annotations."checksum/config" = self.configmap.out.contentHash;
                template.spec.containers = [
                  (container {
                    inherit kix config;
                    env = [ ];
                  })
                ];
              };
            }
            |> scope.mkDeployment;

          service =
            self.deployment
            |> kix.service.fromWorkload {
              inherit name;
              ports = [
                {
                  name = "http";
                  port = 80;
                  targetPort = 8080;
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource;

          root = self.service;
        };
    };

  webPackage =
    { scope, kix, ... }:
    let
      name = scope.instanceName;
    in
    {
      meta = {
        version = "1.0.0";
        description = "Fixture web server: one Deployment that reads the store";
        owner = "fixture-team";
        # Lower than the cluster's default, so each build carries a warning.
        availability.max = "none";
      };

      options.image = kix.options.image image;

      build =
        {
          self,
          config,
          store,
          ...
        }:
        {
          deployment =
            {
              inherit name;
              spec = {
                replicas = 1;
                selector.matchLabels = scope.selectorLabels;
                template.spec.containers = [
                  (container {
                    inherit kix config;
                    env = [
                      {
                        name = "STORE_HOST";
                        value = store.out.fqdn;
                      }
                    ];
                  })
                ];
              };
            }
            |> scope.mkDeployment;

          root = self.deployment;
        };
    };
in
kix.buildCluster {
  name = "test-cli-fixture";
  modules = [
    {
      cluster.availability.default = "node";
      cluster.capabilities.multiNode = true;

      namespaces.fixture = { };

      instances.fixture = {
        store.package = storePackage;
        web.package = webPackage;
      };
    }
  ];
}
