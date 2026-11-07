# How `mkFlake` names the clusters it lists, and that `buildCluster` refuses
# a call without a name.
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

  mkflake-unknown-builder-fails =
    !(builtins.tryEval (projectFlake "unknown-builder").legacyPackages.test-system.kixConfig.builder)
    .success;

  mkflake-buildcluster-without-name-fails =
    !(builtins.tryEval (eval.buildCluster { modules = [ ]; }).name).success
    || throw "buildCluster accepted a call without a name";
}
