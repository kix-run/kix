# clusters/test-spread.nix — derived pod spread on a multi-zone kind cluster.
#
# kind itself is one node per container, so zones are node labels set by
# the kind config (scripts/kind-spread.sh); the flavor's multiNode = false
# and availabilityZones = [ ] are overridden here to say so.
# Design: v2_discussions/143_pod_spread_and_failure_zones.md.
#
# Build:  nix build .#cluster-spread --extra-experimental-features pipe-operators
# Deploy: scripts/kind-spread.sh

{ kix, packages }:

kix.buildCluster {
  name = "spread";
  modules = [
    kix.flavors.kind

    {
      cluster.capabilities.multiNode = true;
      cluster.capabilities.availabilityZones = [
        "a"
        "b"
        "c"
      ];
      namespaces.echo = { };

      instances.echo = {
        # cluster default: hard on zones, soft on hosts, plus a PDB.
        zoned = {
          package = packages.echo-server;
          config.replicaCount = 3;
        };
        # operator escape hatch: no spread, no PDB.
        unspread = {
          package = packages.echo-server;
          config.replicaCount = 2;
          spread = "off";
        };
        # hard on every key: even across zones and across hosts.
        pinned = {
          package = packages.echo-server;
          config.replicaCount = 3;
          spread = "hard";
        };
      };
    }
  ];
}
