{ lib, kixlib }:

let
  systemArgNames = [
    "scope"
    "lib"
    "kix"
    "availability"
  ];

  systemBuildArgNames = [
    "self"
    "config"
    "clusterConfig"
    "scope"
    "lib"
    "kix"
    "deps"
    "availability"
  ];
in

rec {
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

  resolveArg =
    {
      argName,
      resolutionIndex,
      requesterNamespace,
      hasDefault,
      explicitOverride,
    }:
    if explicitOverride != null then
      # `deps.x = ref.a.b` names an instance and resolves like the index
      # would have, so every check an auto-resolved dep gets applies to it.
      # Any other value is bound as it is.
      if builtins.isAttrs explicitOverride && (explicitOverride._type or "") == "kix-ref" then
        {
          found = true;
          inherit (explicitOverride) namespace instanceName;
          direct = false;
        }
      else
        {
          found = true;
          value = explicitOverride;
          direct = true;
        }

    else
      let
        candidates = resolutionIndex.byKey.${argName} or [ ];

        managed = builtins.filter (c: !(c.meta.isImport or false)) candidates;
        effectiveCandidates = if managed != [ ] then managed else candidates;

        sameNs = builtins.filter (c: c.namespace == requesterNamespace) effectiveCandidates;
        otherNs = builtins.filter (c: c.namespace != requesterNamespace) effectiveCandidates;
      in
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

      else if builtins.length sameNs > 1 then
        throw "dependency '${argName}' matches multiple instances in namespace '${requesterNamespace}'. Set deps.${argName} explicitly to the intended instance."

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

      else if builtins.length otherNs > 1 then
        throw "dependency '${argName}' matches instances in multiple namespaces. Set deps.${argName} explicitly to the intended instance."

      else if hasDefault then
        { found = false; }

      else
        throw "dependency '${argName}' was not found for namespace '${requesterNamespace}'. Add an instance with that name or alias, or set deps.${argName} explicitly.";

  # The definitions of an instance's `config` (a deferredModule value), as
  # `{ file; value; }`. deferredModule wraps each definition in
  # `{ _file; imports; }`; `file` is the innermost `_file`, or null.
  extractDeferredDefs =
    deferredConfig:
    let
      modules = deferredConfig.imports or [ ];
      extractOne =
        file: m:
        if builtins.isAttrs m && m ? _file && m ? imports then
          builtins.concatMap (extractOne m._file) m.imports
        else if builtins.isAttrs m || builtins.isFunction m then
          [
            {
              inherit file;
              value = m;
            }
          ]
        else
          [ ];
    in
    builtins.concatMap (extractOne null) modules;

  # Priority of a `lib.mkDefault` in a package's own `config`. It sits
  # between `lib.mkDefault` (1000) and an option's declared default (1500),
  # so the package default replaces the declared default, and an instance or
  # config injection replaces the package default even when it also uses
  # `lib.mkDefault`.
  packageDefaultPriority = 1250;

  # Moves every `lib.mkDefault` in a package's `config` to
  # `packageDefaultPriority`, through `mkIf`, `mkMerge`, `mkOrder` and
  # nested attrsets. Other priorities and plain values keep their meaning,
  # so a plain value in a package's `config` conflicts with a plain instance
  # value. `mapAttrs` keeps the rewrite lazy: a value is forced only when
  # the module system reads it.
  lowerPackageDefaults =
    value:
    if !builtins.isAttrs value then
      value
    else
      let
        type = value._type or null;
      in
      if type == null then
        lib.mapAttrs (_: lowerPackageDefaults) value
      else if type == "override" then
        value
        // {
          priority =
            if value.priority == (lib.mkDefault null).priority then packageDefaultPriority else value.priority;
          content = lowerPackageDefaults value.content;
        }
      else if type == "if" || type == "order" then
        value // { content = lowerPackageDefaults value.content; }
      else if type == "merge" then
        value // { contents = map lowerPackageDefaults value.contents; }
      else
        value;

  # `packageConfig` is the package's own `config`, a plain attrset or a
  # module function such as `{ config, lib, ... }: { ... }`. It is one more
  # module beside `packageOptions`, so a package can default one option
  # from another with `lib.mkDefault` (see `packageDefaultPriority`).
  # `packageConfigFile` names that module in module-system errors. With
  # `namespaceName` and `instanceName`, option errors name the option as
  # `instances.<ns>.<instance>.config.<option>`.
  evaluateInstanceConfig =
    {
      packageOptions,
      packageConfig ? { },
      packageConfigFile ? "package config",
      instCfg,
      clusterConfig ? { },
      configInjections ? [ ],
      namespaceName ? null,
      instanceName ? null,
    }:
    let
      deferredConfig = instCfg.config;
      configDefs = extractDeferredDefs deferredConfig;
      configValues = map (d: d.value) configDefs;
      named = namespaceName != null && instanceName != null;
      instanceText = if named then "${namespaceName}/${instanceName}" else "this instance";

      findLockedInAttrs =
        attrs:
        if builtins.isAttrs attrs then
          lib.filterAttrs (_: v: builtins.isAttrs v && (v._type or "") == "locked") attrs
        else
          { };

      lockedFields = builtins.foldl' (
        acc: m: if builtins.isAttrs m then acc // findLockedInAttrs m else acc
      ) { } configValues;

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
          throw "dependency configuration tries to override locked fields: ${builtins.concatStringsSep ", " msgs}"
        else
          null;

      unwrapLocked = v: if builtins.isAttrs v && (v._type or "") == "locked" then v.value else v;

      unwrapLockedAttrs =
        attrs: if builtins.isAttrs attrs then lib.mapAttrs (_: unwrapLocked) attrs else attrs;

      # Each module carries the file that defined it, so a module-system
      # error names that file rather than `<unknown-file>`.
      wrappedModules = map (
        d:
        let
          file =
            if d.file != null then
              toString d.file
            else if named then
              "instances.${namespaceName}.${instanceName}.config"
            else
              "instance config";
        in
        if builtins.isFunction d.value then
          {
            _file = file;
            imports = [ d.value ];
          }
        else
          {
            _file = file;
            config = unwrapLockedAttrs d.value;
          }
      ) configDefs;

      injectionModules = map (injection: {
        _file = "config injected into ${instanceText} by ${injection.source or "a dependency"}";
        config = injection.config;
      }) configInjections;

      # The package's `config` is always wrapped as a module's `config`, so
      # a package option named `config`, `options` or `imports` is set
      # rather than read as module structure.
      packageConfigModule =
        if builtins.isFunction packageConfig then
          lib.setFunctionArgs (args: {
            _file = packageConfigFile;
            config = lowerPackageDefaults (packageConfig args);
          }) (lib.functionArgs packageConfig)
        else
          {
            _file = packageConfigFile;
            config = lowerPackageDefaults packageConfig;
          };

      evaluated =
        removeAttrs
          (lib.evalModules {
            prefix = lib.optionals named [
              "instances"
              namespaceName
              instanceName
              "config"
            ];
            modules = [
              { options = packageOptions; }
              packageConfigModule
            ]
            ++ injectionModules
            ++ wrappedModules;
          }).config
          [ "_module" ];

      optionDefaults = lib.filterAttrs (_: v: v != null) (
        lib.mapAttrs (_: opt: if opt ? default then opt.default else null) packageOptions
      );

      # The post-eval recursive merge preserves nested defaults for
      # types.anything options. Do not reintroduce those defaults when the
      # instance explicitly used mkForce on the whole option.
      forcedOptionNames = lib.unique (
        builtins.concatMap (
          value:
          if builtins.isAttrs value then
            builtins.attrNames (
              lib.filterAttrs (
                _: optionValue:
                builtins.isAttrs optionValue
                && (optionValue._type or "") == "override"
                && (optionValue.priority or null) == (lib.mkForce null).priority
              ) value
            )
          else
            [ ]
        ) configValues
      );
      mergeableDefaults = removeAttrs optionDefaults forcedOptionNames;
    in
    builtins.seq _lockedCheck (lib.recursiveUpdate mergeableDefaults evaluated);

  # `availability` is the instance's resolved level (core/availability.nix),
  # a plain string a package may take as an argument so its option defaults
  # can read it.
  normalizePackage =
    {
      package,
      scope,
      availability ? "none",
    }:
    if builtins.isAttrs package && package ? build then
      package
    else if (package._type or "") == "kix-import" then
      package
    else
      let
        fnArgs = builtins.functionArgs package;
      in
      package (
        {
          inherit scope lib;
        }
        // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
        // lib.optionalAttrs (fnArgs ? availability) { inherit availability; }
      );

  callPackagePhase1 = normalizePackage;

  discoverBuildDeps =
    rawBuild:
    let
      buildEntries =
        if builtins.isList rawBuild then
          map (entry: if builtins.isPath entry then import entry else entry) rawBuild
        else
          [ rawBuild ];
      allBuildArgs = builtins.foldl' (
        acc: fn:
        let
          fnArgs = builtins.functionArgs fn;
          overrides = lib.mapAttrs (n: v: acc.${n} && v) (lib.intersectAttrs acc fnArgs);
        in
        acc // fnArgs // overrides
      ) { } buildEntries;
      depArgs = removeAttrs allBuildArgs systemBuildArgNames;
    in
    lib.mapAttrs (_: hasDefault: { optional = hasDefault; }) depArgs;

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
        acc
    ) { } (builtins.attrNames declaredDeps);

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
                  consumerNs = ns;
                  consumerInst = inst;
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
              inherit (e)
                config
                source
                consumerNs
                consumerInst
                ;
            }
          ];
        };
      }
    ) { } entries;

  mkLocked = value: {
    _type = "locked";
    inherit value;
  };

  inherit systemArgNames systemBuildArgNames;
}
