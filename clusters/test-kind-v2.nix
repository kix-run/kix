# clusters/test-kind-v2.nix: Updated kind cluster for demo (v2).
#
# Changes from v1: different message, 2 replicas.
# Used by demo/vhs/run-demos.sh to simulate a cluster config change.
#
# Build:  nix build .#cluster-kind-activation --extra-experimental-features pipe-operators

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
