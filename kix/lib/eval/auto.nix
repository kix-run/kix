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

  getRequiredDeps =
    pkg:
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
      builtins.filter (name: !(discoveredDeps.${name}.optional or false)) (
        builtins.attrNames discoveredDeps
      )
    else
      [ ];

  # Weak role demand (doc 127 §5): an OPTIONAL dep whose arg name is a
  # registry role still demands that role — optional only means "compile
  # even when nothing provides it", not "don't pull curated stock". These
  # deps seed auto-instantiation, but only as a last resort: an existing
  # instance or platform import providing the role always wins (the seed
  # is filtered out at the call site when the key resolves elsewhere).
  getWeakRoleDeps =
    pkg:
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
      builtins.filter (
        name: (discoveredDeps.${name}.optional or false) && builtins.elem name roles.roleNames
      ) (builtins.attrNames discoveredDeps)
    else
      [ ];

  computeAutoInstances =
    {
      explicitInstances,
      availablePackages,
      autoNamespace,
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

      seeds = builtins.concatMap (
        ns:
        builtins.concatMap (
          instName:
          let
            instCfg = mandatory.${ns}.${instName};
            reqDeps = getRequiredDeps instCfg.package;
            # Weak role demand: only when the role resolves nowhere else —
            # an explicit instance or (possibly inactive) platform import
            # providing the role suppresses the stock pull entirely, so
            # existing clusters keep their resolution unchanged.
            weakDeps = builtins.filter (
              depName:
              !(mandatoryKeys ? ${depName}) && !(optionalByKey ? ${depName}) && availableByKey ? ${depName}
            ) (getWeakRoleDeps instCfg.package);
          in
          builtins.concatMap (
            depName:
            if mandatoryKeys ? ${depName} then
              [ ]
            else
              [
                {
                  key = "${depName}@${ns}";
                  inherit depName;
                  requesterNs = ns;
                }
              ]
          ) (reqDeps ++ weakDeps)
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
              newDeps = getRequiredDeps optPkg.package;
            in
            builtins.concatMap (
              d:
              if mandatoryKeys ? ${d} || optionalByKey ? ${d} || availableByKey ? ${d} then
                [
                  {
                    key = "${d}@${opt.ns}";
                    depName = d;
                    requesterNs = opt.ns;
                  }
                ]
              else
                [ ]
            ) newDeps

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
              newDeps = getRequiredDeps avPkg.package;
            in
            builtins.concatMap (
              d:
              if mandatoryKeys ? ${d} || optionalByKey ? ${d} then
                [ ]
              else
                [
                  {
                    key = "${d}@${targetNs}";
                    depName = d;
                    requesterNs = targetNs;
                  }
                ]
            ) newDeps

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
