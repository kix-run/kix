{ lib }:

let
  severityLevels = {
    "info" = 0;
    "warning" = 1;
    "error" = 2;
  };

  matchPattern =
    pattern: value:
    if pattern == "*" then
      true
    else if lib.hasSuffix "*" pattern then
      lib.hasPrefix (lib.removeSuffix "*" pattern) value
    else
      pattern == value;

  validLevels = [
    "manifest"
    "package"
    "namespace"
    "cluster"
  ];

  isValidSeverity = s: builtins.hasAttr s severityLevels;
  isValidLevel = l: builtins.elem l validLevels;

  # Validate both vocabularies before running any rule. An unknown level would
  # otherwise match no filter, while an unknown severity would be treated as
  # a warning.
  checkLevel =
    ruleName: rule:
    let
      level = rule.level or null;
    in
    if level == null then
      throw "scorecard rule '${ruleName}' declares no level. It must be one of: ${lib.concatStringsSep ", " validLevels}."
    else if !(isValidLevel level) then
      throw "scorecard rule '${ruleName}' has level '${toString level}', which is not one of: ${lib.concatStringsSep ", " validLevels}. A rule at an unknown level is never evaluated."
    else
      null;

  checkSeverity =
    ruleName: severity: source:
    if severity == null || isValidSeverity severity then
      null
    else
      throw "scorecard rule '${ruleName}' has severity '${toString severity}'${source}, which is not one of: ${lib.concatStringsSep ", " (builtins.attrNames severityLevels)}.";

  flattenRules =
    rules:
    lib.concatLists (
      lib.mapAttrsToList (
        category: categoryRules:
        if builtins.isAttrs categoryRules then
          lib.mapAttrsToList (
            ruleName: rule:
            let
              name = "${category}.${ruleName}";
            in
            builtins.seq (checkLevel name rule) {
              inherit name rule;
            }
          ) categoryRules
        else
          [ ]
      ) rules
    );

  severityRank = {
    info = 0;
    warning = 1;
    error = 2;
  };

  # The lower of a resolved severity and the cluster's cap. The cap is
  # what lets the scorecard run by default: every finding is printed at
  # its resolved level or below, and the build fails only where the
  # cluster has raised the cap to error.
  capSeverity =
    maxSeverity: severity:
    if severity == null || severityRank.${severity} <= severityRank.${maxSeverity} then
      severity
    else
      maxSeverity;

  resolveEffectiveSeverity =
    {
      ruleName,
      rule,
      ruleDefaults ? { },
      ruleOverrides ? { },
      namespaceName ? null,
      owner ? null,
      maxSeverity ? "error",
    }:
    let
      baseSeverity = rule.severity or ruleDefaults.severity or "warning";

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

      byRuleMatch =
        let
          byRule = ruleOverrides.byRule or { };
        in
        byRule.${ruleName} or null;

      ruleDisabled = if byRuleMatch != null then !(byRuleMatch.enabled or true) else false;
      ruleSeverity = if byRuleMatch != null then byRuleMatch.severity or null else null;

      _severityChecks = builtins.seq (checkSeverity ruleName baseSeverity "") (
        builtins.seq (checkSeverity ruleName ruleSeverity " (via ruleOverrides.byRule)") (
          builtins.seq (checkSeverity ruleName ownerSeverity " (via ruleOverrides.byOwner)") (
            checkSeverity ruleName nsSeverity " (via ruleOverrides.byNamespace)"
          )
        )
      );
    in
    capSeverity maxSeverity (
      builtins.seq _severityChecks (
        if ruleDisabled then
          null
        else if ruleSeverity != null then
          ruleSeverity
        else if ownerSeverity != null then
          ownerSeverity
        else if nsSeverity != null then
          nsSeverity
        else
          baseSeverity
      )
    );

  checkAppliesTo =
    rule: ctx: if rule ? appliesTo && rule.appliesTo != null then rule.appliesTo ctx else true;

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

  evaluateManifestRules =
    {
      rules,
      resource,
      instanceName,
      namespaceName,
      ruleDefaults ? { },
      ruleOverrides ? { },
      maxSeverity ? "error",
      owner ? null,
      meta ? { },
      # `cluster.secrets.accept`, for security.secretSource.
      acceptedSecretSources ? null,
    }:
    let
      manifestRules = builtins.filter (r: (r.rule.level or "") == "manifest") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          inherit maxSeverity;
          ruleName = name;
          inherit
            rule
            ruleDefaults
            ruleOverrides
            namespaceName
            owner
            ;
        };
        # Include package metadata so a manifest rule can honor a scoped
        # meta.unsafe grant without lowering severity for the namespace.
        ctx = {
          inherit
            resource
            instanceName
            namespaceName
            meta
            acceptedSecretSources
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
          level = "manifest";
          finding = f;
          inherit namespaceName instanceName;
          resourceName = resource.metadata.name or null;
          tags = rule.tags or [ ];
        }
      ) findings
    ) manifestRules;

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
      maxSeverity ? "error",
      owner ? null,
      # Inputs for architecture.annotationDomainOwnership: domain declarers,
      # dependency identities as "namespace/instance", and known domains.
      annotationDomainIndex ? { },
      resolvedDepTargets ? [ ],
      knownAnnotationDomains ? [ ],
    }:
    let
      packageRules = builtins.filter (r: (r.rule.level or "") == "package") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          inherit maxSeverity;
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
            annotationDomainIndex
            resolvedDepTargets
            knownAnnotationDomains
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

  evaluateNamespaceRules =
    {
      rules,
      instances,
      resources,
      namespaceName,
      ruleDefaults ? { },
      ruleOverrides ? { },
      maxSeverity ? "error",
      # Kinds that count as a network policy in this cluster: the Kubernetes
      # NetworkPolicy plus whatever the network-policy-enforcer provider
      # emits. The caller reads the provider so no rule names an enforcer.
      networkPolicyKinds ? [ "NetworkPolicy" ],
    }:
    let
      nsRules = builtins.filter (r: (r.rule.level or "") == "namespace") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          inherit maxSeverity;
          ruleName = name;
          inherit
            rule
            ruleDefaults
            ruleOverrides
            namespaceName
            ;
        };
        ctx = {
          inherit
            instances
            resources
            namespaceName
            networkPolicyKinds
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
          level = "namespace";
          finding = f;
          inherit namespaceName;
          tags = rule.tags or [ ];
        }
      ) findings
    ) nsRules;

  evaluateClusterRules =
    {
      rules,
      allInstances,
      allResources,
      clusterConfig ? { },
      ruleDefaults ? { },
      ruleOverrides ? { },
      maxSeverity ? "error",
      # "<namespace>/<name>" → { creatorNamed; } for every name a package
      # declared external with kix.untrackedRef. Collected before string
      # context is stripped, which is the only point it can be read at.
      externalNames ? { },
    }:
    let
      clusterRules = builtins.filter (r: (r.rule.level or "") == "cluster") (flattenRules rules);
    in
    builtins.concatMap (
      { name, rule }:
      let
        severity = resolveEffectiveSeverity {
          inherit maxSeverity;
          ruleName = name;
          inherit rule ruleDefaults ruleOverrides;
        };
        ctx = {
          inherit
            allInstances
            allResources
            clusterConfig
            externalNames
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
          level = "cluster";
          finding = f;
          tags = rule.tags or [ ];
          # Preserve an optional resource identity on cluster-level findings
          # so reports distinguish equal names in different namespaces.
          namespaceName = f.namespace or null;
          resourceName = f.resource or null;
        }
      ) findings
    ) clusterRules;

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
            # A cluster-level rule copies `metadata.namespace` from a
            # manifest that still carries string context, and an attribute
            # name may not refer to a store path.
            value = f.${field} or null;
            key = if value == null then "unknown" else builtins.unsafeDiscardStringContext value;
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
