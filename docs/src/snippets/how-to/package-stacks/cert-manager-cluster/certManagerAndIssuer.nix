      instances.cert-manager = {
        cert-manager = {
          package = packages.cert-manager;
        };

        cluster-issuers = {
          package = packages.cluster-issuers;
          config = { lib, ... }: {
            mainIssuer = "local-self-signed";
            issuers = lib.mkForce {
              local-self-signed.kind = "selfSigned";
            };
          };
        };
      };