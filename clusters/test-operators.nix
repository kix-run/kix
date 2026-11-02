# clusters/test-operators.nix: operator and storage-driver packages on a
# three-zone kind cluster.
#
# coredns, arc, cdi, kubevirt, infisical-operator, zfs-localpv,
# snapshot-controller, and mayastor, every workload sealed through the
# typed builders: derived spread, PodDisruptionBudgets, network-policy
# edges. prometheus-operator gives the packages that take a `prometheus`
# dependency their monitors and alerts, and smartctl-exporter runs beside
# it; test-operators.rules-test.yaml tests the alerts of arc and
# smartctl-exporter. multiNode and three zones are declared so the derivation has
# domains to spread over; the kind cluster matches
# (scripts/kind-spread-config.yaml). prometheus-operator in `monitoring`
# answers the `prometheus` dependency, so the packages that take one render
# their ServiceMonitors and alert rules; no Prometheus server runs.
# smartctl-exporter runs beside it. test-operators.rules-test.yaml tests
# the rules of arc, coredns, infisical-operator, and smartctl-exporter.
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
        arc-systems = { };
        cdi = { };
        kubevirt = { };
        infisical = { };
        storage = { };
        mayastor = { };
        monitoring = { };
      };

      instances = {
        # kind's bundled CoreDNS holds 10.96.0.10 and stays the kubelet's
        # DNS. This second server exercises the derived spread and a managed
        # dns provider.
        dns.coredns = {
          package = packages.coredns;
          config.clusterIP = "10.96.0.53";
        };
        monitoring.prometheus-operator.package = packages.prometheus-operator;
        monitoring.smartctl-exporter.package = packages.smartctl-exporter;
        arc-systems.arc.package = packages.arc;
        cdi.cdi.package = packages.cdi;
        kubevirt.kubevirt.package = packages.kubevirt;
        infisical.infisical-operator.package = packages.infisical-operator;
        storage.snapshot-controller.package = packages.snapshot-controller;
        # kind nodes have no ZFS pool, so the node plugin starts but
        # provisions nothing; the controller, the registration, and the
        # classes are what is judged.
        storage.zfs-localpv = {
          package = packages.zfs-localpv;
          config = {
            storageClasses.zfs.parameters.poolname = "zfspv-pool";
            volumeSnapshotClasses.zfs = { };
          };
        };
        mayastor.mayastor = {
          package = packages.mayastor;
          # No node carries this label, so csi-node and agent-ha-node
          # schedule nowhere and the run judges the control plane and etcd.
          # The kubelet sets openebs.io/csi-node once csi-node registers, so
          # that label would not keep them off.
          config.csiNode.nodeSelector."example.com/test-schedule" = "never";
        };
      };
    }
  ];
}
