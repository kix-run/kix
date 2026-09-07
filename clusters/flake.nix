# Test clusters — exercise various kix features.
#
# Build:  nix build .#cluster-minimal --extra-experimental-features pipe-operators
#
# Note: test-helm is excluded — it references ../tests/helm-test-chart which is
# outside this flake tree. Build it from the root flake instead.

{
  description = "kix test clusters";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    kix.url = "path:../kix";
  };

  outputs =
    inputs:
    inputs.kix.lib.mkFlake {
      inherit inputs;
      clusters = {
        minimal = ./test-minimal.nix;
        example = ./example.nix;
        full = ./test-full.nix;
        example-import = ./example-import.nix;
        auto = ./test-auto.nix;
        auto2 = ./test-auto2.nix;
        immich = ./test-immich.nix;
        kind = ./test-kind.nix;
        monitoring-helm = ./test-monitoring-helm.nix;
        monitoring-native = ./test-monitoring-native.nix;
        test-secrets = ./test-secrets.nix;
        victoria-metrics = ./test-victoria-metrics.nix;
        satchel-dev = ./satchel/dev.nix;
        satchel-prod = ./satchel/prod.nix;
      };
    };
}
