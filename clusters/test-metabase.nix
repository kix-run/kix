# clusters/test-metabase.nix: Metabase on a per-app StackGres database,
# under Cilium default-deny.
#
# Every optional dependency is wired: ingress-nginx and a host give the
# route and `MB_SITE_URL`, and prometheus-operator gives the Service its
# metrics port and a ServiceMonitor. The application database is a
# stackgres-database on a one-instance stackgres-cluster, which receives
# the citext extension the package requests.
#
# Build:  nix build .#cluster-metabase --extra-experimental-features pipe-operators
# Deploy: kix deploy metabase --flake ./clusters --context <kind context> --timeout 35m
#         on a kind cluster created with `disableDefaultCNI: true`. The
#         first start migrates the schema, hence the timeout.

{ kix, packages }:

kix.buildCluster {
  name = "test-metabase";
  modules = [
    kix.flavors.kind
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
      instances.monitoring.prometheus-operator.package = packages.prometheus-operator;
      instances.stackgres-system.stackgres-operator.package = packages.stackgres-operator;

      instances.analytics = {
        metabase = {
          package = packages.metabase;
          config.ingress.host = "metabase.localtest.me";
        };
        metabase-pg = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
          # kind has one node and the pods anti-affine, so a second
          # instance never schedules.
          config.instances = 1;
        };
        metabase-db = {
          package = packages.stackgres-database;
          # Dev-only value; it protects nothing.
          config.password = "dev-metabase-db-password";
        };
        metabase-encryption-key = {
          package = packages.secret;
          aliases = [ "encryptionKey" ];
          config.stringData.key = "0123456789abcdef0123456789abcdef";
        };
      };
    }
  ];
}
