      clientConfig = scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "legacy-api-client";
        data.endpoint = "http://${legacyApi.out.fqdn}:${toString legacyApi.out.port}";
      };

      root = self.clientConfig;