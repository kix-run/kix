# clusters/test-kind-v2.nix: Updated kind cluster for demo (v2).
#
# Changes from v1: different message, 2 replicas.
# The kind integration tests in cli/kix-cli deploy it over kind to simulate a
# cluster config change.
#
# Build:  kix build kind-v2

{ kix, packages }:

kix.buildCluster {
  name = "kind";
  modules = [
    kix.flavors.kind

    {
      namespaces = {
        echo = { };
      };

      instances = {
        echo = {
          echo-server = {
            package = packages.echo-server;
            config = {
              message = "hello from kix v2 — updated!";
              replicaCount = 2;
            };
          };
        };
      };
    }
  ];
}
