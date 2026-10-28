{
  lib,
  k8s,
  helm ? { },
  # The flake that defines these clusters (its `self`), or null when omitted.
  # Image sources record file paths relative to this flake.
  self ? null,
}:

let
  rbac = import ../vocab/rbac.nix { inherit lib; };
  kixlib = import ../vocab { inherit lib; };
  meta = import ../meta.nix { inherit lib; };

  scorecard = import ../scorecard.nix { inherit lib; };
  validate = import ./validate.nix { inherit lib; };
  helpers = import ./helpers.nix { inherit lib; };
  edgeAnalysis = import ./edges.nix { inherit k8s; };
  roles = import ./roles.nix { inherit lib; };
  hooks = import ./hooks.nix { inherit lib roles; };
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
  optionContract = import ./options.nix { inherit lib; };
  packageOptions = import ./package-options.nix {
    inherit lib kixlib meta;
    inherit (resolve) callPackagePhase1;
    inherit (optionContract) optionContractViolations;
  };
  import_ = import ./import.nix {
    inherit
      lib
      k8s
      rbac
      kixlib
      helpers
      ;
    inherit (resolve)
      evaluateInstanceConfig
      buildEntriesOf
      discoverBuildDeps
      systemArgNames
      ;
  };
  namespaceMod = import ./namespace.nix { inherit lib k8s; };
  podSecurity = import ./pod-security.nix { inherit lib; };
  consumersMod = import ./consumers.nix {
    inherit lib k8s;
    inherit (import_) mkImport;
    inherit (resolve) instancePinsLib;
  };
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
      self
      lib
      k8s
      meta
      kixlib
      helpers
      scorecard
      validate
      hooks
      roles
      ;
    inherit (namespaceMod) mkNamespace;
    inherit (auto) computeAutoInstances possibleInstanceNames;
    inherit (resolve)
      buildResolutionIndex
      callPackagePhase1
      discoverBuildDeps
      resolveDepTargets
      describeRequester
      buildConfigInjections
      checkRefTargets
      refsOf
      evaluateInstanceModules
      instancePinsLib
      ;
    inherit (instance) evaluateInstance;
    inherit (import_) mkImport checkExtraDeps;
    inherit consumersMod podSecurity;
  };

in

{
  inherit (helpers) mergeCollide collectTypedAttrs knownFolders;

  inherit (view) mkPackageView;

  inherit (scopeMod) mkScope;

  inherit (import_) mkImport mkImportScope evaluateImportInstance;

  inherit (namespaceMod) mkNamespace;

  inherit (consumersMod) interface;

  inherit (auto)
    normalizeAvailablePackages
    getRequiredDeps
    computeAutoInstances
    ;

  inherit (resolve)
    buildResolutionIndex
    resolveArg
    checkRefTargets
    describeRequester
    extractDeferredDefs
    evaluateInstanceConfig
    evaluateInstanceModules
    packageDefaultPriority
    callPackagePhase1
    buildEntriesOf
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

  inherit (optionContract) optionContractViolations checkOptionContract;

  inherit (packageOptions) packageOptionViolations checkPackageOptions;
}
