# Reloader on a four-node kind cluster (scripts/kind-spread-config.yaml):
# two reloader replicas with one leader in `reloader`, and two Deployments in
# `demo` that each read one Secret created outside Kix and opt in to restarts
# with `out.withReloadOn`. `web` reads `demo-token` and `web2` reads
# `demo-other`, so a change to one Secret must restart only its Deployment.
#
# Bring up: kind create cluster --name kix-reloader --config scripts/kind-spread-config.yaml
# Secrets:  kubectl create namespace demo
#           kubectl -n demo create secret generic demo-token --from-literal=token=a
#           kubectl -n demo create secret generic demo-other --from-literal=token=a
#           (the deploy waits for both)
# Deploy:   kix --flake ./clusters --context kind-kix-reloader deploy reloader -y
# Rotate:   kubectl -n demo patch secret demo-token -p '{"stringData":{"token":"b"}}'
#           restarts web, not web2.
{ kix, packages }:

let
  demoPackage =
    { secretName }:
    {
      meta = {
        version = "test";
        description = "nginx that reads the Secret ${secretName} and restarts when it changes";
        owner = "test";
      };
      build =
        {
          self,
          scope,
          kix,
          reloader,
          ...
        }:
        {
          token = scope.mkSecretRef {
            name = secretName;
            keys = [ "token" ];
          };
          deployment =
            {
              name = scope.instanceName;
              spec = {
                selector.matchLabels = scope.selectorLabels;
                template.spec = {
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    runAsNonRoot = true;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "web";
                      image = "docker.io/nginxinc/nginx-unprivileged:1.30-alpine@sha256:ed04ec1ff34502c339ee5c3ae3f855442398edc1d05591e2b98981dcbbd20b1e";
                      ports = [ (kix.port "http" 8080) ];
                      env = self.token.out.mkEnv { TOKEN = "token"; };
                      livenessProbe.httpGet = {
                        path = "/";
                        port = "http";
                      };
                      readinessProbe.httpGet = {
                        path = "/";
                        port = "http";
                      };
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "16Mi";
                        };
                        limits = {
                          cpu = "100m";
                          memory = "64Mi";
                        };
                      };
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        capabilities.drop = [ "ALL" ];
                      };
                    }
                  ];
                };
              };
            }
            |> reloader.out.withReloadOn [ self.token ]
            |> scope.mkDeployment;
          root = self.deployment;
        };
    };
in
kix.buildCluster {
  name = "reloader";
  modules = [
    kix.flavors.kind
    { cluster.capabilities.multiNode = true; }
    {
      namespaces.reloader = { };
      namespaces.demo = { };

      instances.reloader.reloader = {
        package = packages.experimental.reloader;
        availability = "node";
      };

      instances.demo = {
        web.package = demoPackage { secretName = "demo-token"; };
        web2.package = demoPackage { secretName = "demo-other"; };
      };
    }
  ];
}
