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
    }:
    let
      deferredConfig = instCfg.config;
      configValues = extractDeferredValues deferredConfig;
      wrappedModules = map (v: if builtins.isFunction v then v else { config = v; }) configValues;

      evaluated =
        removeAttrs
          (lib.evalModules {
            modules = [
              { options = packageOptions; }
              { config = clusterConfig.global or { }; }
            ]
            ++ wrappedModules;
          }).config
          [ "_module" ];

      # Collect option defaults for deep merge.
      optionDefaults = lib.filterAttrs (_: v: v != null) (
        lib.mapAttrs (_: opt: if opt ? default then opt.default else null) packageOptions
      );
    in
    lib.recursiveUpdate optionDefaults evaluated;

  # Phase 1: call package function with system args only.
  # Returns { meta?, options?, deps?, build, assertions?, warnings? }.
  # No dep resolution — package function must not take dep args.
  callPackagePhase1 =
    { packageFn, scope }:
    let
      fnArgs = builtins.functionArgs packageFn;
    in
    packageFn (
      {
        inherit scope lib;
      }
      // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
    );

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
      # Union all build function args across entries
      allBuildArgs = builtins.foldl' (acc: fn: acc // builtins.functionArgs fn) { } buildEntries;
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

  inherit systemArgNames systemBuildArgNames;
}
