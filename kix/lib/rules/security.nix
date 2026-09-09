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

  # The sentinel class: a committed placeholder that renders a manifest which
  # is well-formed and wrong. `sha-REPLACE_ME` is a valid tag string, so the
  # build passes, `noLatestTag` passes, `kix check` passes and `kix deploy
  # --dry-run` reports "configured". The first signal is ImagePullBackOff, in
  # production, minutes later.
  #
  # This rule is a ratchet, not the fix. A predicate over spelling cannot tell
  # you that `sha-typo12` is wrong, which is the same limitation `noLatestTag`
  # has. What closes the class is resolving the reference to a digest and
  # checking that digest against a registry: `kix.pins` plus `kix pin --check`.
  # This rule's one job is to make the known placeholders unwriteable again.
  #
  # Warning by default. Promote it to error in any flavor that deploys
  # something you care about.
  noUnresolvedPlaceholder = {
    description = "Image references must not carry an unresolved placeholder";
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
        # Spellings seen in the wild, plus an unexpanded shell or template
        # variable, which means a substitution step did not run.
        # `label` is what the message shows; `pattern` is the regex. They
        # differ only where the regex would read as noise.
        patterns = [
          {
            pattern = "REPLACE_ME";
            label = "the placeholder REPLACE_ME";
          }
          {
            pattern = "REPLACEME";
            label = "the placeholder REPLACEME";
          }
          {
            pattern = "CHANGE_ME";
            label = "the placeholder CHANGE_ME";
          }
          {
            pattern = "CHANGEME";
            label = "the placeholder CHANGEME";
          }
          {
            pattern = "PLACEHOLDER";
            label = "the placeholder PLACEHOLDER";
          }
          {
            pattern = "TODO";
            label = "the placeholder TODO";
          }
          {
            pattern = "FIXME";
            label = "the placeholder FIXME";
          }
          {
            pattern = "XXX";
            label = "the placeholder XXX";
          }
          # An unexpanded shell or template variable: a substitution step
          # that was meant to run did not.
          {
            pattern = "[$][{]";
            label = "an unexpanded variable";
          }
        ];
        hit =
          image:
          let
            found = builtins.filter (p: builtins.match ".*${p.pattern}.*" image != null) patterns;
          in
          if found == [ ] then null else (builtins.head found).label;
        containers = getContainers resource;
        failing = builtins.filter (c: hit (c.image or "") != null) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' uses image '${c.image or ""}', which still contains ${hit (c.image or "")}. Resolve it before deploying: keep the reference in a pin file (kix.pins) and set it with `kix pin set <key> --tag <tag>`.";
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
