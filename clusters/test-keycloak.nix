# clusters/test-keycloak.nix: Keycloak on a per-app StackGres database,
# under Cilium default-deny.
#
# Every optional dependency is wired: ingress-nginx and a host give the
# route and `KC_HOSTNAME`, and prometheus-operator gives the Service its
# metrics port and a ServiceMonitor. The database is a stackgres-database on
# a one-instance stackgres-cluster. kind offers availability `none`, so one
# Keycloak replica runs and the `jgroups` intent carries no peer traffic.
#
# Build:  nix build ./clusters#cluster-keycloak --extra-experimental-features pipe-operators
# Deploy: kix deploy keycloak --flake ./clusters --context <kind context> --timeout 20m
#         on a kind cluster created with `disableDefaultCNI: true`. Every
#         start runs Keycloak's build step, hence the timeout.

{ kix, packages }:

kix.buildCluster {
  name = "test-keycloak";
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

      instances.auth = {
        keycloak = {
          package = packages.keycloak;
          config = {
            ingress.host = "keycloak.localtest.me";
            extraArgs = [ "--log-console-output=json" ];
          };
        };
        keycloak-pg = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
          # kind has one node and the pods anti-affine, so a second
          # instance never schedules.
          config.instances = 1;
        };
        keycloak-db = {
          package = packages.stackgres-database;
          # Dev-only value; it protects nothing.
          config.password = "dev-keycloak-db-password";
        };
        # Test values only.
        keycloak-admin = {
          package = packages.secret;
          aliases = [ "bootstrapAdmin" ];
          config.stringData = {
            username = "admin";
            password = "dev-keycloak-admin-password";
          };
        };
      };
    }
  ];
}
