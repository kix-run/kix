# kixpkgs flake — the entry point for building kix modules.
#
# Architecture (2026-03):
#
# Each Helm chart migration lives in pkgs/<chart-name>/ as a Nix module.
# Modules are evaluated using lib.evalModules (the NixOS module system),
# which gives us typed options, submodules, and cross-module references.
#
# kixlib is passed to every module via specialArgs. It provides resource
# builders (mkDeployment, mkService, etc.) that produce plain attrsets.
# Only mkManifest serializes to a Nix store derivation.
#
# Each module writes its resources to config.manifests.<name>, where each
# entry is one resource (not one-per-module). This makes verification and
# inspection straightforward — each JSON file is one Kubernetes resource.
#
# To build a chart's manifests:
#   nix build .#<chart-name>
#
# To evaluate without building (useful for debugging):
#   nix eval .#legacyPackages.<system>.mkCluster { ... }

{
  description = "kixpkgs - Kubernetes packages built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        let
          lib = pkgs.lib;

          kixlib = import ./lib { inherit pkgs lib; };

          # Evaluate modules with a given config.
          #
          # `chartModules` — list of chart module paths to include
          #   (e.g., [ ./pkgs/coredns ])
          # `config` — the user's config module that sets options
          #   (e.g., { services.coredns.enable = true; replicas = 3; })
          #
          # The base ./modules provides the `manifests` option that all chart
          # modules write into. Each chart module adds its own options under
          # services.<name> and its resources under config.manifests.
          mkCluster =
            { chartModules ? [ ], config ? { } }:
            lib.evalModules {
              modules = [
                ./modules
              ] ++ chartModules ++ [
                config
              ];
              specialArgs = {
                inherit pkgs lib kixlib;
              };
            };

          # Collect all manifests from an evaluation into a directory.
          # Each manifest becomes a separate .json file, named by its key
          # in config.manifests. This is what verify-parity.sh compares against.
          mkManifests =
            evaluation:
            pkgs.runCommand "k8s-manifests" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (
                  name: path: "cp ${path} $out/${name}.json"
                ) evaluation.config.manifests
              )}
            '';

          # Convenience: evaluate a single chart with a config and build manifests.
          # This is what the flake packages use:
          #   packages.coredns = mkChartManifests ./pkgs/coredns {
          #     services.coredns.enable = true;
          #   };
          mkChartManifests =
            chartPath: config:
            mkManifests (mkCluster {
              chartModules = [ chartPath ];
              config = config;
            });

        in
        {
          # Exposed via legacyPackages so they're accessible as:
          #   nix eval .#legacyPackages.<system>.kixlib
          # Standard `packages` only allows derivations, not functions.
          legacyPackages = {
            inherit mkCluster mkManifests mkChartManifests kixlib;
          };

          # Per-chart build targets. Each entry should be a derivation
          # (the output of mkChartManifests) so `nix build .#<name>` works.
          # verify-parity.sh uses this to build the kix side of the comparison.
          packages = {
            coredns = mkChartManifests ./pkgs/coredns {
              services.coredns.enable = true;
            };
          };
        };
    };
}
