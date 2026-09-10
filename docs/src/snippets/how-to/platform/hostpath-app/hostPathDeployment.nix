      deployment =
        {
          name = scope.instanceName;
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "worker";
                image = "docker.io/library/busybox:1.37";
                command = [
                  "sh"
                  "-c"
                  "sleep infinity"
                ];
              }
            ];
          };
        }
        |> kix.withMounts [ self.cacheMount ]
        |> scope.mkDeployment;