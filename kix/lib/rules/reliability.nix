# Built-in scorecard rules: Reliability
#
# Checks for resource limits, probes, PDB, and graceful shutdown.
#
# See v2_discussions/60_scorecard_rules_design.md §Built-in rule library.

{ lib }:

let
  normalize = import ../core/normalize.nix { inherit lib; };

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
                  "container '${c.name or "unnamed"}' is missing resource settings: "
                  + builtins.concatStringsSep ", " missing
                  + ". Set CPU and memory requests and limits. Without a memory limit, a workload can exhaust the node's memory.";
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
        [
          {
            message = "'${instanceName}' has Deployments with multiple replicas but no PodDisruptionBudget. Add one to limit how many pods can be disrupted during maintenance";
          }
        ]
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

  # kixpkgs#9 family: a Volume with a name but no source is rejected by the
  # apiserver. The dangerous path is a constructor that builds the source
  # from optional arguments that are all null: under collapse-rule
  # normalization the source vanishes at render time while the rawManifest
  # this rule receives still shows the key. So the check normalizes each
  # volume exactly the way the renderer will and inspects the result,
  # catching the constructor trap at build time instead of at apply time.
  # Severity is "error": the manifest is unconditionally invalid.
  volumeHasSource = {
    description = "Every pod volume must carry a source (emptyDir, configMap, secret, ...)";
    level = "manifest";
    severity = "error";
    tags = [
      "reliability"
      "correctness"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        volumes = (resource.spec.template.spec or { }).volumes or [ ];
        rendered =
          let
            n = normalize.normalizeValue volumes;
          in
          if builtins.isList n then n else [ ];
        sourceless = builtins.filter (
          v: builtins.isAttrs v && builtins.attrNames (removeAttrs v [ "name" ]) == [ ]
        ) rendered;
      in
      map (v: {
        message =
          "volume '${v.name or "unnamed"}' has no source, so the Kubernetes "
          + "apiserver will reject this manifest. Give the volume a source "
          + "such as emptyDir, configMap, secret, or persistentVolumeClaim. "
          + "If you did set a source, its value was null or contained only "
          + "nulls, so Kix removed it as unset: write a literal `{ }` for an "
          + "intentionally empty source, or wrap helper output in `kix.keep`.";
      }) sourceless;
  };
}
