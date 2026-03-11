# Fixpoint pattern library for Kubernetes resource management.
#
# Re-exports all fixpoint primitives as a single attrset. This is the
# primary interface for packages using the fixpoint pattern.
#
# Usage:
#   k8s = import ./lib/fixpoint { inherit lib; };
#   coredns = k8s.mkPackage ({ ... }: self: { ... }) { ... };
#
# The fixpoint library sits ON TOP of existing kixlib builders — it does not
# replace mkDeployment, mkService, etc. Those builders return plain attrsets,
# which is exactly what mkResource wraps with ref tracking and closure
# computation.
#
# Architecture layers:
#   Level 3: mkPackage, mkCluster (fixpoints, self-reference, closure)
#   Level 2: mkResource (ref tracking, tree walker, deps)
#   Level 1: refs, resolve, computeClosure (primitives)

{ lib }:

let
  refs = import ./refs.nix;
  resolver = import ./resolve.nix { inherit lib refs; };
  closureLib = import ./closure.nix { inherit lib; };
  resourceLib = import ./resource.nix {
    inherit
      lib
      refs
      resolver
      closure
      ;
  };
  closure = closureLib;
  packageLib = import ./package.nix { inherit lib; };
  clusterLib = import ./cluster.nix { inherit lib; };
in

{
  # --- Refs (Level 1) ---
  inherit (refs)
    mkRef
    isRef
    str
    isTrackedStr
    ;

  # --- Tree walker (Level 1) ---
  inherit (resolver) resolve;

  # --- Closure (Level 1) ---
  inherit (closureLib) computeClosure closureManifests validateClosure closureToDot closureToTree;

  # --- Resource constructor (Level 2) ---
  inherit (resourceLib) mkResource withRequires;

  # --- Package constructor (Level 3) ---
  inherit (packageLib) mkPackage;

  # --- Cluster composition (Level 3) ---
  inherit (clusterLib) mkCluster applyOverlays clusterToDot clusterToTree;
}
