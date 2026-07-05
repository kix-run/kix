{ lib }:

let
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
      apiVersion = "kix.dev/v1alpha1";
      kind = "PackageInstance";
      name = instanceName;
      inherit namespace labels;
      requires = [ kixCRDs.packageInstance ];
      annotations = {
        "kix.dev/root" = mainResource.out.name;
      }
      // lib.optionalAttrs (inverseDeps != [ ]) {
        "kix.dev/inverse-deps" = builtins.concatStringsSep "," (
          map (r: "${r.kind}/${r.out.name}") inverseDeps
        );
      }
      // lib.optionalAttrs (packageRequires != [ ]) {
        "kix.dev/package-requires" = builtins.concatStringsSep "," (
          map (r: "${r.kind}/${r.out.name}") packageRequires
        );
      }
      // lib.optionalAttrs (postHooks != [ ]) {
        "kix.dev/post-hooks" = builtins.concatStringsSep "," (map (r: "${r.kind}/${r.out.name}") postHooks);
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
      apiVersion = "kix.dev/v1alpha1";
      kind = "Activation";
      inherit name;
      labels = {
        "app.kubernetes.io/managed-by" = "kix";
        "kix.dev/cluster" = name;
      };
      requires = [ kixCRDs.activation ];
      extraDeps = extraDeps;
      namespace = clusterScoped;
      extra.spec = {
        inherit instances;
      };
    };

}
