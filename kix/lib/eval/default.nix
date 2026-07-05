{
  lib,
  k8s,
  helm ? { },
}:

let
  rbac = import ../vocab/rbac.nix { inherit lib; };
  kixlib = import ../vocab/compose.nix { inherit lib; };
  meta = import ../meta.nix { inherit lib; };

  scorecard = import ../scorecard.nix { inherit lib; };
  helpers = import ./helpers.nix { inherit lib; };
  edgeAnalysis = import ./edges.nix { inherit k8s; };
  roles = import ./roles.nix { inherit lib; };
  hooks = import ./hooks.nix {
    inherit
      lib
      meta
      kixlib
      roles
      ;
  };
  view = import ./view.nix { inherit lib helpers; };
  crd = import ../vocab/crd.nix { inherit lib; };
  scopeMod = import ../scope/default.nix {
    inherit
      lib
      k8s
      rbac
      crd
      helpers
      helm
      ;
  };
  resolve = import ./resolve.nix { inherit lib kixlib; };
  import_ = import ./import.nix {
    inherit
      lib
      k8s
      rbac
      kixlib
      ;
    inherit (resolve) evaluateInstanceConfig;
  };
  namespaceMod = import ./namespace.nix { inherit lib k8s; };
  auto = import ./auto.nix {
    inherit
      lib
      meta
      kixlib
      resolve
      roles
      ;
  };
  instance = import ./instance.nix {
    inherit
      lib
      k8s
      meta
      helpers
      kixlib
      scorecard
      edgeAnalysis
      ;
    scope = scopeMod;
    inherit view resolve import_;
  };
  cluster = import ./cluster.nix {
    inherit
      lib
      k8s
      meta
      kixlib
      helpers
      scorecard
      hooks
      roles
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
  inherit (helpers) mergeCollide collectTypedAttrs knownFolders;

  inherit (view) mkPackageView;

  inherit (scopeMod) mkScope;

  inherit (import_) mkImport mkImportScope evaluateImportInstance;

  inherit (namespaceMod) mkNamespace;

  inherit (auto) normalizeAvailablePackages getRequiredDeps computeAutoInstances;

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

  inherit (instance) evaluateInstance;

  inherit (cluster) buildCluster;
}
