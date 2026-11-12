# clusters/test-metabase.nix: Metabase on a per-app StackGres database,
# under Cilium default-deny.
#
# Every optional dependency is wired: ingress-nginx and a host give the
# route and `MB_SITE_URL`, and prometheus-operator gives the Service its
# metrics port and a ServiceMonitor. The application database is a
# stackgres-database on a one-instance stackgres-cluster, which receives
# the citext extension the package requests.
#
# `data` holds a second stackgres-cluster, `pg-replicated`, with two
# instances and backups to an in-cluster S3 store (./s3-test-store.nix)
# through a stackgres-object-storage wired to it as its endpointService.
# With metabase-pg it renders every alert of the package, which
# test-metabase.rules-test.yaml tests.
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
        instances.kube-system.cilium.package = packages.experimental.cilium;

        instances.ingress-system.ingress-nginx.package = packages.experimental.ingress-nginx;
        instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;
        instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;

        instances.analytics = {
          metabase = {
            package = packages.experimental.metabase;
            config.ingress.host = "metabase.localtest.me";
          };
          metabase-pg = {
            package = packages.experimental.stackgres-cluster;
            aliases = [ "postgres" ];
            # kind has one node and the pods anti-affine, so a second
            # instance never schedules.
            config.instances = 1;
          };
          metabase-db = {
            package = packages.experimental.stackgres-database;
            # Dev-only value; it protects nothing.
            config.passwordSource = ./dev-secrets/metabase-db.sops.yaml;
            config.passwordHash = "sha256-k0pdgI1oX0m5LiEyPB32gfh3QgB7yTQZPRyNBtkmqpM=";
          };
          metabase-encryption-key = {
            package = packages.secret;
            aliases = [ "encryptionKey" ];
            config.stringData.key = "0123456789abcdef0123456789abcdef";
          };
        };

        instances.data = {
          s3-credentials = {
            package = packages.secret;
            aliases = [
              "storageCredentials"
              "s3RootCredentials"
            ];
            # Test values only.
            config.stringData = {
              accessKeyId = "stackgres-test";
              secretAccessKey = "stackgres-test-secret";
            };
          };
          s3.package = import ./s3-test-store.nix {
            buckets = [ "stackgres" ];
            description = "S3 test store for the StackGres backups";
          };
          backups = {
            package = packages.experimental.stackgres-object-storage;
            deps.endpointService = ref.data.s3;
            config = {
              type = "s3Compatible";
              bucket = "stackgres";
            };
          };
          pg-replicated = {
            package = packages.experimental.stackgres-cluster;
            config = {
              instances = 2;
              instanceProfile = {
                cpu = "500m";
                memory = "1Gi";
              };
              persistentVolume.size = "1Gi";
              backups = [
                {
                  cronSchedule = "0 3 * * *";
                  retention = 3;
                }
              ];
            };
          };
        };
      }
    )
  ];
}
