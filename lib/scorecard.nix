# Scorecard rule engine — multi-level policy evaluation for kix clusters.
#
# Rules are declaratively defined with configurable severity, evaluated at
# four levels (manifest, package, namespace, cluster), and reported as
# structured findings.
#
# See v2_discussions/60_scorecard_rules_design.md for design rationale.

{ lib }:

let
  # ---------------------------------------------------------------------------
  # Severity ordering for override resolution
  # ---------------------------------------------------------------------------
  severityLevels = {
    "info" = 0;
    "warning" = 1;
    "error" = 2;
  };

  isValidSeverity = s: builtins.hasAttr s severityLevels;
  isValidLevel =
    l:
    builtins.elem l [
      "manifest"
      "package"
      "namespace"
      "cluster"
    ];

  # ---------------------------------------------------------------------------
  # Glob-style pattern matching (prefix* or exact match)
  # ---------------------------------------------------------------------------
  matchPattern =
    pattern: value:
    if pattern == "*" then
      true
    else if lib.hasSuffix "*" pattern then
      lib.hasPrefix (lib.removeSuffix "*" pattern) value
    else
      pattern == value;

  # ---------------------------------------------------------------------------
  # flattenRules — convert nested attrset { category.ruleName = rule } into
  # a flat list of { name = "category.ruleName"; rule = { ... }; }.
  # ---------------------------------------------------------------------------
  flattenRules =
    rules:
    lib.concatLists (
      lib.mapAttrsToList (
        category: categoryRules:
        if builtins.isAttrs categoryRules then
          lib.mapAttrsToList (ruleName: rule: {
            name = "${category}.${ruleName}";
            inherit rule;
          }) categoryRules
        else
          [ ]
      ) rules
    );

  # ---------------------------------------------------------------------------
  # resolveEffectiveSeverity — apply override chain to determine final severity.
  #
  # Override resolution order (most specific wins):
  # 1. Per-rule disable (byRule.X.enabled = false)
  # 2. Per-owner override
  # 3. Per-namespace override
  # 4. Rule's own default severity
  # 5. Cluster-wide ruleDefaults.severity
  # ---------------------------------------------------------------------------
  resolveEffectiveSeverity =
    {
      ruleName,
      rule,
      ruleDefaults ? { },
      ruleOverrides ? { },
      namespaceName ? null,
      owner ? null,
    }:
    let
      baseSeverity = rule.severity or ruleDefaults.severity or "warning";

      # Per-namespace overrides
      nsSeverity =
        if namespaceName == null then
          null
        else
          let
            nsOverrides = ruleOverrides.byNamespace or { };
            matchingNs = lib.filterAttrs (pattern: _: matchPattern pattern namespaceName) nsOverrides;
            matchingRules = lib.concatLists (
              lib.mapAttrsToList (
                _: nsRules:
                lib.concatLists (
                  lib.mapAttrsToList (
                    rulePattern: override: if matchPattern rulePattern ruleName then [ override ] else [ ]
                  ) nsRules
                )
              ) matchingNs
            );
          in
          if matchingRules == [ ] then null else (builtins.head matchingRules).severity or null;

      # Per-owner overrides
      ownerSeverity =
        if owner == null then
          null
        else
          let
            ownerOverrides = ruleOverrides.byOwner or { };
            matchingOwner = lib.filterAttrs (pattern: _: matchPattern pattern owner) ownerOverrides;
            matchingRules = lib.concatLists (
              lib.mapAttrsToList (
                _: ownerRules:
                lib.concatLists (
                  lib.mapAttrsToList (
                    rulePattern: override: if matchPattern rulePattern ruleName then [ override ] else [ ]
                  ) ownerRules
                )
              ) matchingOwner
            );
          in
          if matchingRules == [ ] then null else (builtins.head matchingRules).severity or null;

      # Per-rule overrides (disable or severity)
      byRuleMatch =
        let
          byRule = ruleOverrides.byRule or { };
        in
        byRule.${ruleName} or null;

      ruleDisabled = if byRuleMatch != null then !(byRuleMatch.enabled or true) else false;
      ruleSeverity = if byRuleMatch != null then byRuleMatch.severity or null else null;
    in
    if ruleDisabled then
      null # null = skip this rule entirely
    else if ruleSeverity != null then
      ruleSeverity
    else if ownerSeverity != null then
      ownerSeverity
    else if nsSeverity != null then
      nsSeverity
    else
      baseSeverity;

  # ---------------------------------------------------------------------------
  # checkAppliesTo — evaluate the appliesTo predicate if present.
  # ---------------------------------------------------------------------------
  checkAppliesTo =
    rule: ctx: if rule ? appliesTo && rule.appliesTo != null then rule.appliesTo ctx else true;

  # ---------------------------------------------------------------------------
  # mkFinding — construct a structured finding from a rule check result.
  # ---------------------------------------------------------------------------
  mkFinding =
    {
      ruleName,
      severity,
      level,
      finding,
      namespaceName ? null,
      instanceName ? null,
      resourceName ? null,
      tags ? [ ],
    }:
    {
      rule = ruleName;
      inherit severity level;
      namespace = namespaceName;
      instance = instanceName;
      resource = resourceName;
      message = finding.message or "check failed";
      inherit tags;
    };

in
rec {
  inherit flattenRules resolveEffectiveSeverity;

  # ---------------------------------------------------------------------------
  # evaluateManifestRules — run level="manifest" rules against a single resource.
  #
  # Returns a list of findings.
  # ---------------------------------------------------------------------------
  evaluateManifestRules =
    {
      rules,
      resource,
      instanceName,
      namespaceName,
      ruleDefaults ? { },
      ruleOverrides ? { },
      owner ? null,
    }:
    let
      manifestRules = builtins.filter (r: (r.rule.level or "") == "manifest") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          ruleName = name;
          inherit
            rule
            ruleDefaults
            ruleOverrides
            namespaceName
            owner
            ;
        };
        ctx = {
          inherit resource instanceName namespaceName;
        };
        applies = checkAppliesTo rule ctx;
        findings = if severity != null && applies then rule.check ctx else [ ];
      in
      map (
        f:
        mkFinding {
          ruleName = name;
          inherit severity;
          level = "manifest";
          finding = f;
          inherit namespaceName instanceName;
          resourceName = resource.metadata.name or null;
          tags = rule.tags or [ ];
        }
      ) findings
    ) manifestRules;

  # ---------------------------------------------------------------------------
  # evaluatePackageRules — run level="package" rules against a package instance.
  #
  # Returns a list of findings.
  # ---------------------------------------------------------------------------
  evaluatePackageRules =
    {
      rules,
      resources,
      parts,
      config,
      meta,
      instanceName,
      namespaceName,
      ruleDefaults ? { },
      ruleOverrides ? { },
      owner ? null,
    }:
    let
      packageRules = builtins.filter (r: (r.rule.level or "") == "package") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          ruleName = name;
          inherit
            rule
            ruleDefaults
            ruleOverrides
            namespaceName
            owner
            ;
        };
        ctx = {
          inherit
            resources
            parts
            config
            meta
            instanceName
            namespaceName
            ;
        };
        applies = checkAppliesTo rule ctx;
        findings = if severity != null && applies then rule.check ctx else [ ];
      in
      map (
        f:
        mkFinding {
          ruleName = name;
          inherit severity;
          level = "package";
          finding = f;
          inherit namespaceName instanceName;
          tags = rule.tags or [ ];
        }
      ) findings
    ) packageRules;

  # ---------------------------------------------------------------------------
  # evaluateNamespaceRules — run level="namespace" rules against all resources
  # in a namespace.
  #
  # Returns a list of findings.
  # ---------------------------------------------------------------------------
  evaluateNamespaceRules =
    {
      rules,
      instances,
      resources,
      namespaceName,
      ruleDefaults ? { },
      ruleOverrides ? { },
    }:
    let
      nsRules = builtins.filter (r: (r.rule.level or "") == "namespace") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          ruleName = name;
          inherit
            rule
            ruleDefaults
            ruleOverrides
            namespaceName
            ;
        };
        ctx = {
          inherit instances resources namespaceName;
        };
        applies = checkAppliesTo rule ctx;
        findings = if severity != null && applies then rule.check ctx else [ ];
      in
      map (
        f:
        mkFinding {
          ruleName = name;
          inherit severity;
          level = "namespace";
          finding = f;
          inherit namespaceName;
          tags = rule.tags or [ ];
        }
      ) findings
    ) nsRules;

  # ---------------------------------------------------------------------------
  # evaluateClusterRules — run level="cluster" rules against the entire cluster.
  #
  # Returns a list of findings.
  # ---------------------------------------------------------------------------
  evaluateClusterRules =
    {
      rules,
      allInstances,
      allResources,
      clusterConfig ? { },
      ruleDefaults ? { },
      ruleOverrides ? { },
    }:
    let
      clusterRules = builtins.filter (r: (r.rule.level or "") == "cluster") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          ruleName = name;
          inherit rule ruleDefaults ruleOverrides;
        };
        ctx = {
          inherit allInstances allResources clusterConfig;
        };
        applies = checkAppliesTo rule ctx;
        findings = if severity != null && applies then rule.check ctx else [ ];
      in
      map (
        f:
        mkFinding {
          ruleName = name;
          inherit severity;
          level = "cluster";
          finding = f;
          tags = rule.tags or [ ];
        }
      ) findings
    ) clusterRules;

  # ---------------------------------------------------------------------------
  # buildScorecardReport — aggregate findings into a structured report.
  # ---------------------------------------------------------------------------
  buildScorecardReport =
    {
      findings,
      totalChecks ? builtins.length findings,
    }:
    let
      errors = builtins.filter (f: f.severity == "error") findings;
      warnings = builtins.filter (f: f.severity == "warning") findings;
      infos = builtins.filter (f: f.severity == "info") findings;

      countByField =
        field: items:
        builtins.foldl' (
          acc: f:
          let
            key = f.${field} or "unknown";
          in
          acc // { ${key} = (acc.${key} or 0) + 1; }
        ) { } items;
    in
    {
      inherit findings;
      summary = {
        total = builtins.length findings;
        errors = builtins.length errors;
        warnings = builtins.length warnings;
        info = builtins.length infos;
        byNamespace = countByField "namespace" findings;
        byRule = countByField "rule" findings;
      };
    };

  # ---------------------------------------------------------------------------
  # scorecardToWarnings — convert scorecard findings into kix diagnostic warnings.
  # Error-severity findings become assertions (block build).
  # Warning/info findings become trace warnings.
  # ---------------------------------------------------------------------------
  scorecardToWarnings =
    findings:
    let
      errors = builtins.filter (f: f.severity == "error") findings;
      nonErrors = builtins.filter (f: f.severity != "error") findings;
    in
    {
      warnings = map (
        f:
        let
          loc = lib.concatStringsSep "/" (
            builtins.filter (x: x != null) [
              f.namespace
              f.instance
              f.resource
            ]
          );
        in
        "[scorecard:${f.rule}] ${loc}: ${f.message}"
      ) nonErrors;
      assertions = map (f: {
        assertion = false;
        message =
          let
            loc = lib.concatStringsSep "/" (
              builtins.filter (x: x != null) [
                f.namespace
                f.instance
                f.resource
              ]
            );
          in
          "[scorecard:${f.rule}] ${loc}: ${f.message}";
      }) errors;
    };
}
