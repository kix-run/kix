# Cluster-shape constants shared between (eventually) NixOS configs and kix.
#
# Plain Nix attrset, no kix or NixOS dependency. New per-cluster blocks go
# under their cluster name (e.g. `nw1`, `ja2`). Read from kix cluster
# definitions via `let globals = import ../globals.nix; in ...`.

{
  nw1 = {
    domain = "nw1.example.net";

    workers = [
      "nw1-worker1"
      "nw1-worker2"
      "nw1-worker3"
    ];

    # Disk path used by the openebs/mayastor DiskPool on every worker.
    # If/when workers diverge, switch this to a per-worker attrset.
    mayastorDiskPath = "/dev/mapper/vg0-mayastor0";

    # CIDRs. The dump's Connectors `nw1-production-pod-cidrs` /
    # `nw1-production-service-cidrs` consume these (TODO: wire them in).
    podCidr = "10.69.0.0/16";
    serviceCidr = "10.70.0.0/16";
  };
}
