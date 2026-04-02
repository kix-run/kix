# Resolution and dependency injection — index building, DNS-like arg resolution,
# config evaluation, and two-phase package calling.

{ lib, kixlib }:

let
  systemArgNames = [
    "scope"
    "lib"
    "kix"
  ];

  # Args that are passed to build functions by the eval system (not deps).
  systemBuildArgNames = [
    "self"
    "config"
    "clusterConfig"
    "scope"
    "lib"
    "kix"
    "deps"
  ];
in

rec {
  # Build the resolution index from static metadata.
  # Returns { byKey = { argName = [ { namespace, instanceName, ... } ]; }; }
  # Only uses _meta — no inner fixpoint evaluation triggered.
  buildResolutionIndex =
    staticMeta:
    let
      nsNames = builtins.attrNames staticMeta;
      entries = builtins.concatMap (
        ns:
        builtins.concatMap (
          instName:
          let
            meta = staticMeta.${ns}.${instName}._meta;
            keys = lib.unique ([ instName ] ++ (meta.aliases or [ ]));
          in
          map (key: {
            inherit key;
            namespace = ns;
            inherit instName;
            meta = meta;
          }) keys
        ) (builtins.attrNames staticMeta.${ns})
      ) nsNames;

      byKey = lib.foldl' (
        acc: entry:
        acc
        // {
          ${entry.key} = (acc.${entry.key} or [ ]) ++ [ entry ];
        }
      ) { } entries;

    in
    {
      inherit byKey;
    };

  # DNS-like dependency resolution.
  # Returns { found, namespace?, instanceName? } — caller looks up actual instance from fixpoint.
  resolveArg =
    {
      argName,
      resolutionIndex,
      requesterNamespace,
      hasDefault,
      explicitOverride,
    }:
    # 1. Explicit override always wins
    if explicitOverride != null then
      {
        found = true;
        value = explicitOverride;
        direct = true;
      }

    # 2. DNS-like resolution
    else
      let
        candidates = resolutionIndex.byKey.${argName} or [ ];
        sameNs = builtins.filter (c: c.namespace == requesterNamespace) candidates;
        otherNs = builtins.filter (c: c.namespace != requesterNamespace) candidates;
      in
      # Same namespace, exactly one → use it
      if builtins.length sameNs == 1 then
        let
          c = builtins.head sameNs;
        in
        {
          found = true;
          namespace = c.namespace;
          instanceName = c.instName;
          direct = false;
        }

      # Same namespace, multiple → ambiguous
      else if builtins.length sameNs > 1 then
        throw "ambiguous auto-resolution for '${argName}' in namespace '${requesterNamespace}': multiple matches"

      # No same-ns, one cluster-wide → use it
      else if sameNs == [ ] && builtins.length otherNs == 1 then
        let
          c = builtins.head otherNs;
        in
        {
          found = true;
          namespace = c.namespace;
          instanceName = c.instName;
          direct = false;
        }

      # Multiple cluster-wide → ambiguous
      else if builtins.length otherNs > 1 then
        throw "ambiguous auto-resolution for '${argName}': found in multiple namespaces — specify explicitly"

      # No candidates, has Nix default → let Nix handle it
      else if hasDefault then
        { found = false; }

      # No candidates, no default → error
      else
        throw "no '${argName}' found in cluster for namespace '${requesterNamespace}'";

  # Extract raw config attrsets from a deferredModule value.
  # deferredModuleWith wraps each definition as { _file = "..."; imports = [ actualValue ]; }.
  # This unwraps that structure to get the actual config values.
  extractDeferredValues =
    deferredConfig:
    let
      modules = deferredConfig.imports or [ ];
      extractOne =
        m:
        if builtins.isAttrs m && m ? _file && m ? imports then
          # deferredModuleWith wrapper — unwrap
          builtins.concatMap extractOne m.imports
        else if builtins.isAttrs m then
          [ m ]
        else if builtins.isFunction m then
          [ m ]
        else
          [ ];
    in
    builtins.concatMap extractOne modules;

  # Evaluate instance config using the package's typed options.
  # Runs evalModules with the package's option declarations, global defaults,
  # and instance config (a deferredModule from the cluster module system).
  #
  # After evaluation, deep-merges the option defaults onto the result.
  # This preserves nested defaults for `lib.types.anything` options, which
  # don't deep-merge user values with defaults (a user setting `backend.image`
  # would otherwise drop `backend.hpa` from the default).  This matches the
  # deep-merge semantics of the old `scope.defaults` pattern.
  evaluateInstanceConfig =
    {
      packageOptions,
      instCfg,
      clusterConfig ? { },
      configInjections ? [ ],
    }:
    let
      deferredConfig = instCfg.config;
      configValues = extractDeferredValues deferredConfig;

      # --- mkLocked support ---
      # Scan instance config values for locked fields (top-level only).
      findLockedInAttrs =
        attrs:
        if builtins.isAttrs attrs then
          lib.filterAttrs (_: v: builtins.isAttrs v && (v._type or "") == "locked") attrs
        else
          { };

      lockedFields = builtins.foldl' (
        acc: m: if builtins.isAttrs m then acc // findLockedInAttrs m else acc
      ) { } configValues;

      # Check dep injections against locked fields
      lockedConflicts = builtins.concatMap (
        injection:
        let
          injectionKeys = builtins.attrNames (injection.config or { });
          conflicts = builtins.filter (key: lockedFields ? ${key}) injectionKeys;
        in
        map (key: {
          inherit key;
          source = injection.source or "unknown";
        }) conflicts
      ) configInjections;

      _lockedCheck =
        if lockedConflicts != [ ] then
          let
            msgs = map (c: "'${c.key}' (injected by ${c.source})") lockedConflicts;
          in
          throw "dep config injection blocked by locked fields: ${builtins.concatStringsSep ", " msgs}"
        else
          null;

      # Unwrap locked values before feeding into evalModules
      unwrapLocked = v: if builtins.isAttrs v && (v._type or "") == "locked" then v.value else v;

      unwrapLockedAttrs =
        attrs: if builtins.isAttrs attrs then lib.mapAttrs (_: unwrapLocked) attrs else attrs;

      wrappedModules = map (
        v: if builtins.isFunction v then v else { config = unwrapLockedAttrs v; }
      ) configValues;

      # Dep injection modules — merged at same priority as instance config.
      # For listOf types: concatenates with instance config.
      # For scalar types: errors on conflict (user must resolve).
      injectionModules = map (injection: { config = injection.config; }) configInjections;

      evaluated =
        removeAttrs
          (lib.evalModules {
            modules = [
              { options = packageOptions; }
              { config = clusterConfig.global or { }; }
            ]
            ++ injectionModules
            ++ wrappedModules;
          }).config
          [ "_module" ];

      # Collect option defaults for deep merge.
      optionDefaults = lib.filterAttrs (_: v: v != null) (
        lib.mapAttrs (_: opt: if opt ? default then opt.default else null) packageOptions
      );
    in
    builtins.seq _lockedCheck (lib.recursiveUpdate optionDefaults evaluated);

  # Normalize a package value to its phase-1 result.
  # Accepts: function (traditional), attrset with `build` (inline), or kix-import.
  # Returns { meta?, options?, deps?, build, assertions?, warnings? }.
  #
  # This is the SINGLE place that knows about package shapes — all other code
  # calls this instead of doing its own detection.
  normalizePackage =
    { package, scope }:
    if builtins.isAttrs package && package ? build then
      # Inline package — already a { meta?, options?, deps?, build } attrset
      package
    else if (package._type or "") == "kix-import" then
      package
    else
      # Function package — call with system args only
      let
        fnArgs = builtins.functionArgs package;
      in
      package (
        {
          inherit scope lib;
        }
        // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
      );

  # Convenience alias — same as normalizePackage but named for clarity at call sites.
  callPackagePhase1 = normalizePackage;

  # Discover deps by introspecting build function args.
  # Returns { depName = { optional = bool; }; } for each discovered dep.
  discoverBuildDeps =
    rawBuild:
    let
      buildEntries =
        if builtins.isList rawBuild then
          map (entry: if builtins.isPath entry then import entry else entry) rawBuild
        else
          [ rawBuild ];
      # Union all build function args across entries.
      # For deps declared by multiple entries: required wins over optional
      # (both must have a default for the result to be optional).
      allBuildArgs = builtins.foldl' (
        acc: fn:
        let
          fnArgs = builtins.functionArgs fn;
          # For deps in both: AND optionality (required wins)
          overrides = lib.mapAttrs (n: v: acc.${n} && v) (lib.intersectAttrs acc fnArgs);
        in
        acc // fnArgs // overrides
      ) { } buildEntries;
      depArgs = removeAttrs allBuildArgs systemBuildArgNames;
    in
    lib.mapAttrs (name: hasDefault: { optional = hasDefault; }) depArgs;

  # Resolve discovered deps against the cluster.
  # Returns attrset of resolved dep instances (by name).
  resolveDeclaredDeps =
    {
      declaredDeps,
      resolutionIndex,
      namespace,
      explicitOverrides,
      allInstances,
    }:
    builtins.foldl' (
      acc: argName:
      let
        depSpec = declaredDeps.${argName};
        isOptional = depSpec.optional or false;
        explicitOverride = explicitOverrides.${argName} or null;
        resolution = resolveArg {
          inherit argName resolutionIndex explicitOverride;
          requesterNamespace = namespace;
          hasDefault = isOptional;
        };
      in
      if resolution.found then
        acc
        // {
          ${argName} =
            if resolution.direct or false then
              resolution.value
            else
              allInstances.${resolution.namespace}.${resolution.instanceName};
        }
      else
        acc # optional dep, not found — will get null via Nix default
    ) { } (builtins.attrNames declaredDeps);

  # Resolve deps to coordinates only — no instance lookup needed.
  # Used by the phase-1 pre-pass to build the config injection map.
  resolveDepTargets =
    {
      declaredDeps,
      resolutionIndex,
      namespace,
      explicitOverrides,
    }:
    lib.mapAttrs (
      argName: depSpec:
      let
        isOptional = depSpec.optional or false;
        explicitOverride = explicitOverrides.${argName} or null;
        resolution = resolveArg {
          inherit argName resolutionIndex explicitOverride;
          requesterNamespace = namespace;
          hasDefault = isOptional;
        };
      in
      if resolution.found then
        if resolution.direct or false then
          {
            found = true;
            direct = true;
          }
        else
          {
            found = true;
            inherit (resolution) namespace instanceName;
          }
      else
        { found = false; }
    ) declaredDeps;

  # Build the config injection map from phase-1 pre-pass results.
  # Inverts "consumer X wants to inject config into dep Y" into
  # "target Y receives config injections from [X1, X2, ...]".
  #
  # Returns { ns.inst = [ { config, source } ]; }
  buildConfigInjections =
    phase1Map:
    let
      entries = builtins.concatMap (
        ns:
        builtins.concatMap (
          inst:
          let
            p1 = phase1Map.${ns}.${inst};
          in
          builtins.concatMap (
            depName:
            let
              target = p1.resolvedTargets.${depName};
              depEnrichment = p1.depsEnrichment.${depName} or { };
              hasConfig = depEnrichment ? config;
            in
            if target.found && !(target.direct or false) && hasConfig then
              [
                {
                  targetNs = target.namespace;
                  targetInst = target.instanceName;
                  config = depEnrichment.config;
                  source = "${ns}/${inst}";
                }
              ]
            else
              [ ]
          ) (builtins.attrNames p1.discoveredDeps)
        ) (builtins.attrNames phase1Map.${ns})
      ) (builtins.attrNames phase1Map);
    in
    builtins.foldl' (
      acc: e:
      let
        existing = (acc.${e.targetNs} or { }).${e.targetInst} or [ ];
      in
      acc
      // {
        ${e.targetNs} = (acc.${e.targetNs} or { }) // {
          ${e.targetInst} = existing ++ [
            {
              inherit (e) config source;
            }
          ];
        };
      }
    ) { } entries;

  # Lock a config field against dep config injection.
  # Cluster authors wrap a field value with mkLocked to prevent any
  # consumer from injecting into it. Injections targeting a locked
  # field produce a build-time error with source attribution.
  mkLocked = value: {
    _type = "locked";
    inherit value;
  };

  inherit systemArgNames systemBuildArgNames;
}
