# How `mkFlake` names the clusters it lists, and that `buildCluster` refuses
# a call without a name.
{ lib, eval, ... }:

let
  # The `kixClusters` output of a flake that lists `clusters`, with nixpkgs
  # stubbed down to its `lib`. Forcing `pkgs` is an error, so a cluster that
  # evaluates here needs no derivation.
  clustersOf =
    clusters:
    (import ../../mkFlake.nix {
      inputs = {
        nixpkgs = {
          inherit lib;
          legacyPackages.test-system = throw "evaluating the cluster forced pkgs";
        };
        self = null;
      };
      systems = [ "test-system" ];
      inherit clusters;
    }).legacyPackages.test-system.kixClusters;
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

  mkflake-buildcluster-without-name-fails =
    !(builtins.tryEval (eval.buildCluster { modules = [ ]; }).name).success
    || throw "buildCluster accepted a call without a name";
}
