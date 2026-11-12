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

  # The project's settings from `kix.toml` beside its flake.nix. Nix sees the
  # file only once git tracks it, and Kix checks that its own
  # reading agrees with `kixConfig.builder`.
  builders = [
    "kix"
    "nix"
    "remote"
  ];
  self = inputs.self or null;
  configFile = if self == null then null else "${self}/kix.toml";
  settings =
    if configFile != null && builtins.pathExists configFile then
      builtins.fromTOML (builtins.readFile configFile)
    else
      { };
  builder =
    let
      value = settings.builder or "kix";
    in
    if builtins.elem value builders then
      value
    else
      throw "kix.toml sets builder = ${builtins.toJSON value}, which is not a known builder (the Kix library supports: ${lib.concatStringsSep ", " builders}). Check the spelling, or run `kix lib update` if the project needs a newer Kix library.";

  catalogPackages = import ../packages { inherit lib; };
  packagesByLevel = import ../packages/by-level.nix { inherit lib; };

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
        inherit pkgs lib self;
      };
      # The same library with Helm run by Nix, for the `nix` builder. Nothing
      # evaluates it unless something reads its clusters.
      kixNix = import ./. {
        inherit pkgs lib self;
        helmRoute = "nix";
      };
      # Return the `kix` a cluster definition receives. Its `buildCluster`
      # prepends `clusterModules` and names the cluster after its `clusters`
      # key unless the definition sets `name`. A definition keeps its own
      # `name` because renaming a deployed cluster orphans its deploy records.
      # A key-derived name is marked in the build, so the CLI can stop a
      # cluster that Kix 0.6 deployed as `cluster` from changing its name.
      kixFor =
        kix: key:
        kix
        // {
          buildCluster =
            args:
            kix.buildCluster (
              {
                name = key;
                _nameFromFlakeKey = !(args ? name);
              }
              // args
              // {
                modules = clusterModules ++ (args.modules or [ ]);
              }
            );
        };
      kixChecks = import ../checks.nix {
        inherit pkgs lib;
      };
      piChecks = import ../pi-checks.nix { inherit lib; };

      # Return the clusters as the library instance `kix` builds them.
      resolveClusters =
        kix:
        lib.mapAttrs (
          name: clusterDef:
          let
            fn =
              if builtins.isPath clusterDef || builtins.isString clusterDef then
                import clusterDef
              else
                clusterDef;
            available = {
              kix = kixFor kix name;
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

      resolvedClusters = resolveClusters kix;
      resolvedClustersNix = resolveClusters kixNix;

      # The library and clusters that the packages and checks below build.
      # Under the `kix` builder a cluster that uses Helm stops at its first
      # chart there, because only Kix renders charts. Under the
      # `nix` builder, Nix renders them.
      built =
        if builder == "nix" then
          {
            kix = kixNix;
            clusters = resolvedClustersNix;
          }
        else
          {
            inherit kix;
            clusters = resolvedClusters;
          };

      clusterPackages = lib.concatMapAttrs (
        cname: cluster:
        {
          "cluster-${cname}" = built.kix.mkManifests cluster;
        }
        // lib.optionalAttrs (builder == "nix") {
          "cluster-${cname}-activation" = activationOutput cluster;
        }
      ) built.clusters;

      # Return a directory with a link to each file of the cluster's build,
      # named as `kix build` names them, and to the activation index itself.
      activationOutput =
        cluster:
        let
          files = cluster.activationFiles;
          link = name: path: lib.optionalString (path != null) "ln -s ${path} $out/${name}\n";
        in
        pkgs.runCommand "k8s-activation-${cluster.name}" { } (
          ''
            mkdir -p $out
          ''
          + link "activation" files.activation
          + link "kix-packages.json" files.packages
          + link "kix-scorecard.json" files.scorecard
          + link "kix-extra-images.json" files.extraImages
          + link "kix-image-sources.json" files.imageSources
          + lib.concatStrings (
            lib.mapAttrsToList (consumer: file: link "kix-interface-${consumer}.json" file) files.interfaces
          )
          + link "kix-activation-index.json" cluster.activationIndex
        );

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
        "schema-cluster-${cname}" = kixChecks.schemaCheck "cluster-${cname}" (
          built.kix.mkManifests cluster
        );
        "rules-cluster-${cname}" = kixChecks.rulesCheck "cluster-${cname}" (built.kix.mkManifests cluster) (
          ruleTestsOf clusters.${cname}
        );
        "pi-wiring-cluster-${cname}" =
          assert piChecks.validatePIWiring "cluster-${cname}" cluster;
          pkgs.runCommand "pi-wiring-cluster-${cname}" { } ''
            echo "PI wiring validation passed for cluster-${cname}."
            touch $out
          '';
      }) built.clusters;

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
        # The same clusters with Helm charts rendered by Nix. Kix
        # reads these under the `nix` builder.
        kixClustersNix = resolvedClustersNix;
        # The project's settings from kix.toml. Kix compares
        # `builder` with its own reading of the file.
        kixConfig = {
          inherit builder;
        };
        # Kix reads this to name the library release in its
        # messages and to compare it with its own version.
        kixLibrary = {
          inherit (kix) version;
        };
        # The library and package set the flake's builder uses, in the shape
        # a cluster function receives them. A project that merges these
        # outputs into a larger flake builds its own checks from this, so
        # they render Helm charts the same way as its clusters.
        kixLib = {
          inherit (built) kix;
          packages = catalogPackages;
        };
        kixPackages =
          lib.mapAttrs
            (
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
            )
            (
              packagesByLevel.stable
              // lib.mapAttrs' (
                name: pkg: lib.nameValuePair "experimental.${name}" pkg
              ) packagesByLevel.experimental
            );
      };
    };

  systemOutputs = eachSystem perSystem;
in
{
  packages = lib.mapAttrs (_: s: s.packages) systemOutputs;
  checks = lib.mapAttrs (_: s: s.checks) systemOutputs;
  legacyPackages = lib.mapAttrs (_: s: s.legacyPackages) systemOutputs;
}
