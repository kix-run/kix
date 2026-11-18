# clusters/test-infisical-operator.nix: infisical-operator on a single kind
# node with Cilium as the CNI and network policy on, so the package's egress
# intent for TCP 443 is enforced.
#
# The upgrade test deploys the pinned release, writes an InfisicalAuth and an
# InfisicalStaticSecret in `infisical` (the operator's state), then deploys
# the new release over it.
#
# Build:  kix build infisical-operator

{ kix, packages }:

kix.buildCluster {
  name = "test-infisical-operator";
  specialArgs = { inherit packages kix; };
  modules = [
    kix.flavors.kind

    (
      {
        packages,
        ...
      }:
      {
        availablePackages = packages // {
          inherit (packages.experimental) infisical-operator;
        };
        networkPolicy.enable = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium = {
          package = packages.experimental.cilium;
        };

        instances.infisical.infisical-operator.package = packages.experimental.infisical-operator;
      }
    )
  ];
}
