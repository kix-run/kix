{ lib }:

let
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
  kixAnnotations = import ./annotations.nix;
  kixKeys = kixAnnotations.keys;
  resource = import ./resource.nix { inherit lib; };
  inherit (resource) mkResource kixCRDs clusterScoped;
in
{

  mkPackageInstance =
    {
      instanceName,
      namespaceName,
      namespace,
      mainResource,
      packageRequires ? [ ],
      postHooks ? [ ],
      inverseDeps ? [ ],
      version ? null,
      labels ? { },
      extraAnnotations ? { },
      lifecycle ? null,
    }:
    let
      resolvedVersion =
        if version == null then
          builtins.trace "warning: package ${instanceName} has no version set" "<undefined>"
        else
          version;
    in
    mkResource {
      apiVersion = kixAnnotations.apiVersion;
      kind = "PackageInstance";
      name = instanceName;
      inherit namespace labels;
      requires = [ kixCRDs.packageInstance ];
      annotations = {
        ${kixKeys.root} = mainResource.out.name;
      }
      // lib.optionalAttrs (inverseDeps != [ ]) {
        ${kixKeys.inverseDeps} = builtins.concatStringsSep "," (
          map (r: "${r.kind}/${r.out.name}") inverseDeps
        );
      }
      // lib.optionalAttrs (packageRequires != [ ]) {
        ${kixKeys.packageRequires} = builtins.concatStringsSep "," (
          map (r: "${r.kind}/${r.out.name}") packageRequires
        );
      }
      // lib.optionalAttrs (postHooks != [ ]) {
        ${kixKeys.postHooks} = builtins.concatStringsSep "," (map (r: "${r.kind}/${r.out.name}") postHooks);
      }
      // extraAnnotations;
      extra.spec = {
        inherit instanceName namespaceName;
        version = resolvedVersion;
      }
      // lib.optionalAttrs (lifecycle != null) {
        inherit lifecycle;
      };
    };

  mkActivation =
    {
      name,
      instances,
      extraDeps ? [ ],
    }:
    mkResource {
      apiVersion = kixAnnotations.apiVersion;
      kind = "Activation";
      inherit name;
      labels = {
        "app.kubernetes.io/managed-by" = "kix";
        ${kixKeys.clusterLabel} = name;
      };
      requires = [ kixCRDs.activation ];
      extraDeps = extraDeps;
      namespace = clusterScoped;
      extra.spec = {
        inherit instances;
      };
    };

}
