          partsOverlays = [
            (
              scope: _self: base:
              let
                patchedConfig = scope.mkResource {
                  inherit (base.clientConfig) apiVersion kind name;
                  inherit (base.clientConfig.rawManifest) data;
                  annotations."example.com/adopted-from" = "legacy-config";
                };
              in
              {
                clientConfig = patchedConfig;
                root = patchedConfig;
              }
            )
          ];