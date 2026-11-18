# clusters/test-clickhouse-operator-upgrade.nix: the Altinity operator with
# one Keeper quorum, one replicated installation, and one database on it,
# under Cilium default-deny, for testing an operator version change.
#
# A new operator version reconciles what the old one created. This cluster
# gives it a ClickHouseKeeperInstallation and a ClickHouseInstallation to
# take over, and a replicated table to keep. Write rows before the upgrade
# and read them after it, from both replicas.
#
# The operator spreads the two ClickHouse replicas over nodes with a
# required anti-affinity, so kind needs at least two workers. Three keep
# the Keeper replicas apart too.
#
# Bring up (three workers, no default CNI; Cilium comes from this cluster):
#   kind create cluster --name <name> --kubeconfig <file> --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker }, { role: worker }, { role: worker } ]
#   EOF
# Deploy:  SOPS_AGE_KEY_FILE=clusters/dev-secrets/age-key.txt \
#          kix deploy clickhouse-operator-upgrade --context kind-<name> -y
#
{ kix, packages }:

kix.buildCluster {
  name = "test-clickhouse-operator-upgrade";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.clickhouse-system = {
          clickhouse-operator.package = packages.experimental.clickhouse-operator;
          clickhouse-operator-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData = {
              username = "clickhouse_operator";
              password = "operator-dev-password";
            };
          };
        };

        instances.analytics-ha = {
          keeper = {
            package = packages.experimental.clickhouse-keeper;
            config.storage.size = "1Gi";
          };
          ch = {
            package = packages.experimental.clickhouse-cluster;
            config = {
              storage.size = "2Gi";
              resources.requests.cpu = "100m";
            };
          };
          ch-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData.password = "ha-dev-password";
          };
        };

        instances.apps-ha.ha-events = {
          package = packages.experimental.clickhouse-database;
          deps.clickhouse = ref.analytics-ha.ch;
          config = {
            database = "events";
            user = "events_writer";
            privileges = [
              "INSERT"
              "SELECT"
            ];
            schema."01-events.sql" = ''
              CREATE TABLE IF NOT EXISTS {database:Identifier}.events ON CLUSTER '{cluster}'
              (ts DateTime, message String)
              ENGINE = ReplicatedMergeTree ORDER BY ts
            '';
          };
        };
        instances.apps-ha.ha-events-password = {
          package = packages.secret;
          aliases = [ "password" ];
          config = {
            source = ./dev-secrets/clickhouse-ha-writer.sops.yaml;
            keys = [ "password" ];
          };
        };
      }
    )
  ];
}
