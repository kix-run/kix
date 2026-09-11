      # The Kind cluster for this example is created without kindnet, so the
      # CNI role is available for a managed package.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };

      networkPolicy.enable = true;