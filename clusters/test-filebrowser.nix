# clusters/test-filebrowser.nix: File Browser on kind under Cilium default-deny.
#
# One File Browser with its volume and two users. The sync-users init
# container runs on every start, so a deploy over an older version exercises
# the user database that the old version left behind. The passwords are test
# values.
#
# Bring-up, on a kind cluster created with `disableDefaultCNI: true` and
# `podSubnet: "10.244.0.0/16"`:
#   kix deploy filebrowser --context kind-<name> -y
#
# Build:  kix build filebrowser

{ kix, packages }:

kix.buildCluster {
  name = "test-filebrowser";
  modules = [
    kix.flavors.kind

    {
      # kind runs with the default CNI disabled; the managed cilium instance
      # fills the vacant role.
      cluster.roles.cni = {
        binding = "absent";
        provider = null;
      };
      cluster.domain = "filebrowser.test";
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

        files = {
          filebrowser = {
            package = packages.experimental.filebrowser;
            config.users = {
              me.admin = true;
              guest = {
                scope = "/from-guest";
                perm.share = false;
              };
            };
          };
          filebrowser-users = {
            package = packages.secret;
            aliases = [ "filebrowserUsers" ];
            config.stringData = {
              me = "test-only-me-password-0123";
              guest = "test-only-guest-password-0123";
            };
          };
          filebrowser-data = {
            package = packages."persistent-volume-claim";
            aliases = [ "storage" ];
            config.size = "1Gi";
          };
        };
      };
    }
  ];
}
