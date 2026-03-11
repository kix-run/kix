# clusters/test-minimal.nix — Minimal cluster: only coredns with defaults.
#
# Tests that a minimal configuration produces no extra resources.
# Used for negative assertions (disabled features absent).

{ k8s, lib }:

k8s.mkCluster {
  basePackages = self: {
    coredns = import ../pkgs-fp/coredns { inherit k8s lib; };
  };
}
