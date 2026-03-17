# kixpkgs flake — declarative Kubernetes cluster state built with Nix.
#
# Each package lives in packages/<name>/ as a plain Nix function.
# The kix library (lib/) provides resource constructors, cluster evaluation,
# dependency injection, helm bridge, and YAML serialization.
#
# To build a cluster's manifests:
#   nix build .#cluster-example

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

          # Consolidated kix library.
          kix = import ./lib { inherit pkgs lib; };

          # Checks library (schema + cross-resource validation).
          kixChecks = import ./checks.nix { inherit pkgs lib; };

          # Auto-discover packages from packages/ directory.
          packages' =
            let
              entries = builtins.readDir ./packages;
              dirs = lib.filterAttrs (_: type: type == "directory") entries;
            in
            lib.mapAttrs (name: _: import ./packages/${name}) dirs;

          # Cluster evaluations.
          clusterMinimal = import ./clusters/test-minimal.nix {
            inherit kix;
            packages = packages';
          };
          clusterExample = import ./clusters/example.nix {
            inherit kix;
            packages = packages';
          };
          clusterFull = import ./clusters/test-full.nix {
            inherit kix;
            packages = packages';
          };
          clusterHelm = import ./clusters/test-helm.nix { inherit kix; };

          # Serializes manifests (already post-processed) into a YAML directory.
          mkManifests =
            manifests:
            let
              fileEntries = map (
                m:
                let
                  kindLower = lib.toLower m.kind;
                  name = m.metadata.name;
                in
                {
                  fileName = "${name}-${kindLower}";
                  drv = kix.mkManifest m;
                }
              ) manifests;
            in
            pkgs.runCommand "k8s-manifests" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (map (e: "cp ${e.drv} $out/${e.fileName}.yaml") fileEntries)}
            '';

          # Serializes raw manifests (store paths intact) into a YAML directory.
          # Each YAML derivation retains store-path references to its dependencies,
          # so nix-store -q --tree / --requisites shows the actual resource DAG.
          mkManifestsRaw =
            rawManifests:
            let
              fileEntries = map (
                m:
                let
                  kindLower = lib.toLower m.kind;
                  name = m.metadata.name;
                in
                {
                  fileName = "${name}-${kindLower}";
                  drv = kix.mkManifest m;
                }
              ) rawManifests;
            in
            pkgs.runCommand "k8s-manifests-raw" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (map (e: "ln -s ${e.drv} $out/${e.fileName}.yaml") fileEntries)}
            '';

        in
        {
          packages = {
            cluster-minimal = mkManifests clusterMinimal.manifests;
            cluster-example = mkManifests clusterExample.manifests;
            cluster-full = mkManifests clusterFull.manifests;
            cluster-helm = mkManifests clusterHelm.manifests;

            cluster-minimal-raw = mkManifestsRaw clusterMinimal.rawManifests;
            cluster-example-raw = mkManifestsRaw clusterExample.rawManifests;
            cluster-full-raw = mkManifestsRaw clusterFull.rawManifests;
            cluster-helm-raw = mkManifestsRaw clusterHelm.rawManifests;
          };

          checks =
            let
              exampleManifests = kixChecks.manifestMap clusterExample.manifests;
              fullManifests = kixChecks.manifestMap clusterFull.manifests;
              minimalManifests = kixChecks.manifestMap clusterMinimal.manifests;
              helmManifests = kixChecks.manifestMap clusterHelm.manifests;
            in
            {
              # --- Schema validation ---
              schema-cluster-example = kixChecks.schemaCheck "cluster-example" (mkManifests clusterExample.manifests);
              schema-cluster-full = kixChecks.schemaCheck "cluster-full" (mkManifests clusterFull.manifests);
              schema-cluster-minimal = kixChecks.schemaCheck "cluster-minimal" (mkManifests clusterMinimal.manifests);
              schema-cluster-helm = kixChecks.schemaCheck "cluster-helm" (mkManifests clusterHelm.manifests);

              # --- Cross-resource validation ---
              validate-cluster-example =
                assert kixChecks.validateManifestSet "cluster-example" exampleManifests;
                pkgs.runCommand "validate-cluster-example" { } ''
                  echo "Cross-resource validation passed for cluster-example."
                  touch $out
                '';

              validate-cluster-full =
                assert kixChecks.validateManifestSet "cluster-full" fullManifests;
                pkgs.runCommand "validate-cluster-full" { } ''
                  echo "Cross-resource validation passed for cluster-full."
                  touch $out
                '';

              validate-cluster-minimal =
                assert kixChecks.validateManifestSet "cluster-minimal" minimalManifests;
                pkgs.runCommand "validate-cluster-minimal" { } ''
                  echo "Cross-resource validation passed for cluster-minimal."
                  touch $out
                '';

              validate-cluster-helm =
                assert kixChecks.validateManifestSet "cluster-helm" helmManifests;
                pkgs.runCommand "validate-cluster-helm" { } ''
                  echo "Cross-resource validation passed for cluster-helm."
                  touch $out
                '';
            };
        };
    };
}
