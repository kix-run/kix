# clusters/ludo.nix — Luca's home server.
#
# Single node: i5 8-core, 16GB RAM, 512GB SSD + 4x HDD raidz2.
# NixOS + k3s. See demo/ludo-migration-plan.md for deployment plan.
#
# Build:  nix build .#cluster-ludo

{ kix, packages }:

kix.buildCluster {
  name = "ludo";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.k3s

    ./ludo/platform.nix
    ./ludo/databases.nix
    ./ludo/services.nix
    ./ludo/monitoring.nix

    {
      # Auto-instantiate deps (coredns, valkey, stackgres-operator, etc.)
      availablePackages = packages;

      # Single-node homelab — override k3s multi-node default
      cluster.capabilities.multiNode = false;

      cluster.domain = "ludo.lan";
      monitoring.enabled = true;
      clusterLabels = {
        "app.kubernetes.io/part-of" = "ludo";
        "cluster" = "ludo";
      };
    }
  ];
}
