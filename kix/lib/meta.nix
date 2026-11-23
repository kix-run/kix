{ lib }:

let
  unsafe = import ./unsafe.nix { inherit lib; };
  roles = import ./eval/roles.nix { inherit lib; };

  versions = import ./core/version.nix { inherit lib; };
  errors = import ./core/error.nix { inherit lib; };
  packageLib = import ./core/package.nix { inherit lib; };
  inherit (import ./core/util.nix { inherit lib; }) instanceLabel reasonSentence;

  failedAssertion = message: {
    assertion = false;
    inherit message;
  };

  # Check `version` against a `minVersion`/`maxVersion` constraint set.
  # Non-version constraints fail as author errors. Null, non-version, or
  # under-precise versions emit warnings instead, except that null is skipped
  # silently when `warnWhenNull` is false. `dependency` names the dependency
  # whose version this is, or is null.
  constraintDiagnostics =
    {
      field,
      subject,
      version,
      constraint,
      describeFailure,
      warnWhenNull ? true,
      dependency ? null,
    }:
    let
      skipped = message: {
        inherit message dependency;
      };
      bounds = builtins.filter (b: constraint ? ${b}) [
        "minVersion"
        "maxVersion"
      ];
      badBounds = builtins.filter (b: !(versions.isVersion constraint.${b})) bounds;
      reason = lib.optionalString (constraint ? reason) ". ${constraint.reason}";
      check =
        bound:
        let
          want = constraint.${bound};
          result =
            if bound == "minVersion" then versions.atLeast version want else versions.atMost version want;
        in
        if result == null then
          {
            warnings = [
              (skipped "cannot check ${field}: ${subject} reports version \"${version}\", which is less precise than ${bound} \"${want}\", so Kix skipped this version check.")
            ];
            assertions = [ ];
          }
        else
          {
            warnings = [ ];
            assertions = lib.optional (!result) (failedAssertion (describeFailure bound want + reason));
          };
      checks = map check bounds;
    in
    if badBounds != [ ] then
      {
        warnings = [ ];
        assertions = map (
          b:
          failedAssertion "${field}.${b} ${
            builtins.toJSON constraint.${b}
          } is not a version: expected numbers separated by dots, for example \"1.31\" or \"v2.12.2\"."
        ) badBounds;
      }
    else if bounds == [ ] then
      noDiagnostics
    else if version == null && !warnWhenNull then
      noDiagnostics
    else if version == null then
      {
        warnings = [
          (skipped "cannot check ${field}: ${subject} reports no version, so Kix skipped this version check.")
        ];
        assertions = [ ];
      }
    else if !(versions.isVersion version) then
      {
        warnings = [
          (skipped "cannot check ${field}: ${subject} reports ${builtins.toJSON version}, which is not a version number (such as \"1.31\" or \"2.4.0\"), so Kix skipped this version check.")
        ];
        assertions = [ ];
      }
    else
      {
        warnings = builtins.concatMap (c: c.warnings) checks;
        assertions = builtins.concatMap (c: c.assertions) checks;
      };

  # Return warning or assertion `w` with `dependency` set to `name` unless it
  # sets one.
  aboutDependency =
    name: w:
    {
      dependency = name;
    }
    // (if builtins.isString w then { message = w; } else w);

  emitTraces = prefix: items: lib.foldl' (acc: msg: builtins.trace "${prefix}${msg}" acc) null items;

  noDiagnostics = {
    warnings = [ ];
    assertions = [ ];
    failedAssertions = [ ];
  };

in
rec {
  peekPackageMeta =
    { package, kixlib }:
    packageLib.metaOf {
      inherit package;
      kix = kixlib;
    };

  scopeValues = [
    "cluster"
    "namespace"
  ];

  # Return `meta.scope` as declared, or null when the package leaves it
  # unset. Refuse a value outside `scopeValues`.
  scopeOf =
    { packageMeta, context }:
    let
      scope = packageMeta.scope or null;
    in
    if scope == null || builtins.elem scope scopeValues then
      scope
    else
      errors.fail {
        message = "meta.scope of ${context} is ${builtins.toJSON scope}.";
        fix = "Set it to \"cluster\" or \"namespace\", or leave it unset.";
      };

  # Return a package's `meta.conflictsWith` entries as `{ key; reason; }`.
  # An entry is a key, such as "cluster:tailscale", or `{ key; reason; }`,
  # where `reason` is a sentence that says why two such instances cannot
  # run together.
  conflictEntries =
    packageMeta:
    map (
      e:
      if builtins.isString e then
        {
          key = e;
          reason = null;
        }
      else if
        builtins.isAttrs e
        && builtins.isString (e.key or null)
        && builtins.isString (e.reason or "")
        &&
          removeAttrs e [
            "key"
            "reason"
          ] == { }
      then
        {
          inherit (e) key;
          reason = e.reason or null;
        }
      else
        errors.fail {
          message = "meta.conflictsWith contains an invalid entry: ${builtins.toJSON e}.";
          fix = "Write each entry as a string (\"<name>\" or \"cluster:<name>\") or as { key = \"...\"; reason = \"...\"; }.";
        }
    ) (packageMeta.conflictsWith or [ ]);

  # Return the keys of a package's `meta.conflictsWith` entries.
  conflictKeys = packageMeta: map (e: e.key) (conflictEntries packageMeta);

  # Return whether a package serves every namespace. Dependency resolution
  # binds an instance of such a package from any namespace, and
  # auto-instantiation places it once per cluster. A package serves the whole
  # cluster when it sets `meta.scope = "cluster"`, claims a role in
  # `meta.roles`, or declares `meta.conflictsWith` on a `cluster:` key.
  # `meta.scope = "namespace"` wins over a role or a conflict. A package
  # that sets none of these is used from another namespace only when the
  # cluster definition names it with `ref`.
  servesCluster =
    { packageMeta, context }:
    let
      scope = scopeOf { inherit packageMeta context; };
    in
    scope == "cluster"
    || (
      scope != "namespace"
      && (
        (packageMeta.roles or [ ]) != [ ]
        || builtins.any (lib.hasPrefix "cluster:") (conflictKeys packageMeta)
      )
    );

  # Return the DI aliases for an instance. Role names always remain active.
  # A list in `instanceAliases` replaces `meta.defaultAliases`, even an empty
  # one, and null keeps the defaults.
  effectiveAliases =
    { instanceAliases, packageMeta }:
    lib.unique (
      (packageMeta.roles or [ ])
      ++ (if instanceAliases != null then instanceAliases else packageMeta.defaultAliases or [ ])
    );

  peekPackageAliases =
    {
      availEntry,
      kixlib,
      context ? "availablePackages entry",
    }:
    let
      explicitAliases = availEntry.aliases or [ ];
      packageMeta = peekPackageMeta {
        package = availEntry.package;
        inherit kixlib;
      };
      # Validate `meta.roles` here because `availablePackages` entries bypass
      # `buildRolesIndex` until instantiated.
      catalogRoles = map (roles.assertKnownRole "meta.roles of ${context}") (packageMeta.roles or [ ]);
    in
    lib.unique (explicitAliases ++ catalogRoles ++ (packageMeta.defaultAliases or [ ]));

  # Return the version an instance reports on its PackageInstance and to the
  # `meta.compatibleWith` checks of its consumers. The instance's `version`
  # option wins. Next comes the `out.version` the package builds, which may
  # be null when the instance runs an image whose tag names no version.
  # A package that builds no `out.version` reports its `meta.version`.
  instanceVersion =
    {
      instCfg,
      packageOut,
      packageMeta,
    }:
    if (instCfg.version or null) != null then
      instCfg.version
    else if packageOut ? version then
      packageOut.version
    else
      packageMeta.version or null;

  checkMetaStatic =
    {
      packageMeta,
      instanceName,
      namespaceName,
      clusterConfig,
      resolvedDepMeta,
      resolutionIndex,
    }:
    let
      # `meta.k8s` holds two ranges. The bounds at its top level refuse a
      # cluster, so each needs evidence that the package fails outside it.
      # `supported` is what upstream states it supports, and only warns.
      k8s = removeAttrs (packageMeta.k8s or { }) [ "supported" ];
      k8sSupported = removeAttrs ((packageMeta.k8s or { }).supported or { }) [ "source" ];
      clusterK8s = clusterConfig.k8sVersion or null;

      supportedRange =
        let
          min = k8sSupported.minVersion or null;
          max = k8sSupported.maxVersion or null;
        in
        if min != null && max != null then
          (if min == max then "${min} only" else "${min} to ${max}")
        else if min != null then
          "${min} and later"
        else
          "${max} and earlier";
      supportedSource = (packageMeta.k8s or { }).supported.source or null;
      supportedDiag = constraintDiagnostics {
        field = "meta.k8s.supported";
        subject = "the cluster's k8sVersion";
        version = clusterK8s;
        constraint = k8sSupported;
        warnWhenNull = false;
        describeFailure =
          _: _:
          "the cluster sets k8sVersion to ${clusterK8s}, while the upstream project supports or tests Kubernetes ${supportedRange}. Kix knows of no failure on Kubernetes ${clusterK8s}, so the build continues."
          + lib.optionalString (supportedSource != null) " Source: ${supportedSource}."
          + " To stay on a supported Kubernetes version, move the cluster to one and update k8sVersion.";
      };
      supportedIsMalformed = builtins.any (
        b: k8sSupported ? ${b} && !(versions.isVersion k8sSupported.${b})
      ) (builtins.attrNames k8sSupported);
      # A version outside `supported` warns once, even when it misses both
      # bounds. A bound that is not a version stays an author error.
      supportedWarnings =
        supportedDiag.warnings
        ++ lib.optionals (!supportedIsMalformed) (lib.unique (map (a: a.message) supportedDiag.assertions));
      supportedAssertions = lib.optionals supportedIsMalformed supportedDiag.assertions;

      # Most clusters leave k8sVersion unset, so null does not warn.
      k8sDiag = constraintDiagnostics {
        field = "meta.k8s";
        subject = "the cluster's k8sVersion";
        version = clusterK8s;
        constraint = k8s;
        warnWhenNull = false;
        describeFailure =
          bound: want:
          if bound == "minVersion" then
            "package requires Kubernetes ${want} or newer, cluster targets ${clusterK8s}"
          else
            "package requires Kubernetes ${want} or older, cluster targets ${clusterK8s}";
      };

      compat = packageMeta.compatibleWith or { };
      compatDiags = builtins.concatMap (
        depName:
        map (
          depTarget:
          let
            dep = depTarget.instance;
            depVersion = dep._meta.version;
          in
          constraintDiagnostics {
            field = "meta.compatibleWith.${depName}";
            subject = "dependency '${depName}'";
            dependency = depName;
            version = depVersion;
            constraint = compat.${depName};
            describeFailure =
              bound: want:
              if bound == "minVersion" then
                "dependency '${depName}' version ${depVersion} is older than the required minimum ${want}"
              else
                "dependency '${depName}' version ${depVersion} is newer than the supported maximum ${want}";
          }
        ) (resolvedDepMeta.${depName}.targets or [ ])
      ) (builtins.attrNames compat);

      versionDiags = [ k8sDiag ] ++ compatDiags;

      conflictAssertions = builtins.concatMap (
        entry:
        let
          conflict = entry.key;
          isClusterWide = lib.hasPrefix "cluster:" conflict;
          name = if isClusterWide then lib.removePrefix "cluster:" conflict else conflict;
          isSelf = c: c.instName == instanceName && c.namespace == namespaceName;
          # An instance whose package declares `name` as a default alias
          # conflicts even when its own `aliases` replace that default.
          byKey = resolutionIndex.byKey.${name} or [ ];
          sameInstance = a: b: a.instName == b.instName && a.namespace == b.namespace;
          candidates =
            byKey
            ++ builtins.filter (c: !(builtins.any (sameInstance c) byKey)) (
              resolutionIndex.byDefaultAlias.${name} or [ ]
            );
          matching =
            if isClusterWide then
              builtins.filter (c: !(isSelf c)) candidates
            else
              builtins.filter (c: c.namespace == namespaceName && !(isSelf c)) candidates;
          scope = if isClusterWide then "(cluster-wide)" else "in namespace '${namespaceName}'";
          isAuto = c: (c.meta.autoInstantiatedFor or null) != null;
          label = c: instanceLabel "${c.namespace}/${c.instName}" (c.meta.autoInstantiatedFor or null);
          instances = builtins.concatStringsSep ", " (map label matching);
          autoAdvice = lib.optionalString (builtins.any isAuto matching) (
            " An auto-instantiated instance is created for a required dependency that no declared instance answers. "
            + "Make ${namespaceName}/${instanceName} answer '${name}' (instances.${namespaceName}.${instanceName}.aliases), "
            + "or bind the consumers to it with deps.<arg> = ref.${namespaceName}.${instanceName}."
          );
        in
        lib.optional (matching != [ ]) {
          assertion = false;
          message =
            "It conflicts with '${name}' ${scope}. Conflicting instances: ${instances}."
            + lib.optionalString (entry.reason != null) " ${reasonSentence entry.reason}"
            + autoAdvice;
          fix =
            if isClusterWide then
              "Remove either ${namespaceName}/${instanceName} or the conflicting instance(s) so they do not run in the same cluster. If they are copies of the same cluster-wide package, keep one instance and consumers in every namespace will use it."
            else
              "Remove ${namespaceName}/${instanceName}, or remove or move the conflicting instance(s) to another namespace.";
        }
      ) (conflictEntries packageMeta);

      # Validate `meta.scope` up front, because resolution reads it only for
      # a dependency from another namespace.
      scopeValue = packageMeta.scope or null;
      scopeAssertions = lib.optional (scopeValue != null && !(builtins.elem scopeValue scopeValues)) (
        failedAssertion "meta.scope is ${builtins.toJSON scopeValue}. Set it to \"cluster\" or \"namespace\", or leave it unset."
      );

      # Validate `meta.unsafe` grants up front so unknown grant names fail even
      # when the corresponding rule does not fire during evaluation.
      unsafeAssertions = builtins.concatMap (
        grant:
        lib.optional (!(unsafe.registry ? ${grant})) (
          failedAssertion "meta.unsafe contains unknown grant '${grant}'. ${unsafe.knownGrantsHint}"
        )
      ) (packageMeta.unsafe or [ ]);

      deprecated = packageMeta.deprecated or null;
      deprecationWarnings =
        if deprecated == null then
          [ ]
        else
          [
            (
              "package '${instanceName}' is deprecated: ${deprecated.message or "no reason given"}"
              + lib.optionalString (deprecated ? replacement) ". Use '${deprecated.replacement}' instead"
            )
          ];
    in
    {
      assertions = lib.concatLists [
        (builtins.concatMap (d: d.assertions) versionDiags)
        supportedAssertions
        conflictAssertions
        scopeAssertions
        unsafeAssertions
      ];
      warnings =
        deprecationWarnings ++ builtins.concatMap (d: d.warnings) versionDiags ++ supportedWarnings;
    };

  evaluatePackageDiagnostics =
    {
      raw,
      evaluatedConfig,
      parts,
      resolvedDepMeta,
      depsEnrichment ? { },
      resolvedDeps ? { },
    }:
    let
      ctx = {
        config = evaluatedConfig;
        self = parts;
        deps = lib.mapAttrs (_: di: di.value) resolvedDepMeta;
      };

      depDiagnostics =
        lib.foldlAttrs
          (
            acc: depName: enrichment:
            let
              dep = resolvedDeps.${depName} or null;
            in
            if dep == null then
              acc
            else
              {
                warnings =
                  acc.warnings
                  ++ map (aboutDependency depName) (if enrichment ? warnings then enrichment.warnings dep else [ ]);
                assertions =
                  acc.assertions
                  ++ map (aboutDependency depName) (
                    if enrichment ? assertions then enrichment.assertions dep else [ ]
                  );
              }
          )
          {
            warnings = [ ];
            assertions = [ ];
          }
          depsEnrichment;
    in
    {
      warnings = (if raw ? warnings then raw.warnings ctx else [ ]) ++ depDiagnostics.warnings;
      assertions = (if raw ? assertions then raw.assertions ctx else [ ]) ++ depDiagnostics.assertions;
    };

  # An assertion is `{ assertion; message; fix ? null; id ? null; option ?
  # null; }`, with the fields `kix.fail` takes (`core/error.nix`). A warning
  # is a message or a record with those fields. Each assertion and warning
  # gets `instance` set to the instance that raised it, so the code that
  # raises one leaves the instance out of its text.
  #
  # `scorecardWarnings` are left out of `allWarnings`, because the scorecard
  # report already carries them as findings and the CLI shows that report.
  #
  # `evaluateWarnings` computes every warning and prints nothing. The
  # instance forces it, so an error raised while a warning is worked out
  # stops the build of the instance.
  combineDiagnostics =
    {
      instanceName,
      namespaceName,
      metaResult,
      packageResult,
      structuralWarnings,
      scorecardWarnings ? [ ],
    }:
    let
      instance = "${namespaceName}/${instanceName}";
      allWarnings = map (errors.warning instance) (
        metaResult.warnings ++ structuralWarnings ++ packageResult.warnings
      );
      allAssertions = map (a: { inherit instance; } // a) (
        metaResult.assertions ++ packageResult.assertions
      );
      failedAssertions = builtins.filter (a: !a.assertion) allAssertions;
    in
    {
      inherit allWarnings allAssertions failedAssertions;
      evaluateWarnings = builtins.deepSeq (
        map (errors.describe "  ") allWarnings ++ scorecardWarnings
      ) null;
      emitAssertionWarnings = emitTraces "ASSERTION FAILED: " (
        map (a: "${a.instance}: ${a.message}") failedAssertions
      );
    };

  # Aggregate diagnostics across all instances and attach cluster- and
  # namespace-level ones. `scorecardWarnings` are left out of `warnings`, as
  # in `combineDiagnostics`. `evaluateExtraWarnings` computes them and prints
  # nothing. Each instance has already computed its own warnings.
  collectClusterDiagnostics =
    {
      clusterName,
      allInstancesList,
      scorecardWarnings ? [ ],
      extraAssertions ? [ ],
      extraWarnings ? [ ],
    }:
    let
      collect =
        field: builtins.concatMap (inst: (inst._diagnostics or noDiagnostics).${field}) allInstancesList;
      warnings = collect "warnings" ++ extraWarnings;
      assertions = collect "assertions" ++ extraAssertions;
      failedAssertions = collect "failedAssertions" ++ builtins.filter (a: !a.assertion) extraAssertions;
      assertionCheck =
        if failedAssertions == [ ] then
          null
        else
          errors.failAll {
            cluster = clusterName;
            errors = map (errors.fromAssertion null) failedAssertions;
          };
    in
    {
      inherit
        warnings
        assertions
        failedAssertions
        assertionCheck
        ;
      evaluateExtraWarnings = builtins.deepSeq scorecardWarnings null;
    };
}
