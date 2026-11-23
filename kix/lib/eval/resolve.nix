{ lib, kixlib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  packageLib = import ../core/package.nix { inherit lib; };
  inherit (packageLib) systemArgNames;
  roles = import ./roles.nix { inherit lib; };

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

      groupByKey = lib.foldl' (
        acc: entry:
        acc
        // {
          ${entry.key} = (acc.${entry.key} or [ ]) ++ [ entry ];
        }
      ) { };

      byKey = groupByKey entries;

      # Index instances by their package's `meta.defaultAliases`, including
      # the defaults the instance's own `aliases` replace. The
      # `meta.conflictsWith` check reads it, so an instance cannot leave a
      # singleton's conflict by renaming its aliases.
      byDefaultAlias = groupByKey (
        builtins.concatMap (
          ns:
          builtins.concatMap (
            instName:
            let
              meta = staticMeta.${ns}.${instName}._meta;
            in
            map (key: {
              inherit key instName meta;
              namespace = ns;
            }) (lib.unique (meta.defaultAliases or [ ]))
          ) (builtins.attrNames staticMeta.${ns})
        ) nsNames
      );

    in
    {
      inherit byKey byDefaultAlias;
    };

  # Return the sentence that tells a reader why an instance they did not
  # declare exists, or "" for a declared instance. `addedFor` lists the
  # instances whose dependencies made auto-instantiation add it.
  addedForNote =
    instance: addedFor:
    lib.optionalString (addedFor != [ ])
      " The cluster definition does not declare ${instance}. Kix added it from availablePackages because ${builtins.concatStringsSep ", " addedFor} ${
         if builtins.length addedFor == 1 then "depends" else "depend"
       } on it.";

  # Return the error for a required dependency on a cluster role that no
  # instance provides. A provider of a role serves every namespace, so the
  # fix may declare it in any namespace. It lists the packages of Kix's own
  # set that claim the role in `meta.roles`.
  missingRole =
    role:
    let
      byLevel = import ../../packages/by-level.nix { inherit lib; };
      claims =
        package:
        builtins.elem role (
          (packageLib.metaOf {
            inherit package;
            kix = kixlib;
          }).roles or [ ]
        );
      claimants =
        builtins.concatMap
          (
            level:
            map (package: "packages.${builtins.replaceStrings [ "/" ] [ "." ] (packageLib.idOf package)}") (
              builtins.filter claims (builtins.attrValues byLevel.${level})
            )
          )
          [
            "stable"
            "experimental"
          ];
    in
    {
      message = "dependency '${role}' is a cluster role, and no instance in the cluster provides it.";
      fix =
        (
          if claimants == [ ] then
            "Declare an instance in any namespace of a package with meta.roles = [ \"${role}\" ]."
          else
            "Declare an instance of a package that provides '${role}' in any namespace:"
            + lib.concatMapStrings (c: "\n  instances.<namespace>.<name>.package = ${c};") claimants
        )
        + "\nIf the cluster already provides '${role}' outside Kix, declare an import with `package = kix.mkImport { roles = [ \"${role}\" ]; ... };` instead.";
    };

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
              fail {
                instance = "${nsName}/${instName}";
                dependency = arg;
                message = "${
                  if builtins.isList v then "deps.${arg} lists" else "deps.${arg} ="
                } ref.${r.namespace}.${r.instanceName}, which is not a declared instance. '${r.instanceName}' is in availablePackages, and a ref pointer does not create it automatically.";
                fix = "Declare the instance in your cluster definition:\n  instances.${r.namespace}.${r.instanceName}.package = packages.<package>;";
              }
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
      # The requesting instance, as `<namespace>/<name>`.
      requester ? null,
      # The requesting instance's name, for the `instances.<ns>.<name>` path
      # in messages.
      requesterName ? null,
      # The instances whose dependencies made auto-instantiation add the
      # requester, as `<namespace>/<name>`. Empty for a declared instance.
      addedFor ? [ ],
      # `{ name; id; }` from the package's `deps.<arg>.renamedFrom`, when the
      # dependency had another name in an earlier release. `id` is the id of
      # the change record for the rename, such as "K1234".
      renamedFrom ? null,
    }:
    let
      # Fail with `e`, naming the requesting instance and, for an instance
      # that auto-instantiation added, the instances that needed it.
      refuse =
        e:
        fail (
          {
            instance = requester;
          }
          // e
          // {
            message = e.message + addedForNote requester addedFor;
          }
        );
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
          refuse {
            message = "deps.${argName} = ref.${t.namespace}.${t.instanceName} points to an instance in namespace '${t.namespace}' whose package sets meta.scope = \"namespace\", so it cannot be used from namespace '${requesterNamespace}'.";
            fix =
              "Declare a separate instance in namespace '${requesterNamespace}' and point ${consumerPath}.deps.${argName} to it."
              + "\nIf the package can safely serve every namespace, set meta.scope = \"cluster\" in its package instead.";
          }
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
          refuse {
            message = "${consumerPath}.deps.${argName} is a list that mixes ref.<namespace>.<instance> entries with plain values.";
            fix = "Make every list entry a ref.<namespace>.<instance>, or pass a list of plain values without refs.";
          }
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
        none = "dependency '${argName}' has no instance in namespace '${requesterNamespace}', and";
        several = cs: {
          message = "${none} ${toString (builtins.length cs)} instances in other namespaces match: ${labels cs}.";
          fix = "Choose one by adding one of these lines to ${consumerPath}:\n${depLines cs}";
        };
      in
      if builtins.length own == 1 then
        bind (builtins.head own)

      else if builtins.length own > 1 then
        refuse {
          message = "dependency '${argName}' matches multiple instances in namespace '${requesterNamespace}': ${
            builtins.concatStringsSep ", " (map (c: c.instName) own)
          }.";
          fix = "Choose one by adding one of these lines to ${consumerPath}:\n${depLines own}";
        }

      else if builtins.length shared == 1 then
        bind (builtins.head shared)

      else if builtins.length shared > 1 then
        refuse (several (shared ++ nameable))

      else if hasDefault then
        {
          found = false;
          warnings = lib.optional (nameable != [ ]) {
            dependency = argName;
            message =
              "optional dependency '${argName}' has no instance in namespace '${requesterNamespace}', so Kix skipped it. "
              + (
                if builtins.length nameable == 1 then
                  "${labels nameable} matches in another namespace."
                else
                  "${labels nameable} match in other namespaces."
              );
            fix =
              (
                if builtins.length nameable == 1 then
                  "To use it, add this line to ${consumerPath}:"
                else
                  "To use one, add one of these lines to ${consumerPath}:"
              )
              + "\n${depLines nameable}";
          };
        }

      else if builtins.length nameable == 1 then
        refuse {
          message = "${none} 1 instance in another namespace matches: ${labels nameable}.";
          fix =
            "To use ${labels nameable}, add this line to ${consumerPath}:"
            + "\n${depLines nameable}"
            + "\nIf this package serves every namespace in the cluster, set meta.scope = \"cluster\" in its package instead.";
        }

      else if builtins.length nameable > 1 then
        refuse (several nameable)

      else if roles.registry ? ${argName} then
        refuse (missingRole argName)

      else
        refuse {
          # Older packages give the id in brackets, as an error printed it.
          id =
            if renamedFrom == null then null else lib.removeSuffix "]" (lib.removePrefix "[" renamedFrom.id);
          message =
            "dependency '${argName}' has no matching instance in namespace '${requesterNamespace}'."
            +
              lib.optionalString (namespaced != [ ])
                " Matching instances in other namespaces (${labels namespaced}) set meta.scope = \"namespace\" and serve only their own namespace."
            + lib.optionalString (renamedFrom != null) (
              " This dependency was named '${renamedFrom.name}' in earlier releases. An instance named '${renamedFrom.name}' no longer answers it, and neither does deps.${renamedFrom.name}."
            );
          fix =
            "Declare an instance named '${argName}' in namespace '${requesterNamespace}':"
            + "\n  instances.${requesterNamespace}.${argName}.package = packages.<package>;"
            + "\nIf another instance in '${requesterNamespace}' provides '${argName}', wire it in ${consumerPath}:"
            + "\n  deps.${argName} = ref.${requesterNamespace}.<instance>;"
            + lib.optionalString (renamedFrom != null) (
              "\nOr rename the instance named '${renamedFrom.name}' to '${argName}'."
            );
        };

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
            configPath =
              if named then "instances.${namespaceName}.${instanceName}.config" else "the instance config";
          in
          fail {
            message = "${instanceText}: config option(s) ${
              builtins.concatStringsSep ", " (map (c: "'${c.key}' (set by consumer ${c.source})") lockedConflicts)
            } cannot be changed by a dependency because ${configPath} locks ${
              if builtins.length lockedConflicts == 1 then "it" else "them"
            } with kix.mkLocked.";
            fix = "Update the locked value in ${configPath} to include what ${
              builtins.concatStringsSep " and " (lib.unique (map (c: c.source) lockedConflicts))
            } needs, or remove kix.mkLocked so the consumer can set it.";
          }
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
  callPackagePhase1 =
    {
      package,
      scope,
      availability ? "none",
      kix ? kixlib,
      instance ? null,
    }:
    packageLib.call {
      inherit
        package
        scope
        availability
        kix
        instance
        ;
    };

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
      addedFor ? [ ],
      # The package's `deps` attribute, read for `renamedFrom`.
      depsEnrichment ? { },
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
            addedFor
            ;
          renamedFrom = depsEnrichment.${argName}.renamedFrom or null;
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
      addedFor ? [ ],
      # The package's `deps` attribute, read for `renamedFrom`.
      depsEnrichment ? { },
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
            addedFor
            ;
          renamedFrom = depsEnrichment.${argName}.renamedFrom or null;
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
        existing = acc.${e.targetNs}.${e.targetInst} or [ ];
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
