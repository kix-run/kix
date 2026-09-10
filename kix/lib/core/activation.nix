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

  # The cluster's deploy record, and the root of its Merkle tree.
  #
  # `instances` is built from every PackageInstance's `out.name`, and `out`
  # carries each instance's identity context, which transitively carries every
  # resource. So this node depends on the whole closure by construction, its
  # store hash covers everything, and "the activation hash changed" means
  # "something changed". That is also why it lands in the last wave: the
  # position is the dependency, not a choice.
  #
  # The engine does not wait for that wave to create the record. It applies
  # this same stamped manifest at the start of the run, so a deploy that stops
  # part way still leaves something that says what it was attempting
  # (kixpkgs#82); the last-wave apply is then an unchanged re-assertion. On a
  # cluster's first deploy the record's own CRD is in this plan, so the create
  # waits for the CRD barrier rather than the first wave. Keep the two in
  # step: whatever the engine creates must be exactly this manifest.
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
