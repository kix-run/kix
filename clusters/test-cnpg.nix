# clusters/test-cnpg.nix: the CloudNativePG packages under Cilium
# default-deny, with every option the packages read turned on.
#
# cnpg-operator runs in cnpg-system. In `data`, `pg` is a one-instance
# cnpg-cluster with metrics (a PodMonitor through prometheus-operator) and
# an extraSpec parameter, and `pg-replicated` runs two instances, which
# turns on the operator's PodDisruptionBudgets. `app-db` is a cnpg-database
# on `pg` with an extension by name and one by `{ name; version; }`.
#
# Build:  nix build .#cluster-cnpg --extra-experimental-features pipe-operators
# Deploy: kix deploy cnpg --flake ./clusters --context <kind context>
#         on a kind cluster created with `disableDefaultCNI: true`.

{ kix, packages }:

kix.buildCluster {
  name = "test-cnpg";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        networkPolicy.enable = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.cilium;
        instances.monitoring.prometheus-operator.package = packages.prometheus-operator;
        instances.cnpg-system.cnpg-operator.package = packages.cnpg-operator;

        instances.data = {
          pg = {
            package = packages.cnpg-cluster;
            config = {
              storage.size = "1Gi";
              metrics.enabled = true;
              extraSpec.postgresql.parameters.max_connections = "50";
            };
          };
          pg-replicated = {
            package = packages.cnpg-cluster;
            config = {
              instances = 2;
              storage.size = "1Gi";
            };
          };
          app-db = {
            package = packages.cnpg-database;
            deps.postgres = ref.data.pg;
            config = {
              database = "app";
              user = "app_user";
              extensions = [
                "citext"
                {
                  name = "vector";
                  version = null;
                }
              ];
              # Test values only.
              password = "test-cnpg-password";
            };
          };
        };
      }
    )
  ];
}
