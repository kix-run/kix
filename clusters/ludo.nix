# clusters/ludo.nix — Luca's home server (single laptop, parents' house).
#
# Single node: i5 8-core, 16GB RAM, 512GB SSD + 4x HDD raidz2 (~12TB).
# NixOS + k3s. All services behind Tailscale VPN.
#
# Build:  nix build .#cluster-ludo

{ kix, packages }:

kix.buildCluster {
  name = "ludo";
  specialArgs = { inherit packages kix; };
  modules = [
    # Platform infrastructure
    ./ludo/platform.nix
    ./ludo/monitoring.nix

    # Phase 1 — core family services
    ./ludo/immich.nix
    ./ludo/nas.nix

    # Phase 2 — stable value drivers (uncomment when Phase 1 is stable)
    # ./ludo/vaultwarden.nix
    # ./ludo/homeassistant.nix

    # Cluster-level settings
    {
      cluster.domain = "ludo.example.com";
      monitoring.enabled = true;
      clusterLabels = {
        "app.kubernetes.io/part-of" = "ludo";
        "cluster" = "ludo";
      };
    }
  ];
}
