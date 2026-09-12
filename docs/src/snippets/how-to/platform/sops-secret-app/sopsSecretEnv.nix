      deployment = scope.mkDeployment {
        name = scope.instanceName;
        spec = {
          replicas = 1;
          selector.matchLabels = scope.selectorLabels;
          template.spec.containers = [
            {
              name = "app";
              image = "busybox:1.36";
              command = [
                "sh"
                "-c"
                "sleep 3600"
              ];
              env = self.credentials.out.mkEnv {
                APP_USERNAME = "username";
                APP_PASSWORD = "password";
              };
            }
          ];
        };
      };