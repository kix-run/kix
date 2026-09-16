  # `kix.modules.monitoring` reads the package catalogue, which buildCluster
  # does not pass to modules on its own. specialArgs forwards it.
  specialArgs = { inherit kix packages; };

  modules = [
    kix.flavors.kind
    {
      imports = [ kix.modules.monitoring ];

      monitoring = {
        enabled = true;
        prometheus = {
          retention = "7d";
          scrapeInterval = "30s";
        };

        # Keep the local example independent of persistent storage.
        grafana.persistence.enabled = false;

        # Add the standard Kubernetes alerts, recording rules, and monitors.
        defaultRules.enabled = true;
      };
    }
  ];