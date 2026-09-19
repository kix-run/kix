# clusters/test-spread.nix — the availability level and derived pod spread
# on a multi-zone kind cluster.
#
# kind itself is one node per container, so zones are node labels set by
# the kind config (scripts/kind-spread.sh); the flavor's multiNode = false
# and availabilityZones = [ ] are overridden here to say so.
# Design: v2_discussions/archive/145_availability_level.md (spread mechanism: archive/143).
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
        # cluster default, derived "zone": three replicas from the level,
        # hard on the zone key, soft on hosts, plus a PDB.
        zoned = {
          package = packages.echo-server;
        };
        # operator escape hatch: one replica from the level, so no spread
        # and no PDB.
        unspread = {
          package = packages.echo-server;
          availability = "none";
        };
        # "node" on a zoned cluster: hard on hosts, soft on the zone.
        pinned = {
          package = packages.echo-server;
          config.replicaCount = 3;
          availability = "node";
        };
      };
    }
  ];
}
