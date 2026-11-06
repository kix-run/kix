# How `mkFlake` names the clusters it lists, and that `buildCluster` refuses
# a call without a name.
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

  mkflake-buildcluster-without-name-fails =
    !(builtins.tryEval (eval.buildCluster { modules = [ ]; }).name).success
    || throw "buildCluster accepted a call without a name";
}
