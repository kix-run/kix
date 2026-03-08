# clusters/test-minimal.nix — Minimal cluster: only coredns with defaults.
#
# Tests that a minimal configuration produces no extra resources.
# Used for negative assertions (disabled features absent).

{
  services.coredns = {
    enable = true;
    namespace = "kube-system";
  };
}
