# Package meta system — structured metadata, warnings, assertions, compatibility.
#
# Packages declare `meta` (static constraints), `warnings` and `assertions`
# (evaluated with config/deps context). The evaluator calls into this module
# to validate constraints and collect diagnostics.
#
# See v2_discussions/25_package_meta_warnings.md for design rationale.

{ lib }:

let
  # --- Version comparison (semver-ish: major.minor[.patch]) ---

  parseVersion = v: map lib.toIntBase10 (builtins.filter builtins.isString (builtins.split "\\." v));

  compareVersions =
    a: b:
    let
      la = parseVersion a;
      lb = parseVersion b;
      len = lib.max (builtins.length la) (builtins.length lb);
      pad = l: l ++ lib.genList (_: 0) (len - builtins.length l);
      pa = pad la;
      pb = pad lb;
      go =
        i:
        if i >= len then
          0
        else if builtins.elemAt pa i < builtins.elemAt pb i then
          -1
        else if builtins.elemAt pa i > builtins.elemAt pb i then
          1
        else
          go (i + 1);
    in
    go 0;

  versionAtLeast = a: b: compareVersions a b >= 0;
  versionAtMost = a: b: compareVersions a b <= 0;

  # --- Assertion/warning constructors ---

  fail = message: {
    assertion = false;
    inherit message;
  };

  versionCheck =
    {
      depName,
      depVersion,
      constraint,
    }:
    let
      reason = lib.optionalString (constraint ? reason) " — ${constraint.reason}";
    in
    lib.concatLists [
      (lib.optional (constraint ? minVersion && !(versionAtLeast depVersion constraint.minVersion)) (
        fail "dependency '${depName}' version ${depVersion} < required minimum ${constraint.minVersion}${reason}"
      ))
      (lib.optional (constraint ? maxVersion && !(versionAtMost depVersion constraint.maxVersion)) (
        fail "dependency '${depName}' version ${depVersion} > required maximum ${constraint.maxVersion}${reason}"
      ))
    ];

  # --- Helpers ---

  emitTraces = prefix: items: lib.foldl' (acc: msg: builtins.trace "${prefix}${msg}" acc) null items;

  noDiagnostics = {
    warnings = [ ];
    assertions = [ ];
    failedAssertions = [ ];
  };

in
rec {
  inherit versionAtLeast versionAtMost compareVersions;

  # ---------------------------------------------------------------------------
  # peekPackageMeta — extract meta from a package without full evaluation.
  #
  # Accepts function packages, inline attrset packages, and kix-imports.
  # Uses the same shape detection as resolve.normalizePackage.
  # ---------------------------------------------------------------------------
  peekPackageMeta =
    { package, kixlib }:
    if builtins.isAttrs package && package ? build then
      # Inline attrset package
      package.meta or { }
    else if (package._type or "") == "kix-import" then
      package.meta or { }
    else
      let
        fnArgs = builtins.functionArgs package;
        result = package (
          {
            scope = { };
            inherit lib;
          }
          // lib.optionalAttrs (fnArgs ? kix) { kix = kixlib; }
        );
      in
      result.meta or { };

  # ---------------------------------------------------------------------------
  # effectiveAliases — instance aliases win, fall back to package defaults.
  # ---------------------------------------------------------------------------
  effectiveAliases =
    { instanceAliases, packageMeta }:
    if instanceAliases != [ ] then instanceAliases else packageMeta.defaultAliases or [ ];

  # ---------------------------------------------------------------------------
  # peekPackageAliases — extract resolution aliases from an available package
  # entry, combining explicit aliases with peekPackageMeta-derived defaults.
  # Works even for packages with required deps (falls back to explicit aliases).
  # ---------------------------------------------------------------------------
  peekPackageAliases =
    { availEntry, kixlib }:
    let
      explicitAliases = availEntry.aliases or [ ];
      metaAliases =
        (peekPackageMeta {
          package = availEntry.package;
          inherit kixlib;
        }).defaultAliases or [ ];
    in
    lib.unique (explicitAliases ++ metaAliases);

  # ---------------------------------------------------------------------------
  # checkMetaStatic — meta-derived assertions and warnings (before build).
  #
  # Returns { assertions = [...]; warnings = [...]; }
  # ---------------------------------------------------------------------------
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

      # K8s version bounds
      k8sAssertions =
        if clusterK8s == null then
          [ ]
        else
          lib.concatLists [
            (lib.optional (k8s ? minVersion && !(versionAtLeast clusterK8s k8s.minVersion)) (
              fail "package requires Kubernetes >= ${k8s.minVersion}, cluster targets ${clusterK8s}"
            ))
            (lib.optional (k8s ? maxVersion && !(versionAtMost clusterK8s k8s.maxVersion)) (
              fail "package requires Kubernetes <= ${k8s.maxVersion}, cluster targets ${clusterK8s}"
            ))
          ];

      # Dependency version compatibility
      compat = packageMeta.compatibleWith or { };
      compatAssertions = builtins.concatMap (
        depName:
        let
          depInfo = resolvedDepMeta.${depName} or null;
          dep = if depInfo != null then depInfo.instance else null;
          depVersion = if dep != null then dep._meta.version or (dep.out.version or null) else null;
        in
        if depVersion == null then
          [ ]
        else
          versionCheck {
            inherit depName depVersion;
            constraint = compat.${depName};
          }
      ) (builtins.attrNames compat);

      # Conflict detection
      conflictAssertions = builtins.concatMap (
        conflict:
        let
          isClusterWide = lib.hasPrefix "cluster:" conflict;
          name = if isClusterWide then lib.removePrefix "cluster:" conflict else conflict;
          candidates = resolutionIndex.byKey.${name} or [ ];
          isSelf = c: c.instName == instanceName && c.namespace == namespaceName;
          matching =
            if isClusterWide then
              builtins.filter (c: !(isSelf c)) candidates
            else
              builtins.filter (c: c.namespace == namespaceName && !(isSelf c)) candidates;
          scope = if isClusterWide then "(cluster-wide)" else "in namespace '${namespaceName}'";
          instances = builtins.concatStringsSep ", " (map (c: "${c.namespace}/${c.instName}") matching);
        in
        lib.optional (matching != [ ]) (fail "conflicts with '${name}' ${scope} — instances: ${instances}")
      ) (packageMeta.conflictsWith or [ ]);

      # Deprecation
      deprecated = packageMeta.deprecated or null;
      deprecationWarnings =
        if deprecated == null then
          [ ]
        else
          [
            (
              "package '${instanceName}' is deprecated: ${deprecated.message or "no reason given"}"
              + lib.optionalString (deprecated ? replacement) " — use '${deprecated.replacement}' instead"
            )
          ];
    in
    {
      assertions = lib.concatLists [
        k8sAssertions
        compatAssertions
        conflictAssertions
      ];
      warnings = deprecationWarnings;
    };

  # ---------------------------------------------------------------------------
  # evaluatePackageDiagnostics — call package-declared warnings/assertions fns
  # and per-dep diagnostics from deps enrichment.
  #
  # Returns { warnings = [...]; assertions = [...]; }
  # ---------------------------------------------------------------------------
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
        deps = lib.mapAttrs (_: di: di.instance) resolvedDepMeta;
      };

      # Per-dep diagnostics from deps enrichment
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

  # ---------------------------------------------------------------------------
  # combineDiagnostics — merge structural, meta, and package diagnostics.
  #
  # Returns { allWarnings, allAssertions, failedAssertions, emitWarnings, emitAssertionWarnings }
  # ---------------------------------------------------------------------------
  combineDiagnostics =
    {
      instanceName,
      metaResult,
      packageResult,
      structuralWarnings,
    }:
    let
      allWarnings = lib.concatLists [
        metaResult.warnings
        structuralWarnings
        (map (w: "[${instanceName}] ${w}") packageResult.warnings)
      ];
      allAssertions = lib.concatLists [
        metaResult.assertions
        (map (a: a // { message = "[${instanceName}] ${a.message}"; }) packageResult.assertions)
      ];
      failedAssertions = builtins.filter (a: !a.assertion) allAssertions;
    in
    {
      inherit allWarnings allAssertions failedAssertions;
      emitWarnings = emitTraces "warning: " allWarnings;
      emitAssertionWarnings = emitTraces "ASSERTION FAILED: " (map (a: a.message) failedAssertions);
    };

  # ---------------------------------------------------------------------------
  # collectClusterDiagnostics — gather from all instances, throw on failures.
  # ---------------------------------------------------------------------------
  collectClusterDiagnostics =
    { clusterName, allInstancesList }:
    let
      collect =
        field: builtins.concatMap (inst: (inst._diagnostics or noDiagnostics).${field}) allInstancesList;
      warnings = collect "warnings";
      assertions = collect "assertions";
      failedAssertions = collect "failedAssertions";
      assertionCheck =
        if failedAssertions == [ ] then
          null
        else
          throw (
            "Cluster '${clusterName}' has ${toString (builtins.length failedAssertions)} failed assertion(s):\n"
            + builtins.concatStringsSep "\n" (map (a: "  - ${a.message}") failedAssertions)
          );
    in
    {
      inherit
        warnings
        assertions
        failedAssertions
        assertionCheck
        ;
    };
}
