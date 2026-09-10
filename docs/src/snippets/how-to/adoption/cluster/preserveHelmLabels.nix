        apps.helm-web = {
          package = webPackage;
          labelStyle = "helm";
          config = {
            message = "Kix manages a Helm-labelled workload";
            environment = "production";
          };
        };