# clusters/test-consumers/acme.nix: the consumer of ./platform.nix, built
# from its own code against the platform's interface file.
#
# The platform creates acme-app, so this build renders no Namespace, and
# reaches the platform's api service as the import acme-app/api.
#
# Build:  nix build .#cluster-consumers-acme

{ kix, packages }:

kix.buildCluster {
  name = "test-platform-acme";
  modules = [
    (kix.interface ./kix-interface/test-platform.json)
    (
      { config, ... }:
      {
        instances.acme-app.web.package = {
          meta.version = "0.0.0";
          build =
            { self, scope, ... }:
            {
              config = scope.mkResource {
                apiVersion = "v1";
                kind = "ConfigMap";
                name = "web";
                data.api = config.interfaces.test-platform.services."platform/api".out.fqdn;
              };
              root = self.config;
            };
        };
      }
    )
  ];
}
