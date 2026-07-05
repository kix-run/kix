# Built-in scorecard rules: Reliability
#
# Checks for resource limits, probes, PDB, and graceful shutdown.
#
# See v2_discussions/60_scorecard_rules_design.md §Built-in rule library.

{ lib }:

let
  getContainers =
    resource:
    let
      podSpec = resource.spec.template.spec or { };
    in
    (podSpec.containers or [ ]) ++ (podSpec.initContainers or [ ]);

  # Only check main containers for probes (not init containers).
  getMainContainers = resource: (resource.spec.template.spec or { }).containers or [ ];

  isWorkload =
    resource:
    builtins.elem (resource.kind or "") [
      "Deployment"
      "StatefulSet"
      "DaemonSet"
    ];
in
{
  # v2_discussions/105 §A9 / §B7: single-node clusters cannot evict to "another
  # node", so an OOM that escapes a workload becomes a kernel-level event.
  # `requests` and `limits` are the only thing standing between a runaway pod
  # and a hung host. This rule is stricter than `hasResourceLimits` /
  # `hasResourceRequests` above — it requires *both* CPU and memory in *both*
  # requests and limits on every container.
  #
  # Parameterization is via the scorecard override machinery rather than a
  # bespoke flavor option:
  #   - lift severity:  scorecard.ruleOverrides.byRule.boundedResources.severity = "error";
  #   - disable:        scorecard.ruleOverrides.byRule.boundedResources.enabled = false;
  #   - per-namespace:  scorecard.ruleOverrides.byNamespace."kube-system".boundedResources.severity = "info";
  # Default severity is "warning" so an opt-in cluster surfaces findings without
  # blocking the build during the migration toward fully-bounded workloads.
  boundedResources = {
    description = "Every container should declare CPU+memory requests and limits";
    level = "manifest";
    severity = "warning";
    tags = [
      "reliability"
      "resources"
      "capacity"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        missingFor =
          c:
          let
            r = c.resources or { };
            requests = r.requests or { };
            limits = r.limits or { };
            missing =
              (lib.optional (!(requests ? cpu)) "requests.cpu")
              ++ (lib.optional (!(requests ? memory)) "requests.memory")
              ++ (lib.optional (!(limits ? cpu)) "limits.cpu")
              ++ (lib.optional (!(limits ? memory)) "limits.memory");
          in
          missing;
        findings = builtins.concatMap (
          c:
          let
            missing = missingFor c;
          in
          if missing == [ ] then
            [ ]
          else
            [
              {
                message =
                  "container '${c.name or "unnamed"}' is unbounded (missing: "
                  + builtins.concatStringsSep ", " missing
                  + "). On single-node clusters this means a runaway workload can OOM the host.";
              }
            ]
        ) containers;
      in
      findings;
  };

  hasResourceLimits = {
    description = "Every container should have resource limits";
    level = "manifest";
    severity = "warning";
    tags = [
      "reliability"
      "resources"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: !(c ? resources && c.resources ? limits)) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' has no resource limits";
      }) failing;
  };

  hasResourceRequests = {
    description = "Every container should have resource requests";
    level = "manifest";
    severity = "warning";
    tags = [
      "reliability"
      "resources"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: !(c ? resources && c.resources ? requests)) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' has no resource requests";
      }) failing;
  };

  hasProbes = {
    description = "Workload containers should have liveness and readiness probes";
    level = "manifest";
    severity = "warning";
    tags = [
      "reliability"
      "observability"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getMainContainers resource;
        missingLiveness = builtins.filter (c: !(c ? livenessProbe)) containers;
        missingReadiness = builtins.filter (c: !(c ? readinessProbe)) containers;
      in
      (map (c: {
        message = "container '${c.name or "unnamed"}' has no livenessProbe";
      }) missingLiveness)
      ++ (map (c: {
        message = "container '${c.name or "unnamed"}' has no readinessProbe";
      }) missingReadiness);
  };

  hasPDB = {
    description = "Multi-replica Deployments should have a PodDisruptionBudget";
    level = "package";
    severity = "warning";
    tags = [
      "reliability"
      "ha"
    ];
    check =
      { resources, instanceName, ... }:
      let
        multiReplicaDeployments = builtins.filter (
          r: (r.kind or "") == "Deployment" && (r.spec.replicas or 1) > 1
        ) resources;
        hasPDB = builtins.any (r: (r.kind or "") == "PodDisruptionBudget") resources;
      in
      if multiReplicaDeployments != [ ] && !hasPDB then
        [ { message = "'${instanceName}' has multi-replica Deployments but no PDB"; } ]
      else
        [ ];
  };

  gracefulShutdown = {
    description = "Workloads should set terminationGracePeriodSeconds";
    level = "manifest";
    severity = "info";
    tags = [
      "reliability"
      "operations"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        podSpec = resource.spec.template.spec or { };
        grace = podSpec.terminationGracePeriodSeconds or null;
      in
      if grace == null || grace == 0 then
        [ { message = "terminationGracePeriodSeconds is not set or is 0"; } ]
      else
        [ ];
  };
}
