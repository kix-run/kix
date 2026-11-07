{
  pkgs,
  lib,
  # The calling flake (`self`), used to record flake-relative pin file paths
  # in image sources.
  self ? null,
  # How Helm charts are fetched and rendered: "placeholder" for the `kix`
  # builder or "nix" for the `nix` builder (see helm.nix).
  helmRoute ? "placeholder",
}:

let
  k8s = import ./core { inherit lib; };
  eval = import ./eval {
    inherit
      lib
      k8s
      helm
      self
      ;
  };
  env = import ./env.nix { inherit lib; };
  fragments = import ./vocab/fragments.nix { inherit lib; };
  helm = import ./helm.nix { inherit lib pkgs helmRoute; };
  rbac = import ./vocab/rbac.nix { inherit lib; };
  kixlib = import ./vocab { inherit lib; };
  meta = import ./meta.nix { inherit lib; };
  scorecard = import ./scorecard.nix { inherit lib; };
  rules = import ./rules { inherit lib; };

  normalize = import ./core/normalize.nix { inherit lib; };

  inherit (normalize) normalizeManifest;

  # Encode colons in the filename because Nix store path names cannot contain
  # them. Resource identity comes from the manifest itself.
  # Read the Kix version from the workspace version in cli/Cargo.toml, the
  # file a release bumps. Kix reports the same version, so Kix
  # can tell a project which program matches its library. A copy of the
  # library without that file has no version.
  cargoToml = ../../cli/Cargo.toml;
  version =
    if builtins.pathExists cargoToml then
      (builtins.fromTOML (builtins.readFile cargoToml)).workspace.package.version
    else
      null;

  manifestFileName =
    manifest:
    let
      name = manifest.metadata.name or "unnamed";
      kind = manifest.kind or "resource";
    in
    "${builtins.replaceStrings [ ":" ] [ "_" ] name}-${lib.toLower kind}.yaml";
in

{
  inherit version;

  inherit (k8s)
    clusterScoped
    mkResource
    mkImportResource
    mkPackageInstance
    mkActivation
    kixCRDs
    attachCtxDeep
    extractStoreHash
    nsOf
    resourceId
    ;

  inherit (eval)
    mkImport
    mkImportScope
    mkScope
    mkNamespace
    buildResolutionIndex
    resolveArg
    callPackagePhase1
    discoverBuildDeps
    resolveDeclaredDeps
    resolveDepTargets
    buildConfigInjections
    mkLocked
    evaluateInstance
    evaluateImportInstance
    buildCluster
    interface
    checkPackageOptions
    packageOptionViolations
    ;

  inherit (env) mkEnv;

  inherit (fragments) mergeFragments;

  inherit rbac;

  inherit kixlib;

  # Expose image and pin helpers to cluster definitions as well as packages.
  inherit (kixlib) pins image;

  inherit (meta) peekPackageMeta;

  inherit scorecard rules;

  inherit (helm)
    fetchHelmChart
    helmTemplateDerivation
    wrapHelmResource
    importChart
    importChartCrds
    helmChart
    isClusterScopedKind
    ;

  flavors = {
    k3s = ./flavors/k3s.nix;
    kind = ./flavors/kind.nix;
    kubeadm = ./flavors/kubeadm.nix;
    eks = ./flavors/eks.nix;
    gke = ./flavors/gke.nix;
    gke-autopilot = ./flavors/gke-autopilot.nix;
    aks = ./flavors/aks.nix;
    ovh = ./flavors/ovh.nix;
    scaleway = ./flavors/scaleway.nix;
    openshift = ./flavors/openshift.nix;
    rke2 = ./flavors/rke2.nix;
    talos = ./flavors/talos.nix;
  };

  modules = {
    monitoring = ./modules/monitoring.nix;
  };

  mkManifest =
    manifest:
    let
      yamlFormat = pkgs.formats.yaml { };
      cleaned = normalizeManifest manifest;
    in
    yamlFormat.generate (manifestFileName manifest) cleaned;

  mkManifests =
    cluster:
    let
      manifests = cluster.rawManifests;

      grouped = builtins.groupBy (m: m.metadata.namespace or "_cluster") manifests;

      mkYaml =
        manifest:
        let
          yamlFormat = pkgs.formats.yaml { };
          cleaned = normalizeManifest manifest;
          filename = manifestFileName manifest;
        in
        {
          inherit filename;
          drv = yamlFormat.generate filename cleaned;
        };

      nsCopyCommands = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          ns: nsManifests:
          let
            uniqueManifests = builtins.attrValues (
              lib.foldl' (
                acc: m:
                let
                  key = "${m.kind or "unknown"}/${m.metadata.name or "unnamed"}";
                in
                if acc ? ${key} then acc else acc // { ${key} = m; }
              ) { } nsManifests
            );
            yamls = map mkYaml uniqueManifests;
            copies = lib.concatMapStringsSep "\n" (y: "  cp ${y.drv} $out/${ns}/${y.filename}") yamls;
          in
          ''
              mkdir -p $out/${ns}
            ${copies}''
        ) grouped
      );
    in
    pkgs.runCommand "k8s-manifests-${cluster.name}" { } nsCopyCommands;
}
