          legacy.legacy-api = {
            package = kix.mkImport {
              kind = "Service";
              apiVersion = "v1";
              out = {
                name = "legacy-api";
                fqdn = "legacy-api.legacy.svc.cluster.local";
                port = 8080;
              };
            };
            aliases = [ "legacyApi" ];

            extraDeps = [ ref.apps.legacy-api-contract.root ];
          };

          apps.legacy-api-contract.package = contractPackage;