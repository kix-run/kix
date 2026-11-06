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

  # Format an instance identifier for resolution error messages, noting
  # auto-instantiated instances that do not appear in the cluster config.
  describeRequester =
    namespaceName: instanceName: instCfg:
    "${namespaceName}/${instanceName}${
      lib.optionalString (instCfg._autoInstantiated or false) " (auto-instantiated)"
    }";

  isRef = v: builtins.isAttrs v && (v._type or "") == "kix-ref";

  refsOf =
    v:
    if isRef v then
      [ v ]
    else if builtins.isList v then
      builtins.filter isRef v
    else
      [ ];

  # Return the `{ namespace, instanceName }` targets for a single or list
  # dependency resolution.
  targetsOf = resolution: resolution.targets or [ { inherit (resolution) namespace instanceName; } ];

  # Reject `deps` references that point to an `availablePackages` entry that
  # was neither declared nor auto-instantiated.
  checkRefTargets =
    { instances, mergedInstances }:
    lib.foldlAttrs (
      acc: nsName: nsInsts:
      lib.foldlAttrs (
        acc: instName: instCfg:
        lib.foldlAttrs (
          acc: arg: v:
          lib.foldl' (
            acc: r:
            if (mergedInstances.${r.namespace} or { }) ? ${r.instanceName} then
              acc
            else
              throw "kix: ${nsName}/${instName} ${
                if builtins.isList v then
                  "lists ref.${r.namespace}.${r.instanceName} in deps.${arg}"
                else
                  "sets deps.${arg} = ref.${r.namespace}.${r.instanceName}"
              }, which is not an instance. It names a package in availablePackages that nothing auto-instantiated there; declare it under instances.${r.namespace}.${r.instanceName}."
          ) acc (refsOf v)
        ) acc (instCfg.deps or { })
      ) acc nsInsts
    ) null instances;

  # Resolve a package dependency argument against `explicitOverride` or
  # `resolutionIndex`. An instance in another namespace binds only when the
  # override names it, when its package serves the whole cluster
  # (`meta.servesCluster`), or when a dependency demand created or switched
  # it on (`demanded` in the index). An unbound optional argument carries `warnings`
  # when an instance in another namespace answers its name, because a
  # `ref` would bind it.
  resolveArg =
    {
      argName,
      resolutionIndex,
      requesterNamespace,
      hasDefault,
      explicitOverride,
      requester ? null,
      # The requesting instance's name, for the `instances.<ns>.<name>` path
      # in messages.
      requesterName ? null,
    }:
    let
      prefix = lib.optionalString (requester != null) "${requester}: ";
      label = c: "${c.namespace}/${c.instName}";
      labels = cs: builtins.concatStringsSep ", " (map label cs);
      depLine = c: "  deps.${argName} = ref.${c.namespace}.${c.instName};";
      depLines = cs: builtins.concatStringsSep "\n" (map depLine cs);
      consumerPath =
        if requesterName != null then
          "instances.${requesterNamespace}.${requesterName}"
        else
          "the consumer's instance";

      # Return the index entry for a ref target, or null when no active
      # instance has that name. `checkRefTargets` reports a missing target.
      indexed =
        t:
        lib.findFirst (c: c.namespace == t.namespace && c.instName == t.instanceName) null (
          resolutionIndex.byKey.${t.instanceName} or [ ]
        );

      # Refuse a ref from another namespace to an instance whose package
      # declares `meta.scope = "namespace"`.
      checkRefScope =
        t:
        let
          c = indexed t;
        in
        if t.namespace != requesterNamespace && c != null && (c.meta.scope or null) == "namespace" then
          throw "${prefix}deps.${argName} = ref.${t.namespace}.${t.instanceName} names an instance in another namespace whose package declares meta.scope = \"namespace\", so it serves only namespace '${t.namespace}'. Use an instance in namespace '${requesterNamespace}', or set meta.scope = \"cluster\" in its package if every namespace may use it."
        else
          t;
    in
    if explicitOverride != null then
      # Resolve `ref` and `[ ref ... ]` overrides with `direct = false` so they
      # run through the same meta checks as auto-resolved dependencies.
      if isRef explicitOverride then
        let
          t = checkRefScope { inherit (explicitOverride) namespace instanceName; };
        in
        {
          found = true;
          inherit (t) namespace instanceName;
          direct = false;
        }
      else if builtins.isList explicitOverride && builtins.any isRef explicitOverride then
        if builtins.all isRef explicitOverride then
          {
            found = true;
            targets = map (r: checkRefScope { inherit (r) namespace instanceName; }) explicitOverride;
            direct = false;
          }
        else
          throw "${prefix}deps.${argName} is a list that mixes ref.<namespace>.<instance> entries with other values. Make every entry a ref, or set deps.${argName} to a value without refs."
      else
        {
          found = true;
          value = explicitOverride;
          direct = true;
        }

    else
      let
        all = resolutionIndex.byKey.${argName} or [ ];
        sameNs = builtins.filter (c: c.namespace == requesterNamespace) all;
        foreign = builtins.filter (c: c.namespace != requesterNamespace) all;
        # Foreign instances every namespace may use: the package serves the
        # whole cluster, or a dependency demand created or switched on the
        # instance (`demanded`), which binds it for every requester of its
        # name. `meta.scope = "namespace"` stays within its namespace.
        usableFromHere =
          c:
          (c.meta.servesCluster or false)
          || ((c.meta.demanded or false) && (c.meta.scope or null) != "namespace");
        serving = builtins.filter usableFromHere foreign;
        # Foreign instances that bind only when a ref names them.
        nameable = builtins.filter (
          c: !(usableFromHere c) && (c.meta.scope or null) != "namespace"
        ) foreign;
        namespaced = builtins.filter (c: (c.meta.scope or null) == "namespace") foreign;

        # Prefer managed instances over imports among the instances this
        # namespace may use, so a managed provider that serves the cluster
        # shadows a flavour's import in the requester's namespace.
        eligible = sameNs ++ serving;
        managed = builtins.filter (c: !(c.meta.isImport or false)) eligible;
        candidates = if managed != [ ] then managed else eligible;
        own = builtins.filter (c: c.namespace == requesterNamespace) candidates;
        shared = builtins.filter (c: c.namespace != requesterNamespace) candidates;

        bind = c: {
          found = true;
          namespace = c.namespace;
          instanceName = c.instName;
          direct = false;
        };
        none = "dependency '${argName}' has no instance in namespace '${requesterNamespace}'.";
        several =
          cs:
          "${toString (builtins.length cs)} instances in other namespaces match: ${labels cs}. Kix does not choose between them. Add one of these lines to ${consumerPath}:\n${depLines cs}";
      in
      if builtins.length own == 1 then
        bind (builtins.head own)

      else if builtins.length own > 1 then
        throw "${prefix}dependency '${argName}' matches multiple instances in namespace '${requesterNamespace}': ${
          builtins.concatStringsSep ", " (map (c: c.instName) own)
        }. Set deps.${argName} explicitly to the intended instance."

      else if builtins.length shared == 1 then
        bind (builtins.head shared)

      else if builtins.length shared > 1 then
        throw "${prefix}${none} ${several (shared ++ nameable)}"

      else if hasDefault then
        {
          found = false;
          warnings = lib.optional (nameable != [ ]) (
            "${prefix}optional dependency '${argName}' has no instance in namespace '${requesterNamespace}', so Kix skips it. "
            + (
              if builtins.length nameable == 1 then
                "${labels nameable} matches in another namespace. To use it, add this line to ${consumerPath}:"
              else
                "${labels nameable} match in other namespaces. To use one, add one of these lines to ${consumerPath}:"
            )
            + "\n${depLines nameable}"
          );
        }

      else if builtins.length nameable == 1 then
        throw "${prefix}${none} One instance in another namespace matches: ${labels nameable}. Kix uses an instance from another namespace only when the cluster definition names it or its package serves the whole cluster. To use it, add this line to ${consumerPath}:\n${depLines nameable}\nIf this package serves the whole cluster, set meta.scope = \"cluster\" in its package instead."

      else if builtins.length nameable > 1 then
        throw "${prefix}${none} ${several nameable}"

      else
        throw "${prefix}dependency '${argName}' was not found for namespace '${requesterNamespace}'.${
          lib.optionalString (namespaced != [ ])
            " Instances in other namespaces (${labels namespaced}) declare meta.scope = \"namespace\" and serve only their own namespace."
        } Add an instance with that name or alias, or set deps.${argName} explicitly.";

  # Unwrap `deferredModule` definitions into `{ file, value }` pairs,
  # preserving the innermost `_file` for error reporting.
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

  # Priority between `lib.mkDefault` (1000) and option defaults (1500).
  # Package `config` defaults override option defaults while yielding to
  # instance or injected `lib.mkDefault` values.
  packageDefaultPriority = 1250;

  instancePinsLib = import ./instance-pins.nix { inherit lib packageDefaultPriority; };

  # Rewrite `lib.mkDefault` priorities in a package's `config` to
  # `packageDefaultPriority` across `mkIf`, `mkMerge`, `mkOrder`, and nested
  # attrsets.
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

  # Evaluate an instance's option modules, combining package options, package
  # config defaults, dependency config injections, and instance pins. Return
  # `{ config, options }`, where forcing `config` validates locked fields and
  # instance pins.
  evaluateInstanceModules =
    {
      packageOptions,
      packageConfig ? { },
      packageConfigFile ? "package config",
      instCfg,
      clusterConfig ? { },
      configInjections ? [ ],
      namespaceName ? null,
      instanceName ? null,
      instancePins ? null,
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

      # Wrap the package's `config` under `config = ...` so package options
      # named `config`, `options`, or `imports` are not treated as top-level
      # module keys.
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

      result = lib.evalModules {
        prefix = lib.optionals named [
          "instances"
          namespaceName
          instanceName
          "config"
        ];
        specialArgs = { inherit clusterConfig; };
        modules = [
          { options = packageOptions; }
          packageConfigModule
        ]
        ++ injectionModules
        ++ lib.optional (instancePins != null) (instancePinsLib.module instancePins)
        ++ wrappedModules;
      };

      options = removeAttrs result.options [ "_module" ];

      _pinCheck =
        if instancePins == null then
          null
        else
          instancePinsLib.check {
            inherit
              packageOptions
              options
              instancePins
              instanceText
              ;
          };
    in
    {
      inherit options;
      config = builtins.seq _lockedCheck (
        builtins.seq _pinCheck (removeAttrs result.config [ "_module" ])
      );
    };

  evaluateInstanceConfig = args: (evaluateInstanceModules args).config;

  # Evaluate phase 1 of a package definition, passing `scope`, `lib`, and
  # optional `kix` and `availability` arguments.
  normalizePackage =
    {
      package,
      scope,
      availability ? "none",
      kix ? kixlib,
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
        // lib.optionalAttrs (fnArgs ? kix) { inherit kix; }
        // lib.optionalAttrs (fnArgs ? availability) { inherit availability; }
      );

  callPackagePhase1 = normalizePackage;

  # Normalize a package's `build` attribute into a list of build functions,
  # importing any path entries.
  buildEntriesOf =
    rawBuild:
    if builtins.isList rawBuild then
      map (entry: if builtins.isPath entry then import entry else entry) rawBuild
    else
      [ rawBuild ];

  discoverBuildDeps =
    rawBuild:
    let
      buildEntries = buildEntriesOf rawBuild;
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
      requester ? null,
      requesterName ? null,
    }:
    builtins.foldl' (
      acc: argName:
      let
        depSpec = declaredDeps.${argName};
        isOptional = depSpec.optional or false;
        explicitOverride = explicitOverrides.${argName} or null;
        resolution = resolveArg {
          inherit
            argName
            resolutionIndex
            explicitOverride
            requester
            requesterName
            ;
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
            else if resolution ? targets then
              map (t: allInstances.${t.namespace}.${t.instanceName}) resolution.targets
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
      requester ? null,
      requesterName ? null,
    }:
    lib.mapAttrs (
      argName: depSpec:
      let
        isOptional = depSpec.optional or false;
        explicitOverride = explicitOverrides.${argName} or null;
        resolution = resolveArg {
          inherit
            argName
            resolutionIndex
            explicitOverride
            requester
            requesterName
            ;
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
        else if resolution ? targets then
          {
            found = true;
            inherit (resolution) targets;
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
              map (t: {
                targetNs = t.namespace;
                targetInst = t.instanceName;
                config = depEnrichment.config;
                consumerNs = ns;
                consumerInst = inst;
                source = "${ns}/${inst}";
              }) (targetsOf target)
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
