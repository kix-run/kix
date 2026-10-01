# Built-in scorecard rules: Security
#
# Checks for container security context, host access, cluster-wide RBAC,
# image hygiene, and namespace-level network policies.
#
# See v2_discussions/60_scorecard_rules_design.md §Built-in rule library.

{ lib }:

let
  # Extract all containers (regular + init) from a workload resource.
  listOr = v: if v == null then [ ] else v;

  getContainers =
    resource:
    let
      podSpec = resource.spec.template.spec or { };
    in
    # A chart-rendered pod spec can carry `initContainers: null`; the rules
    # see the manifest before the null is stripped at emission.
    listOr (podSpec.containers or [ ]) ++ listOr (podSpec.initContainers or [ ]);

  # Container securityContext fields override the pod securityContext. Use the
  # pod value when the container does not set the field.
  effectiveSecurity =
    resource: container: field:
    let
      podLevel = resource.spec.template.spec.securityContext or { };
      containerLevel = container.securityContext or { };
    in
    if containerLevel ? ${field} then
      containerLevel.${field}
    else if podLevel ? ${field} then
      podLevel.${field}
    else
      null;

  # Treat runAsNonRoot=true or a resolved nonzero runAsUser as non-root.
  runsAsNonRoot =
    resource: container:
    let
      flag = effectiveSecurity resource container "runAsNonRoot";
      uid = effectiveSecurity resource container "runAsUser";
    in
    (flag == true) || (flag == null && uid != null && uid != 0);

  # A package opts out of a structural rule with a declared grant
  # (kix/lib/unsafe.nix), which `architecture.unsafeGrants` then lists in
  # every build, so the exception stays visible in review.
  holdsGrant = meta: grant: builtins.elem grant (meta.unsafe or [ ]);

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
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      isWorkload resource && !(holdsGrant meta "run-as-root");
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: !(runsAsNonRoot resource c)) containers;
      in
      map (c: {
        message =
          "container '${c.name or "unnamed"}' may run as root: neither it nor the pod "
          + "sets securityContext.runAsNonRoot, and no non-zero runAsUser resolves for it";
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
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      isWorkload resource && !(holdsGrant meta "privileged");
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
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      isWorkload resource && !(holdsGrant meta "host-network");
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

  # A ClusterRoleBinding to the built-in `cluster-admin`, or a ClusterRole
  # with a rule whose apiGroups, resources, and verbs all contain "*" (the
  # same reach under another name). A namespaced RoleBinding and a wildcard
  # limited to one API group are not checked.
  noClusterAdmin = {
    description = "No binding may grant cluster-admin or an all-wildcard ClusterRole";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "rbac"
      "cis-benchmark"
    ];
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      builtins.elem (resource.kind or "") [
        "ClusterRoleBinding"
        "ClusterRole"
      ]
      && !(holdsGrant meta "cluster-admin");
    check =
      { resource, ... }:
      let
        name = resource.metadata.name or "unnamed";
        fix =
          "Derive the rules the program needs with scope.rbac, or, when it must read and write "
          + "every kind (a cluster-wide backup tool), add \"cluster-admin\" to the package's meta.unsafe "
          + "with a comment that gives the reason.";
        describeSubject =
          s:
          if (s.kind or "") == "ServiceAccount" then
            "ServiceAccount ${s.namespace or "?"}/${s.name or "?"}"
          else
            "${s.kind or "subject"} ${s.name or "?"}";
        subjects = map describeSubject (listOr (resource.subjects or [ ]));
        subjectText = if subjects == [ ] then "no subjects" else lib.concatStringsSep ", " subjects;
        isAllWildcard =
          rule:
          builtins.all (field: builtins.elem "*" (listOr (rule.${field} or [ ]))) [
            "apiGroups"
            "resources"
            "verbs"
          ];
      in
      if resource.kind == "ClusterRoleBinding" then
        lib.optional
          ((resource.roleRef.kind or "") == "ClusterRole" && (resource.roleRef.name or "") == "cluster-admin")
          {
            message = "ClusterRoleBinding '${name}' grants cluster-admin to ${subjectText}. ${fix}";
          }
      else
        lib.optional (builtins.any isAllWildcard (listOr (resource.rules or [ ]))) {
          message = "ClusterRole '${name}' grants every verb on every resource in every API group, the reach of cluster-admin. ${fix}";
        };
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
            # A colon after the last slash separates the tag from the repository.
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

  # Detect known placeholder spellings and unexpanded variables in image
  # references. This cannot detect plausible but incorrect tags or digests;
  # `kix pin check` performs registry verification. The rule warns by default.
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
        # label is user-facing text; pattern is the regular expression.
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
          # Match the start of an unexpanded ${...} variable.
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
    description = "Namespaces with workloads must have at least one network policy";
    level = "namespace";
    severity = "warning";
    tags = [
      "security"
      "network"
    ];
    check =
      {
        resources,
        namespaceName,
        # NetworkPolicy plus the kinds the cluster's enforcer emits; the
        # rule runner reads them from the network-policy-enforcer role.
        networkPolicyKinds ? [ "NetworkPolicy" ],
        ...
      }:
      let
        hasWorkload = builtins.any (
          r:
          builtins.elem (r.kind or "") [
            "Deployment"
            "StatefulSet"
            "DaemonSet"
          ]
        ) resources;
        hasNetpol = builtins.any (r: builtins.elem (r.kind or "") networkPolicyKinds) resources;
      in
      if hasWorkload && !hasNetpol then
        [ { message = "namespace '${namespaceName}' has workloads but no network policy"; } ]
      else
        [ ];
  };
}
