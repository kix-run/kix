{
  lib,
  meta,
  kixlib,
  resolve,
  roles,
}:

let
  inherit (resolve) discoverBuildDeps refsOf;
in

rec {
  isPackageEntry =
    value:
    builtins.isFunction value
    || (value._type or "") == "kix-import"
    || (builtins.isAttrs value && value ? package)
    || (builtins.isAttrs value && value ? build);

  normalizeAvailablePackages =
    raw:
    lib.mapAttrs (
      name: value:
      if builtins.isFunction value then
        {
          package = value;
          namespace = null;
          aliases = [ ];
        }
      else if (value._type or "") == "kix-import" then
        {
          package = value;
          namespace = null;
          aliases = [ ];
        }
      else if builtins.isAttrs value && value ? build then
        {
          package = value;
          namespace = null;
          aliases = [ ];
        }
      else
        {
          package = value.package or (throw "availablePackages.${name}: missing 'package'");
          namespace = value.namespace or null;
          aliases = value.aliases or [ ];
        }
    ) (lib.filterAttrs (_: isPackageEntry) raw);

  getDepsWhere =
    pred: pkg:
    let
      raw = resolve.normalizePackage {
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

  # Every `<ns>.<inst>` computeAutoInstances could produce, as
  # `{ <ns> = [ <inst> ... ]; }`: the explicit instances plus each shelf
  # package in each namespace it could be placed in. It needs no closure,
  # so `ref` can be built from it and `deps` values read during
  # auto-instantiation without recursion.
  possibleInstanceNames =
    {
      explicitInstances,
      availablePackages,
      autoNamespace,
    }:
    let
      normalizedAvail = normalizeAvailablePackages availablePackages;
      fixedNs = lib.filter (n: n != null) (lib.mapAttrsToList (_: e: e.namespace) normalizedAvail);
      # A shelf package without a namespace lands in autoNamespace, or else
      # in the namespace of whatever demanded it.
      floatingNs =
        if autoNamespace != null then
          [ autoNamespace ]
        else
          lib.unique (builtins.attrNames explicitInstances ++ fixedNs);
      shelfPlacements = lib.mapAttrsToList (
        name: e: map (ns: { ${ns} = name; }) (if e.namespace != null then [ e.namespace ] else floatingNs)
      ) normalizedAvail;
      shelfByNs = builtins.zipAttrsWith (_: names: names) (lib.flatten shelfPlacements);
    in
    builtins.zipAttrsWith (_: lists: lib.unique (lib.flatten lists)) [
      (lib.mapAttrs (_: builtins.attrNames) explicitInstances)
      shelfByNs
    ];

  # Instances pulled from availablePackages to satisfy demands, and the
  # optional instances the demands activate. Only a required dependency
  # places a demand. An optional dependency resolves against active
  # instances and is null otherwise; it never pulls a shelf package or
  # activates an optional instance. A shelf package that runs once per
  # cluster (onePerClusterReason) and would be placed in more than one
  # namespace is refused.
  computeAutoInstances =
    {
      explicitInstances,
      availablePackages,
      autoNamespace,
    }:
    let
      normalizedAvail = normalizeAvailablePackages availablePackages;

      shelfKeys =
        name:
        lib.unique (
          [ name ]
          ++ meta.peekPackageAliases {
            availEntry = normalizedAvail.${name};
            inherit kixlib;
            context = "availablePackages.${name}";
          }
        );

      # Key to every shelf package that answers it, in attrNames order.
      # Membership tests (`?`) do not look at the claimants; a demand goes
      # through pickShelf, which refuses a key with more than one.
      availableByKey = builtins.zipAttrsWith (_: names: names) (
        builtins.concatMap (name: map (key: { ${key} = name; }) (shelfKeys name)) (
          builtins.attrNames normalizedAvail
        )
      );

      # Why a shelf package answers a key, for the refusal message only.
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
              instanceAliases = instCfg.aliases or [ ];
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
              instanceAliases = instCfg.aliases or [ ];
              inherit packageMeta;
            };
            keys = lib.unique ([ instName ] ++ aliases);
          in
          map (key: {
            ${key} = {
              inherit ns instName;
              isImport = (instCfg.package._type or "") == "kix-import";
              scope = packageMeta.scope or "cluster";
            };
          }) keys
        ) (builtins.attrNames (optional.${ns} or { }))
      ) (builtins.attrNames optional);

      # Key to every optional instance that answers it; pickOptional chooses.
      optionalByKey = builtins.zipAttrsWith (_: opts: opts) optionalByKeyList;

      # Why a shelf package runs once per cluster, or null: its
      # meta.conflictsWith lists `cluster:<key>` for a key it answers, or it
      # claims a role, which hooks.findRoleProvider allows one managed
      # provider of. A package with meta.scope = "namespace" is excluded,
      # because a requester in another namespace cannot resolve to it.
      onePerClusterReason =
        name:
        let
          packageMeta = meta.peekPackageMeta {
            package = normalizedAvail.${name}.package;
            inherit kixlib;
          };
          conflictKeys = builtins.filter (
            k: builtins.elem "cluster:${k}" (packageMeta.conflictsWith or [ ])
          ) (shelfKeys name);
          quoted = xs: builtins.concatStringsSep ", " (map builtins.toJSON xs);
        in
        if (packageMeta.scope or "cluster") == "namespace" then
          null
        else if conflictKeys != [ ] then
          "meta.conflictsWith ${quoted (map (k: "cluster:${k}") conflictKeys)}"
        else if (packageMeta.roles or [ ]) != [ ] then
          "meta.roles ${quoted packageMeta.roles}"
        else
          null;

      # The demand key, which genericClosure deduplicates on. A role-named
      # dependency is keyed by the role, so consumers in several namespaces
      # share one provider. Any other demand is keyed by its requesting
      # namespace, so it activates that namespace's optional instance or
      # places a shelf package there. `requester` (`<ns>/<inst>`) names the
      # first demand for the refusal messages and does not take part in
      # deduplication.
      mkItem = depName: requesterNs: requester: {
        key =
          if builtins.elem depName roles.roleNames then "role:${depName}" else "${depName}@${requesterNs}";
        inherit depName requesterNs requester;
      };

      # The demands an instance places on optional instances and the shelf.
      # A dependency answered by a mandatory instance places none. One wired
      # with `deps.<arg>` places none by name; each `ref` in the wiring (one,
      # or a list) to an optional instance demands that instance directly.
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
          "role '${item.depName}', needed by ${item.requester}, has no provider"
        else
          "dependency '${item.depName}' of ${item.requester} has no instance";

      # The optional instance answering a demanded key, chosen as resolveArg
      # chooses: instances with meta.scope = "namespace" in other namespaces
      # are skipped, then a managed instance wins over an import, then the
      # requester's namespace over the others. More than one at the deciding
      # step is refused; null when none is left.
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
          throw "kix: dependency '${item.depName}' of ${item.requester} matches ${toString (builtins.length tier)} optional instances${
            lib.optionalString (sameNs != [ ]) " in namespace '${item.requesterNs}'"
          }: ${
            builtins.concatStringsSep ", " (map (o: "${o.ns}/${o.instName}") tier)
          }. Keep one of them, or set deps.${item.depName} on ${item.requester} to the intended one.";

      # The optional instance an item activates, or null.
      activatedBy =
        item:
        if item ? target then
          item.target
        else if optionalByKey ? ${item.depName} then
          pickOptional item
        else
          null;

      # The one shelf package answering a demanded key. Kix does not rank
      # claimants, so a contested key is refused here, when something
      # depends on it, and never when it merely sits on the shelf.
      pickShelf =
        item:
        let
          claimants = availableByKey.${item.depName};
        in
        if builtins.length claimants == 1 then
          builtins.head claimants
        else
          throw (
            builtins.concatStringsSep "\n" (
              [
                "kix: ${describeDemand item}, and ${toString (builtins.length claimants)} packages in availablePackages provide it:"
              ]
              ++ map (
                name: "  ${name} (${builtins.concatStringsSep ", " (claimSources name item.depName)})"
              ) claimants
              ++ [
                "Kix does not choose between them. Declare the one this cluster uses as an optional instance, which is created only when something depends on it:"
                "  instances.<namespace>.${item.depName} = { package = packages.<one of the above>; optional = true; };"
                "or remove the others from availablePackages."
              ]
              ++ lib.optional (builtins.elem item.depName roles.roleNames) "If the environment provides this role, set cluster.roles.${item.depName}.binding instead."
            )
          );

      shelfInstance =
        item:
        let
          canonicalName = pickShelf item;
          avPkg = normalizedAvail.${canonicalName};
        in
        {
          inherit canonicalName avPkg;
          ns =
            if avPkg.namespace != null then
              avPkg.namespace
            else if autoNamespace != null then
              autoNamespace
            else
              item.requesterNs;
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

          else if availableByKey ? ${item.depName} then
            let
              shelf = shelfInstance item;
            in
            demandsOf { inherit (shelf.avPkg) package; } shelf.ns shelf.canonicalName

          else
            [ ];
      };

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
            inherit (shelfInstance item) canonicalName avPkg ns;
          in
          [
            {
              inherit ns;
              inherit (item) depName requester;
              instName = canonicalName;
              instCfg = {
                package = avPkg.package;
                aliases = meta.peekPackageAliases {
                  availEntry = avPkg;
                  inherit kixlib;
                  context = "availablePackages.${canonicalName}";
                };
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

      # Every requester of the instance at `<ns>/<inst>`, for the refusals
      # that name an auto-instantiated instance (meta.nix conflictsWith,
      # hooks.findRoleProvider, sharedClusterObjectAssertions).
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
        if declared then r else "${r} (auto-instantiated)";

      # A shelf package that runs once per cluster and that the closure
      # places in more than one namespace. A fixed availablePackages
      # namespace or autoNamespace places every copy in one namespace, so
      # only a package that floats to its requesters can spread.
      spreadRefusals = builtins.concatMap (
        name:
        let
          ps = placementsByName.${name};
          namespaces = lib.unique (map (p: p.ns) ps);
          reason = onePerClusterReason name;
        in
        lib.optional (builtins.length namespaces > 1 && reason != null) (
          builtins.concatStringsSep "\n" (
            [
              "kix: ${name} runs once per cluster (${reason}), but auto-instantiation would place it in ${toString (builtins.length namespaces)} namespaces:"
            ]
            ++ map (p: "  ${p.ns}/${name}, for dependency '${p.depName}' of ${labelRequester p.requester}") ps
            ++ [
              "Declare it once, and every consumer resolves to it:"
              "  instances.<namespace>.${name}.package = packages.${name};"
            ]
          )
        )
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
    if spreadRefusals != [ ] then
      throw (builtins.concatStringsSep "\n" spreadRefusals)
    else
      (if traceMsg != "" then builtins.trace "[kix] ${traceMsg}" else lib.id) {
        inherit autoInstances activatedOptionals;
      };
}
