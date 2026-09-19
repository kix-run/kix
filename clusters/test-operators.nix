# clusters/test-operators.nix — the operator packages whose workloads used
# to be raw scope.mkResource Deployments, on a three-zone kind cluster.
#
# coredns, velero, arc, cdi, kubevirt, infisical-operator and openebs, one
# namespace each, every workload now sealed through the typed builders:
# derived spread, PodDisruptionBudgets, network-policy edges. multiNode and
# three zones are declared so the derivation has domains to spread over;
# the kind cluster matches (scripts/kind-spread-config.yaml).
#
# Build:  nix build .#cluster-operators --extra-experimental-features pipe-operators
# Deploy: scripts/kind-operators.sh

{ kix, packages }:

kix.buildCluster {
  name = "operators";
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
        dns = { };
        velero = { };
        arc-systems = { };
        cdi = { };
        kubevirt = { };
        infisical = { };
        openebs = { };
      };

      instances = {
        dns.coredns.package = packages.coredns;
        velero.velero = {
          package = packages.velero;
          # Test credentials, so the kix-managed Secret is built and mounted.
          # The BackupStorageLocation has no bucket behind it and stays
          # Unavailable; the server itself is what the run judges.
          config.credentials.secretContents.cloud = "[default]\naws_access_key_id = test\naws_secret_access_key = test\n";
        };
        arc-systems.arc.package = packages.arc;
        cdi.cdi.package = packages.cdi;
        kubevirt.kubevirt.package = packages.kubevirt;
        infisical.infisical-operator.package = packages.infisical-operator;
        openebs.openebs = {
          package = packages.openebs;
          # Mayastor's node agents need a real host: csi-node writes nvme_core
          # parameters into sysfs, which kind mounts read-only, and
          # agent-ha-node mounts /run/udev, which kind nodes lack. The upstream
          # topology switch confines both to nodes labelled
          # openebs.io/csi-node=mayastor, so here they schedule nowhere, as
          # io-engine already does, and the control plane is what is judged.
          config.mayastor.csiNode.topology.nodeSelector = true;
        };
      };
    }
  ];
}
