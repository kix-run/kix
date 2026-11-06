{
  inputs,

  # Cluster definitions keyed by name: each a `{ kix, packages, ... }:`
  # function or a path to one. The key names the flake outputs and, unless
  # the definition passes `name` to `buildCluster`, the cluster itself.
  clusters ? { },

  # Pin file passed to cluster functions that declare a `pins` argument.
  # Instance pins target a single cluster, so a flake with multiple clusters
  # should load per-cluster pin files with `kix.pins`.
  pins ? null,

  # Prepended to each cluster's modules.
  clusterModules ? [ ],

  # Packages defined by this flake (each a package or a path to one), checked
  # by `option-contract-<name>` since cluster evaluation does not run option
  # contract checks.
  packages ? { },

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
      # `lib` comes from the nixpkgs input rather than `pkgs.lib`, so
      # evaluating a cluster forces `pkgs` only when a package needs it.
      kix = import ./. {
        inherit pkgs lib;
        self = inputs.self or null;
      };
      # Return the `kix` a cluster definition receives. Its `buildCluster`
      # prepends `clusterModules` and names the cluster after its `clusters`
      # key unless the definition sets `name`. A definition keeps its own
      # `name` because renaming a deployed cluster orphans its deploy records.
      kixFor =
        key:
        kix
        // {
          buildCluster =
            args:
            kix.buildCluster (
              { name = key; } // args // { modules = clusterModules ++ (args.modules or [ ]); }
            );
        };
      kixChecks = import ../checks.nix {
        inherit pkgs lib;
      };
      piChecks = import ../pi-checks.nix { inherit lib; };

      resolvedClusters = lib.mapAttrs (
        name: clusterDef:
        let
          fn =
            if builtins.isPath clusterDef || builtins.isString clusterDef then
              import clusterDef
            else
              clusterDef;
          available = {
            kix = kixFor name;
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

      # Plain Nix cannot render a Helm chart, so for a cluster that uses Helm
      # these packages and the checks below stop at the first chart. Only
      # `kix` builds such a cluster.
      clusterPackages = lib.concatMapAttrs (cname: cluster: {
        "cluster-${cname}" = kix.mkManifests cluster;
      }) resolvedClusters;

      # Return the `<name>.rules-test.yaml` path beside a cluster file if it
      # exists, or null when the cluster is given as an inline value.
      ruleTestsOf =
        clusterDef:
        let
          sibling =
            if builtins.isPath clusterDef || builtins.isString clusterDef then
              "${dirOf clusterDef}/${lib.removeSuffix ".nix" (baseNameOf clusterDef)}.rules-test.yaml"
            else
              null;
        in
        if sibling != null && builtins.pathExists sibling then sibling else null;

      clusterChecks = lib.concatMapAttrs (cname: cluster: {
        "schema-cluster-${cname}" = kixChecks.schemaCheck "cluster-${cname}" (kix.mkManifests cluster);
        "rules-cluster-${cname}" = kixChecks.rulesCheck "cluster-${cname}" (kix.mkManifests cluster) (
          ruleTestsOf clusters.${cname}
        );
        "pi-wiring-cluster-${cname}" =
          assert piChecks.validatePIWiring "cluster-${cname}" cluster;
          pkgs.runCommand "pi-wiring-cluster-${cname}" { } ''
            echo "PI wiring validation passed for cluster-${cname}."
            touch $out
          '';
      }) resolvedClusters;

      packageChecks = lib.mapAttrs' (
        name: package:
        lib.nameValuePair "option-contract-${name}" (
          builtins.seq
            (kix.checkPackageOptions {
              package = if builtins.isPath package || builtins.isString package then import package else package;
              who = "package `${name}`";
              scope = {
                instanceName = name;
                namespaceName = name;
              };
            })
            (
              pkgs.runCommand "option-contract-${name}" { } ''
                echo "The options of ${name} satisfy the option contract."
                touch $out
              ''
            )
        )
      ) packages;
    in
    {
      packages = clusterPackages;
      checks = clusterChecks // packageChecks;
      legacyPackages = {
        kixClusters = resolvedClusters;
        # The kix program reads this to name the library release in its
        # messages and to compare it with its own version.
        kixLibrary = {
          inherit (kix) version;
        };
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
