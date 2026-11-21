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

  # Arguments this library does not know. `unknownArguments` below refuses
  # them unless a newer version of Kix in the same project may read them.
  ...
}@arguments:

let
  lib = inputs.nixpkgs.lib;
  inherit (import ./core/error.nix { inherit lib; }) fail;

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
      fail {
        message = "kix.toml sets builder = ${builtins.toJSON value}, which is not a known builder (the Kix library supports: ${lib.concatStringsSep ", " builders}).";
        fix = "Check the spelling, or run `kix upgrade` if the project needs a newer Kix library.";
      };

  # The clusters each Kix library input builds, from `[versions]` in
  # kix.toml, or null when the project has one version of Kix.
  versions = settings.versions or null;
  inputOf =
    name:
    lib.findFirst (input: builtins.elem name versions.${input}) null (builtins.attrNames versions);

  # Return `cluster` when this library is the input that `[versions]` names
  # for it. The flake's outputs read only the input `kix`, and Kix replaces
  # that input with the cluster's own before it evaluates. Without the
  # replacement, a cluster on another input would build with the library of
  # `kix`, so it fails here. A cluster on `kix` cannot be checked, because
  # the replaced input is not visible to the library.
  onItsLibrary =
    name: cluster:
    let
      input = inputOf name;
      listed = lib.concatMapStringsSep ", " (i: "`${i}`") (builtins.attrNames versions);
    in
    if versions == null then
      cluster
    else if input == null then
      fail {
        message = "Cluster '${name}' in flake.nix is missing from kix.toml [versions].";
        fix = "Add \"${name}\" to one of the input lists in kix.toml [versions] (${listed}).";
      }
    else if input == "kix" then
      cluster
    else if !(inputs ? ${input}) then
      fail {
        message = "kix.toml [versions] assigns cluster '${name}' to input `${input}`, which is missing from flake.nix.";
        fix = "Add `inputs.${input}.url = \"github:kix-run/kix/v<version>\";` to flake.nix, then run `kix upgrade ${input}` to lock it.";
      }
    else if (inputs.kix.outPath or null) != inputs.${input}.outPath then
      fail {
        message = "Cluster '${name}' is assigned to input `${input}` in kix.toml [versions], which pins a different Kix library than `inputs.kix`.";
        fix = "Run `kix check ${name}` or `kix build ${name}` so Kix selects `${input}` automatically, or pass `--override-input kix <locked-${input}-ref>` to `nix`.";
      }
    else
      cluster;

  # The release tag that flake.lock records for the input `kix`, or null
  # when the project has no lock or `kix` names no tag. Replacing the input
  # for one evaluation does not change the file, so this is the newest
  # version of Kix in the project.
  lockedKixTag =
    let
      lockFile = if self == null then null else "${self}/flake.lock";
      lock =
        if lockFile != null && builtins.pathExists lockFile then
          builtins.fromJSON (builtins.readFile lockFile)
        else
          { };
      node = lock.nodes.${lock.root or "root"}.inputs.kix or null;
      ref = if builtins.isString node then lock.nodes.${node}.original.ref or null else null;
    in
    if ref == null then null else lib.removePrefix "refs/tags/" ref;

  cargoToml = ../../cli/Cargo.toml;
  libraryVersion =
    if builtins.pathExists cargoToml then
      (builtins.fromTOML (builtins.readFile cargoToml)).workspace.package.version
    else
      null;

  # Split a Kix version such as `0.12.3` or `0.12.0-rc.1` into its three
  # numbers and the parts of its pre-release label. Return null for text
  # that is not a version, such as a branch name.
  parseVersion =
    text:
    let
      match = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)(-([0-9A-Za-z.-]+))?" text;
      pre = builtins.elemAt match 4;
    in
    if match == null then
      null
    else
      {
        numbers = map lib.toIntBase10 (lib.take 3 match);
        pre = if pre == null then null else lib.splitString "." pre;
      };

  # Compare two parts of a pre-release label as semantic versioning does:
  # numbers by value, and a number before a word.
  comparePart =
    a: b:
    let
      number = part: builtins.match "[0-9]+" part != null;
    in
    if number a && number b then
      lib.compare (lib.toIntBase10 a) (lib.toIntBase10 b)
    else if number a then
      -1
    else if number b then
      1
    else
      lib.compare a b;

  # Whether the version `a` is older than `b`. A pre-release is older than
  # its release.
  olderVersion =
    a: b:
    let
      numbers = lib.compareLists lib.compare a.numbers b.numbers;
    in
    if numbers != 0 then
      numbers < 0
    else if a.pre == null then
      false
    else if b.pre == null then
      true
    else
      lib.compareLists comparePart a.pre b.pre < 0;

  # Whether this library is an older version of Kix than the release the
  # project's input `kix` pins, which holds some clusters back on it
  # (`[versions]`). Every version reads the same flake.nix, so an older one
  # skips the arguments it does not know. The library of `kix` is the
  # newest and checks them. A `kix` input on a branch names no release, so
  # every library checks its arguments.
  heldBack =
    let
      newest = if lockedKixTag == null then null else parseVersion (lib.removePrefix "v" lockedKixTag);
      own = if libraryVersion == null then null else parseVersion libraryVersion;
    in
    versions != null && newest != null && own != null && olderVersion own newest;

  unknownArguments = builtins.attrNames (
    removeAttrs arguments [
      "inputs"
      "clusters"
      "pins"
      "clusterModules"
      "packages"
      "systems"
    ]
  );

  catalogPackages = import ../packages { inherit lib; };
  packagesByLevel = import ../packages/by-level.nix { inherit lib; };
  packageLib = import ./core/package.nix { inherit lib; };

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
                  fail {
                    message = "mkFlake: cluster '${name}' takes a `pins` argument, but this flake declares no pin file.";
                    fix = "Add `pins = ./pins.json;` beside `clusters` in flake.nix, or read one directly with `kix.pins ./pins.json`.";
                  }
                else
                  kix.kixlib.pins pins;
            };
          in
          onItsLibrary name (
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
          )
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
          + link "kix-warnings.json" (files.warnings or null)
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
        # messages and to compare it with its own version. Kix shows the
        # stack frames of an error that sit under `projectRoot`, the
        # project's own files, and hides the rest.
        kixLibrary = {
          inherit (kix) version;
          projectRoot = if self == null then null else toString self;
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
                package = packageLib.idOf pkg;
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
  # Refuse an argument this library does not know, when the outputs are
  # read. The check reads the project's files through `self`, and the flake
  # needs the names of the outputs before `self` exists, so it cannot wrap
  # the whole set.
  checked =
    outputs:
    if unknownArguments != [ ] && !heldBack then
      fail {
        message = "Unknown `mkFlake` argument ${
          lib.concatMapStringsSep ", " (a: "`${a}`") unknownArguments
        }${
          lib.optionalString (libraryVersion != null) " in the Kix library ${libraryVersion}"
        } (supported: inputs, clusters, pins, clusterModules, packages, systems).";
        fix = "Check the spelling in flake.nix, or run `kix upgrade` if the project needs a newer Kix library.";
      }
    else
      outputs;
in
{
  packages = checked (lib.mapAttrs (_: s: s.packages) systemOutputs);
  checks = checked (lib.mapAttrs (_: s: s.checks) systemOutputs);
  legacyPackages = checked (lib.mapAttrs (_: s: s.legacyPackages) systemOutputs);
}
