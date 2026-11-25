{ lib }:

let
  inherit (import ./error.nix { inherit lib; }) fail;
  kixAnnotations = import ./annotations.nix;
  kixKeys = kixAnnotations.keys;
in
rec {

  # Return the entries of a `requires` or `extraDeps` list that are
  # resources. Kix skips the other entries, such as strings.
  resourcesIn = builtins.filter (dep: builtins.isAttrs dep && dep ? outPath);

  facts = import ./facts.nix { inherit lib; };

  markers = import ./markers.nix { inherit lib; };

  normalize = import ./normalize.nix { inherit lib; };

  podSpecReader = import ./pod-spec.nix { inherit lib; };
  workloadKinds = import ./workload-kinds.nix { inherit lib; };
  util = import ./util.nix { inherit lib; };

  # Return the name of the store file that holds a resource's sealed
  # manifest. `podReadContentHashes` finds a Kix-built object by this name in
  # the string context of a reference to it.
  identityFilePrefix = kind: "k8s-${kind}-";
  identityFileName =
    kind: nsKey: name:
    "${identityFilePrefix kind}${nsKey}-${name}";

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
              fail {
                message = "resource manifest contains an internal `_kix` attribute with unknown key(s): ${builtins.concatStringsSep ", " unknown} (expected only: ${builtins.concatStringsSep ", " validKixKeys}).";
                fix = "Remove `_kix` from your manifest data, or if you are constructing a reference helper fragment, use only the keys above.";
              }
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

  # Attach `ctx` to every string in `value`. A number or a boolean cannot
  # carry string context, so a consumer that reads one from `.manifest`
  # gets no dependency on the resource.
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
      value;

  extractStoreHash =
    path: builtins.substring 11 32 (builtins.unsafeDiscardStringContext (toString path));

  # Return the SHA-256 of a manifest's own content, which `out.contentHash`
  # carries. It leaves out every `kix.run/*` annotation and label except
  # `kixAnnotations.contentKeys`, and drops the string context that records
  # dependencies. A change below the resource in the graph, or a new Kix
  # annotation, therefore leaves the hash unchanged.
  contentHashOf =
    manifest:
    let
      isKixKey =
        k: lib.hasPrefix "${kixAnnotations.domain}/" k && !(builtins.elem k kixAnnotations.contentKeys);
      ownEntries = attrs: lib.filterAttrs (k: _: !(isKixKey k)) attrs;
      metadata = manifest.metadata or { };
      ownMetadata =
        removeAttrs metadata [
          "annotations"
          "labels"
        ]
        // lib.optionalAttrs (ownEntries (metadata.annotations or { }) != { }) {
          annotations = ownEntries metadata.annotations;
        }
        // lib.optionalAttrs (ownEntries (metadata.labels or { }) != { }) {
          labels = ownEntries metadata.labels;
        };
    in
    builtins.hashString "sha256" (
      builtins.unsafeDiscardStringContext (builtins.toJSON (manifest // { metadata = ownMetadata; }))
    );

  # Return the own content hash of each Kix-built Secret and ConfigMap that
  # `podSpec` reads, keyed by `<kind>/<name>`. A reference names a Kix-built
  # object when its string context carries that object's identity file, which
  # holds the object's sealed manifest. A Secret from `mkSecretRef` carries an
  # import marker instead, and a plain string carries no context, so Kix does
  # not know their content and leaves them out.
  podReadContentHashes =
    podSpec:
    builtins.listToAttrs (
      builtins.concatMap (
        read:
        let
          plainName = builtins.unsafeDiscardStringContext read.name;
          files = builtins.filter (p: lib.hasPrefix (identityFilePrefix read.kind) (markers.pathName p)) (
            builtins.attrNames (builtins.getContext read.name)
          );
          manifests = builtins.filter (
            m:
            (m.apiVersion or null) == "v1"
            && (m.kind or null) == read.kind
            && (m.metadata.name or null) == plainName
          ) (map (p: builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile p))) files);
        in
        map (m: lib.nameValuePair "${read.kind}/${plainName}" (contentHashOf m)) manifests
      ) (builtins.filter (read: builtins.isString read.name) (podSpecReader.reads podSpec))
    );

  # Return the `kix.run/rerun-hash` of a manifest. It is the manifest's own
  # content hash, folded with the content hashes of the Kix-built Secrets and
  # ConfigMaps its pod reads, so a Job reruns when any of them changes. A
  # manifest whose pod reads none of them keeps its own content hash.
  rerunHashOf =
    manifest:
    let
      own = contentHashOf manifest;
      reads = podReadContentHashes (podSpecReader.podSpecOf manifest);
    in
    if reads == { } then own else builtins.hashString "sha256" (builtins.toJSON { inherit own reads; });

  # Return whether a manifest holds data, as `kix.run/holds-data` records it:
  # `declared` (the kind's `holdsData`) when it is set, true for a
  # PersistentVolumeClaim, a PersistentVolume, or a StatefulSet with volume
  # claim templates, and null otherwise. Other built-in kinds stay unmarked
  # because the CLI's storage-shape fallback already reads them as holding
  # no data, and a "false" mark would change every object's identity hash.
  holdsDataOf =
    declared: manifest:
    let
      apiVersion = manifest.apiVersion or "";
      kind = manifest.kind or "";
    in
    if declared != null then
      declared
    else if
      apiVersion == "v1"
      && builtins.elem kind [
        "PersistentVolumeClaim"
        "PersistentVolume"
      ]
    then
      true
    else if
      apiVersion == "apps/v1"
      && kind == "StatefulSet"
      && (manifest.spec.volumeClaimTemplates or [ ]) != [ ]
    then
      true
    else
      null;

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
      # Store paths referenced by the sealed manifest without adding a
      # `kix.run/depends-on` entry (such as `kix-packages.json` on Activation).
      storeReferences ? [ ],
      extra ? { },
      clusterDomain ? "cluster.local",
      # Per-kind endpoint fact behavior from the CRD declaration or
      # `cluster.factBehavior`. Null falls back to `facts.conducts`.
      factBehavior ? null,
      # Function `cr: { <ResourceQuota key> = <quantity>; }` from the CRD
      # declaration, or null. `buildCluster` calls it on the rendered manifest
      # to check namespace ResourceQuotas.
      usesAtLeast ? null,
      # Set only by the typed CRD builders (`cr` and `mkCR`), not by packages:
      # `{ declaredBy; holdsData; controllers; }`, the declaration the kind
      # comes from, its `holdsData` (a boolean or null), and the workloads
      # that handle it. `holdsData` is written as `kix.run/holds-data` (see
      # `holdsDataOf`), and each controller as a `controller:` entry of
      # `kix.run/depends-on`.
      _crd ? null,
      # Field paths (`ownership.cede = [ "spec.versions" "webhooks[*].rules" ]`)
      # that another controller takes over after creation. When a subsequent
      # apply hits a field-ownership conflict limited to these paths, deploy
      # retries without them.
      ownership ? { },
    }:
    let
      holdsData = if _crd == null then null else _crd.holdsData;
      cede = ownership.cede or [ ];
      _ownershipCheck =
        if builtins.attrNames ownership != (if ownership == { } then [ ] else [ "cede" ]) then
          fail "k8s-resource '${kind}/${name}': ownership takes only `cede`, got ${builtins.toJSON (builtins.attrNames ownership)}"
        else if !(builtins.isList cede) || !(builtins.all builtins.isString cede) then
          fail "k8s-resource '${kind}/${name}': ownership.cede must be a list of field paths, e.g. [ \"spec.versions\" ]"
        else if holdsData != null && !(facts.isForeignGroup apiVersion) then
          fail {
            message = "k8s-resource '${kind}/${name}': ${_crd.declaredBy} declares holdsData for ${apiVersion}, a group whose kinds Kix treats as built-in. Kix decides whether those hold data from their shape.";
            fix = "Remove holdsData from that declaration.";
          }
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
          let
            topArgs = builtins.concatStringsSep ", " (lib.unique (map (p: builtins.head p) _shadowedPaths));
          in
          fail {
            message = "${kind} '${name}': extra sets ${
              builtins.concatStringsSep ", " (map (p: "extra.${builtins.concatStringsSep "." p}") _shadowedPaths)
            }, which conflicts with the top-level ${topArgs} argument on this builder call.";
            fix = "Move those fields into the top-level ${topArgs} argument (for example, `spec = { ... };` instead of `extra.spec = { ... };`), and use `extra` only for top-level manifest fields that have no dedicated builder argument.";
          }
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

      # Exclude fact tokens and markers from `kix.run/depends-on` because their
      # store hashes do not correspond to deployable manifests.
      implicitCtxPaths = builtins.filter (
        p: lib.hasPrefix "/nix/store/" p && !facts.isFactPath p && !markers.isMarkerPath p
      ) (builtins.attrNames (builtins.getContext manifestJson));
      implicitEntries = map extractStoreHash implicitCtxPaths;

      # A custom resource's controllers are in `requires` too. Their entries
      # say `controller:` instead of `requires:`, so the deploy can name the
      # controller when the resource's delete does not finish.
      controllerHashes = map extractStoreHash (
        resourcesIn (if _crd == null then [ ] else _crd.controllers or [ ])
      );
      controllerEntries = map (hash: "controller:${hash}") controllerHashes;
      requiresResources = resourcesIn requires;
      requiresEntries = map (hash: "requires:${hash}") (
        builtins.filter (hash: !(builtins.elem hash controllerHashes)) (
          map extractStoreHash requiresResources
        )
      );

      extraResources = resourcesIn extraDeps;
      extraEntries = map (dep: "extra:${extractStoreHash dep}") extraResources;

      depEntries = implicitEntries ++ requiresEntries ++ controllerEntries ++ extraEntries;

      untrackedMarkers = builtins.filter markers.isUntrackedRefPath (
        builtins.attrNames (builtins.getContext manifestJson)
      );

      # A `by = "self"` reference claims this resource creates the object.
      _selfCreatedCheck =
        let
          selfCreated = builtins.filter markers.isSelfCreated untrackedMarkers;
        in
        if selfCreated != [ ] && markers.isPassiveKind { inherit apiVersion kind; } then
          fail {
            message = "kix.untrackedRef (${(markers.readMarker (builtins.head selfCreated)).name}): `by = \"self\"` is used in ${kind} '${name}', a built-in kind that creates no object a manifest refers to by name.";
            fix = "Name the resource that creates it with `by`, or use the string form.";
          }
        else
          null;

      # A pod does not start until every object its spec names without
      # `optional = true` exists, so a workload cannot require an object it
      # creates itself. Names passed as args or env values are not checked.
      _selfRequiredCheck =
        let
          lst = util.listOr;
          required =
            obj: field: if obj.${field} or null == null || obj.optional or false then [ ] else [ obj.${field} ];
          podSpec = podSpecReader.podSpecOf rawManifest;
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
        if !(workloadKinds.isPodKind { inherit apiVersion kind; }) || selfRequired == [ ] then
          null
        else
          fail {
            message = "kix.untrackedRef (${builtins.head selfRequired}): `by = \"self\"` is used in ${kind} '${name}' where the pod requires the object, and the pod cannot start to create it.";
            fix = "Set `optional = true` on the reference if this ${kind} creates it; otherwise name the resource that creates it with `by`.";
          };

      # External objects declared via `kix.untrackedRef` with a `kind`, which
      # deploy waits for before applying this resource.
      expectations = builtins.seq _selfCreatedCheck (
        builtins.seq _selfRequiredCheck (
          builtins.filter (e: e != null) (map markers.readExpectation untrackedMarkers)
        )
      );
      expectEntries = lib.unique (map (e: "${e.apiVersion}|${e.kind}|${e.name}") expectations);

      holdsDataMark = holdsDataOf holdsData rawManifest;

      stampedAnnotations =
        lib.optionalAttrs (holdsDataMark != null) {
          ${kixKeys.holdsData} = lib.boolToString holdsDataMark;
        }
        // lib.optionalAttrs (depEntries != [ ]) {
          ${kixKeys.dependsOn} = builtins.concatStringsSep "," depEntries;
        }
        // lib.optionalAttrs (expectEntries != [ ]) {
          ${kixKeys.expects} = builtins.concatStringsSep "," expectEntries;
        }
        // lib.optionalAttrs ((rawManifest.metadata.annotations or { }) ? ${kixKeys.rerun}) {
          ${kixKeys.rerunHash} = rerunHashOf rawManifest;
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
      # controller's pods connect to it.
      _undeclaredCrWarning =
        if
          factBehavior == null
          && facts.isForeignGroup apiVersion
          && facts.factsOfKind "endpoint" manifestJson != [ ]
        then
          {
            object = { inherit kind name; };
            message =
              "${kind}/${name} (${apiVersion}) references a Service address without declaring whether pods for this resource connect to that Service (`factBehavior`). "
              + "Kix assumed this resource only passes the address on (`endpoint = \"conduct\"`). "
              + "When network policies are enabled, Kix does not allow pods for this resource to connect to that Service.";
            fix =
              "Set `cluster.factBehavior.\"<group>/${kind}\"` in the cluster definition (for Helm charts or raw manifests), or set `factBehavior` on `scope.mkCRD` or `scope.mkCRDRef` and build the resource with `scope.mkCR <owner>.out.crds.<kind>`. "
              + "Use `{ endpoint = \"terminate\"; podSelector = cr: "
              + "{ ... }; }` if pods for this resource connect to the Service, or `{ endpoint = \"conduct\"; }` if the resource only passes the address on.";
          }
        else
          null;

      manifestJsonSealed = builtins.appendContext (builtins.unsafeDiscardStringContext manifestJsonWithDeps) (facts.partitionCtx (
        builtins.getContext manifestJsonWithDeps
      )).rest;

      # toFile requires a context-free filename. Retain dependency context in
      # the file content, and replace colons that Nix store names cannot contain.
      sanitizedName = builtins.unsafeDiscardStringContext (builtins.replaceStrings [ ":" ] [ "_" ] name);
      sanitizedNsKey = builtins.unsafeDiscardStringContext (toString nsKey);

      _identityPath = builtins.toFile (identityFileName kind sanitizedNsKey
        sanitizedName
      ) manifestJsonSealed;

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
        # Carries the same dependency as identityHash, so a pod template
        # annotation built from it still orders the workload after this
        # resource.
        contentHash = attachCtx (contentHashOf rawManifest);
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

        outPath = _identityPath;

        # Warnings about this resource, which `eval/instance.nix` adds to the
        # instance's diagnostics. The scope's builders append their own.
        _warnings = lib.optional (_undeclaredCrWarning != null) _undeclaredCrWarning;

        out = mergedOut;

        # Endpoint context available to callers of facts.connect.
        factTokens = lib.optionalAttrs _isEndpointProducer { endpoint = _ownFactCtx; };

        # The netpol instance processor uses podSelector and absorbed endpoint
        # facts to derive policies for pods created by custom controllers.
        inherit factBehavior usesAtLeast;
        # The `holdsData` this object was built with (the kind's declaration,
        # or null) and the declaration it came from (null when the object was
        # not built through `cr` or `mkCR`). `buildCluster` refuses a stateful
        # package's custom resources that have no `holdsData` and names the
        # declaration to change.
        declaredHoldsData = holdsData;
        crdDeclaredBy = if _crd == null then null else _crd.declaredBy;
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
            fail "secret \"${name}\" does not declare key \"${key}\"\n  declared keys: ${builtins.concatStringsSep ", " keys}"
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

  # Validate a readiness declaration, allowing null to omit it. The ready
  # rule is { path; equals; }, { path; notEquals; }, or { condition; }. Three
  # optional keys sit beside it:
  # - `failed` lists the states that mean the custom resource will not become
  #   ready until its spec changes, so `kix deploy` stops waiting as soon as
  #   one matches.
  # - `observedGeneration` is the JSON pointer of the status field where the
  #   controller reports the generation it has acted on, or false when the
  #   kind reports none. The deploy reads `/status/observedGeneration` when it
  #   is absent.
  # - `pendingRestart` names the state in which the controller has accepted
  #   the spec and the running workload still runs the previous one. The
  #   deploy then reports the resource as ready with a restart pending.
  # mkCRD/mkCRDRef force this at declaration time so malformed declarations
  # fail even when the package builds no custom resources of that kind.
  validateReadiness =
    context: groupKind: readiness:
    let
      extraKeys = [
        "failed"
        "observedGeneration"
        "pendingRestart"
      ];
      ready = if builtins.isAttrs readiness then removeAttrs readiness extraKeys else readiness;
      failed = if builtins.isAttrs readiness then readiness.failed or null else null;
      observedGeneration =
        if builtins.isAttrs readiness then readiness.observedGeneration or null else null;
      pendingRestart = if builtins.isAttrs readiness then readiness.pendingRestart or null else null;
      isPointer = p: builtins.isString p && lib.hasPrefix "/" p;
      isPathForm =
        builtins.isAttrs ready
        &&
          builtins.attrNames ready == [
            "equals"
            "path"
          ]
        && isPointer ready.path
        && builtins.isString ready.equals;
      isPathNotForm =
        builtins.isAttrs ready
        &&
          builtins.attrNames ready == [
            "notEquals"
            "path"
          ]
        && isPointer ready.path
        && builtins.isString ready.notEquals;
      isConditionForm =
        builtins.isAttrs ready
        && builtins.attrNames ready == [ "condition" ]
        && builtins.isAttrs ready.condition
        &&
          builtins.attrNames ready.condition == [
            "status"
            "type"
          ]
        && builtins.isString ready.condition.type
        && builtins.isString ready.condition.status;

      # A failed entry is a condition with an optional reason, or a path
      # value. The condition's status is required: a controller reports a
      # rejection as `Valid=False` or `Accepted=False`, and the status says
      # which side of the condition the rejection is. A path entry may add
      # `rejected = true` when the state is the controller's verdict on the
      # spec, `hint` with what to do next, and `message`, one JSON pointer
      # or a list of them, whose values the failure message quotes.
      isFailedCondition =
        e:
        builtins.isAttrs e
        && builtins.attrNames e == [ "condition" ]
        && builtins.isAttrs e.condition
        && builtins.elem (builtins.attrNames e.condition) [
          [
            "status"
            "type"
          ]
          [
            "reason"
            "status"
            "type"
          ]
        ]
        && builtins.isString e.condition.type
        && builtins.isString e.condition.status
        && (e.condition.reason or null == null || builtins.isString e.condition.reason);
      pathEntryKeys = [
        "equals"
        "hint"
        "message"
        "path"
        "rejected"
      ];
      isPointerList = v: builtins.isList v && v != [ ] && builtins.all isPointer v;
      isFailedPath =
        e:
        builtins.isAttrs e
        && e ? path
        && e ? equals
        && builtins.all (k: builtins.elem k pathEntryKeys) (builtins.attrNames e)
        && isPointer e.path
        && builtins.isString e.equals
        && (e.rejected or null == null || builtins.isBool e.rejected)
        && (e.hint or null == null || builtins.isString e.hint)
        && (e.message or null == null || isPointer e.message || isPointerList e.message);
      failedOk =
        failed == null
        || (builtins.isList failed && builtins.all (e: isFailedCondition e || isFailedPath e) failed);
      # `false` says the kind reports no generation. Null means "not set"
      # elsewhere in the library, so it cannot carry that meaning here.
      observedGenerationOk =
        observedGeneration == null || observedGeneration == false || isPointer observedGeneration;
      # A pending-restart state is a condition or a path value, as a failed
      # entry is. Either may add `hint` with how to restart the workload, and
      # the path form `message` pointers whose values the deploy quotes.
      isOptionalString = v: v == null || builtins.isString v;
      isPendingCondition =
        e:
        builtins.isAttrs e
        && e ? condition
        && builtins.all (
          k:
          builtins.elem k [
            "condition"
            "hint"
          ]
        ) (builtins.attrNames e)
        && isFailedCondition { inherit (e) condition; }
        && isOptionalString (e.hint or null);
      isPendingPath = e: isFailedPath e && !(e ? rejected);
      pendingRestartOk =
        pendingRestart == null || isPendingCondition pendingRestart || isPendingPath pendingRestart;
      # Drop a null reason, hint, or message, a false `rejected`, and wrap a
      # single message pointer in a list, so the annotation carries only the
      # keys the deploy reads.
      normalizeFailed =
        e:
        if e ? condition then
          { condition = lib.filterAttrs (_: v: v != null) e.condition; }
        else
          lib.filterAttrs (k: v: v != null && (k != "rejected" || v)) (
            e // lib.optionalAttrs (builtins.isString (e.message or null)) { message = [ e.message ]; }
          );
      normalizedFailed = map normalizeFailed failed;
      normalizedPendingRestart =
        if pendingRestart ? condition then
          normalizeFailed { inherit (pendingRestart) condition; }
          // lib.optionalAttrs (pendingRestart.hint or null != null) { inherit (pendingRestart) hint; }
        else
          normalizeFailed pendingRestart;
    in
    if readiness == null then
      null
    else if !(isPathForm || isPathNotForm || isConditionForm) then
      fail ''
        ${context}: readiness declaration for ${groupKind} must be one of
          { path = "/status/..."; equals = "<value>"; }
          { path = "/status/..."; notEquals = "<value>"; }
          { condition = { type = "<Type>"; status = "True"; }; }
        (path: a JSON pointer string starting with "/"; every value a string,
        and equals = "true" or "3" also matches a JSON true or 3 at the path;
        notEquals is ready while the path is absent or holds another value;
        no other keys except the optional `failed`, `observedGeneration`, and
        `pendingRestart`)
      ''
    else if !failedOk then
      fail ''
        ${context}: readiness.failed for ${groupKind} must be a list whose entries are
          { condition = { type = "<Type>"; status = "False"; reason = "<Reason>"; }; }
          { path = "/status/..."; equals = "<value>"; rejected = <bool>; hint = "<text>"; message = "/status/..."; }
        (reason is optional and matches any reason when omitted; rejected, hint,
        and message are optional: rejected = true says the state is the
        controller's verdict on the spec, hint is what to do next, and message is
        a JSON pointer, or a list of them, whose values the failure quotes; no
        other keys). Each entry names a state the controller does not leave on
        its own.
        Got: ${builtins.toJSON failed}
      ''
    else if !observedGenerationOk then
      fail ''
        ${context}: readiness.observedGeneration for ${groupKind} must be a JSON
        pointer string starting with "/", such as "/status/desiredGeneration", that
        names the status field where the controller reports the generation it has
        acted on. Set it to false when the kind reports no such field, and leave it
        out when the field is "/status/observedGeneration".
        Got: ${builtins.toJSON observedGeneration}
      ''
    else if !pendingRestartOk then
      fail ''
        ${context}: readiness.pendingRestart for ${groupKind} must be one of
          { condition = { type = "<Type>"; status = "True"; reason = "<Reason>"; }; hint = "<text>"; }
          { path = "/status/..."; equals = "<value>"; hint = "<text>"; message = "/status/..."; }
        (reason, hint, and message are optional: hint says how to restart the
        workload, and message is a JSON pointer, or a list of them, whose values
        the deploy quotes; no other keys). It names the state in which the
        controller has accepted the spec and the running workload still runs the
        previous one.
        Got: ${builtins.toJSON pendingRestart}
      ''
    else
      ready
      // lib.optionalAttrs (failed != null && failed != [ ]) { failed = normalizedFailed; }
      // lib.optionalAttrs (observedGeneration != null) { inherit observedGeneration; }
      // lib.optionalAttrs (pendingRestart != null) { pendingRestart = normalizedPendingRestart; };

  # Return `crRequires` when it is a list, and stop the build otherwise.
  # `scope.mkCRD` and `scope.mkCRDRef` call it when the kind is declared, so
  # a wrong value fails even when no custom resource of the kind is built.
  validateCrRequires =
    declaredBy: groupKind: crRequires:
    if builtins.isList crRequires then
      crRequires
    else
      fail {
        message = "${declaredBy}: crRequires for ${groupKind} must be a list of resources (got ${builtins.typeOf crRequires}).";
        fix = "Set crRequires to a list of resources, such as [ self.webhookCheck ].";
      };

  # Arguments `scope.mkCRD` and `scope.mkCRDRef` accept. `scope.mkCRDRef`
  # takes the CRD's identity as arguments and `scope.mkCRD` reads it from
  # `spec`.
  crdSharedArguments = [
    "factBehavior"
    "readiness"
    "usesAtLeast"
    "holdsData"
    "crRequires"
    "controller"
  ];
  mkCRDArguments = [
    "spec"
    "labels"
    "annotations"
    "ownership"
  ]
  ++ crdSharedArguments;
  mkCRDRefArguments = [
    "group"
    "kind"
    "plural"
    "version"
    "servedVersions"
    "crdScope"
    "installedBy"
  ]
  ++ crdSharedArguments;

  # Return `null` when every name in `args` is in `accepted`, or fail naming
  # the unknown ones. `site` is the builder, such as `scope.mkCRD`, and
  # `declares` names the kind being declared.
  refuseUnknownCrdArguments =
    {
      site,
      declares,
      accepted,
      args,
    }:
    let
      unknown = builtins.filter (n: !(builtins.elem n accepted)) (builtins.attrNames args);
      list = names: builtins.concatStringsSep ", " names;
    in
    if unknown == [ ] then
      null
    else
      fail {
        id = "K9267";
        message = "${site} for ${declares} received unknown argument(s): ${list unknown}. Kix rejected this CRD declaration.";
        fix = "Rename or remove the unknown argument(s). Accepted arguments: ${list accepted}.";
      };

  # Return `controller` as a list of workloads, and stop the build when it is
  # anything other than null, a workload, or a list of workloads. A workload
  # is a Deployment, StatefulSet, or DaemonSet, or an import marker for one
  # that runs outside Kix. `scope.mkCRD` and `scope.mkCRDRef` call it when
  # the kind is declared, so a wrong value fails even when no custom resource
  # of the kind is built.
  validateController =
    declaredBy: groupKind: controller:
    let
      listed =
        if controller == null then
          [ ]
        else if builtins.isList controller then
          controller
        else
          [ controller ];
      isWorkload =
        r:
        builtins.isAttrs r
        && r ? outPath
        && (
          builtins.elem (r.kind or null) workloadKinds.servingKinds || (r.kind or null) == "PackageInstance"
        );
      wrong = builtins.filter (r: !(isWorkload r)) listed;
      describe =
        r:
        if builtins.isAttrs r && r ? kind then
          "${r.kind} ${builtins.toJSON (r.name or null)}"
        else
          "type ${builtins.typeOf r}";
    in
    if wrong == [ ] then
      listed
    else
      fail {
        message = "${declaredBy}: controller for ${groupKind} must be a workload or list of workloads (got ${describe (builtins.head wrong)}).";
        fix = "Set controller to the Deployment, StatefulSet, or DaemonSet that reconciles ${groupKind} objects (such as self.operator), an import marker for an external workload, or a list of them. Omit controller or set it to null when nothing in the cluster reconciles this kind.";
      };

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
      # Resources every CR of the kind requires, such as a Job that checks
      # the operator's admission webhook serves. The package declares them
      # on `scope.mkCRD` or `scope.mkCRDRef`. They come before the CRD in
      # each CR's `requires`.
      crRequires ? [ ],
      # The workloads that handle custom resources of the kind, from
      # `validateController`. Every CR requires them, so a deploy creates
      # the CR after its controller and deletes it before. They are written
      # to `kix.run/depends-on` as `controller:` entries, which the deploy
      # reads to name the controller when a CR's delete does not finish.
      controllers ? [ ],
      # Appended to every CR's `requires` after the CRD (a chart's workloads,
      # any of which can be the CRD's webhook).
      extraRequires ? [ ],
      # Validated behavior to pass to each CR for endpoint fact handling.
      factBehavior ? null,
      # Function `cr: { <ResourceQuota key> = <quantity>; }` returning the
      # least the operator always uses for a CR, keyed like a ResourceQuota's
      # `spec.hard` (`pods`, `requests.cpu`, `requests.storage`, `services`).
      # Passed to each CR so `buildCluster` can check namespace ResourceQuotas.
      usesAtLeast ? null,
      # Whether each CR of the kind holds data that removing it can lose:
      # true for a database or storage pool, false for monitoring, policy,
      # or configuration. Written on each CR as `kix.run/holds-data`. A
      # stateful package's custom resources must have it.
      holdsData ? null,
      # Readiness check stamped as `kix.run/readiness` on each CR (`{ path; equals; }`,
      # `{ path; notEquals; }`, or `{ condition = { type; status; }; }`) for
      # operators that do not use standard `Ready` or `Available` conditions,
      # with the optional `failed`, `observedGeneration`, and `pendingRestart`
      # keys that `validateReadiness` describes. A CR's own `readiness`
      # argument replaces it.
      readiness ? null,
    }:
    let
      crKind = kind;

      _validatedReadiness = validateReadiness "mkCRDBuilders" "${group}/${kind}" readiness;

      _validatedHoldsData =
        if holdsData == null then
          null
        else if !builtins.isBool holdsData then
          fail {
            message = "${declaredBy}: holdsData for ${group}/${kind} is ${builtins.toJSON holdsData}.";
            fix = "Set it to true when a ${kind} keeps data that deleting it loses, such as a database or a storage pool, and to false otherwise.";
          }
        else if !(facts.isForeignGroup "${group}/${version}") then
          fail {
            message = "${declaredBy}: holdsData is not accepted for ${group}/${kind}. Kix treats the kinds of ${group} as built-in and decides whether they hold data from their shape.";
            fix = "Remove holdsData.";
          }
        else
          holdsData;

      _validatedCrRequires = validateCrRequires declaredBy "${group}/${kind}" crRequires;

      # A CR can override the default version, normally the CRD's storage
      # version, with another served one. `consumer` is "ns/instance" when
      # the CR is built through mkCR, null when through `cr` directly.
      checkServed =
        consumer: args: v:
        if builtins.elem v servedVersions then
          v
        else
          fail {
            instance = consumer;
            message =
              "${crKind} ${
                builtins.toJSON (args.name or null)
              }: version \"${v}\" is not one that ${declaredBy} lists as served for ${group}/${crKind} ("
              + builtins.concatStringsSep ", " servedVersions
              + ").";
            fix =
              "Set version on the custom resource to one of these, or leave it unset for ${version}."
              + lib.optionalString (unservedFix != null) " ${unservedFix}";
          };

      # A custom resource may pass its own `readiness`, which replaces the
      # kind's rule for that resource. A kind whose ready state depends on the
      # resource's spec, such as a VirtualMachine that should run or stay
      # stopped, needs one. It goes through the same validation as the kind's.
      readinessFor =
        consumer: args:
        if args.readiness or null == null then
          _validatedReadiness
        else
          validateReadiness (
            "${crKind} ${builtins.toJSON (args.name or null)}"
            + lib.optionalString (consumer != null) " in ${consumer}"
          ) "${group}/${kind}" args.readiness;

      crFor =
        consumer: args:
        let
          readiness = readinessFor consumer args;
        in
        removeAttrs args [
          "version"
          "readiness"
        ]
        // {
          apiVersion = "${group}/${checkServed consumer args (args.version or version)}";
          kind = crKind;
          requires =
            (args.requires or [ ]) ++ _validatedCrRequires ++ controllers ++ [ crdOrRef ] ++ extraRequires;
        }
        // lib.optionalAttrs (factBehavior != null) { inherit factBehavior; }
        // lib.optionalAttrs (usesAtLeast != null) { inherit usesAtLeast; }
        // {
          _crd = {
            inherit declaredBy controllers;
            holdsData = _validatedHoldsData;
          };
        }
        // lib.optionalAttrs (readiness != null) {
          annotations = (args.annotations or { }) // {
            ${kixKeys.readiness} = builtins.toJSON readiness;
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

  # Build an import-mode `PackageInstance` marker that deploy waits for without
  # creating the underlying object.
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

  # Build an import marker and `{ cr, mkCR }` builders for a CRD installed
  # outside Kix. Used by `scope.mkCRDRef` and `kix.mkImport { crds }`.
  mkCRDRefHandle =
    {
      mkResource,
      instanceName,
      namespaceName,
      site ? "scope.mkCRDRef",
    }:
    args@{
      group,
      kind,
      plural,
      # Default API version for custom resources of this kind (required).
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
      # The least the operator always uses for each CR; see mkCRDBuilders.
      usesAtLeast ? null,
      # Whether each CR of the kind holds data; see mkCRDBuilders.
      holdsData ? null,
      # Resources every CR of the kind requires; see mkCRDBuilders.
      crRequires ? [ ],
      # The workload, workloads, or import marker that handles CRs of the
      # kind; see validateController.
      controller ? null,
      ...
    }:
    let
      declaration = "${site} in ${namespaceName}/${instanceName}";
      who = "${site} ${group}/${kind} in ${namespaceName}/${instanceName}";
      isApiVersion = v: builtins.isString v && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" v != null;
      _validatedVersion =
        if version == null then
          fail {
            message = "${who}: version is not set. Kix does not install this CRD, so it cannot read the version, and a wrong one fails every apply of this kind.";
            fix = "Set version to the API version the CustomResourceDefinition serves for this kind (for example \"v1\" or \"v1beta1\").";
          }
        else if !(isApiVersion version) then
          fail "${who}: version ${builtins.toJSON version} is not an API version. Kubernetes API versions are lowercase RFC 1035 labels, such as \"v1\" or \"v1beta1\"."
        else
          version;
      _validatedServed =
        let
          listed = if servedVersions == null then [ _validatedVersion ] else servedVersions;
          invalid = builtins.filter (v: !(isApiVersion v)) listed;
        in
        if !(builtins.isList listed) then
          fail {
            message = "${who}: servedVersions is a ${builtins.typeOf listed}.";
            fix = "Set servedVersions to a list of API versions, such as [ \"v1\" \"v1beta1\" ].";
          }
        else if invalid != [ ] then
          fail "${who}: servedVersions entries ${builtins.toJSON invalid} are not API versions. Kubernetes API versions are lowercase RFC 1035 labels, such as \"v1\" or \"v1beta1\"."
        else if !(builtins.elem _validatedVersion listed) then
          fail {
            message = "${who}: servedVersions ${builtins.toJSON listed} does not include version \"${_validatedVersion}\".";
            fix = "Add it, or set version to one of the listed versions.";
          }
        else
          lib.unique listed;
      _validatedScope =
        if crdScope == "Namespaced" || crdScope == "Cluster" then
          crdScope
        else
          fail {
            message = "${who}: crdScope is ${builtins.toJSON crdScope}.";
            fix = "Use \"Namespaced\" or \"Cluster\", as the CustomResourceDefinition's spec.scope says.";
          };
      _validatedReadiness = validateReadiness declaration "${group}/${kind}" readiness;
      _validatedBehavior =
        if factBehavior != null then
          facts.validateBehavior declaration "${group}/${kind}" factBehavior
        else
          null;
      crdName = "${plural}.${group}";
      groupSlug = builtins.replaceStrings [ "." ] [ "-" ] group;
      # Scope the marker name to the declaring instance so two instances in the
      # same namespace do not collide.
      markerName = "crd-ref-${instanceName}-${plural}-${groupSlug}";

      installedByList =
        if installedBy == null then
          [ ]
        else if builtins.isList installedBy then
          installedBy
        else
          [ installedBy ];

      _validatedCrRequires = validateCrRequires declaration "${group}/${kind}" crRequires;
      _validatedControllers = validateController declaration "${group}/${kind}" controller;
      _validatedArguments = refuseUnknownCrdArguments {
        inherit site args;
        declares = "${group}/${kind}";
        accepted = mkCRDRefArguments;
      };
      _validated = builtins.seq _validatedArguments (
        builtins.seq _validatedServed (
          builtins.seq _validatedScope (
            builtins.seq _validatedCrRequires (builtins.seq _validatedControllers _validatedReadiness)
          )
        )
      );

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
        inherit usesAtLeast holdsData;
        crRequires = _validatedCrRequires;
        controllers = _validatedControllers;
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
