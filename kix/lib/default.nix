{ pkgs, lib }:

let
  k8s = import ./core { inherit lib; };
  eval = import ./eval { inherit lib k8s helm; };
  env = import ./env.nix { inherit lib; };
  fragments = import ./vocab/fragments.nix { inherit lib; };
  helm = import ./helm.nix { inherit pkgs lib; };
  rbac = import ./vocab/rbac.nix { inherit lib; };
  kixlib = import ./vocab/compose.nix { inherit lib; };
  meta = import ./meta.nix { inherit lib; };
  scorecard = import ./scorecard.nix { inherit lib; };
  rules = import ./rules { inherit lib; };

  removeNulls =
    attrs:
    builtins.mapAttrs
      (
        _: v:
        if builtins.isAttrs v && !(lib.isDerivation v) && !(v ? type) then
          removeNulls v
        else if builtins.isList v then
          builtins.map (x: if builtins.isAttrs x && !(lib.isDerivation x) then removeNulls x else x) v
        else
          v
      )
      (
        lib.filterAttrs (
          _: v:
          v != null
          && !(builtins.isAttrs v && !(lib.isDerivation v) && !(v ? type) && v == { })
          && !(builtins.isList v && v == [ ])
        ) attrs
      );
in

{
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
    ;

  inherit (env) mkEnv;

  inherit rbac;

  inherit kixlib;

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
    lithus = ./flavors/lithus.nix;
    talos = ./flavors/talos.nix;
  };

  modules = {
    monitoring = ./modules/monitoring.nix;
  };

  mkManifest =
    manifest:
    let
      yamlFormat = pkgs.formats.yaml { };
      cleaned = removeNulls manifest;
      name = manifest.metadata.name or "unnamed";
      kind = manifest.kind or "resource";
    in
    yamlFormat.generate "${name}-${lib.toLower kind}.yaml" cleaned;

  mkManifests =
    cluster:
    let
      manifests = cluster.rawManifests;

      grouped = builtins.groupBy (m: m.metadata.namespace or "_cluster") manifests;

      mkYaml =
        manifest:
        let
          yamlFormat = pkgs.formats.yaml { };
          cleaned = removeNulls manifest;
          name = manifest.metadata.name or "unnamed";
          kind = manifest.kind or "resource";
        in
        {
          filename = "${name}-${lib.toLower kind}.yaml";
          drv = yamlFormat.generate "${name}-${lib.toLower kind}.yaml" cleaned;
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
