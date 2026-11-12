# clusters/test-keycloak.nix: Keycloak on a per-app StackGres database,
# under Cilium default-deny.
#
# Every optional dependency is wired: ingress-nginx and a host give the
# route and `KC_HOSTNAME`, and prometheus-operator gives the Service its
# metrics port and a ServiceMonitor. The database is a stackgres-database on
# a one-instance stackgres-cluster, which publishes `out.tls = true`, so
# Keycloak connects with `sslmode=require`. kind offers availability `none`,
# so one Keycloak replica runs and no `keycloak-jgroups` policy renders.
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
      instances.kube-system.cilium.package = packages.experimental.cilium;

      instances.ingress-system.ingress-nginx.package = packages.experimental.ingress-nginx;
      instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;
      instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;

      instances.auth = {
        keycloak = {
          package = packages.experimental.keycloak;
          config = {
            ingress.host = "keycloak.localtest.me";
            extraArgs = [ "--log-console-output=json" ];
          };
        };
        keycloak-pg = {
          package = packages.experimental.stackgres-cluster;
          aliases = [ "postgres" ];
          # kind has one node and the pods anti-affine, so a second
          # instance never schedules.
          config.instances = 1;
        };
        keycloak-db = {
          package = packages.experimental.stackgres-database;
        };
        keycloak-db-password = {
          package = packages.secret;
          aliases = [ "password" ];
          # Dev-only value; it protects nothing.
          config = {
            source = ./dev-secrets/keycloak-db.sops.yaml;
            hash = "sha256-rgn6JZpWdY4hK9Cs6xIUUsG71gsVbab0Da/CZ0N4kRA=";
            keys = [ "password" ];
          };
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
