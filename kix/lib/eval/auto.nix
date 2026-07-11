{
  lib,
  meta,
  kixlib,
  resolve,
  roles,
}:

let
  inherit (resolve) discoverBuildDeps;
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

  # Weak role demand (doc 127 §5): an OPTIONAL dep whose arg name is a
  # registry role still demands that role — optional only means "compile
  # even when nothing provides it", not "don't pull curated stock". These
  # deps seed auto-instantiation, but only as a last resort: an existing
  # instance, platform import, or environment binding providing the role
  # always wins (see weakStockDemands below).
  getWeakRoleDeps = getDepsWhere (
    name: spec: (spec.optional or false) && builtins.elem name roles.roleNames
  );

  computeAutoInstances =
    {
      explicitInstances,
      availablePackages,
      autoNamespace,
      # cluster.roles binding modes — an environment-bound role (exclusive
      # or shadowable) is provided by the platform, so weak demand must not
      # pull stock for it (stock would either fight the environment CNI or
      # silently shadow the platform default).
      clusterRoles ? { },
    }:
    let
      normalizedAvail = normalizeAvailablePackages availablePackages;

      availableByKey =
        let
          entries = builtins.concatMap (
            name:
            let
              entry = normalizedAvail.${name};
              allKeys = lib.unique (
                [ name ]
                ++ meta.peekPackageAliases {
                  availEntry = entry;
                  inherit kixlib;
                  context = "availablePackages.${name}";
                }
              );
            in
            map (key: {
              inherit key name;
            }) allKeys
          ) (builtins.attrNames normalizedAvail);
        in
        builtins.listToAttrs (map (e: lib.nameValuePair e.key e.name) entries);

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
            inherit key ns instName;
          }) keys
        ) (builtins.attrNames (optional.${ns} or { }))
      ) (builtins.attrNames optional);

      optionalByKey = builtins.listToAttrs (
        map (e: lib.nameValuePair e.key { inherit (e) ns instName; }) optionalByKeyList
      );

      # Roles the environment itself provides. "absent" and null (unknown)
      # leave the role vacant — stock may fill it.
      isEnvBoundRole =
        role:
        builtins.elem ((clusterRoles.${role} or { }).binding or null) [
          "exclusive"
          "shadowable"
        ];

      # Role providers are cluster-scoped: a stock pull for a role-named dep
      # is keyed by the role itself, never per requesting namespace — two
      # consumers in two namespaces share one provider instead of
      # instantiating two strong symbols of the same role.
      mkItem = depName: requesterNs: {
        key =
          if builtins.elem depName roles.roleNames then "role:${depName}" else "${depName}@${requesterNs}";
        inherit depName requesterNs;
      };

      # Weak demands that actually pull stock: the role resolves nowhere
      # else — no explicit instance, no (possibly inactive) platform import,
      # no environment binding — and the catalog has a provider. Applied to
      # explicit instances AND to every package the closure discovers, so
      # demand propagates transitively (an auto-instantiated package's own
      # weak role deps still pull their stock).
      weakStockDemands =
        pkg:
        builtins.filter (
          role:
          !(mandatoryKeys ? ${role})
          && !(optionalByKey ? ${role})
          && !(isEnvBoundRole role)
          && availableByKey ? ${role}
        ) (getWeakRoleDeps pkg);

      seeds = builtins.concatMap (
        ns:
        builtins.concatMap (
          instName:
          let
            instCfg = mandatory.${ns}.${instName};
            reqDeps = builtins.filter (d: !(mandatoryKeys ? ${d})) (getRequiredDeps instCfg.package);
          in
          map (d: mkItem d ns) (reqDeps ++ weakStockDemands instCfg.package)
        ) (builtins.attrNames (mandatory.${ns} or { }))
      ) (builtins.attrNames mandatory);

      closure = builtins.genericClosure {
        startSet = seeds;
        operator =
          item:
          let
            depName = item.depName;
            requesterNs = item.requesterNs;
          in
          if optionalByKey ? ${depName} then
            let
              opt = optionalByKey.${depName};
              optPkg = optional.${opt.ns}.${opt.instName};
              newReq = builtins.filter (
                d: mandatoryKeys ? ${d} || optionalByKey ? ${d} || availableByKey ? ${d}
              ) (getRequiredDeps optPkg.package);
            in
            map (d: mkItem d opt.ns) (newReq ++ weakStockDemands optPkg.package)

          else if availableByKey ? ${depName} then
            let
              canonicalName = availableByKey.${depName};
              avPkg = normalizedAvail.${canonicalName};
              targetNs =
                if avPkg.namespace != null then
                  avPkg.namespace
                else if autoNamespace != null then
                  autoNamespace
                else
                  requesterNs;
              newReq = builtins.filter (d: !(mandatoryKeys ? ${d}) && !(optionalByKey ? ${d})) (
                getRequiredDeps avPkg.package
              );
            in
            map (d: mkItem d targetNs) (newReq ++ weakStockDemands avPkg.package)

          else
            [ ];
      };

      activatedOptionals = builtins.listToAttrs (
        builtins.concatMap (
          item:
          if optionalByKey ? ${item.depName} then
            let
              opt = optionalByKey.${item.depName};
            in
            [ (lib.nameValuePair "${opt.ns}/${opt.instName}" true) ]
          else
            [ ]
        ) closure
      );

      autoInstanceList = builtins.concatMap (
        item:
        if !(optionalByKey ? ${item.depName}) && availableByKey ? ${item.depName} then
          let
            canonicalName = availableByKey.${item.depName};
            avPkg = normalizedAvail.${canonicalName};
            targetNs =
              if avPkg.namespace != null then
                avPkg.namespace
              else if autoNamespace != null then
                autoNamespace
              else
                item.requesterNs;
          in
          [
            {
              ns = targetNs;
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

      autoInstances = builtins.foldl' (
        acc: item:
        let
          existing = acc.${item.ns} or { };
        in
        acc
        // {
          ${item.ns} =
            existing // (if existing ? ${item.instName} then { } else { ${item.instName} = item.instCfg; });
        }
      ) { } autoInstanceList;

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
    (if traceMsg != "" then builtins.trace "[kix] ${traceMsg}" else lib.id) {
      inherit autoInstances activatedOptionals;
    };
}
