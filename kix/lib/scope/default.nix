{
  lib,
  k8s,
  rbac,
  crd,
  helpers,
  helm ? { },
}:

let
  inherit (helpers) collectTypedAttrs;

  labelsMod = import ./labels.nix;
  validatorsMod = import ./validators.nix { inherit lib; };
  buildersMod = import ./builders.nix { inherit lib k8s; };
  unsafe = import ../unsafe.nix { inherit lib; };
  errors = import ../core/error.nix { inherit lib; };

  emptyEdgeAnalysis = {
    edgesFor = _: {
      edges = [ ];
      dnsEdges = [ ];
      warnings = [ ];
    };
    dnsRoot = null;
    serviceRegistry = { };
    serviceRefRegistry = { };
    serviceIndex = { };
    isServiceRef = _: false;
  };
in

rec {
  mkScope =
    {
      instanceName,
      namespaceName,
      namespaceResource,
      # Namespace the instance lives in. `forNamespace` changes
      # `namespaceName` and keeps this, so a resource built into another
      # namespace still records this instance as its builder.
      homeNamespaceName ? namespaceName,
      namespaces ? { },
      clusterLabels ? { },
      labelStyle ? "kix",
      selectorLabelsOverride ? null,
      clusterDomain,
      capabilities ? { },
      networkPolicyEnforcer ? null,
      peekedPackageMeta ? { },
      workloadInterceptors ? [ ],
      # Resolved availability for this instance from `core/availability.nix`.
      availability ? {
        level = "none";
        ceiling = null;
        warnings = [ ];
      },
      factBehaviorOverrides ? { },
      edgeAnalysis ? emptyEdgeAnalysis,
      clusterCtx ? {
        config = { };
        findRoleProvider = _: null;
      },
    }:
    let
      scopeLabels = labelsMod.mkScopeLabels {
        inherit instanceName labelStyle selectorLabelsOverride;
      };
      inherit (scopeLabels) selectorLabels instanceLabels labels;

      # Policy directions enforced by the cluster (`{ ingress; egress; }`), or
      # null when no enforcer is active. Generating a policy section for an
      # unenforced direction would isolate pods in a direction that default deny
      # leaves open.
      networkPolicyEnforced =
        if networkPolicyEnforcer == null then null else clusterCtx.config.networkPolicy.enforced;

      # Return whether a cluster role is "provided", "absent", or "unknown".
      # `findRoleProvider` only inspects package `meta`, so this check stays lazy.
      roleStatus =
        role:
        let
          binding = clusterCtx.config.cluster.roles.${role}.binding or null;
          provider = (clusterCtx.findRoleProvider or (_: null)) role;
        in
        if provider != null then
          "provided"
        else if binding == "shadowable" || binding == "exclusive" then
          "provided"
        else if binding == "absent" then
          "absent"
        else
          "unknown";

      validators = validatorsMod.mkValidators {
        inherit
          instanceName
          namespaceName
          capabilities
          roleStatus
          ;
        # A typo in this closed vocabulary throws during scope
        # construction, naming the declaring instance.
        unsafeGrants = map (unsafe.assertKnownGrant "meta.unsafe of instance ${instanceName}") (
          peekedPackageMeta.unsafe or [ ]
        );
      };

      builders = buildersMod.mkBuilders {
        inherit
          instanceName
          namespaceName
          namespaceResource
          clusterLabels
          clusterDomain
          instanceLabels
          validators
          edgeAnalysis
          workloadInterceptors
          peekedPackageMeta
          clusterCtx
          availability
          factBehaviorOverrides
          scopeObj
          ;
        builtBy = "${homeNamespaceName}/${instanceName}";
      };

      inherit (builders)
        scopeMkResource
        scopeMkClusterResource
        emit
        mkWorkload
        mkJob
        mkCronJob
        mkHelmWorkload
        mkOptional
        mkWebhookService
        mkCRD
        mkCRDRef
        mkCR
        mkSecret
        mkSecretRef
        mkServiceRef
        ;

      scopeObj = {
        inherit
          instanceName
          namespaceName
          selectorLabels
          labels
          labelStyle
          namespaces
          mkOptional
          networkPolicyEnforcer
          networkPolicyEnforced
          ;
        namespace = namespaceResource;

        mkResource = scopeMkResource;

        # Stop evaluation with an error for a person to fix, naming this
        # instance (`core/error.nix`). Takes what `kix.fail` takes.
        fail = errors.failFor "${homeNamespaceName}/${instanceName}";

        # Verify that the cluster serves `metrics.k8s.io` for `subject`. Packages
        # whose workloads read the metrics API without an HPA call this directly.
        requireMetricsApi = validators.requireMetricsApi;

        # Hook emission facade passed to hooks as `ctx.emit`. Not part of the
        # package-authoring API.
        _emit = emit;

        # Attach the ordering and endpoint-fact string context of `passengers`
        # (implicit resource dependencies) to `value`.
        augmentEdge =
          passengers: value:
          let
            extraCtx = builtins.foldl' (
              acc: p:
              acc
              // (if builtins.isAttrs p && p ? outPath then builtins.getContext "${p}" else { })
              // (builtins.foldl' (a: fc: a // fc) { } (builtins.attrValues (p.factTokens or { })))
            ) { } passengers;
          in
          builtins.appendContext (toString value) extraCtx;

        augmentAllEdges =
          passengers: outAttrs:
          lib.mapAttrs (_: v: if builtins.isString v then scopeObj.augmentEdge passengers v else v) outAttrs;

        # Re-export `dep.out` with the string context of `passengers` (additional
        # resources the consumer must wait for) attached to every string value.
        # Also include any ServiceRef markers from `dep.raw` so network policy
        # analysis sees the target Service on the re-exporting package.
        forwardEdges =
          dep: passengers:
          let
            augmented = scopeObj.augmentAllEdges passengers (dep.out or { });
            depRaw = dep.raw or { };
            typed = builtins.filter (v: (v._type or "") == "k8s-resource") (
              collectTypedAttrs {
                excludeKeys = [
                  "root"
                  "meta"
                ];
              } depRaw
            );
            markers = builtins.filter edgeAnalysis.isServiceRef typed;
            markerMap = builtins.listToAttrs (
              map (m: {
                inherit (m) name;
                value = m;
              }) markers
            );
          in
          augmented // markerMap;

        forService =
          dep:
          let
            depNs =
              dep._meta.namespaceName or (errors.fail {
                message = "scope.forService: the dependency does not declare its namespace (_meta.namespaceName is missing).";
                fix = "Use scope.forNamespace with the namespace name instead.";
              });
          in
          scopeObj.forNamespace depNs;

        forNamespace =
          nsName:
          let
            nsRes =
              namespaces.${nsName} or (scopeObj.fail {
                message = "scope.forNamespace requested namespace '${nsName}', which does not exist in this cluster. Declared namespaces: ${builtins.concatStringsSep ", " (builtins.attrNames namespaces)}.";
                fix = "Check this instance's config for a misspelled namespace name, or declare the namespace in the cluster definition:\n  namespaces.${nsName} = { };";
              });
          in
          mkScope {
            inherit
              instanceName
              homeNamespaceName
              namespaces
              clusterLabels
              labelStyle
              clusterDomain
              capabilities
              networkPolicyEnforcer
              peekedPackageMeta
              workloadInterceptors
              clusterCtx
              availability
              ;
            # Clear `dnsRoot` so resources emitted into another namespace do not
            # inherit DNS readiness ordering from the caller's scope.
            edgeAnalysis = edgeAnalysis // {
              dnsRoot = null;
            };
            namespaceName = nsName;
            namespaceResource = nsRes;
          };

        mkClusterResource = scopeMkClusterResource;

        inherit rbac helm;

        mkDeployment = mkWorkload "apps/v1" "Deployment";
        mkStatefulSet = mkWorkload "apps/v1" "StatefulSet";
        mkDaemonSet = mkWorkload "apps/v1" "DaemonSet";
        inherit mkJob mkCronJob mkHelmWorkload;

        inherit
          crd
          mkCRD
          mkCRDRef
          mkCR
          mkSecret
          mkSecretRef
          mkServiceRef
          mkWebhookService
          ;
      };
    in
    scopeObj;
}
