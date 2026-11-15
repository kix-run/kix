# clusters/test-secrets.nix: Integration test for SOPS secret hydration.
#
# Deploys:
#   1. A standalone SOPS-encrypted secret (credentials)
#   2. A pod that reads credentials from the secret via env vars
#
# Build:  kix build secrets
# Deploy: kix deploy secrets --yes

{ kix, packages }:

kix.buildCluster {
  name = "test-secrets";
  modules = [
    kix.flavors.kind

    {
      namespaces = {
        test = { };
      };

      instances = {
        test = {
          # SOPS-encrypted database credentials.
          # The SOPS file is created by the integration test script.
          credentials = {
            package = packages.secret;
            config = {
              keys = [
                "username"
                "password"
                "host"
                "port"
              ];
              source = ./test-secrets/db-credentials.enc.json;
            };
          };

          # Echo server that proves secrets were injected.
          secret-echo = {
            package = packages.experimental.secret-echo;
          };
        };
      };
    }
  ];
}
