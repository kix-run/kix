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