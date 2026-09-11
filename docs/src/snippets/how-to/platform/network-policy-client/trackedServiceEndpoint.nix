  build =
    {
      self,
      scope,
      backend,
      ...
    }:
    {
      deployment = scope.mkDeployment {
        name = scope.instanceName;
        spec = {
          replicas = 1;
          selector.matchLabels = scope.selectorLabels;
          template.spec.containers = [
            {
              name = "client";
              image = "docker.io/library/nginx:1.27-alpine";
              env = [
                {
                  name = "BACKEND_URL";
                  value = backend.out.url { };
                }
              ];
            }
          ];
        };
      };

      root = self.deployment;
    };