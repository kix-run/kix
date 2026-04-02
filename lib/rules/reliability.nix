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
