{
  lib,
  meta,
  kixlib,
  resolve,
  roles,
}:

let
  inherit (resolve) discoverBuildDeps refsOf;
  inherit (import ../core/error.nix { inherit lib; }) fail;
  inherit (import ../core/util.nix { inherit lib; }) instanceLabel;
  packageLib = import ../core/package.nix { inherit lib; };
in

rec {
  # Return whether `value` is an `availablePackages` entry: a package, or
  # `{ package; namespace; aliases; }`.
  isPackageEntry = value: packageLib.isPackage value || (builtins.isAttrs value && value ? package);

  normalizeAvailablePackages =
    raw:
    lib.mapAttrs (
      name: value:
      if packageLib.isPackage value then
        {
          package = value;
          namespace = null;
          aliases = [ ];
        }
      else
        {
          package = value.package or (fail "availablePackages.${name}: missing 'package'");
          namespace = value.namespace or null;
          aliases = value.aliases or [ ];
        }
    ) (lib.filterAttrs (_: isPackageEntry) raw);

  getDepsWhere =
    pred: pkg:
    let
      raw = resolve.callPackagePhase1 {
        package = pkg;
        scope = { };
      };
    in
    if raw ? build then
      let
        discoveredDeps = discoverBuildDeps raw.build;
      in
      builtins.filter (name: pred name discoveredDeps.${name}) (builtins.attrNames discoveredDeps)
    else
      [ ];

  getRequiredDeps = getDepsWhere (_name: spec: !(spec.optional or false));

  getAllDeps = getDepsWhere (_name: _spec: true);

  # Return every `<ns>.<inst>` that computeAutoInstances could produce, as
  # `{ <ns> = [ <inst> ... ]; }`. This includes explicit instances and each
  # availablePackages entry in each namespace where it could be placed. It needs
  # no closure, so `ref` can be built from it and `deps` values can be read
  # during auto-instantiation without recursion.
  possibleInstanceNames =
    {
      explicitInstances,
      availablePackages,
      autoNamespace,
    }:
    let
      normalizedAvail = normalizeAvailablePackages availablePackages;
      fixedNs = lib.filter (n: n != null) (lib.mapAttrsToList (_: e: e.namespace) normalizedAvail);
      # Place an availablePackages entry without a fixed namespace in
      # autoNamespace, or in the namespace of whatever demanded it.
      floatingNs =
        if autoNamespace != null then
          [ autoNamespace ]
        else
          lib.unique (builtins.attrNames explicitInstances ++ fixedNs);
      catalogPlacements = lib.mapAttrsToList (
        name: e: map (ns: { ${ns} = name; }) (if e.namespace != null then [ e.namespace ] else floatingNs)
      ) normalizedAvail;
      catalogByNs = builtins.zipAttrsWith (_: names: names) (lib.flatten catalogPlacements);
    in
    builtins.zipAttrsWith (_: lists: lib.unique (lib.flatten lists)) [
      (lib.mapAttrs (_: builtins.attrNames) explicitInstances)
      catalogByNs
    ];

  # Compute instances pulled from availablePackages to satisfy demands and the
  # optional instances those demands activate. Only a required dependency
  # places a demand. An optional dependency resolves against active instances
  # and is null otherwise. It never pulls from availablePackages or activates an
  # optional instance. Reject any availablePackages entry that runs once per
  # cluster (onePerClusterReason) if demands would place it in multiple
  # namespaces.
  computeAutoInstances =
    {
      explicitInstances,
      availablePackages,
      autoNamespace,
    }:
    let
      normalizedAvail = normalizeAvailablePackages availablePackages;

      catalogKeys =
        name:
        lib.unique (
          [ name ]
          ++ meta.peekPackageAliases {
            availEntry = normalizedAvail.${name};
            inherit kixlib;
            context = "availablePackages.${name}";
          }
        );

      # Map each key to every availablePackages entry that answers it, in
      # attrNames order. Membership tests (`?`) do not check how many packages
      # match. `ambiguityRefusals` rejects a demanded key with multiple
      # matching packages.
      availableByKey = builtins.zipAttrsWith (_: names: names) (
        builtins.concatMap (name: map (key: { ${key} = name; }) (catalogKeys name)) (
          builtins.attrNames normalizedAvail
        )
      );

      # Map each key to the packages that `availablePackages = packages`
      # offered before they moved to experimental. Their old names are
      # markers there, which the catalog skips.
      movedByKey = builtins.zipAttrsWith (_: names: names) (
        lib.concatLists (
          lib.mapAttrsToList (
            name: marker:
            map (key: { ${key} = marker.name; }) (
              lib.unique (
                [ name ]
                ++ meta.peekPackageAliases {
                  availEntry = {
                    package = marker.experimentalPackage;
                    aliases = [ ];
                    namespace = null;
                  };
                  inherit kixlib;
                  context = "availablePackages.${name}";
                }
              )
            )
          ) (lib.filterAttrs (_: v: (v._type or "") == "kix-moved") availablePackages)
        )
      );

      # Refuse a demand that only a package which moved to experimental would
      # answer, naming the package to add.
      refuseMoved =
        item:
        let
          names = lib.unique movedByKey.${item.depName};
        in
        fail {
          id = "K0549";
          message = "${item.requester} needs dependency '${item.depName}'. `availablePackages = packages` offered ${
            lib.concatMapStringsSep " or " (n: "`${n}`") names
          } for it, but that package is experimental now, and `packages` offers only stable packages.";
          fix =
            "Add it by name:"
            + "\n  availablePackages = packages // { inherit (packages.experimental) ${builtins.head names}; };"
            + "\nOr declare the instance under `instances` with `packages.experimental.${builtins.head names}`.";
        };

      # Return the reasons an availablePackages entry matches `key`, for error
      # messages.
      claimSources =
        name: key:
        let
          entry = normalizedAvail.${name};
          packageMeta = meta.peekPackageMeta {
            package = entry.package;
            inherit kixlib;
          };
        in
        lib.optional (key == name) "package name"
        ++ lib.optional (builtins.elem key entry.aliases) "availablePackages.${name}.aliases"
        ++ lib.optional (builtins.elem key (packageMeta.roles or [ ])) "meta.roles"
        ++ lib.optional (builtins.elem key (packageMeta.defaultAliases or [ ])) "meta.defaultAliases";

      mandatory = lib.mapAttrs (
        _ns: nsInsts: lib.filterAttrs (_: inst: !(inst.optional or false)) nsInsts
      ) explicitInstances;

      optional = lib.mapAttrs (
        _ns: nsInsts: lib.filterAttrs (_: inst: inst.optional or false) nsInsts
      ) explicitInstances;

      mandatoryKeysList = builtins.concatMap (
        ns:
        builtins.concatMap (
          instName:
          let
            instCfg = mandatory.${ns}.${instName};
            packageMeta = meta.peekPackageMeta {
              package = instCfg.package;
              inherit kixlib;
            };
            aliases = meta.effectiveAliases {
              instanceAliases = instCfg.aliases or null;
              inherit packageMeta;
            };
          in
          [ instName ] ++ aliases
        ) (builtins.attrNames (mandatory.${ns} or { }))
      ) (builtins.attrNames mandatory);

      mandatoryKeys = builtins.listToAttrs (map (k: lib.nameValuePair k true) mandatoryKeysList);

      optionalByKeyList = builtins.concatMap (
        ns:
        builtins.concatMap (
          instName:
          let
            instCfg = optional.${ns}.${instName};
            packageMeta = meta.peekPackageMeta {
              package = instCfg.package;
              inherit kixlib;
            };
            aliases = meta.effectiveAliases {
              instanceAliases = instCfg.aliases or null;
              inherit packageMeta;
            };
            keys = lib.unique ([ instName ] ++ aliases);
          in
          map (key: {
            ${key} = {
              inherit ns instName;
              isImport = (instCfg.package._type or "") == "kix-import";
              scope = meta.scopeOf {
                inherit packageMeta;
                context = "instances.${ns}.${instName}";
              };
            };
          }) keys
        ) (builtins.attrNames (optional.${ns} or { }))
      ) (builtins.attrNames optional);

      optionalByKey = builtins.zipAttrsWith (_: opts: opts) optionalByKeyList;

      # Return the reason an availablePackages entry runs once per cluster, or
      # null. A package runs once per cluster when it serves the whole
      # cluster (meta.servesCluster): dependency resolution then binds
      # consumers in every namespace to the one declared instance.
      onePerClusterReason =
        name:
        let
          context = "availablePackages.${name}";
          packageMeta = meta.peekPackageMeta {
            package = normalizedAvail.${name}.package;
            inherit kixlib;
          };
          clusterConflicts = builtins.filter (lib.hasPrefix "cluster:") (meta.conflictKeys packageMeta);
          quoted = xs: builtins.concatStringsSep ", " (map builtins.toJSON xs);
        in
        if !(meta.servesCluster { inherit packageMeta context; }) then
          null
        else if (packageMeta.scope or null) == "cluster" then
          "meta.scope \"cluster\""
        else if clusterConflicts != [ ] then
          "meta.conflictsWith ${quoted clusterConflicts}"
        else
          "meta.roles ${quoted packageMeta.roles}";

      # Build a demand item keyed for genericClosure deduplication. Key role
      # dependencies by role name so consumers across namespaces share one
      # provider. Key other demands by the requesting namespace so they activate
      # that namespace's optional instance or place an availablePackages entry
      # there. Record the first `requester` (`<ns>/<inst>`) for error messages
      # without affecting deduplication.
      mkItem = depName: requesterNs: requester: {
        key =
          if builtins.elem depName roles.roleNames then "role:${depName}" else "${depName}@${requesterNs}";
        inherit depName requesterNs requester;
      };

      # Return the demands an instance places on optional instances and
      # availablePackages. Dependencies satisfied by mandatory instances place no
      # demand. Dependencies wired via `deps.<arg>` place no demand by name, but
      # each `ref` in the wiring to an optional instance demands that instance
      # directly.
      demandsOf =
        instCfg: ns: instName:
        let
          requester = "${ns}/${instName}";
          # resolveArg treats a null entry as not wired.
          wired = lib.filterAttrs (_: v: v != null) (instCfg.deps or { });
          required = builtins.filter (d: !(mandatoryKeys ? ${d})) (getRequiredDeps instCfg.package);
          wiredOptionals = builtins.filter (v: (optional.${v.namespace} or { }) ? ${v.instanceName}) (
            builtins.concatMap (d: refsOf wired.${d}) (
              builtins.filter (d: wired ? ${d}) (getAllDeps instCfg.package)
            )
          );
        in
        map (d: mkItem d ns requester) (builtins.filter (d: !(wired ? ${d})) required)
        ++ map (v: {
          key = "ref:${v.namespace}/${v.instanceName}";
          target = {
            ns = v.namespace;
            instName = v.instanceName;
          };
        }) wiredOptionals;

      describeDemand =
        item:
        if builtins.elem item.depName roles.roleNames then
          "needs role '${item.depName}', which has no active provider"
        else
          "needs dependency '${item.depName}', which has no active instance";

      # Select the optional instance matching a demand. A demand from any
      # namespace switches on an optional instance, because the cluster
      # author chose where it lives; the activated instance then binds from
      # every namespace (`demanded` in the resolution index). Skip instances
      # in other namespaces with `meta.scope = "namespace"`, prefer managed
      # instances over imports, and prefer the requester's namespace over
      # other namespaces. Throw if multiple candidates remain at the deciding
      # tier, or return null if none match.
      pickOptional =
        item:
        let
          all = builtins.filter (o: o.ns == item.requesterNs || o.scope != "namespace") (
            optionalByKey.${item.depName}
          );
          managed = builtins.filter (o: !o.isImport) all;
          candidates = if managed != [ ] then managed else all;
          sameNs = builtins.filter (o: o.ns == item.requesterNs) candidates;
          tier = if sameNs != [ ] then sameNs else candidates;
        in
        if tier == [ ] then
          null
        else if builtins.length tier == 1 then
          builtins.head tier
        else
          fail {
            message = "${item.requester}: dependency '${item.depName}' matches ${toString (builtins.length tier)} optional instances${
              lib.optionalString (sameNs != [ ]) " in namespace '${item.requesterNs}'"
            }: ${builtins.concatStringsSep ", " (map (o: "${o.ns}/${o.instName}") tier)}.";
            fix =
              "Wire the one ${item.requester} should use in instances.${
                builtins.replaceStrings [ "/" ] [ "." ] item.requester
              }:"
              + "\n  deps.${item.depName} = ref.${(builtins.head tier).ns}.${(builtins.head tier).instName};"
              + "\nIf this cluster needs only one of those optional instances, remove the others.";
          };

      # Return the optional instance that `item` activates, or null.
      activatedBy =
        item:
        if item ? target then
          item.target
        else if optionalByKey ? ${item.depName} then
          pickOptional item
        else
          null;

      # Return whether more than one availablePackages entry answers a demand.
      # Kix does not rank them, so `ambiguityRefusals` rejects the key when a
      # consumer demands it rather than when the entries are declared.
      isAmbiguous = item: builtins.length availableByKey.${item.depName} > 1;

      # Return the availablePackages entry that answers a demand that is not
      # ambiguous.
      pickCatalog = item: builtins.head availableByKey.${item.depName};

      # Return the refusal for a demand that several availablePackages
      # entries answer.
      ambiguityError =
        item:
        let
          claimants = availableByKey.${item.depName};
        in
        {
          message = builtins.concatStringsSep "\n" (
            [
              "${item.requester}: ${describeDemand item}, and ${toString (builtins.length claimants)} packages in availablePackages match '${item.depName}':"
            ]
            ++ map (
              name: "  ${name} (${builtins.concatStringsSep ", " (claimSources name item.depName)})"
            ) claimants
          );
          fix = builtins.concatStringsSep "\n" (
            [
              "Declare the package this cluster should use by adding one of these lines. `optional = true` creates the instance only when something depends on it, and the namespace and name match what Kix creates automatically so any existing instance keeps its data:"
            ]
            ++ map (name: "  ${chosenInstanceLine item name}") claimants
            ++ [
              "If the other matching packages are not used in this cluster, remove them from availablePackages."
            ]
            ++ lib.optional (builtins.elem item.depName roles.roleNames) "If the cluster environment already provides '${item.depName}', set `cluster.roles.${item.depName}.binding = \"shadowable\";` (or `\"exclusive\";`) in your cluster definition instead."
          );
        };

      # Return the namespace auto-instantiation gives availablePackages entry
      # `avPkg` for `item`.
      catalogNamespace =
        item: avPkg:
        if avPkg.namespace != null then
          avPkg.namespace
        else if autoNamespace != null then
          autoNamespace
        else
          item.requesterNs;

      # Return the `instances` line that declares availablePackages entry
      # `name` as an optional instance under the namespace, the name, and the
      # aliases auto-instantiation gives it for `item`.
      chosenInstanceLine =
        item: name:
        let
          avPkg = normalizedAvail.${name};
          # A declared instance without `aliases` answers the package's own
          # aliases, which are the catalog aliases unless the entry adds some.
          aliases =
            lib.optionalString (avPkg.aliases != [ ])
              " aliases = [ ${lib.concatMapStringsSep " " builtins.toJSON (catalogAliases name)} ];";
        in
        "instances.${catalogNamespace item avPkg}.${name} = { package = ${packageSpelling name}; optional = true;${aliases} };";

      catalogInstance =
        item:
        let
          canonicalName = pickCatalog item;
          avPkg = normalizedAvail.${canonicalName};
        in
        {
          inherit canonicalName avPkg;
          ns = catalogNamespace item avPkg;
        };

      seeds = builtins.concatMap (
        ns:
        builtins.concatMap (instName: demandsOf mandatory.${ns}.${instName} ns instName) (
          builtins.attrNames (mandatory.${ns} or { })
        )
      ) (builtins.attrNames mandatory);

      closure = builtins.genericClosure {
        startSet = seeds;
        operator =
          item:
          let
            opt = activatedBy item;
          in
          if opt != null then
            demandsOf optional.${opt.ns}.${opt.instName} opt.ns opt.instName

          else if availableByKey ? ${item.depName} && isAmbiguous item then
            [ ]

          else if availableByKey ? ${item.depName} then
            let
              catalog = catalogInstance item;
            in
            demandsOf { inherit (catalog.avPkg) package; } catalog.ns catalog.canonicalName

          else if movedByKey ? ${item.depName} then
            refuseMoved item

          else
            [ ];
      };

      # Demands that several availablePackages entries answer. Collecting
      # them after the closure reports every one at once, and the closure
      # does not follow them.
      ambiguityRefusals = map ambiguityError (
        builtins.filter (
          item: activatedBy item == null && availableByKey ? ${item.depName} && isAmbiguous item
        ) closure
      );

      activatedOptionals = builtins.listToAttrs (
        builtins.concatMap (
          item:
          let
            opt = activatedBy item;
          in
          lib.optional (opt != null) (lib.nameValuePair "${opt.ns}/${opt.instName}" true)
        ) closure
      );

      autoInstanceList = builtins.concatMap (
        item:
        if activatedBy item == null && availableByKey ? ${item.depName} then
          let
            inherit (catalogInstance item) canonicalName avPkg ns;
          in
          [
            {
              inherit ns;
              inherit (item) depName requester;
              instName = canonicalName;
              instCfg = {
                package = avPkg.package;
                aliases = catalogAliases canonicalName;
                config = { };
                deps = { };
                partsOverlays = [ ];
                version = null;
                labelStyle = "kix";
                selectorLabels = null;
                optional = false;
                _autoInstantiated = true;
              };
            }
          ]
        else
          [ ]
      ) closure;

      placementsByName = builtins.groupBy (p: p.instName) autoInstanceList;

      # Record every requester of `<ns>/<inst>` for error messages that report an
      # auto-instantiated instance (meta.nix conflictsWith,
      # hooks.findRoleProvider, and sharedClusterObjectAssertions).
      requestersOf = builtins.mapAttrs (_: ps: lib.unique (map (p: p.requester) ps)) (
        builtins.groupBy (p: "${p.ns}/${p.instName}") autoInstanceList
      );

      autoInstances = builtins.foldl' (
        acc: item:
        let
          existing = acc.${item.ns} or { };
        in
        acc
        // {
          ${item.ns} =
            existing
            // (
              if existing ? ${item.instName} then
                { }
              else
                {
                  ${item.instName} = item.instCfg // {
                    _autoInstantiatedFor = requestersOf."${item.ns}/${item.instName}";
                  };
                }
            );
        }
      ) { } autoInstanceList;

      labelRequester =
        r:
        let
          parts = lib.splitString "/" r;
          declared = (explicitInstances.${builtins.head parts} or { }) ? ${builtins.elemAt parts 1};
        in
        if declared then r else instanceLabel r (requestersOf.${r} or null);

      # Reject availablePackages entries that must run once per cluster when
      # demands place them in multiple namespaces. A fixed namespace on the
      # availablePackages entry or autoNamespace places every copy in one
      # namespace, so only packages placed in their requester's namespace can
      # spread across namespaces.
      # Return how a cluster definition names the package of
      # availablePackages entry `name`.
      packageSpelling =
        name:
        let
          spelling = packageLib.spellingOf normalizedAvail.${name}.package;
        in
        if spelling == null then "<package for ${name}>" else spelling;

      # Return the aliases auto-instantiation gives availablePackages entry
      # `name`.
      catalogAliases =
        name:
        meta.peekPackageAliases {
          availEntry = normalizedAvail.${name};
          inherit kixlib;
          context = "availablePackages.${name}";
        };

      # Return the fix for a package that runs once per cluster and that
      # nothing places in a namespace of its own.
      onePerClusterFix =
        name:
        "Declare ${name} once in its own namespace so all consumers share it:"
        + "\n  instances.<namespace>.${name}.package = ${packageSpelling name};"
        + "\nOr set `availablePackages.${name}.namespace = \"<namespace>\";` to place just this package there, or `autoNamespace = \"<namespace>\";` to place all auto-instantiated packages there.";

      # Refuse a package that runs once per cluster when demands would place
      # it in several namespaces. The refusal stops evaluation at once,
      # because the copies in each namespace would otherwise raise their own
      # conflict and duplicate-resource errors, which hide the cause.
      spreadRefusals = builtins.concatMap (
        name:
        let
          ps = placementsByName.${name};
          namespaces = lib.unique (map (p: p.ns) ps);
          reason = onePerClusterReason name;
        in
        lib.optional (builtins.length namespaces > 1 && reason != null) {
          message = builtins.concatStringsSep "\n" (
            [
              "${name} runs once per cluster (${reason}), but no namespace is set for it, so Kix refused to create separate copies in ${toString (builtins.length namespaces)} namespaces:"
            ]
            ++ map (p: "  ${p.ns}/${name}, for dependency '${p.depName}' of ${labelRequester p.requester}") ps
          );
          fix = onePerClusterFix name;
        }
      ) (builtins.attrNames placementsByName);

      # Refuse a package that runs once per cluster and would land beside
      # the one consumer that needs it, because nothing names its namespace.
      # Removing that consumer would remove the package for the whole
      # cluster. Two consumers in two namespaces are refused by
      # spreadRefusals.
      besideConsumerRefusals = builtins.concatMap (
        name:
        let
          ps = placementsByName.${name};
          namespaces = lib.unique (map (p: p.ns) ps);
          reason = onePerClusterReason name;
          placed = normalizedAvail.${name}.namespace != null || autoNamespace != null;
        in
        lib.optional (builtins.length namespaces == 1 && reason != null && !placed) {
          id = "K2377";
          message = builtins.concatStringsSep "\n" (
            [
              "${name} runs once per cluster (${reason}), and nothing names its namespace. Kix would add it to namespace ${builtins.head namespaces}, beside the package that needs it:"
            ]
            ++ map (p: "  ${labelRequester p.requester}, for dependency '${p.depName}'") ps
            ++ [
              "Removing that package would then remove ${name} for the whole cluster."
            ]
          );
          fix = onePerClusterFix name;
        }
      ) (builtins.attrNames placementsByName);

      traceMsg =
        let
          items = map (item: "${item.instName} (${item.ns})") autoInstanceList;
          optItems = builtins.attrNames activatedOptionals;
        in
        (
          if items != [ ] then
            "auto-instantiated: ${builtins.concatStringsSep ", " (lib.unique items)}"
          else
            ""
        )
        + (
          if optItems != [ ] then
            "${
              if items != [ ] then "; " else ""
            }activated optionals: ${builtins.concatStringsSep ", " optItems}"
          else
            ""
        );
    in
    if ambiguityRefusals != [ ] then
      fail ambiguityRefusals
    else if spreadRefusals != [ ] then
      fail spreadRefusals
    else
      (if traceMsg != "" then builtins.trace "[kix] ${traceMsg}" else lib.id) {
        inherit autoInstances activatedOptionals besideConsumerRefusals;
      };
}
