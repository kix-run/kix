# clusters/test-kind-port.nix: the kind cluster with the echo-server
# Service on another port.
#
# Changes from test-kind.nix: service port 8081. The Service depends on the
# Deployment and the Deployment does not depend on the Service, so this
# build changes the Service and its PackageInstance and leaves the
# Deployment unchanged. The kind integration test deploys it over a
# Deployment it broke with kubectl, to check that the deploy fails on the
# Deployment and not on the Service.
#
# Build:  nix build .#cluster-kind-port-activation --extra-experimental-features pipe-operators

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
              service.port = 8081;
            };
          };
        };
      };
    }
  ];
}
