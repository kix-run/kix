{ lib }:

let
  unsafe = import ./unsafe.nix { inherit lib; };
  roles = import ./eval/roles.nix { inherit lib; };

  versions = import ./core/version.nix { inherit lib; };
  errors = import ./core/error.nix { inherit lib; };

  fail = message: {
    assertion = false;
    inherit message;
  };

  # Check `version` against a `minVersion`/`maxVersion` constraint set.
  # Non-version constraints fail as author errors. Null, non-version, or
  # under-precise versions emit warnings instead, except that null is skipped
  # silently when `warnWhenNull` is false.
  constraintDiagnostics =
    {
      field,
      subject,
      version,
      constraint,
      describeFailure,
      warnWhenNull ? true,
    }:
    let
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
              "cannot check ${field}: ${subject} reports version \"${version}\", which is less precise than ${bound} \"${want}\", so Kix cannot tell. Kix skipped the check."
            ];
            assertions = [ ];
          }
        else
          {
            warnings = [ ];
            assertions = lib.optional (!result) (fail (describeFailure bound want + reason));
          };
      checks = map check bounds;
    in
    if badBounds != [ ] then
      {
        warnings = [ ];
        assertions = map (
          b:
          fail "${field}.${b} ${
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
        warnings = [ "cannot check ${field}: ${subject} reports no version. Kix skipped the check." ];
        assertions = [ ];
      }
    else if !(versions.isVersion version) then
      {
        warnings = [
          "cannot check ${field}: ${subject} reports version ${builtins.toJSON version}, which is not a version number. Kix skipped the check."
        ];
        assertions = [ ];
      }
    else
      {
        warnings = builtins.concatMap (c: c.warnings) checks;
        assertions = builtins.concatMap (c: c.assertions) checks;
      };

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
    if (package._type or "") == "kix-moved" then
      errors.fail package.error
    else if builtins.isAttrs package && package ? build then
      package.meta or { }
    else if (package._type or "") == "kix-import" then
      package.meta or { }
    else if builtins.isAttrs package && package ? meta then
      package.meta
    else if builtins.isAttrs package && !(builtins.isFunction package) then
      { }
    else
      let
        fnArgs = builtins.functionArgs package;
        result = package (
          {
            scope = { };
            inherit lib;
          }
          // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
          # `meta` must not depend on `availability`, because this peek runs
          # before the availability level is resolved.
          // lib.optionalAttrs (fnArgs ? availability) { availability = "none"; }
        );
      in
      result.meta or { };

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
        || builtins.any (lib.hasPrefix "cluster:") (packageMeta.conflictsWith or [ ])
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
      shelfRoles = map (roles.assertKnownRole "meta.roles of ${context}") (packageMeta.roles or [ ]);
    in
    lib.unique (explicitAliases ++ shelfRoles ++ (packageMeta.defaultAliases or [ ]));

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
      k8s = packageMeta.k8s or { };
      clusterK8s = clusterConfig.k8sVersion or null;

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
            depVersion = dep._meta.packageMeta.version or (dep.out.version or null);
          in
          constraintDiagnostics {
            field = "meta.compatibleWith.${depName}";
            subject = "dependency '${depName}'";
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
        conflict:
        let
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
          label =
            c:
            "${c.namespace}/${c.instName}"
            + lib.optionalString (isAuto c) " (auto-instantiated for ${builtins.concatStringsSep ", " c.meta.autoInstantiatedFor})";
          instances = builtins.concatStringsSep ", " (map label matching);
          autoAdvice = lib.optionalString (builtins.any isAuto matching) (
            ". An auto-instantiated instance is created for a required dependency that no declared instance answers. "
            + "Make ${namespaceName}/${instanceName} answer '${name}' (instances.${namespaceName}.${instanceName}.aliases), "
            + "or bind the consumers to it with deps.<arg> = ref.${namespaceName}.${instanceName}."
          );
        in
        lib.optional (matching != [ ]) (
          fail "It conflicts with '${name}' ${scope}. Conflicting instances: ${instances}${autoAdvice}"
        )
      ) (packageMeta.conflictsWith or [ ]);

      # Validate `meta.scope` up front, because resolution reads it only for
      # a dependency from another namespace.
      scopeValue = packageMeta.scope or null;
      scopeAssertions = lib.optional (scopeValue != null && !(builtins.elem scopeValue scopeValues)) (
        fail "meta.scope is ${builtins.toJSON scopeValue}. Set it to \"cluster\" or \"namespace\", or leave it unset."
      );

      # Validate `meta.unsafe` grants up front so unknown grant names fail even
      # when the corresponding rule does not fire during evaluation.
      unsafeAssertions = builtins.concatMap (
        grant:
        lib.optional (!(unsafe.registry ? ${grant})) (
          fail "meta.unsafe contains unknown grant '${grant}'. ${unsafe.knownGrantsHint}"
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
        conflictAssertions
        scopeAssertions
        unsafeAssertions
      ];
      warnings =
        deprecationWarnings
        ++ map (w: "[${instanceName}] ${w}") (builtins.concatMap (d: d.warnings) versionDiags);
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
                warnings = acc.warnings ++ (if enrichment ? warnings then enrichment.warnings dep else [ ]);
                assertions = acc.assertions ++ (if enrichment ? assertions then enrichment.assertions dep else [ ]);
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
  # null; }`, with the fields `kix.fail` takes (`core/error.nix`). Each one
  # gets `instance` set to the instance that raised it.
  combineDiagnostics =
    {
      instanceName,
      namespaceName,
      metaResult,
      packageResult,
      structuralWarnings,
    }:
    let
      instance = "${namespaceName}/${instanceName}";
      allWarnings = lib.concatLists [
        metaResult.warnings
        structuralWarnings
        (map (w: "[${instanceName}] ${w}") packageResult.warnings)
      ];
      allAssertions = map (a: { inherit instance; } // a) (
        metaResult.assertions ++ packageResult.assertions
      );
      failedAssertions = builtins.filter (a: !a.assertion) allAssertions;
    in
    {
      inherit allWarnings allAssertions failedAssertions;
      emitWarnings = emitTraces "warning: " allWarnings;
      emitAssertionWarnings = emitTraces "ASSERTION FAILED: " (
        map (a: "${a.instance}: ${a.message}") failedAssertions
      );
    };

  # Aggregate diagnostics across all instances and attach cluster- and
  # namespace-level findings (`extraWarnings` and `extraAssertions`).
  # `emitExtraWarnings` traces only `extraWarnings` because instance warnings
  # are already traced during instance evaluation.
  collectClusterDiagnostics =
    {
      clusterName,
      allInstancesList,
      extraWarnings ? [ ],
      extraAssertions ? [ ],
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
      emitExtraWarnings = emitTraces "warning: " extraWarnings;
    };
}
