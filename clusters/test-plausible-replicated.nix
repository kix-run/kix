# clusters/test-plausible-replicated.nix: Plausible Community Edition on a
# replicated ClickHouse (clickhouse-cluster, two replicas, a Keeper quorum)
# and a CloudNativePG database, under Cilium default-deny.
#
# Plausible migrates on the first replica that answers, and its
# `replicate` init container then makes its tables replicated and creates
# them on the other replica. To check, send pageviews and count the rows of
# plausible_events.events_v2 on each replica. All passwords are test values
# only.
#
# Bring up (three workers, no default CNI; Cilium comes from this cluster):
#   kind create cluster --name kix-plausible-ha --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker }, { role: worker }, { role: worker } ]
#   EOF
# Build:   kix build plausible-replicated
# Deploy:  kix deploy plausible-replicated --context kind-kix-plausible-ha -y --timeout 30m

{ kix, packages }:

kix.buildCluster {
  name = "test-plausible-replicated";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        availablePackages = packages;
        networkPolicy.enable = true;
        cluster.capabilities.multiNode = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.ingress-system.ingress-nginx.package = packages.experimental.ingress-nginx;
        instances.cnpg-system.cnpg-operator.package = packages.cnpg-operator;

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

        instances.events = {
          keeper = {
            package = packages.experimental.clickhouse-keeper;
            config.storage.size = "1Gi";
          };
          clickhouse = {
            package = packages.experimental.clickhouse-cluster;
            config = {
              replicas = 2;
              storage.size = "2Gi";
              resources.requests.cpu = "250m";
            };
          };
          clickhouse-credentials = {
            package = packages.secret;
            aliases = [ "credentials" ];
            config.stringData.password = "clickhouse-dev-password";
          };
        };

        instances.analytics = {
          plausible = {
            package = packages.experimental.plausible;
            config.ingress.host = "plausible.localtest.me";
          };
          plausible-pg = {
            package = packages.cnpg-cluster;
            aliases = [ "postgres" ];
            config.storage.size = "1Gi";
          };
          plausible-db = {
            package = packages.experimental.cnpg-database;
            deps.password = ref.analytics.plausible-db-password;
          };
          plausible-db-password = {
            package = packages.secret;
            config = {
              source = ./dev-secrets/plausible-db.sops.yaml;
              keys = [ "password" ];
            };
          };
          plausible-events = {
            package = packages.experimental.clickhouse-database;
            deps.clickhouse = ref.events.clickhouse;
            deps.password = ref.analytics.plausible-events-password;
          };
          plausible-events-password = {
            package = packages.secret;
            config = {
              source = ./dev-secrets/plausible-events.sops.yaml;
              keys = [ "password" ];
            };
          };
          plausible-secret-key-base = {
            package = packages.secret;
            aliases = [ "secretKeyBase" ];
            config.stringData.key = "test-only-0123456789abcdef0123456789abcdef0123456789abcdef";
          };
        };
      }
    )
  ];
}
