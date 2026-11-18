# clusters/test-vaultwarden.nix: Vaultwarden on a CloudNativePG database,
# under Cilium default-deny.
#
# One Vaultwarden with its data claim and a cnpg-database on a
# one-instance cnpg-cluster. No ingress controller runs, so `domain` is
# set. Reach Vaultwarden with a port-forward to the Service on port 8080.
# Signups are open so a test can register an account through the API. The
# database password is a dev-only SOPS value.
#
# Bring-up, on a kind cluster created with `disableDefaultCNI: true` and
# `podSubnet: "10.244.0.0/16"`:
#   SOPS_AGE_KEY_FILE=clusters/dev-secrets/age-key.txt \
#     kix deploy vaultwarden --context kind-<name> -y
#
# Build:  kix build vaultwarden

{ kix, packages }:

kix.buildCluster {
  name = "test-vaultwarden";
  modules = [
    kix.flavors.kind

    (
      { ref, ... }:
      {
        # kind runs with the default CNI disabled; the managed cilium
        # instance fills the vacant role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;

        instances = {
          kube-system.cilium = {
            package = packages.experimental.cilium;
            config.values = {
              kubeProxyReplacement = false;
              prometheus.enabled = false;
              ipam.operator.clusterPoolIPv4PodCIDRList = [ "10.244.0.0/16" ];
            };
          };

          cnpg-system.cnpg-operator.package = packages.cnpg-operator;
          db.pg.package = packages.cnpg-cluster;

          vault = {
            vaultwarden = {
              package = packages.experimental.vaultwarden;
              config = {
                domain = "http://vault.localtest.me";
                env.SIGNUPS_ALLOWED = "true";
              };
            };
            vaultwarden-data = {
              package = packages."persistent-volume-claim";
              aliases = [ "storage" ];
              config.size = "1Gi";
            };
            vaultwarden-db = {
              package = packages.experimental.cnpg-database;
              aliases = [ "database" ];
              deps.postgres = ref.db.pg;
            };
            vaultwarden-db-password = {
              package = packages.secret;
              aliases = [ "password" ];
              # Dev-only value; it protects nothing.
              config = {
                source = ./dev-secrets/vaultwarden-db.sops.yaml;
                keys = [ "password" ];
              };
            };
          };
        };
      }
    )
  ];
}
