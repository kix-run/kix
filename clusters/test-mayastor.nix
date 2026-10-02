# clusters/test-mayastor.nix: Mayastor's data path on kind, under Cilium
# default-deny.
#
# Three kind workers: io-engine runs on the two labelled
# `openebs.io/engine=mayastor`, each with a file-backed pool, and the
# first also holds an encrypted pool. etcd runs three members on kind's
# `standard` class (availability `node`). The classes give volumes two
# replicas, or one replica on the encrypted pool, and the snapshot class
# needs the snapshot-controller instance.
#
# Host prerequisites (scripts/kind-mayastor.sh checks them): the
# `nvme_tcp` module loaded, at least 2048 free 2 MiB hugepages before the
# cluster starts, and /run/udev on the host. io-engine runs on one core per
# node (`ioEngine.cpuCount = 1`).
#
# Build:  nix build .#cluster-mayastor --extra-experimental-features pipe-operators
# Deploy: scripts/kind-mayastor.sh

{ kix, packages }:

kix.buildCluster {
  name = "mayastor";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        cluster.capabilities.multiNode = true;
        # kind runs with the default CNI disabled (scripts/kind-mayastor.sh);
        # the managed cilium instance fills the vacant role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;

        namespaces = {
          snapshot = { };
          mayastor = { };
        };

        instances = {
          kube-system.cilium = {
            package = packages.cilium;
            config.values = {
              kubeProxyReplacement = false;
              prometheus.enabled = false;
              ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
            };
          };

          snapshot.snapshot-controller.package = packages.snapshot-controller;

          mayastor = {
            # The example key pair from the OpenEBS pool encryption
            # documentation, for this kind test only. These keys are
            # public: never reuse them for a pool that holds real data.
            pool-key = {
              package = packages.secret;
              config.stringData.encryption_parameters = builtins.toJSON {
                cipher = "AesXts";
                key = "2b7e151628aed2a6abf7158809cf4f3c";
                key_len = 128;
                key2 = "2b7e151628aed2a6abf7158809cf4f3d";
                key2_len = 128;
              };
            };

            mayastor = {
              package = packages.mayastor;
              availability = "node";
              deps.poolEncryptionKey = ref.mayastor.pool-key;
              config = {
                ioEngine.cpuCount = 1;
                # scripts/kind-mayastor.sh mounts each worker's directory at
                # the io-engine host directory and creates the pool files.
                diskPools = {
                  w1 = {
                    node = "kix-mayastor-worker";
                    disks = [ "aio:///var/local/mayastor/io-engine/disk.io" ];
                  };
                  w2 = {
                    node = "kix-mayastor-worker2";
                    disks = [ "aio:///var/local/mayastor/io-engine/disk.io" ];
                  };
                  w1e = {
                    node = "kix-mayastor-worker";
                    disks = [ "aio:///var/local/mayastor/io-engine/disk-enc.io" ];
                    encrypted = true;
                  };
                };
                storageClasses = {
                  ms-2.parameters = {
                    repl = "2";
                    thin = "true";
                  };
                  ms-1-enc.parameters = {
                    repl = "1";
                    thin = "true";
                    encrypted = "true";
                  };
                };
                volumeSnapshotClasses.ms-snap = { };
              };
            };
          };
        };
      }
    )
  ];
}
