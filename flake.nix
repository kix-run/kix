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

      # Expose kix library + packages for external flake consumers.
      # Usage: kixpkgs.lib.forPkgs { inherit pkgs lib; }
      #   => { kix, packages, mkAnnotatedManifests }
      flake.lib.forPkgs =
        { pkgs, lib }:
        let
          kix = import ./lib { inherit pkgs lib; };
          entries = builtins.readDir ./packages;
          dirs = lib.filterAttrs (_: type: type == "directory") entries;
          packages = lib.mapAttrs (name: _: import ./packages/${name}) dirs;
          python3 = pkgs.python3.withPackages (p: [ p.pyyaml ]);
          mkAnnotatedManifests =
            cluster:
            pkgs.runCommand "k8s-manifests-${cluster.name}"
              {
                exportReferencesGraph = [
                  "closure"
                  cluster.activation
                ];
                nativeBuildInputs = [ python3 ];
              }
              ''
                PYTHONPATH=${./pipeline} python3 ${./pipeline/annotate.py} closure ${cluster.activation} $out
              '';
        in
        {
          inherit kix packages mkAnnotatedManifests;
        };

      perSystem =
        { pkgs, ... }:
        let
          lib = pkgs.lib;

          # Consolidated kix library.
          kix = import ./lib { inherit pkgs lib; };

          # Checks library (schema + cross-resource validation).
          kixChecks = import ./checks.nix { inherit pkgs lib; };

          # PI wiring invariant checks.
          piChecks = import ./pi-checks.nix { inherit lib; };

          # Auto-discover packages from packages/ directory.
          packages' =
            let
              entries = builtins.readDir ./packages;
              dirs = lib.filterAttrs (_: type: type == "directory") entries;
            in
            lib.mapAttrs (name: _: import ./packages/${name}) dirs;

          # Cluster registry — add new clusters here, outputs are auto-generated.
          clusters = {
            minimal = import ./clusters/test-minimal.nix {
              inherit kix;
              packages = packages';
            };
            example = import ./clusters/example.nix {
              inherit kix;
              packages = packages';
            };
            full = import ./clusters/test-full.nix {
              inherit kix;
              packages = packages';
            };
            helm = import ./clusters/test-helm.nix { inherit kix; };
            example-import = import ./clusters/example-import.nix {
              inherit kix;
              packages = packages';
            };
            nw1 = import ./clusters/nw1.nix {
              inherit kix;
              packages = packages';
            };
            auto = import ./clusters/test-auto.nix {
              inherit kix;
              packages = packages';
            };
            auto2 = import ./clusters/test-auto2.nix {
              inherit kix;
              packages = packages';
            };
          };

          # --- Pipeline derivation builders ---
          # Each takes a cluster (with .activation) and uses exportReferencesGraph
          # to read the Nix store DAG inside the build sandbox.

          python3 = pkgs.python3.withPackages (p: [ p.pyyaml ]);

          mkAnnotatedManifests =
            cluster:
            pkgs.runCommand "k8s-manifests-${cluster.name}"
              {
                exportReferencesGraph = [
                  "closure"
                  cluster.activation
                ];
                nativeBuildInputs = [ python3 ];
              }
              ''
                PYTHONPATH=${./pipeline} python3 ${./pipeline/annotate.py} closure ${cluster.activation} $out
              '';

          mkAnnotatedManifestsByNs =
            cluster:
            pkgs.runCommand "k8s-manifests-by-ns-${cluster.name}"
              {
                exportReferencesGraph = [
                  "closure"
                  cluster.activation
                ];
                nativeBuildInputs = [ python3 ];
              }
              ''
                PYTHONPATH=${./pipeline} python3 ${./pipeline/annotate.py} closure ${cluster.activation} $out --by-namespace
              '';

          mkDeployGraph =
            cluster:
            let
              manifests = mkAnnotatedManifests cluster;
            in
            pkgs.runCommand "k8s-deploy-graph-${cluster.name}"
              {
                exportReferencesGraph = [
                  "closure"
                  cluster.activation
                ];
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                PYTHONPATH=${./pipeline} python3 ${./pipeline/graph.py} closure ${cluster.activation} ${manifests} $out
              '';

          # Auto-generate per-cluster outputs from the registry.
          clusterPackages = lib.concatMapAttrs (cname: cluster: {
            "cluster-${cname}" = mkAnnotatedManifests cluster;
            "cluster-${cname}-by-ns" = mkAnnotatedManifestsByNs cluster;
            "cluster-${cname}-graph" = mkDeployGraph cluster;
            # Activation root — inspect the DAG with:
            #   nix-store -q --tree $(readlink result/activation)
            "cluster-${cname}-activation" = pkgs.runCommand "k8s-activation-${cluster.name}" { } ''
              mkdir -p $out
              ln -s ${cluster.activation} $out/activation
            '';
          }) clusters;

          clusterChecks = lib.concatMapAttrs (cname: cluster: {
            "schema-cluster-${cname}" = kixChecks.schemaCheck "cluster-${cname}" (mkAnnotatedManifests cluster);
            "validate-cluster-${cname}" =
              assert kixChecks.validateManifestSet "cluster-${cname}" cluster.rawManifests;
              pkgs.runCommand "validate-cluster-${cname}" { } ''
                echo "Cross-resource validation passed for cluster-${cname}."
                touch $out
              '';
            "pi-wiring-cluster-${cname}" =
              assert piChecks.validatePIWiring "cluster-${cname}" cluster;
              pkgs.runCommand "pi-wiring-cluster-${cname}" { } ''
                echo "PI wiring validation passed for cluster-${cname}."
                touch $out
              '';
          }) clusters;

        in
        {
          packages = clusterPackages;
          checks = clusterChecks;

          # Expose cluster evaluation results for the kix CLI (FFI backend).
          # The CLI evaluates: flake.legacyPackages.<system>.kixClusters.<name>.rawManifests
          # This must be in legacyPackages (not packages) because cluster objects
          # are attrsets, not derivations. The `clusters` let-binding is internal
          # to perSystem, so we expose it here for the CLI to reach via builtins.getFlake.
          legacyPackages.kixClusters = clusters;
        };
    };
}
