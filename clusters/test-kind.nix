# clusters/test-kind.nix — Lightweight cluster for local testing with kind.
#
# Contains only resources that work out-of-the-box in a vanilla kind cluster.
# Build:  nix build .#cluster-kind --extra-experimental-features pipe-operators
# Apply:  kubectl apply -f result/

{ kix, packages }:

kix.buildCluster {
  name = "test-kind";
  modules = [
    {
      namespaces = {
        echo = { };
      };

      instances = {
        echo = {
          echo-server = {
            package = packages.echo-server;
            config = {
              message = "hello from kix on kind v2!";
            };
          };
        };
      };
    }
  ];
}
