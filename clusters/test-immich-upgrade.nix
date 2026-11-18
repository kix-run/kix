# clusters/test-immich-upgrade.nix: Immich and its machine-learning worker on
# kind under Cilium default-deny, for testing an Immich version change.
#
# The server keeps its library on a claim and its records in a StackGres
# database, so a deploy of a new Immich release runs its database
# migrations over data the old release wrote. The worker is wired as
# `machineLearning`, so a smart search request shows that the new server
# and worker still talk to each other. valkey arrives through
# auto-instantiation and reads its password from `valkey-password`.
#
# Bring up: kind create cluster --name <name> --kubeconfig <file> --config <config>
#           where the config sets networking.disableDefaultCNI = true
# Deploy:   SOPS_AGE_KEY_FILE=clusters/dev-secrets/age-key.txt \
#             kix deploy immich-upgrade --context kind-<name> -y
# Reach:    kubectl -n immich port-forward svc/immich-server <port>:2283

{ kix, packages }:

kix.buildCluster {
  name = "immich-upgrade";
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

      # The operator is cluster-wide; one instance serves every namespace.
      instances.stackgres-system.stackgres-operator.package = packages.experimental.stackgres-operator;

      # Test values only; they protect nothing.
      instances.immich = {
        immich.package = packages.experimental.immich;
        immich-machine-learning.package = packages.experimental.immich-machine-learning;

        immich-library = {
          package = packages.persistent-volume-claim;
          aliases = [ "storage" ];
          config.size = "50Gi";
        };

        immich-pg = {
          package = packages.experimental.stackgres-cluster;
          aliases = [ "postgres" ];
          config.instances = 1;
        };
        immich-db = {
          package = packages.experimental.stackgres-database;
          aliases = [ "database" ];
          config = {
            database = "immich";
            user = "immich";
          };
        };
        immich-db-password = {
          package = packages.secret;
          aliases = [ "password" ];
          config = {
            source = ./dev-secrets/immich-db.sops.yaml;
            keys = [ "password" ];
          };
        };
        valkey-password = {
          package = packages.secret;
          aliases = [ "valkeyPassword" ];
          config.stringData.password = "immich-test-valkey-password";
        };
      };
    }
  ];
}
