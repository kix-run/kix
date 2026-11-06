# How `mkFlake` names the clusters it lists, how the index records a name
# taken from a key, and that `buildCluster` refuses a call without a name.
{ lib, eval, ... }:

let
  # The `kixClusters` output of a flake that lists `clusters`, with nixpkgs
  # stubbed down to its `lib`: nothing here forces a derivation.
  clustersOf =
    clusters:
    (import ../../mkFlake.nix {
      inputs = {
        nixpkgs = {
          inherit lib;
          legacyPackages.test-system = {
            inherit lib;
          };
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
