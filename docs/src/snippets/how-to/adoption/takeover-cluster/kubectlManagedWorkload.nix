      instances.takeover.legacy-web = {
        package = webPackage;

        # Keep the live Deployment's immutable selector.
        selectorLabels = {
          app = "legacy-web";
          tier = "frontend";
        };

        config = {
          replicas = 2;
          environment = "production";
          message = "This workload is managed by Kix";
        };
      };