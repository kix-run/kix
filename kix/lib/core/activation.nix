{ lib }:

let
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
      }
      // lib.optionalAttrs (version != null) { inherit version; }
      // lib.optionalAttrs (lifecycle != null) {
        inherit lifecycle;
      };
    };

  # Build the cluster's Activation resource, which serves as the root of its
  # store reference graph.
  #
  # Referencing `index` (`kix-packages.json`) pulls every built manifest and
  # import marker into the Activation's store closure so any change alters the
  # Activation hash. `instances` carries each `PackageInstance.out.name`
  # context, which places the Activation in the final deployment wave.
  #
  # The deploy engine also applies this exact manifest at the start of a run
  # (or right after the CRD wave on a first deploy) to record in-progress
  # deployments.
  mkActivation =
    {
      name,
      instances,
      index,
      extraDeps ? [ ],
      # Hosted consumer clusters (`consumer -> { interface = <store-path>; }`).
      # `interfaceFiles` adds each file to the Activation's store closure.
      consumers ? { },
      interfaceFiles ? [ ],
      # Platform interfaces this cluster builds against (`platform -> { consumer; path; sha256; }`).
      interfaces ? { },
      # `cluster.kubernetes.uid`: the kube-system Namespace UID of the one
      # Kubernetes cluster this build may deploy to, or null when unbound.
      kubernetesUid ? null,
    }:
    mkResource {
      apiVersion = kixAnnotations.apiVersion;
      kind = "Activation";
      inherit name;
      labels = {
        "app.kubernetes.io/managed-by" = "kix";
        ${kixKeys.clusterLabel} = name;
      }
      // lib.optionalAttrs (kubernetesUid != null) {
        ${kixKeys.kubernetesUidLabel} = kubernetesUid;
      };
      requires = [ kixCRDs.activation ];
      extraDeps = extraDeps;
      storeReferences = [ index ] ++ interfaceFiles;
      namespace = clusterScoped;
      extra.spec = {
        inherit instances;
      }
      // lib.optionalAttrs (consumers != { }) { inherit consumers; }
      // lib.optionalAttrs (interfaces != { }) { inherit interfaces; };
    };

}
