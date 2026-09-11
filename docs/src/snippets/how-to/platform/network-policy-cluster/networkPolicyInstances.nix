        instances.services.backend = {
          package = packages.echo-server;
          config.message = "Hello across a generated network policy!";
        };

        instances.apps.client = {
          package = clientPackage;
          deps.backend = ref.services.backend;
        };