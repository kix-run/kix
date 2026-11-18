# clusters/test-kind-v2.nix: the second build of test-kind.nix, with
# another message and two replicas.
#
# It keeps the cluster name "kind". The kind integration tests in cli/kix-cli
# deploy it over test-kind.nix to check a change to a deployed cluster.
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
              replicas = 2;
            };
          };
        };
      };
    }
  ];
}
