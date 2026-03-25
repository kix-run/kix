# Auto-instantiation — normalise available packages and compute which
# instances need to be auto-created (or which optionals need activation).
# See v2_discussions/27_auto_instantiation.md for design rationale.

{
  lib,
  meta,
  kixlib,
}:

rec {
  # Normalize mixed availablePackages entries (raw functions vs attrsets).
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
      else
        {
          package = value.package or (throw "availablePackages.${name}: missing 'package'");
          namespace = value.namespace or null;
          aliases = value.aliases or [ ];
        }
    ) raw;

  # Get required dep arg names from a package function (no evaluation needed).
  getRequiredDeps =
    pkg:
    let
      systemArgs = [
        "scope"
        "lib"
        "kix"
      ];
    in
    if builtins.isFunction pkg then
      let
        fnArgs = builtins.functionArgs pkg;
        depArgs = removeAttrs fnArgs systemArgs;
      in
      builtins.filter (name: !depArgs.${name}) (builtins.attrNames depArgs)
    else
      [ ];

  # Compute auto-instantiated instances and activated optionals.
  # Uses builtins.genericClosure for transitive reachability over required deps.
  #
  # Returns { autoInstances = { ns.instName = instCfg; }; activatedOptionals = { "ns/instName" = true; }; }
  computeAutoInstances =
    {
      explicitInstances,
      availablePackages,
      autoNamespace,
    }:
    let
      normalizedAvail = normalizeAvailablePackages availablePackages;

      # --- Build lookup indexes ---

      # availableByKey: depName → canonical availablePackages key
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

      # Partition explicit instances into mandatory and optional
      mandatory = lib.mapAttrs (
        _ns: nsInsts: lib.filterAttrs (_: inst: !(inst.optional or false)) nsInsts
      ) explicitInstances;

      optional = lib.mapAttrs (
        _ns: nsInsts: lib.filterAttrs (_: inst: inst.optional or false) nsInsts
      ) explicitInstances;

      # mandatoryKeys: set of resolution keys from mandatory instances
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

      # optionalByKey: depName → { ns, instName }
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

      # --- Seed: required deps from mandatory instances ---
      seeds = builtins.concatMap (
        ns:
        builtins.concatMap (
          instName:
          let
            instCfg = mandatory.${ns}.${instName};
            reqDeps = getRequiredDeps instCfg.package;
          in
          builtins.concatMap (
            depName:
            if mandatoryKeys ? ${depName} then
              [ ] # already satisfied by a mandatory instance
            else
              [
                {
                  key = "${depName}@${ns}";
                  inherit depName;
                  requesterNs = ns;
                }
              ]
          ) reqDeps
        ) (builtins.attrNames (mandatory.${ns} or { }))
      ) (builtins.attrNames mandatory);

      # --- genericClosure: transitive reachability ---
      closure = builtins.genericClosure {
        startSet = seeds;
        operator =
          item:
          let
            depName = item.depName;
            requesterNs = item.requesterNs;
          in
          # A) Check optional instances first
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

          # B) Check availablePackages
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

          # C) Neither found — will error in resolveArg later
          else
            [ ];
      };

      # --- Collect activated optionals ---
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

      # --- Collect auto-instances ---
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

      # Group by namespace, dedup by instName (first wins)
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
