# clusters/example-hello.nix: the smallest useful Kix cluster, and the one to
# read first.
#
# One namespace holds a web server and a Valkey store. Valkey needs a
# password, and a `secret` instance with the alias `valkeyPassword` provides
# it. Kix finds that dependency by its alias, so neither instance names the
# other. Every package here is stable.
#
# Build:  kix build example-hello
# Deploy: kix deploy example-hello --context <kind context>

{ kix, packages }:

kix.buildCluster {
  name = "hello";
  modules = [
    # Tells Kix what a stock kind cluster already runs: one node, CoreDNS,
    # a default StorageClass, and no load balancer.
    kix.flavors.kind

    {
      namespaces.hello = { };

      instances.hello = {
        web = {
          package = packages.echo-server;
          config.message = "hello from Kix";
        };

        cache = {
          package = packages.valkey;
        };

        # A literal password is fine on a local cluster. Elsewhere, give the
        # secret a SOPS-encrypted `source` instead.
        cache-password = {
          package = packages.secret;
          aliases = [ "valkeyPassword" ];
          config.stringData.password = "hello-dev-password";
        };
      };
    }
  ];
}
