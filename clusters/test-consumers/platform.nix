# clusters/test-consumers/platform.nix: a cluster that hosts a consumer.
#
# It grants consumer `acme` the namespaces acme-* and its own api service,
# and writes acme's interface file beside its Activation record:
# `nix build .#cluster-consumers-platform-activation`, then
# result/kix-interface-acme.json. ./acme.nix builds the consumer against a
# copy of that file, ./kix-interface/test-platform.json.

{ kix, packages }:

let
  apiPackage = {
    meta.version = "0.0.0";
    build =
      { self, scope, ... }:
      {
        deployment = scope.mkDeployment {
          name = "api";
          spec = {
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata.labels = scope.selectorLabels;
              spec.containers = [
                {
                  name = "api";
                  image = "registry.example.com/api:1";
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = 1000;
                    readOnlyRootFilesystem = true;
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                  };
                  resources = {
                    requests = {
                      cpu = "10m";
                      memory = "32Mi";
                    };
                    limits.memory = "64Mi";
                  };
                  livenessProbe.httpGet = {
                    path = "/";
                    port = "http";
                  };
                  readinessProbe.httpGet = {
                    path = "/";
                    port = "http";
                  };
                  ports = [
                    {
                      name = "http";
                      containerPort = 8080;
                    }
                  ];
                }
              ];
            };
          };
        };
        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "api";
          spec = {
            selector = scope.selectorLabels;
            ports = [
              {
                name = "http";
                port = 80;
                targetPort = "http";
              }
            ];
          };
        };
        root = {
          resource = self.service;
          requires = [ self.deployment ];
        };
      };
  };
in
kix.buildCluster {
  name = "test-platform";
  modules = [
    {
      namespaces.kube-system = { };
      instances.kube-system.coredns = {
        package = packages.coredns;
        config.clusterIP = "10.96.0.10";
      };

      instances.platform.api.package = apiPackage;

      consumers.acme = {
        namespaces."acme-*" = {
          podSecurity = "baseline";
          quota.pods = "20";
          max = 5;
        };
        services = [ "platform/api" ];
      };
    }
  ];
}
