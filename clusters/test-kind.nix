# clusters/test-kind.nix: Lightweight cluster for local testing with kind.
#
# Contains only resources that work out-of-the-box in a vanilla kind cluster.
# Build:  kix build kind

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
              message = "hello from kix!";
            };
          };
        };
      };
    }
  ];
}
