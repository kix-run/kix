# Built-in scorecard rules for container resource bounds, probes, graceful
# shutdown, and volume definitions.

{ lib }:

let
  normalize = import ../core/normalize.nix { inherit lib; };

  inherit (import ../core/util.nix { inherit lib; }) listOr;
  inherit (import ../core/pod-spec.nix { inherit lib; }) podSpecOf;
  workloadKinds = import ../core/workload-kinds.nix { inherit lib; };

  getContainers =
    resource:
    let
      podSpec = podSpecOf resource;
    in
    # Helm charts can render `initContainers: null`, and scorecard rules inspect
    # manifests before null fields are stripped.
    listOr (podSpec.containers or [ ]) ++ listOr (podSpec.initContainers or [ ]);

  getMainContainers = resource: listOr ((podSpecOf resource).containers or [ ]);

  isWorkload = resource: builtins.elem (resource.kind or "") workloadKinds.servingKinds;
in
{
  # Require both CPU and memory in `requests` and `limits` on every container.
  # Accept a missing CPU or memory limit when the cluster sets that field of
  # `cluster.defaultLimits` to "none".
  boundedResources = {
    description = "Every container should declare CPU and memory requests and limits, except a limit that cluster.defaultLimits sets to \"none\"";
    level = "manifest";
    severity = "warning";
    tags = [
      "reliability"
      "resources"
      "capacity"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      {
        resource,
        defaultLimits ? (import ../core/default-limits.nix).default,
        ...
      }:
      let
        containers = getContainers resource;
        asksCpu = defaultLimits.cpu != "none";
        asksMemory = defaultLimits.memory != "none";
        advice =
          if asksCpu && asksMemory then
            "Set CPU and memory requests and limits."
          else if asksCpu then
            "Set CPU and memory requests and a CPU limit."
          else if asksMemory then
            "Set CPU and memory requests and a memory limit."
          else
            "Set CPU and memory requests.";
        missingFor =
          c:
          let
            r = c.resources or { };
            requests = r.requests or { };
            limits = r.limits or { };
            missing =
              (lib.optional (!(requests ? cpu)) "requests.cpu")
              ++ (lib.optional (!(requests ? memory)) "requests.memory")
              ++ (lib.optional (asksCpu && !(limits ? cpu)) "limits.cpu")
              ++ (lib.optional (asksMemory && !(limits ? memory)) "limits.memory");
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
                  + ". ${advice}"
                  + lib.optionalString (builtins.elem "limits.memory" missing) " Without a memory limit, a workload can exhaust the node's memory.";
              }
            ]
        ) containers;
      in
      findings;
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

  # Normalize pod volumes before checking that each volume has a source. A
  # volume source built from all-null optional fields is still present in
  # `rawManifest`, but normalization strips it before rendering, leaving a
  # sourceless volume that the API server rejects.
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
        volumes = resource.spec.template.spec.volumes or [ ];
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
