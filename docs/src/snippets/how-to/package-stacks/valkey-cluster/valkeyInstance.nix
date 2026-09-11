      instances.cache.valkey = {
        package = packages.valkey;
        config = {
          replicaCount = 1;
          sentinel.enabled = false;

          persistence = {
            enabled = true;
            size = "2Gi";
          };

          # Use SOPS or an existing Secret outside local development.
          auth.password = "development-only-password";
        };
      };