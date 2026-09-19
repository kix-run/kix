# clusters/test-sealed-jobs.nix — the two packages whose Jobs go through
# scope.mkJob: cert-manager (startupapicheck) and python-app (hooks.migrate).
# Nothing else in clusters/ turns the migrate hook on, so this is where a
# change to mkJob shows up.
#
# Build:  nix build .#cluster-sealed-jobs --extra-experimental-features pipe-operators

{ kix, packages }:

kix.buildCluster {
  name = "sealed-jobs";
  modules = [
    kix.flavors.kind

    {
      cluster.capabilities.multiNode = true;
      cluster.capabilities.availabilityZones = [
        "a"
        "b"
        "c"
      ];

      namespaces = {
        cert-manager = { };
        app = { };
      };

      instances = {
        cert-manager.cert-manager.package = packages.cert-manager;

        app.python-app = {
          package = packages.python-app;
          config = {
            backend.image = {
              repository = "ghcr.io/example/python-app";
              tag = "1.0.0";
            };
            hooks.migrate = {
              enabled = true;
              command = [
                "python"
                "manage.py"
                "migrate"
              ];
            };
          };
        };
      };
    }
  ];
}
