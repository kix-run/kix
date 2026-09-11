      instances.reflector-system.reflector = {
        package = kix.helmChart {
          repo = "https://emberstack.github.io/helm-charts";
          name = "reflector";
          version = "10.0.60";
          hash = "sha256-UdCVcUqJogyUYmGo1HnQ1fMxY7ZEV56+9wQSJfWOhVM=";
          releaseName = "reflector";
        };
      };