      instances.database.postgres = {
        package = packages.stackgres-cluster;
        config = {
          instances = 1;
          postgres.version = "16";
          storage.size = "5Gi";
          instanceProfile = {
            cpu = "500m";
            memory = "1Gi";
          };
        };
      };