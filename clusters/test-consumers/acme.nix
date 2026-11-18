# clusters/test-consumers/acme.nix: the consumer of ./platform.nix, built
# from its own code against the platform's interface file.
#
# The consumer names its own cluster, acme-prod, and renders its own
# namespace, acme-app, which carries the label, Pod Security level and quota
# the interface sets. It reaches the platform's api service as the import
# acme-app/api.
#
# Build:  kix build consumers-acme

{ kix, packages }:

kix.buildCluster {
  name = "acme-prod";
  modules = [
    (kix.interface {
      file = ./kix-interface/test-platform.json;
      importNamespace = "acme-app";
    })
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
