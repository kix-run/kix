      credentials = scope.mkSecret {
        name = "${scope.instanceName}-credentials";
        keys = [
          "username"
          "password"
        ];
        source = ./sops-credentials.enc.yaml;
      };