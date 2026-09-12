          apps.legacy-web = {
            package = webPackage;
            selectorLabels = {
              app = "legacy-web";
              tier = "frontend";
            };
            config = {
              message = "Kix now manages this workload";
              environment = "production";
            };
          };