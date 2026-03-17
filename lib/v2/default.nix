# kixpkgs v2 library — re-exports all v2 components.
#
# Usage:
#   kixv2 = import ./lib/v2 { inherit lib; };
#   cluster = kixv2.buildCluster { ... };

{ lib }:

let
  k8s = import ./k8s.nix { inherit lib; };
  eval = import ./eval.nix { inherit lib k8s; };
  env = import ./env.nix { inherit lib; };
  fragments = import ./fragments.nix { inherit lib; };
in

{
  # --- Level 0: Resource constructor ---
  inherit (k8s)
    clusterScoped
    mkResource
    mkPackageInstance
    postProcessManifest
    computeClosure
    closureToDot
    closureToTree
    buildRegistry
    ;

  # --- Level 1-2: Cluster evaluation + DI ---
  inherit (eval)
    mkScope
    mkNamespace
    buildResolutionIndex
    resolveArg
    kixCallPackage
    evaluateInstance
    buildCluster
    ;

  # --- Level 5: Environments ---
  inherit (env) mkEnv;

  # --- Level 6: Fragments ---
  inherit (fragments) mergeFragments;
}
