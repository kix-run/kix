# clusters/test-plausible.nix: Plausible Community Edition on a CloudNativePG
# database and a single-node ClickHouse, under Cilium default-deny.
#
# Every dependency is wired, the optional smtpPassword included (the relay
# address is a placeholder, so mail fails and nothing else does).
# ingress-nginx and a host give the route and BASE_URL. The ClickHouse
# server lives in `events` and the application in `analytics`, so the
# clickhouse-database facade crosses a namespace as it does in a real
# cluster. All passwords are test values only.
#
# Bring up (no default CNI; Cilium comes from this cluster):
#   kind create cluster --name kix-plausible --config - <<EOF
#   kind: Cluster
#   apiVersion: kind.x-k8s.io/v1alpha4
#   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
#   nodes: [ { role: control-plane }, { role: worker } ]
#   EOF
# Build:   nix build ./clusters#cluster-plausible --extra-experimental-features pipe-operators
# Deploy:  nix run .#kix -- deploy plausible --flake ./clusters --context kind-kix-plausible -y --timeout 20m
#          The first start runs every migration, hence the timeout.

{ kix, packages }:

kix.buildCluster {
  name = "test-plausible";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        availablePackages = packages;
        networkPolicy.enable = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.cilium;

        instances.ingress-system.ingress-nginx.package = packages.ingress-nginx;
        instances.cnpg-system.cnpg-operator.package = packages.cnpg-operator;

        instances.events = {
          clickhouse.package = packages.clickhouse;
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

        instances.analytics = {
          plausible = {
            package = packages.plausible;
            config = {
              ingress.host = "plausible.localtest.me";
              env = {
                MAILER_EMAIL = "plausible@localtest.me";
                SMTP_HOST_ADDR = "smtp.localtest.me";
                SMTP_USER_NAME = "plausible";
              };
            };
          };
          plausible-pg = {
            package = packages.cnpg-cluster;
            aliases = [ "postgres" ];
            config.storage.size = "1Gi";
          };
          plausible-db = {
            package = packages.cnpg-database;
            config.password = "plausible-db-dev-password";
          };
          plausible-events = {
            package = packages.clickhouse-database;
            deps.clickhouse = ref.events.clickhouse;
            config.password = "plausible-events-dev-password";
          };
          plausible-secret-key-base = {
            package = packages.secret;
            aliases = [ "secretKeyBase" ];
            config.stringData.key = "test-only-0123456789abcdef0123456789abcdef0123456789abcdef";
          };
          plausible-smtp = {
            package = packages.secret;
            aliases = [ "smtpPassword" ];
            config.stringData.password = "smtp-dev-password";
          };
        };
      }
    )
  ];
}
