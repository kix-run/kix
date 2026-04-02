# Built-in scorecard rules: Security
#
# Checks for container security context, host access, image hygiene,
# and namespace-level network policies.
#
# See v2_discussions/60_scorecard_rules_design.md §Built-in rule library.

{ lib }:

let
  # Extract all containers (regular + init) from a workload resource.
  getContainers =
    resource:
    let
      podSpec = resource.spec.template.spec or { };
    in
    (podSpec.containers or [ ]) ++ (podSpec.initContainers or [ ]);

  isWorkload =
    resource:
    builtins.elem (resource.kind or "") [
      "Deployment"
      "StatefulSet"
      "DaemonSet"
      "Job"
    ];
in
{
  nonRoot = {
    description = "All containers must run as non-root";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "cis-benchmark"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: !(c.securityContext.runAsNonRoot or false)) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' does not set runAsNonRoot";
      }) failing;
  };

  noPrivileged = {
    description = "No containers may run in privileged mode";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "cis-benchmark"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: c.securityContext.privileged or false) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' runs in privileged mode";
      }) failing;
  };

  readOnlyRootfs = {
    description = "Containers should use read-only root filesystem";
    level = "manifest";
    severity = "warning";
    tags = [ "security" ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: !(c.securityContext.readOnlyRootFilesystem or false)) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' does not set readOnlyRootFilesystem";
      }) failing;
  };

  noHostNetwork = {
    description = "Pods must not use host networking";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "cis-benchmark"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        podSpec = resource.spec.template.spec or { };
        violations = lib.concatLists [
          (lib.optional (podSpec.hostNetwork or false) { message = "pod uses hostNetwork"; })
          (lib.optional (podSpec.hostPID or false) { message = "pod uses hostPID"; })
          (lib.optional (podSpec.hostIPC or false) { message = "pod uses hostIPC"; })
        ];
      in
      violations;
  };

  noLatestTag = {
    description = "Image references should not use :latest or be untagged";
    level = "manifest";
    severity = "warning";
    tags = [
      "security"
      "operations"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        hasLatestOrNoTag =
          c:
          let
            image = c.image or "";
            # After the last '/' (or start), check for ':' — no colon means no tag
            afterSlash = lib.last (lib.splitString "/" image);
            parts = lib.splitString ":" afterSlash;
          in
          (builtins.length parts == 1) || (lib.last parts == "latest");
        failing = builtins.filter hasLatestOrNoTag containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' uses image '${c.image or ""}' with :latest or no tag";
      }) failing;
  };

  hasNetworkPolicy = {
    description = "Namespaces with workloads must have at least one NetworkPolicy";
    level = "namespace";
    severity = "warning";
    tags = [
      "security"
      "network"
    ];
    check =
      { resources, namespaceName, ... }:
      let
        hasWorkload = builtins.any (
          r:
          builtins.elem (r.kind or "") [
            "Deployment"
            "StatefulSet"
            "DaemonSet"
          ]
        ) resources;
        hasNetpol = builtins.any (
          r:
          builtins.elem (r.kind or "") [
            "NetworkPolicy"
            "CiliumNetworkPolicy"
          ]
        ) resources;
      in
      if hasWorkload && !hasNetpol then
        [ { message = "namespace '${namespaceName}' has workloads but no NetworkPolicy"; } ]
      else
        [ ];
  };
}
