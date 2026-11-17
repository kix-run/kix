# clusters/test-valkey.nix: the valkey package under Cilium default-deny,
# in both topologies and with a dependent, for testing version upgrades on
# kind.
#
# In `cache`, `standalone` is one pod and `sentinel` runs three pods, a
# primary and two replicas, each with a Sentinel sidecar. A rolling update
# of `sentinel` moves the primary between pods of two versions. Both have a
# volume from kind's `standard` StorageClass and the redis_exporter sidecar,
# which the prometheus-operator instance turns on.
#
# In `automation`, n8n in queue mode is the dependent. It reads its own
# standalone valkey, `redis`, and a PostgreSQL database on a one-instance
# cnpg-cluster.
#
# Build:  kix build valkey
# Kind:   a cluster created with `networking.disableDefaultCNI: true`
# Deploy: kix deploy valkey --context kind-<name> -y
# Check:  kubectl -n cache exec standalone-0 -c valkey -- valkey-cli INFO server
#         kubectl -n automation exec deploy/n8n -- wget -qO- localhost:5678/healthz/readiness

{ kix, packages }:

kix.buildCluster {
  name = "test-valkey";
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
        instances.kube-system.cilium.package = packages.experimental.cilium;
        instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;
        instances.cnpg-system.cnpg-operator.package = packages.cnpg-operator;

        # Test values only; they protect nothing.
        instances.cache = {
          standalone = {
            package = packages.valkey;
            config.storage.size = "1Gi";
          };
          sentinel = {
            package = packages.valkey;
            config = {
              sentinel.enabled = true;
              storage.size = "1Gi";
            };
          };
          valkey-password = {
            package = packages.secret;
            aliases = [ "valkeyPassword" ];
            config.stringData.password = "test-valkey-password";
          };
        };

        instances.automation = {
          pg = {
            package = packages.cnpg-cluster;
            config.storage.size = "1Gi";
          };
          n8n.package = packages.experimental.n8n;
          redis.package = packages.valkey;
          database = {
            package = packages.experimental.cnpg-database;
            deps.postgres = ref.automation.pg;
          };
          database-password = {
            package = packages.secret;
            aliases = [ "password" ];
            config = {
              source = ./dev-secrets/n8n-db.sops.yaml;
              keys = [ "password" ];
            };
          };
          n8n-encryption-key = {
            package = packages.secret;
            aliases = [ "encryptionKey" ];
            config.stringData.key = "0123456789abcdef0123456789abcdef";
          };
          valkey-password = {
            package = packages.secret;
            aliases = [ "valkeyPassword" ];
            config.stringData.password = "test-n8n-valkey-password";
          };
        };
      }
    )
  ];
}
