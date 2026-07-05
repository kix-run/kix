# kix/lib/mkFlake.nix — Generate a complete flake output from a cluster spec.
#
# Encapsulates all the boilerplate: package discovery, cluster evaluation,
# manifest generation, checks, and legacyPackages for the CLI.
#
# Usage (in a consuming flake.nix):
#
#   outputs = inputs: inputs.kix.lib.mkFlake {
#     inherit inputs;
#     clusters.my-cluster = ./cluster.nix;
#   };
#
# Cluster values can be:
#   - A path       → imported, then called with auto-detected args (kix, packages)
#   - A function   → called with auto-detected args
#   - An attrset   → used as-is (already-evaluated cluster)

{
  # inputs must include nixpkgs; kix framework is resolved via relative paths.
  inputs,

  # Cluster definitions: name → path | function | attrset.
  clusters ? { },

  # Target systems.
  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
}:

let
  lib = inputs.nixpkgs.lib;

  # Package catalog from the kix framework tree (kix/packages/).
  catalogPackages =
    let
      entries = builtins.readDir ../packages;
      dirs = lib.filterAttrs (_: type: type == "directory") entries;
    in
    lib.mapAttrs (name: _: import ../packages/${name}) dirs;

  eachSystem =
    f:
    lib.genAttrs systems (
      system:
      f {
        inherit system;
        pkgs = inputs.nixpkgs.legacyPackages.${system};
      }
    );

  perSystem =
    { pkgs, system }:
    let
      slib = pkgs.lib;
      kix = import ./. {
        inherit pkgs;
        lib = slib;
      };
      kixChecks = import ../checks.nix {
        inherit pkgs;
        lib = slib;
      };
      piChecks = import ../pi-checks.nix { lib = slib; };

      # Resolve cluster definitions: path → import → callPackage-style arg injection.
      resolvedClusters = lib.mapAttrs (
        name: clusterDef:
        let
          fn =
            if builtins.isPath clusterDef || builtins.isString clusterDef then
              import clusterDef
            else
              clusterDef;
          available = {
            inherit kix;
            packages = catalogPackages;
          };
        in
        if builtins.isFunction fn then
          let
            fArgs = builtins.functionArgs fn;
            passArgs = lib.intersectAttrs fArgs available;
          in
          fn passArgs
        else
          fn
      ) clusters;

      clusterPackages = lib.concatMapAttrs (cname: cluster: {
        "cluster-${cname}" = kix.mkManifests cluster;
        "cluster-${cname}-activation" = pkgs.runCommand "k8s-activation-${cluster.name}" { } (
          ''
            mkdir -p $out
            ln -s ${cluster.activation} $out/activation
            ln -s ${cluster.packageIndex} $out/kix-packages.json
          ''
          + slib.optionalString (cluster.scorecardReport != null) ''
            ln -s ${builtins.toFile "kix-scorecard.json" (builtins.toJSON cluster.scorecardReport)} $out/kix-scorecard.json
          ''
          + slib.optionalString (cluster.extraImages != null) ''
            ln -s ${builtins.toFile "kix-extra-images.json" (builtins.toJSON cluster.extraImages)} $out/kix-extra-images.json
          ''
        );
      }) resolvedClusters;

      clusterChecks = lib.concatMapAttrs (cname: cluster: {
        "schema-cluster-${cname}" = kixChecks.schemaCheck "cluster-${cname}" (kix.mkManifests cluster);
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
      }) resolvedClusters;
    in
    {
      packages = clusterPackages;
      checks = clusterChecks;
      legacyPackages = {
        kixClusters = resolvedClusters;
        kixPackages = lib.mapAttrs (
          _name: pkg:
          let
            m = kix.peekPackageMeta {
              package = pkg;
              kixlib = kix.kixlib;
            };
          in
          {
            version = m.version or null;
            owner = m.owner or null;
          }
        ) catalogPackages;
      };
    };

  systemOutputs = eachSystem perSystem;
in
{
  packages = lib.mapAttrs (_: s: s.packages) systemOutputs;
  checks = lib.mapAttrs (_: s: s.checks) systemOutputs;
  legacyPackages = lib.mapAttrs (_: s: s.legacyPackages) systemOutputs;
}
