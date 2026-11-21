# How `mkFlake` names the clusters it lists, how the index records a name
# taken from a key, and that `buildCluster` refuses a call without a name.
{ lib, eval, ... }:

let
  # The `kixClusters` output of a flake that lists `clusters`, with nixpkgs
  # stubbed down to its `lib`. Forcing `pkgs` is an error, so a cluster that
  # evaluates here needs no derivation.
  flakeOf =
    self: clusters:
    import ../../mkFlake.nix {
      inputs = {
        nixpkgs = {
          inherit lib;
          legacyPackages.test-system = throw "evaluating the cluster forced pkgs";
        };
        inherit self;
      };
      systems = [ "test-system" ];
      inherit clusters;
    };

  clustersOf = clusters: (flakeOf null clusters).legacyPackages.test-system.kixClusters;

  # A flake whose project directory holds the kix.toml in ./projects/<name>.
  projectFlake =
    name:
    flakeOf ./projects/${name} {
      alpha = { kix, ... }: kix.buildCluster { modules = [ ]; };
    };
in
{
  mkflake-names-cluster-after-key =
    let
      clusters = clustersOf {
        alpha = { kix, ... }: kix.buildCluster { modules = [ ]; };
      };
    in
    clusters.alpha.name == "alpha"
    || throw "expected the cluster to be named alpha, got ${clusters.alpha.name}";

  mkflake-explicit-name-wins-over-key =
    let
      clusters = clustersOf {
        alpha =
          { kix, ... }:
          kix.buildCluster {
            name = "beta";
            modules = [ ];
          };
      };
    in
    clusters.alpha.name == "beta"
    || throw "expected the definition's name beta, got ${clusters.alpha.name}";

  # The index names the Activation record and the package index, and
  # evaluating it writes files to the store without building anything.
  mkflake-activation-index-needs-no-pkgs =
    let
      cluster =
        (clustersOf {
          alpha = { kix, ... }: kix.buildCluster { modules = [ ]; };
        }).alpha;
      index = builtins.fromJSON (
        builtins.unsafeDiscardStringContext (builtins.readFile cluster.activationIndex)
      );
    in
    (
      index.version == 1
      && index.activation == toString cluster.activation
      && index.packages == toString cluster.packageIndex
      && index.interfaces == { }
    )
    || throw "unexpected activation index: ${builtins.toJSON index}";

  # Without kix.toml the builder is kix, and there is no activation output.
  mkflake-default-builder-is-kix =
    let
      flake = flakeOf null {
        alpha = { kix, ... }: kix.buildCluster { modules = [ ]; };
      };
    in
    (
      flake.legacyPackages.test-system.kixConfig.builder == "kix"
      && builtins.attrNames flake.packages.test-system == [ "cluster-alpha" ]
      && flake.legacyPackages.test-system.kixClustersNix.alpha.name == "alpha"
    )
    || throw "packages: ${builtins.toJSON (builtins.attrNames flake.packages.test-system)}";

  # builder = "nix" adds the activation output beside the manifests.
  mkflake-nix-builder-adds-the-activation-output =
    let
      flake = projectFlake "nix-builder";
    in
    (
      flake.legacyPackages.test-system.kixConfig.builder == "nix"
      &&
        builtins.attrNames flake.packages.test-system == [
          "cluster-alpha"
          "cluster-alpha-activation"
        ]
    )
    || throw "packages: ${builtins.toJSON (builtins.attrNames flake.packages.test-system)}";

  # `kixLib` hands back the library the builder uses. Under the kix builder
  # a chart is a placeholder that needs no nixpkgs. Under the nix builder
  # it is a real derivation, which forces the stubbed nixpkgs here.
  mkflake-kixlib-follows-the-builder =
    let
      chart =
        flake:
        flake.legacyPackages.test-system.kixLib.kix.fetchHelmChart {
          repo = "https://charts.example.com";
          name = "demo";
          version = "1.0.0";
          hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      kixLib = (projectFlake "nix-builder").legacyPackages.test-system.kixLib;
    in
    (
      (chart (flakeOf null { })).system == "kix-helm"
      && !(builtins.tryEval (chart (projectFlake "nix-builder")).drvPath).success
      && kixLib.packages ? cert-manager
    )
    || throw "kixLib does not follow the builder";

  # An argument this library does not know fails, as a typing mistake
  # should. A library that an older version of Kix in the project runs
  # skips it, because the newest version may read it.
  mkflake-unknown-argument-fails =
    let
      flake =
        self:
        import ../../mkFlake.nix {
          inputs = {
            nixpkgs = {
              inherit lib;
              legacyPackages.test-system = throw "evaluating the cluster forced pkgs";
            };
            inherit self;
          };
          systems = [ "test-system" ];
          clusters = { };
          notAnArgument = true;
        };
      builds = self: (builtins.tryEval (builtins.attrNames (flake self).legacyPackages)).success;
    in
    (
      !builds null
      && !builds ./projects/versions-newest
      # A `kix` input on a branch or on an older release does not make
      # this library the older one.
      && !builds ./projects/versions-branch
      && !builds ./projects/versions-older
      && builds ./projects/versions-held-back
    )
    || throw "an unknown mkFlake argument is refused unless the library is held back";

  mkflake-unknown-builder-fails =
    !(builtins.tryEval (projectFlake "unknown-builder").legacyPackages.test-system.kixConfig.builder)
    .success;

  # The index marks a name that `mkFlake` took from the key, which the CLI
  # reads to stop a cluster that Kix 0.6 named `cluster` from changing its
  # name without an error.
  mkflake-index-marks-key-derived-name =
    let
      clusters = clustersOf {
        alpha = { kix, ... }: kix.buildCluster { modules = [ ]; };
        beta =
          { kix, ... }:
          kix.buildCluster {
            name = "beta";
            modules = [ ];
          };
      };
    in
    (
      clusters.alpha.packageIndexContent.nameFromFlakeKey
      || throw "expected the index of alpha to mark its name as taken from the key"
    )
    && (
      !(clusters.beta.packageIndexContent.nameFromFlakeKey or false)
      || throw "expected the index of beta, which sets name, not to mark its name"
    );

  mkflake-index-direct-buildcluster-name-is-unmarked =
    !((eval.buildCluster {
      name = "gamma";
      modules = [ ];
    }).packageIndexContent.nameFromFlakeKey or false
    )
    || throw "expected a direct buildCluster call not to mark its name";

  mkflake-buildcluster-without-name-fails =
    !(builtins.tryEval (eval.buildCluster { modules = [ ]; }).name).success
    || throw "buildCluster accepted a call without a name";
}
