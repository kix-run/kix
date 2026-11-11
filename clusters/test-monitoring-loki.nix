# Test cluster: the monitoring module with Loki and an ephemeral Grafana.
#
# Loki and Grafana share the monitoring namespace, and Grafana's `storage`
# dependency is optional. With Grafana's persistence off, nothing in the
# namespace answers `storage` except Loki's claim, which the module gives
# the alias `lokiStorage` so Grafana does not bind it. The assert below
# fails the build when Grafana mounts a claim or when any workload other
# than Loki mounts `loki-storage`.
#
# Build: nix build ./clusters#cluster-monitoring-loki --extra-experimental-features pipe-operators

{ kix, packages }:

let
  cluster = kix.buildCluster {
    name = "monitoring-loki";
    specialArgs = { inherit packages kix; };
    modules = [
      kix.flavors.kind
      kix.modules.experimental.monitoring
      {
        monitoring = {
          enabled = true;
          grafana.persistence.enabled = false;
          loki.enabled = true;
        };
        # Test values only.
        instances.monitoring-system.grafana-admin = {
          package = packages.secret;
          aliases = [ "grafanaAdmin" ];
          config.stringData = {
            admin-user = "admin";
            admin-password = "test-only";
          };
        };
      }
    ];
  };

  workloads = builtins.filter (
    m:
    builtins.elem m.kind [
      "Deployment"
      "StatefulSet"
      "DaemonSet"
    ]
  ) cluster.rawManifests;

  claimsOf =
    m:
    map (v: v.persistentVolumeClaim.claimName) (
      builtins.filter (v: v ? persistentVolumeClaim) (m.spec.template.spec.volumes or [ ])
    );

  grafanaClaims = builtins.concatMap claimsOf (
    builtins.filter (m: m.kind == "Deployment" && m.metadata.name == "grafana") workloads
  );

  lokiStorageUsers = map (m: "${m.kind}/${m.metadata.name}") (
    builtins.filter (m: builtins.elem "loki-storage" (claimsOf m)) workloads
  );
in
assert
  grafanaClaims == [ ] && lokiStorageUsers == [ "StatefulSet/loki" ]
  || throw "test-monitoring-loki: Deployment/grafana must mount no claim (it mounts: ${builtins.toJSON grafanaClaims}), and StatefulSet/loki must be the only workload that mounts claim loki-storage (mounted by: ${builtins.toJSON lokiStorageUsers}).";
cluster
