      instances.gateway-system.gateway = {
        package = packages."envoy-gateway";
        config.listeners = [
          {
            name = "http";
            port = 80;
            protocol = "HTTP";
            allowedRoutes.namespaces.from = "All";
          }
        ];
      };