{ lib }:

let
  kixAnnotations = import ./annotations.nix;
  kixKeys = kixAnnotations.keys;
in
rec {

  facts = import ./facts.nix { inherit lib; };

  markers = import ./markers.nix { inherit lib; };

  normalize = import ./normalize.nix { inherit lib; };

  clusterScoped = {
    _type = "k8s-cluster-scoped";
    __toString = _: "";
    name = null;
  };

  validKixKeys = [
    "namespace"
    "source"
    "reflected"
    "serviceAccountNamespace"
  ];

  stripKixMeta =
    value:
    if builtins.isAttrs value then
      let
        _kixCheck =
          if value ? _kix then
            let
              unknown = builtins.filter (k: !(builtins.elem k validKixKeys)) (builtins.attrNames value._kix);
            in
            if unknown != [ ] then
              throw "unknown _kix marker key(s): ${builtins.concatStringsSep ", " unknown}. "
              + "Valid keys: ${builtins.concatStringsSep ", " validKixKeys}. "
              + "Check the field names in the fragment that sets _kix."
            else
              null
          else
            null;
      in
      builtins.seq _kixCheck (lib.mapAttrs (_: stripKixMeta) (removeAttrs value [ "_kix" ]))
    else if builtins.isList value then
      map stripKixMeta value
    else
      value;

  attachCtxDeep =
    ctx: value:
    if value == null then
      null
    else if builtins.isString value then
      builtins.appendContext value ctx
    else if builtins.isAttrs value then
      lib.mapAttrs (_: attachCtxDeep ctx) value
    else if builtins.isList value then
      map (attachCtxDeep ctx) value
    else
      builtins.trace "warning: .manifest returned a ${builtins.typeOf value} value. Kix cannot track dependencies through this value; use an out helper or an explicit requires entry" value;

  extractStoreHash =
    path: builtins.substring 11 32 (builtins.unsafeDiscardStringContext (toString path));

  mkImportResource =
    {
      name,
      namespace,
      apiVersion ? "",
      kind ? "",
      spec ? { },
      data ? { },
      stringData ? { },
      labels ? { },
      annotations ? { },
      outputs ? { },
      requires ? [ ],
      extraDeps ? [ ],
      extra ? { },
      clusterDomain ? "cluster.local",
    }:
    let
      isClusterScoped = builtins.isAttrs namespace && (namespace._type or "") == "k8s-cluster-scoped";
      isNsResource = builtins.isAttrs namespace && namespace ? outPath;
      nsKey =
        if isClusterScoped then
          "_cluster_"
        else if isNsResource then
          namespace.name or "ns"
        else
          namespace;

      autoSelector =
        if spec ? selector.matchLabels then
          spec.selector.matchLabels
        else if labels != { } then
          labels
        else
          null;

      # Imported Services with selectors supply endpoint facts for network
      # policy derivation even though Kix does not seal or deploy them.
      _importFactCtx =
        if kind == "Service" && (spec.selector or { }) != { } then
          facts.mkFact "endpoint" {
            inherit name;
            namespace = toString nsKey;
            selector = spec.selector;
            ports = spec.ports or [ ];
          }
        else
          { };

      attachFactCtx = value: builtins.appendContext (toString value) _importFactCtx;

      autoOut = {
        inherit name;
        fqdn = attachFactCtx (if isClusterScoped then name else "${name}.${nsKey}.svc.${clusterDomain}");
      }
      // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      };

      userOut = lib.mapAttrs (
        _: v:
        if facts.isStructural v then
          facts.refOnly (attachFactCtx (toString v.value))
        else
          attachFactCtx (toString v)
      ) outputs;
    in
    {
      _type = "k8s-resource-ref";
      inherit
        name
        namespace
        kind
        apiVersion
        ;
      out = autoOut // userOut;
      factTokens = lib.optionalAttrs (_importFactCtx != { }) { endpoint = _importFactCtx; };
      requires = [ ];
    };

  mkResource =
    {
      apiVersion,
      kind,
      name,
      namespace,
      spec ? { },
      data ? { },
      stringData ? { },
      labels ? { },
      annotations ? { },
      outputs ? { },
      requires ? [ ],
      extraDeps ? [ ],
      # Store files the manifest's store path references without a deploy
      # order (no `kix.run/depends-on` entry), as a store path interpolated
      # into a field would. The Activation record references
      # kix-packages.json this way.
      storeReferences ? [ ],
      extra ? { },
      clusterDomain ? "cluster.local",
      # per-kind terminate/conduct override from the factBehavior index
      # (CRD-owner declared via meta.factBehavior, or cluster override).
      # null = fall back to the core K8s table (facts.conducts).
      factBehavior ? null,
      # Fields another controller takes over once the object exists. Kix
      # sets them at creation; when a later apply meets a field-ownership
      # conflict confined to these paths, deploy applies again without them
      # and the other manager keeps them. A conflict on any other field
      # still fails. `cede` lists paths in the apiserver's own syntax without
      # the leading dot, `*` standing for any list element:
      # `ownership.cede = [ "spec.versions" "webhooks[*].rules" ]`.
      ownership ? { },
    }:
    let
      cede = ownership.cede or [ ];
      _ownershipCheck =
        if builtins.attrNames ownership != (if ownership == { } then [ ] else [ "cede" ]) then
          throw "k8s-resource '${kind}/${name}': ownership takes only `cede`, got ${builtins.toJSON (builtins.attrNames ownership)}"
        else if !(builtins.isList cede) || !(builtins.all builtins.isString cede) then
          throw "k8s-resource '${kind}/${name}': ownership.cede must be a list of field paths, e.g. [ \"spec.versions\" ]"
        else
          null;
      cedeAnnotations = lib.optionalAttrs (cede != [ ]) {
        ${kixAnnotations.keys.cedeFields} = builtins.concatStringsSep "," cede;
      };
      allAnnotations = annotations // cedeAnnotations;

      isClusterScoped = builtins.isAttrs namespace && (namespace._type or "") == "k8s-cluster-scoped";
      isNsResource = builtins.isAttrs namespace && namespace ? outPath;

      nsName =
        if isClusterScoped then
          null
        else if isNsResource then
          builtins.appendContext namespace.name (builtins.getContext "${namespace}")
        else
          namespace;
      nsKey =
        if isClusterScoped then
          "_cluster_"
        else if isNsResource then
          namespace.name or "ns"
        else
          namespace;

      _managedPaths = [
        [ "apiVersion" ]
        [ "kind" ]
        [
          "metadata"
          "name"
        ]
        [
          "metadata"
          "namespace"
        ]
      ]
      ++ lib.optional (spec != { }) [ "spec" ]
      ++ lib.optional (data != { }) [ "data" ]
      ++ lib.optional (stringData != { }) [ "stringData" ];

      _hasPath =
        attrs: path:
        if path == [ ] then
          true
        else if !(builtins.isAttrs attrs) then
          false
        else
          let
            h = builtins.head path;
            t = builtins.tail path;
          in
          (attrs ? ${h}) && (t == [ ] || _hasPath attrs.${h} t);

      _shadowedPaths = builtins.filter (p: _hasPath extra p) _managedPaths;

      _extraShadowCheck =
        if _shadowedPaths != [ ] then
          throw "k8s-resource '${kind}/${name}': extra.* shadows managed field(s) "
          + "${builtins.concatStringsSep ", " (map (p: builtins.concatStringsSep "." p) _shadowedPaths)}. "
          + "Fields under `spec`, `data`, `stringData`, `metadata.{name,namespace,labels,annotations}` "
          + "are set via dedicated args so kix can attach DI tracking. Move your customizations into "
          + "those args (e.g. `spec = { ... }` instead of `extra.spec = { ... }`), or use `extra` only "
          + "for sibling fields kix doesn't manage explicitly."
        else
          null;

      # resolveKeeps runs here so rawManifest (and the identity JSON derived
      # from it) never carries the _kixKeep marker, and so rawManifest
      # consumers see keep-built containers the way they will render.
      rawManifest = builtins.seq _ownershipCheck (
        builtins.seq _extraShadowCheck (
          normalize.resolveKeeps (
            stripKixMeta (
              lib.recursiveUpdate (
                {
                  inherit apiVersion kind;
                  metadata = {
                    inherit name;
                  }
                  // lib.optionalAttrs (nsName != null) { namespace = nsName; }
                  // lib.optionalAttrs (labels != { }) { inherit labels; }
                  // lib.optionalAttrs (allAnnotations != { }) { annotations = allAnnotations; };
                }
                // lib.optionalAttrs (spec != { }) { inherit spec; }
                // lib.optionalAttrs (data != { }) { inherit data; }
                // lib.optionalAttrs (stringData != { }) { inherit stringData; }
              ) extra
            )
          )
        )
      );

      manifestJson = builtins.toJSON rawManifest;

      # Fact tokens and markers carry metadata, not deployable resources.
      # Exclude them from depends-on: their hashes cannot be resolved to
      # manifests by the deploy scheduler.
      implicitCtxPaths = builtins.filter (
        p: lib.hasPrefix "/nix/store/" p && !facts.isFactPath p && !markers.isMarkerPath p
      ) (builtins.attrNames (builtins.getContext manifestJson));
      implicitEntries = map extractStoreHash implicitCtxPaths;

      requiresResources = builtins.filter (dep: builtins.isAttrs dep && dep ? outPath) requires;
      requiresEntries = map (dep: "requires:${extractStoreHash dep}") requiresResources;

      extraResources = builtins.filter (dep: builtins.isAttrs dep && dep ? outPath) extraDeps;
      extraEntries = map (dep: "extra:${extractStoreHash dep}") extraResources;

      depEntries = implicitEntries ++ requiresEntries ++ extraEntries;

      untrackedMarkers = builtins.filter markers.isUntrackedRefPath (
        builtins.attrNames (builtins.getContext manifestJson)
      );

      # A `by = "self"` reference claims this resource creates the object.
      _selfCreatedCheck =
        let
          selfCreated = builtins.filter markers.isSelfCreated untrackedMarkers;
        in
        if selfCreated != [ ] && markers.isPassiveKind { inherit apiVersion kind; } then
          throw "kix.untrackedRef (${(markers.readMarker (builtins.head selfCreated)).name}): `by = \"self\"` is used in ${kind} '${name}', a built-in kind that creates no object a manifest refers to by name. Name the resource that creates it with `by`, or use the string form"
        else
          null;

      # A pod does not start until every object its spec names without
      # `optional = true` exists, so a workload cannot require an object it
      # creates itself. Names passed as args or env values are not checked.
      _selfRequiredCheck =
        let
          lst = x: if builtins.isList x then x else [ ];
          required =
            obj: field: if obj.${field} or null == null || obj.optional or false then [ ] else [ obj.${field} ];
          workloadKinds = {
            v1 = [ "Pod" ];
            "apps/v1" = [
              "Deployment"
              "StatefulSet"
              "DaemonSet"
              "ReplicaSet"
            ];
            "batch/v1" = [
              "Job"
              "CronJob"
            ];
          };
          podSpec =
            if kind == "Pod" then
              rawManifest.spec or { }
            else if kind == "CronJob" then
              rawManifest.spec.jobTemplate.spec.template.spec or { }
            else
              rawManifest.spec.template.spec or { };
          containers = lst (podSpec.containers or [ ]) ++ lst (podSpec.initContainers or [ ]);
          volumeRefs = builtins.concatMap (
            v:
            required (v.secret or { }) "secretName"
            ++ required (v.configMap or { }) "name"
            ++ required (v.persistentVolumeClaim or { }) "claimName"
            ++ builtins.concatMap (
              src: required (src.secret or { }) "name" ++ required (src.configMap or { }) "name"
            ) (lst (v.projected.sources or [ ]))
          ) (lst (podSpec.volumes or [ ]));
          envRefs = builtins.concatMap (
            c:
            builtins.concatMap (
              e:
              required (e.valueFrom.secretKeyRef or { }) "name"
              ++ required (e.valueFrom.configMapKeyRef or { }) "name"
            ) (lst (c.env or [ ]))
            ++ builtins.concatMap (
              ef: required (ef.secretRef or { }) "name" ++ required (ef.configMapRef or { }) "name"
            ) (lst (c.envFrom or [ ]))
          ) containers;
          refs = volumeRefs ++ envRefs ++ required podSpec "serviceAccountName";
          selfRequired = builtins.concatMap markers.selfCreatedNames (builtins.filter builtins.isString refs);
        in
        if !(builtins.elem kind (workloadKinds.${apiVersion} or [ ])) || selfRequired == [ ] then
          null
        else
          throw "kix.untrackedRef (${builtins.head selfRequired}): `by = \"self\"` is used in ${kind} '${name}' where the pod requires the object, and the pod cannot start to create it. Set `optional = true` on the reference if this ${kind} creates it; otherwise name the resource that creates it with `by`";

      # Objects this manifest expects something else to have created: the
      # untracked references that named a kind (core/markers.nix,
      # experimental). Deploy waits for each before applying this resource.
      expectations = builtins.seq _selfCreatedCheck (
        builtins.seq _selfRequiredCheck (
          builtins.filter (e: e != null) (map markers.readExpectation untrackedMarkers)
        )
      );
      expectEntries = lib.unique (map (e: "${e.apiVersion}|${e.kind}|${e.name}") expectations);

      stampedAnnotations =
        lib.optionalAttrs (depEntries != [ ]) {
          ${kixKeys.dependsOn} = builtins.concatStringsSep "," depEntries;
        }
        // lib.optionalAttrs (expectEntries != [ ]) {
          ${kixKeys.expects} = builtins.concatStringsSep "," expectEntries;
        };

      rawManifestStamped =
        if stampedAnnotations == { } then
          rawManifest
        else
          lib.recursiveUpdate rawManifest { metadata.annotations = stampedAnnotations; };

      manifestJsonStamped = builtins.toJSON rawManifestStamped;

      allDeps = requires ++ extraDeps;
      depContexts = builtins.foldl' (
        acc: dep: if builtins.isAttrs dep && dep ? outPath then acc // builtins.getContext "${dep}" else acc
      ) { } allDeps;

      storeReferenceContexts = builtins.foldl' (
        acc: file: acc // builtins.getContext "${file}"
      ) { } storeReferences;

      manifestJsonWithDeps = builtins.appendContext manifestJsonStamped (
        depContexts // storeReferenceContexts
      );

      # Forward facts from manifest values through out.* for conducting
      # resources. manifestJsonSealed removes fact tokens from store references
      # while retaining resource identity context for deployment ordering.
      #
      # Read manifestJson here, before adding requires/extraDeps context.
      # Reading manifestJsonWithDeps would force explicit dependencies' seals
      # when an output is accessed. That can recurse when a Service's name
      # appears in a webhook config and the Service requires its consumer.
      _conducts =
        if factBehavior != null then
          (factBehavior.endpoint or "conduct") == "conduct"
        else
          facts.conducts kind;

      _forwardedFactCtx =
        if _conducts then (facts.partitionCtx (builtins.getContext manifestJson)).facts else { };

      # The netpol instance processor uses these endpoint payloads to build
      # policies for pods selected by a terminating CR's podSelector.
      # Keep this lazy until the processor reads it.
      _absorbedEndpointFacts =
        if factBehavior != null && (factBehavior.endpoint or "") == "terminate" then
          facts.factsOfKind "endpoint" manifestJson
        else
          [ ];

      # Without factBehavior, a custom kind forwards endpoint facts by default.
      # Warn when it absorbs an endpoint so the author can declare whether its
      # controller's pods connect to it. Emit the warning when outPath is forced.
      _undeclaredCrWarning =
        if
          factBehavior == null
          && facts.isForeignGroup apiVersion
          && facts.factsOfKind "endpoint" manifestJson != [ ]
        then
          "kix: ${kind}/${name} (${apiVersion}) references a Service address but does not declare how its controller uses it. "
          + "Kix assumes endpoint = \"conduct\" (the resource passes the address "
          + "to other resources). If pods created by this controller connect to the address "
          + "directly, build the custom resource with `scope.mkCR <owner>.out.crds.<kind>` "
          + "and declare `factBehavior = { endpoint = \"terminate\"; podSelector = cr: "
          + "{ ... }; }` on the owner's mkCRD/mkCRDRef. For resources built without a typed builder (Helm or "
          + "raw kind strings), set `cluster.factBehavior.\"<group>/${kind}\"`."
        else
          null;

      manifestJsonSealed = builtins.appendContext (builtins.unsafeDiscardStringContext manifestJsonWithDeps) (facts.partitionCtx (
        builtins.getContext manifestJsonWithDeps
      )).rest;

      # toFile requires a context-free filename. Retain dependency context in
      # the file content, and replace colons that Nix store names cannot contain.
      sanitizedName = builtins.unsafeDiscardStringContext (builtins.replaceStrings [ ":" ] [ "_" ] name);
      sanitizedNsKey = builtins.unsafeDiscardStringContext (toString nsKey);

      _identityPath = builtins.toFile "k8s-${kind}-${sanitizedNsKey}-${sanitizedName}" manifestJsonSealed;

      _identityPathPlain = builtins.unsafeDiscardStringContext _identityPath;

      _identityCtx = builtins.getContext "${_identityPath}";

      # A selector-based Service supplies endpoint facts for its backend pods.
      # ExternalName Services do not select pods.
      _isEndpointProducer =
        kind == "Service"
        && (rawManifest.spec.selector or { }) != { }
        && (rawManifest.spec.type or "ClusterIP") != "ExternalName";

      _ownFactCtx =
        if _isEndpointProducer then
          facts.mkFact "endpoint" {
            name = builtins.unsafeDiscardStringContext name;
            namespace = builtins.unsafeDiscardStringContext (toString nsKey);
            selector = rawManifest.spec.selector;
            ports = rawManifest.spec.ports or [ ];
          }
        else
          { };

      # Both helpers attach resource identity and forwarded facts.
      # attachConnectCtx also attaches this Service's endpoint fact to address
      # outputs (fqdn, url, and unmarked user outputs). Names and selectors use
      # attachCtx. Callers can use facts.refOnly for a non-address use, or
      # producers can mark such outputs with facts.structural.
      attachCtx = value: builtins.appendContext (toString value) (_identityCtx // _forwardedFactCtx);
      attachConnectCtx =
        value: builtins.appendContext (toString value) (_identityCtx // _forwardedFactCtx // _ownFactCtx);

      autoSelector =
        if rawManifest ? spec.selector.matchLabels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.spec.selector.matchLabels
        else if rawManifest ? metadata.labels then
          lib.mapAttrs (_: v: attachCtx (toString v)) rawManifest.metadata.labels
        else
          null;

      autoOut = {
        name = attachCtx name;
        fqdn =
          if isClusterScoped then
            attachConnectCtx name
          else
            attachConnectCtx "${name}.${nsKey}.svc.${clusterDomain}";
        identityHash = attachCtx (extractStoreHash _identityPathPlain);
      }
      // lib.optionalAttrs (autoSelector != null) {
        selector = autoSelector;
      }
      // lib.optionalAttrs (kind == "Service" && rawManifest ? spec.ports) {
        ports = rawManifest.spec.ports;

        url =
          {
            scheme ? "http",
            port ? null,
          }:
          let
            firstPort =
              if rawManifest.spec.ports != [ ] then (builtins.head rawManifest.spec.ports).port or null else null;
            effectivePort = if port != null then port else firstPort;
            portSuffix = if effectivePort != null then ":${toString effectivePort}" else "";
          in
          attachConnectCtx "${scheme}://${name}.${nsKey}.svc.${clusterDomain}${portSuffix}";
      };

      userOut = lib.mapAttrs (
        _: v:
        if v == null then
          null
        else if facts.isStructural v then
          # Retain ordering context without declaring an endpoint connection.
          facts.refOnly (attachConnectCtx (toString v.value))
        else
          attachConnectCtx (toString v)
      ) outputs;

      mergedOut =
        let
          combined = autoOut // userOut;
        in
        lib.filterAttrs (_: v: v != null) combined;

      self = {
        _type = "k8s-resource";
        inherit
          apiVersion
          kind
          name
          namespace
          requires
          extraDeps
          ;

        outPath =
          if _undeclaredCrWarning != null then
            builtins.trace _undeclaredCrWarning _identityPath
          else
            _identityPath;

        out = mergedOut;

        # Endpoint context available to callers of facts.connect.
        factTokens = lib.optionalAttrs _isEndpointProducer { endpoint = _ownFactCtx; };

        # The netpol instance processor uses podSelector and absorbed endpoint
        # facts to derive policies for pods created by custom controllers.
        inherit factBehavior;
        absorbedEndpointFacts = _absorbedEndpointFacts;

        rawManifest = rawManifestStamped;

        manifest = attachCtxDeep (_identityCtx // _forwardedFactCtx) rawManifestStamped;
      };
    in
    self;

  mkSecretHelpers =
    {
      name,
      keys,
      type,
      attachCtx,
      namespace,
      reflected ? false,
    }:
    let
      ctxName = attachCtx name;
      kixMeta = {
        _kix = {
          inherit namespace;
          source = "secret";
        }
        // lib.optionalAttrs reflected { reflected = true; };
      };
      helpers = {
        inherit keys type;

        keyRef =
          key:
          if !(builtins.elem key keys) then
            throw "secret \"${name}\" does not declare key \"${key}\"\n  declared keys: ${builtins.concatStringsSep ", " keys}"
          else
            {
              valueFrom.secretKeyRef = {
                name = ctxName;
                inherit key;
              };
            }
            // kixMeta;

        mkEnv =
          mapping:
          lib.mapAttrsToList (envName: secretKey: (helpers.keyRef secretKey) // { name = envName; }) mapping;

        envFrom = {
          secretRef = {
            name = ctxName;
          };
        }
        // kixMeta;

        volume =
          volName:
          {
            name = volName;
            secret = {
              secretName = ctxName;
            };
          }
          // kixMeta;
      };
    in
    helpers;

  mkKixCRD =
    {
      kind,
      plural,
      scope ? "Namespaced",
    }:
    mkResource {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      name = "${plural}.${kixAnnotations.group}";
      namespace = clusterScoped;
      labels = {
        "app.kubernetes.io/managed-by" = "kix";
      };
      extra.spec = {
        group = kixAnnotations.group;
        inherit scope;
        names = {
          inherit kind plural;
          singular = lib.toLower kind;
          listKind = "${kind}List";
        };
        versions = [
          {
            name = "v1alpha1";
            served = true;
            storage = true;
            subresources.status = { };
            schema.openAPIV3Schema = {
              type = "object";
              properties = {
                apiVersion.type = "string";
                kind.type = "string";
                metadata.type = "object";
                spec = {
                  type = "object";
                  "x-kubernetes-preserve-unknown-fields" = true;
                };
                status = {
                  type = "object";
                  "x-kubernetes-preserve-unknown-fields" = true;
                };
              };
            };
          }
        ];
      };
    };

  kixCRDs = {
    packageInstance = mkKixCRD {
      kind = "PackageInstance";
      plural = "packageinstances";
    };
    activation = mkKixCRD {
      kind = "Activation";
      plural = "activations";
      scope = "Cluster";
    };
  };

  nsOf =
    r:
    if r.namespace or null == null then
      "_cluster_"
    else if builtins.isAttrs r.namespace then
      if (r.namespace._type or "") == "k8s-cluster-scoped" then
        "_cluster_"
      else
        r.namespace.name or "_cluster_"
    else
      r.namespace;

  resourceId = r: "${r.kind}/${r.name}@${nsOf r}";

  # Validate { path; equals; }, allowing null to omit a readiness declaration.
  # mkCRD/mkCRDRef force this at declaration time so malformed declarations
  # fail even when the package builds no custom resources of that kind.
  validateReadiness =
    context: groupKind: readiness:
    let
      isPathForm =
        builtins.isAttrs readiness
        &&
          builtins.attrNames readiness == [
            "equals"
            "path"
          ]
        && builtins.isString readiness.path
        && lib.hasPrefix "/" readiness.path
        && builtins.isString readiness.equals;
      isPathNotForm =
        builtins.isAttrs readiness
        &&
          builtins.attrNames readiness == [
            "notEquals"
            "path"
          ]
        && builtins.isString readiness.path
        && lib.hasPrefix "/" readiness.path
        && builtins.isString readiness.notEquals;
      isConditionForm =
        builtins.isAttrs readiness
        && builtins.attrNames readiness == [ "condition" ]
        && builtins.isAttrs readiness.condition
        &&
          builtins.attrNames readiness.condition == [
            "status"
            "type"
          ]
        && builtins.isString readiness.condition.type
        && builtins.isString readiness.condition.status;
    in
    if readiness == null then
      null
    else if !(isPathForm || isPathNotForm || isConditionForm) then
      throw ''
        ${context}: readiness declaration for ${groupKind} must be one of
          { path = "/status/..."; equals = "<value>"; }
          { path = "/status/..."; notEquals = "<value>"; }
          { condition = { type = "<Type>"; status = "True"; }; }
        (path: a JSON pointer string starting with "/"; every value a string,
        and equals = "true" or "3" also matches a JSON true or 3 at the path;
        notEquals is ready while the path is absent or holds another value;
        no other keys)
      ''
    else
      readiness;

  mkCRDBuilders =
    {
      crdOrRef,
      group,
      kind,
      version,
      # Versions the CRD serves. `cr` refuses any other, so a wrong version
      # fails the build instead of every apply of the custom resource.
      servedVersions,
      # The declaration the kind comes from, such as
      # "scope.mkCRDRef in ns/instance". Unserved-version errors name it.
      declaredBy,
      # Appended to the unserved-version message when the declaration, not
      # the custom resource, may be what is wrong. Null when the served
      # versions come from a CustomResourceDefinition spec.
      unservedFix ? null,
      crdScope,
      # Appended to every CR's `requires` after the CRD (a chart's workloads,
      # any of which can be the CRD's webhook).
      extraRequires ? [ ],
      # Validated behavior to pass to each CR for endpoint fact handling.
      factBehavior ? null,
      # Stamp kix.run/readiness on each CR for the CLI to evaluate at deploy.
      # Use this for operators with conditions other than Ready/Available.
      # Three shapes:
      #   readiness = { path = "/status/updateStatus"; equals = "operational"; }
      #   readiness = { path = "/status/updateStatus"; notEquals = "failed"; }
      #   readiness = { condition = { type = "Bootstrapped"; status = "True"; }; }
      # path is a JSON pointer into the live object; readiness requires its
      # value to equal the string in equals, or, for a JSON boolean or
      # number, its JSON text to equal it: `equals = "true"` matches
      # `true`. notEquals is ready while the path is absent or holds any
      # other value, for a resource whose status only a consumer writes
      # when the consumer may not exist. The condition form requires an
      # entry in status.conditions whose type and status both match. Every
      # form waits while the operator's observedGeneration
      # (status.observedGeneration for a path; for a condition, its own,
      # else status.observedGeneration) is below metadata.generation, and
      # imposes no such wait when it is absent.
      readiness ? null,
    }:
    let
      crKind = kind;

      _validatedReadiness = validateReadiness "mkCRDBuilders" "${group}/${kind}" readiness;

      # A CR can override the default version, normally the CRD's storage
      # version, with another served one. `consumer` is "ns/instance" when
      # the CR is built through mkCR, null when through `cr` directly.
      checkServed =
        consumer: args: v:
        if builtins.elem v servedVersions then
          v
        else
          throw (
            "${crKind} ${builtins.toJSON (args.name or null)}"
            + lib.optionalString (consumer != null) " in ${consumer}"
            + ": version \"${v}\" is not one that ${declaredBy} lists as served for ${group}/${crKind} ("
            + builtins.concatStringsSep ", " servedVersions
            + "). Set version on the custom resource to one of these, or leave it unset for ${version}."
            + lib.optionalString (unservedFix != null) " ${unservedFix}"
          );

      crFor =
        consumer: args:
        removeAttrs args [ "version" ]
        // {
          apiVersion = "${group}/${checkServed consumer args (args.version or version)}";
          kind = crKind;
          requires = (args.requires or [ ]) ++ [ crdOrRef ] ++ extraRequires;
        }
        // lib.optionalAttrs (factBehavior != null) { inherit factBehavior; }
        // lib.optionalAttrs (_validatedReadiness != null) {
          annotations = (args.annotations or { }) // {
            ${kixKeys.readiness} = builtins.toJSON _validatedReadiness;
          };
        };

      cr = crFor null;

      mkCR =
        consumerScope: args:
        let
          consumer =
            if consumerScope ? namespaceName && consumerScope ? instanceName then
              "${consumerScope.namespaceName}/${consumerScope.instanceName}"
            else
              null;
          enriched = crFor consumer args;
        in
        if crdScope == "Cluster" then
          consumerScope.mkClusterResource enriched
        else
          consumerScope.mkResource enriched;
    in
    {
      inherit cr mkCR;
    };

  # A PackageInstance in import mode: a placeholder for an object Kix does
  # not create, which the deploy waits for. `mkResource` is the caller's
  # builder; it supplies the namespace and the labels.
  mkImportMarker =
    { mkResource, namespaceName }:
    {
      markerName,
      importKind,
      importApiVersion,
      importName,
      extraAnnotations ? { },
      extraRequires ? [ ],
    }:
    mkResource {
      apiVersion = kixAnnotations.apiVersion;
      kind = "PackageInstance";
      name = markerName;
      annotations = {
        ${kixKeys.mode} = "import";
        ${kixKeys.importKind} = importKind;
        ${kixKeys.importApiVersion} = importApiVersion;
        ${kixKeys.importName} = importName;
      }
      // extraAnnotations;
      requires = [ kixCRDs.packageInstance ] ++ extraRequires;
      extra.spec = {
        instanceName = markerName;
        namespaceName = namespaceName;
        mode = "import";
      };
    };

  # A handle for a CRD that something other than Kix installs: an import
  # marker for the CustomResourceDefinition plus the `cr`/`mkCR` builders.
  # scope.mkCRDRef and `kix.mkImport { crds }` both build it, with their own
  # `mkResource`, so a CR built from either handle requires the same kind of
  # marker. `site` names the declaration in error messages.
  mkCRDRefHandle =
    {
      mkResource,
      instanceName,
      namespaceName,
      site ? "scope.mkCRDRef",
    }:
    {
      group,
      kind,
      plural,
      # The API version custom resources of this kind use by default.
      # Required: Kix does not install the CRD, so it cannot read the
      # version from a spec.
      version ? null,
      # Every API version the CRD serves for this kind that custom resources
      # may name. Must include `version`. Defaults to `[ version ]`.
      servedVersions ? null,
      crdScope ? "Namespaced",
      installedBy ? null,
      # Endpoint handling for this kind's controller. mkCR passes it to
      # each custom resource seal.
      factBehavior ? null,
      # Readiness condition stamped on each CR as kix.run/readiness and
      # validated while evaluating the declaring instance.
      readiness ? null,
    }:
    let
      declaration = "${site} in ${namespaceName}/${instanceName}";
      who = "${site} ${group}/${kind} in ${namespaceName}/${instanceName}";
      isApiVersion = v: builtins.isString v && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" v != null;
      _validatedVersion =
        if version == null then
          throw "${who}: set version to the API version the CustomResourceDefinition serves for this kind (for example \"v1\" or \"v1beta1\"). Kix does not install this CRD, so it cannot read the version, and a wrong one fails every apply of this kind."
        else if !(isApiVersion version) then
          throw "${who}: version ${builtins.toJSON version} is not an API version. Kubernetes API versions are lowercase RFC 1035 labels, such as \"v1\" or \"v1beta1\"."
        else
          version;
      _validatedServed =
        let
          listed = if servedVersions == null then [ _validatedVersion ] else servedVersions;
          invalid = builtins.filter (v: !(isApiVersion v)) listed;
        in
        if !(builtins.isList listed) then
          throw "${who}: servedVersions is a list of API versions, such as [ \"v1\" \"v1beta1\" ]; got ${builtins.typeOf listed}."
        else if invalid != [ ] then
          throw "${who}: servedVersions entries ${builtins.toJSON invalid} are not API versions. Kubernetes API versions are lowercase RFC 1035 labels, such as \"v1\" or \"v1beta1\"."
        else if !(builtins.elem _validatedVersion listed) then
          throw "${who}: servedVersions ${builtins.toJSON listed} does not include version \"${_validatedVersion}\". Add it, or set version to one of the listed versions."
        else
          lib.unique listed;
      _validatedScope =
        if crdScope == "Namespaced" || crdScope == "Cluster" then
          crdScope
        else
          throw "${who}: crdScope is ${builtins.toJSON crdScope}; use \"Namespaced\" or \"Cluster\", as the CustomResourceDefinition's spec.scope says.";
      _validatedReadiness = validateReadiness declaration "${group}/${kind}" readiness;
      _validatedBehavior =
        if factBehavior != null then
          facts.validateBehavior declaration "${group}/${kind}" factBehavior
        else
          null;
      crdName = "${plural}.${group}";
      groupSlug = builtins.replaceStrings [ "." ] [ "-" ] group;
      # Per instance, as secret and service refs are: two instances in one
      # namespace that reference the same CRD get two markers, and each
      # marker names the instance that declared it.
      markerName = "crd-ref-${instanceName}-${plural}-${groupSlug}";

      installedByList =
        if installedBy == null then
          [ ]
        else if builtins.isList installedBy then
          installedBy
        else
          [ installedBy ];

      _validated = builtins.seq _validatedServed (builtins.seq _validatedScope _validatedReadiness);

      marker = builtins.seq _validated (
        mkImportMarker { inherit mkResource namespaceName; } {
          inherit markerName;
          importKind = "CustomResourceDefinition";
          importApiVersion = "apiextensions.k8s.io/v1";
          importName = crdName;
          extraAnnotations = {
            ${kixKeys.crdKind} = kind;
            ${kixKeys.crdVersion} = _validatedVersion;
            ${kixKeys.crdScope} = _validatedScope;
            ${kixKeys.crdServedVersions} = builtins.concatStringsSep "," _validatedServed;
          };
          extraRequires = installedByList;
        }
      );

      crdBuilders = mkCRDBuilders {
        crdOrRef = marker;
        factBehavior = _validatedBehavior;
        readiness = _validatedReadiness;
        version = _validatedVersion;
        servedVersions = _validatedServed;
        crdScope = _validatedScope;
        declaredBy = declaration;
        unservedFix = "If the CustomResourceDefinition serves it, add it to that declaration's servedVersions.";
        inherit group kind;
      };
    in
    marker
    // {
      out = marker.out // crdBuilders;
    };

}
