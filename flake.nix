# kixpkgs root flake — aggregates all clusters.
#
# Prefer using the per-directory flakes (nw1/, ludo/, clusters/) directly.
# This root flake exists for backwards compatibility and CI.
#
# Build a cluster:
#   nix build .#cluster-nw1 --extra-experimental-features pipe-operators

{
  description = "kixpkgs - Kubernetes packages built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    inputs:
    let
      mkFlake = import ./kix/lib/mkFlake.nix;
    in
    mkFlake {
      inherit inputs;
      clusters = {
        # Test clusters
        minimal = ./clusters/test-minimal.nix;
        example = ./clusters/example.nix;
        full = ./clusters/test-full.nix;
        helm = ./clusters/test-helm.nix;
        example-import = ./clusters/example-import.nix;
        auto = ./clusters/test-auto.nix;
        auto2 = ./clusters/test-auto2.nix;
        immich = ./clusters/test-immich.nix;
        kind = ./clusters/test-kind.nix;
        monitoring-helm = ./clusters/test-monitoring-helm.nix;
        monitoring-native = ./clusters/test-monitoring-native.nix;

        # Production clusters
        nw1 = ./nw1/cluster.nix;
        ludo = ./ludo/cluster.nix;
      };
    }
    // {
      # Preserve the forPkgs API for external consumers.
      lib.forPkgs =
        { pkgs, lib }:
        let
          kix = import ./kix/lib { inherit pkgs lib; };
          entries = builtins.readDir ./kix/packages;
          dirs = lib.filterAttrs (_: type: type == "directory") entries;
          packages = lib.mapAttrs (name: _: import ./kix/packages/${name}) dirs;
        in
        {
          inherit kix packages;
          inherit (kix) mkManifests;
        };
    };
}
