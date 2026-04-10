# Cluster evaluation — buildCluster, dependency injection, scopes.
#
# Uses the NixOS module system (lib/modules.nix) for cluster composition.
# Namespace-scoped instances, DNS-like dependency injection, and a nested
# fixpoint that ties everything together.
# See v2_discussions/20_module_system_design.md for design rationale.
#
# Subsystems (in eval/):
#   helpers.nix   — mergeCollide, collectTypedAttrs, knownFolders
#   view.nix      — mkPackageView (consumer-facing instance shape)
#   scope.nix     — mkScope (per-instance context for packages)
#   import.nix    — mkImport, mkImportScope, evaluateImportInstance
#   namespace.nix — mkNamespace
#   auto.nix      — auto-instantiation (normalise, getRequiredDeps, compute)
#   resolve.nix   — DI resolution, config evaluation, two-phase package calling
#   instance.nix  — evaluateInstance
#   cluster.nix   — buildCluster

{
  lib,
  k8s,
  helm ? { },
}:

let
  rbac = import ./rbac.nix { inherit lib; };
  kixlib = import ./compose.nix { inherit lib; };
  meta = import ./meta.nix { inherit lib; };

  scorecard = import ./scorecard.nix { inherit lib; };
  helpers = import ./eval/helpers.nix { inherit lib; };
  netpol = import ./netpol.nix { inherit lib k8s; };
  view = import ./eval/view.nix { inherit lib helpers; };
  crd = import ./crd.nix { inherit lib; };
  scopeMod = import ./eval/scope.nix {
    inherit
      lib
      k8s
      rbac
      crd
      netpol
      helm
      ;
  };
  resolve = import ./eval/resolve.nix { inherit lib kixlib; };
  import_ = import ./eval/import.nix {
    inherit
      lib
      k8s
      rbac
      kixlib
      ;
    inherit (resolve) evaluateInstanceConfig;
  };
  namespaceMod = import ./eval/namespace.nix { inherit lib k8s; };
  auto = import ./eval/auto.nix {
    inherit
      lib
      meta
      kixlib
      resolve
      ;
  };
  instance = import ./eval/instance.nix {
    inherit
      lib
      k8s
      meta
      helpers
      netpol
      kixlib
      scorecard
      ;
    scope = scopeMod;
    inherit view resolve import_;
  };
  cluster = import ./eval/cluster.nix {
    inherit
      lib
      k8s
      meta
      kixlib
      helpers
      netpol
      scorecard
      ;
    inherit (namespaceMod) mkNamespace;
    inherit (auto) computeAutoInstances;
    inherit (resolve)
      buildResolutionIndex
      callPackagePhase1
      discoverBuildDeps
      resolveDepTargets
      buildConfigInjections
      evaluateInstanceConfig
      ;
    inherit (instance) evaluateInstance;
    inherit (import_) mkImport;
  };

in

{
  # Helpers
  inherit (helpers) mergeCollide collectTypedAttrs knownFolders;

  # View
  inherit (view) mkPackageView;

  # Scope
  inherit (scopeMod) mkScope;

  # Import
  inherit (import_) mkImport mkImportScope evaluateImportInstance;

  # Namespace
  inherit (namespaceMod) mkNamespace;

  # Auto-instantiation
  inherit (auto) normalizeAvailablePackages getRequiredDeps computeAutoInstances;

  # Resolution / DI
  inherit (resolve)
    buildResolutionIndex
    resolveArg
    extractDeferredValues
    evaluateInstanceConfig
    callPackagePhase1
    discoverBuildDeps
    resolveDeclaredDeps
    resolveDepTargets
    buildConfigInjections
    mkLocked
    systemArgNames
    systemBuildArgNames
    ;

  # Instance evaluation
  inherit (instance) evaluateInstance;

  # Cluster builder
  inherit (cluster) buildCluster;
}
