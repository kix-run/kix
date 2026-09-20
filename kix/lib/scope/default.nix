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
      namespaces ? { },
      clusterLabels ? { },
      labelStyle ? "kix",
      selectorLabelsOverride ? null,
      clusterDomain ? "cluster.local",
      capabilities ? { },
      networkPolicyEnforcer ? null,
      peekedPackageMeta ? { },
      workloadInterceptors ? [ ],
      # the instance's resolved availability (core/availability.nix resolve)
      availability ? {
        level = "none";
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

      # Role satisfaction for validator gates: "provided" (managed provider
      # or environment binding), "absent" (declared vacant), "unknown"
      # (axiom never declared). Lazy — findRoleProvider only peeks meta.
      roleStatus =
        role:
        let
          binding = (((clusterCtx.config or { }).cluster or { }).roles or { }).${role}.binding or null;
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
        # Closed vocabulary — a typo'd grant throws here, at scope
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
      };

      inherit (builders)
        scopeMkResource
        scopeMkClusterResource
        emit
        mkWorkload
        mkJob
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
          ;
        namespace = namespaceResource;

        mkResource = scopeMkResource;

        # Internal: the hook emission facade (see builders.nix). Not part of
        # the package-authoring surface — hooks receive it as ctx.emit.
        _emit = emit;

        augmentEdge =
          passengers: value:
          let
            extraCtx = builtins.foldl' (
              acc: p:
              acc
              # identity: the derivation record (ordering)
              // (if builtins.isAttrs p && p ? outPath then builtins.getContext "${p}" else { })
              # facts: the semantic claims (netpol edges ride along too)
              // (builtins.foldl' (a: fc: a // fc) { } (builtins.attrValues (p.factTokens or { })))
            ) { } passengers;
          in
          builtins.appendContext (toString value) extraCtx;

        augmentAllEdges =
          passengers: outAttrs:
          lib.mapAttrs (_: v: if builtins.isString v then scopeObj.augmentEdge passengers v else v) outAttrs;

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
              dep._meta.namespaceName
                or (throw "scope.forService: the dependency does not declare its namespace (_meta.namespaceName is missing). Use scope.forNamespace with the namespace name instead");
          in
          scopeObj.forNamespace depNs;

        forNamespace =
          nsName:
          let
            nsRes =
              namespaces.${nsName}
                or (throw "scope.forNamespace: namespace '${nsName}' does not exist in the cluster");
          in
          mkScope {
            inherit
              instanceName
              namespaces
              clusterLabels
              labelStyle
              capabilities
              networkPolicyEnforcer
              peekedPackageMeta
              workloadInterceptors
              clusterCtx
              availability
              ;
            # Subscopes keep the edge registries but drop the DNS root:
            # resources built through a subscope are parented into a foreign
            # namespace for emission; DNS readiness ordering belongs to the
            # workloads of the instance that owns the namespace, not to
            # resources a caller plants there.
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
        inherit mkJob mkHelmWorkload;

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
