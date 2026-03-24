# kix library — consolidated entry point for kixpkgs.
#
# Re-exports all kix components: resource constructors (k8s), cluster
# evaluation (eval), environments (env), fragments, helm bridge, and
# YAML serialization (mkManifest).
#
# Usage:
#   kix = import ./lib { inherit pkgs lib; };
#   cluster = kix.buildCluster { ... };

{ pkgs, lib }:

let
  k8s = import ./k8s.nix { inherit lib; };
  eval = import ./eval.nix { inherit lib k8s; };
  env = import ./env.nix { inherit lib; };
  fragments = import ./fragments.nix { inherit lib; };
  helm = import ./helm.nix { inherit pkgs lib; };
  rbac = import ./rbac.nix { inherit lib; };
  kixlib = import ./compose.nix { inherit lib; };
in

{
  # --- Resource constructors (k8s.nix) ---
  inherit (k8s)
    clusterScoped
    mkResource
    mkImportResource
    mkPackageInstance
    mkActivation
    attachCtxDeep
    extractStoreHash
    buildRegistry
    nsOf
    resourceId
    ;

  # --- Cluster evaluation + DI (eval.nix) ---
  inherit (eval)
    mkImport
    mkImportScope
    mkScope
    mkNamespace
    buildResolutionIndex
    resolveArg
    kixCallPackage
    evaluateInstance
    evaluateImportInstance
    buildCluster
    ;

  # --- Environments (env.nix) ---
  inherit (env) mkEnv;

  # --- RBAC DSL (rbac.nix) ---
  inherit rbac;

  # --- kixlib (compose.nix) — pure helpers passed to packages as `kix` arg ---
  inherit kixlib;

  # --- Helm bridge (helm.nix) ---
  inherit (helm)
    fetchHelmChart
    helmTemplateDerivation
    wrapHelmResource
    fromHelmChart
    isClusterScopedKind
    ;

  # --- YAML serialization ---
  # Converts a post-processed manifest attrset into a YAML file derivation.
  # Strips nulls and empty collections before serialization.
  mkManifest =
    manifest:
    let
      yamlFormat = pkgs.formats.yaml { };

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

      cleaned = removeNulls manifest;
      name = manifest.metadata.name or "unnamed";
      kind = manifest.kind or "resource";
    in
    yamlFormat.generate "${name}-${lib.toLower kind}.yaml" cleaned;
}
