# The reloader fixture both clusters share: a reloader instance at `node` in
# `reloaderNs`, and two Deployments in `demoNs` that each read one Secret
# created outside Kix and opt in to restarts with `out.withReloadOn`. `web`
# reads `demo-token`, `web2` reads `demo-other`, so a change to one Secret
# must restart only its Deployment. Create both Secrets (key `token`) before
# deploying; the deploy waits for them.
{
  packages,
  reloaderNs,
  demoNs,
  reloaderConfig,
}:
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
                      image = "nginxinc/nginx-unprivileged:1.27-alpine";
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
{
  namespaces.${reloaderNs} = { };
  namespaces.${demoNs} = { };

  instances.${reloaderNs}.reloader = {
    package = packages.reloader;
    availability = "node";
    config = reloaderConfig;
  };

  instances.${demoNs} = {
    web.package = demoPackage { secretName = "demo-token"; };
    web2.package = demoPackage { secretName = "demo-other"; };
  };
}
