{
  inputs,

  clusters ? { },

  # Passed to cluster functions that declare a required `pins` argument.
  pins ? null,

  # Prepended to each cluster's modules.
  clusterModules ? [ ],

  systems ? [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ],
}:

let
  lib = inputs.nixpkgs.lib;

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
      kix =
        let
          base = import ./. {
            inherit pkgs;
            lib = slib;
          };
        in
        base
        // {
          buildCluster =
            args: base.buildCluster (args // { modules = clusterModules ++ (args.modules or [ ]); });
        };
      kixChecks = import ../checks.nix {
        inherit pkgs;
        lib = slib;
      };
      piChecks = import ../pi-checks.nix { lib = slib; };

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
            # Evaluated only when the cluster function requires `pins`.
            pins =
              if pins == null then
                throw "mkFlake: cluster '${name}' takes a `pins` argument, but this flake declares no pin file. Add `pins = ./pins.json;` beside `clusters` in flake.nix, or read one directly with `kix.pins ./pins.json`."
              else
                kix.kixlib.pins pins;
          };
        in
        if builtins.isFunction fn then
          let
            fArgs = builtins.functionArgs fn;
            # functionArgs marks defaulted arguments as true. Omit `pins`
            # when no shared file exists so the function's default applies.
            wantsItsOwnDefault = pins == null && (fArgs.pins or false);
            passArgs =
              let
                all = lib.intersectAttrs fArgs available;
              in
              if wantsItsOwnDefault then builtins.removeAttrs all [ "pins" ] else all;
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
