# clusters/test-cert-manager.nix: cert-manager on a single kind node with
# Cilium as the CNI and network policy on, plus a self-signed ClusterIssuer
# that depends on it.
#
# The upgrade test deploys the pinned release, creates a Certificate in
# `certs` (the issuer signs it, and its Secret is the state an upgrade must
# keep), then deploys the new release over it. The issuer is the dependent
# that must keep working.
#
# Build:  kix build cert-manager

{ kix, packages }:

kix.buildCluster {
  name = "test-cert-manager";
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
          inherit (packages.experimental) cert-manager cluster-issuer;
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

        namespaces.certs = { };

        instances.cert-manager.cert-manager.package = packages.experimental.cert-manager;
        instances.cert-manager.selfsigned = {
          package = packages.experimental.cluster-issuer;
          config.spec.selfSigned = { };
        };
      }
    )
  ];
}
