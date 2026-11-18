# clusters/test-log-agents.nix: the two packages that run the Vector agent,
# clickhouse-logs and loki-logs, each beside the smallest backend it can
# write to, under Cilium's default-deny policies.
#
# Both packages share clickhouse-logs/vector-agent.nix, so a Vector upgrade
# is tested here against both backends at once. Each package's health check
# is on, so a deploy proves that every agent delivered to its backend.
#
# Bring up (one worker, no default CNI; Cilium comes from this cluster):
#   kind create cluster --name kix-log-agents --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker } ]
#   EOF
# Deploy:  kix deploy log-agents --context kind-kix-log-agents -y
#
{ kix, packages }:

kix.buildCluster {
  name = "test-log-agents";
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

        instances.analytics = {
          clickhouse = {
            package = packages.experimental.clickhouse;
            config.resources.requests.cpu = "250m";
          };
          clickhouse-data = {
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "2Gi";
          };
          clickhouse-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData.password = "clickhouse-dev-password";
          };
        };

        instances.chlogs = {
          logs = {
            package = packages.experimental.clickhouse-logs;
            config = {
              healthCheck.enabled = true;
              retentionDays = 3;
            };
          };
          logs-db = {
            package = packages.experimental.clickhouse-database;
            deps.clickhouse = ref.analytics.clickhouse;
            config = {
              database = "logs";
              user = "logs_writer";
              privileges = [ "INSERT" ];
            };
          };
          logs-db-password = {
            package = packages.secret;
            aliases = [ "password" ];
            config.stringData.password = "logs-writer-dev-password";
          };
        };

        instances.lokilogs = {
          loki.package = packages.experimental.loki;
          loki-data = {
            package = packages.persistent-volume-claim;
            aliases = [ "storage" ];
            config.size = "1Gi";
          };
          loki-logs = {
            package = packages.experimental.loki-logs;
            config.healthCheck.enabled = true;
          };
        };
      }
    )
  ];
}
