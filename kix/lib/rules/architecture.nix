# Built-in scorecard rules: Architecture / Dependency-Injection hygiene
#
# These rules catch "code smells" where a package builds resources that
# belong to another capability instead of requesting that capability via
# DI. The principle: resources are owned by the capability that provides
# them (storage provider owns PVCs, reflector owns reflection wiring,
# prometheus-operator owns ServiceMonitors, …). Consumers request these
# via dep args and call the owner's `out.mk*` builders; they do not
# hand-roll equivalents.
#
# Detection is "fingerprint → capability" driven:
#
#   - A resource matches a fingerprint if its kind (or annotation/label
#     domain) belongs to that capability.
#   - The package "owns" the capability iff either:
#       a) `meta.provides` contains the capability name, or
#       b) one of its emitted resources is tagged with
#          `kix.dev/capability: <name>` (set by the owner's builder when
#          the resource was constructed through DI).
#
# If a resource matches a fingerprint and the package does not own the
# capability, the rule fires with a suggestion to use DI.
#
# Gotchas / non-obvious bits:
#
#   - The `kix.dev/capability` annotation is what lets consumers pass the
#     rule post-migration: when a consumer calls `reflector.out.reflectSecret`
#     the builder stamps this annotation on the resources it returns, so
#     this rule can distinguish "built inline" from "built via the owner's
#     DI builder" without needing any provenance machinery.
#
#   - We check `resources` (the package's emitted manifests), not the
#     resolved dep graph — having a `reflector` dep resolved is not proof
#     of good hygiene, the package might still hand-roll the annotator
#     resources. Provenance has to be explicit via the annotation.
#
# Adding a new fingerprint: append a record to `fingerprints` below.

{ lib }:

let
  workloadKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
    "Job"
    "CronJob"
    "Pod"
    "ReplicaSet"
  ];

  # Recursively collect every string value reachable under `v`.
  # Runs pre-JSON so string context is intact.
  collectStrings =
    v:
    if builtins.isString v then
      [ v ]
    else if builtins.isList v then
      builtins.concatMap collectStrings v
    else if builtins.isAttrs v then
      builtins.concatMap collectStrings (builtins.attrValues v)
    else
      [ ];

  # Heuristic: does the string contain a `<name>.<ns>.svc` fragment?
  # `builtins.match` is whole-string, so pad with `.*` on both sides.
  looksLikeSvcFqdn =
    s: lib.hasInfix ".svc" s && builtins.match ".*[a-zA-Z0-9-]+\\.[a-zA-Z0-9-]+\\.svc.*" s != null;

  # Read a resource's capability annotation (returns null if absent).
  getCapAnnotation =
    r:
    let
      ann = r.metadata.annotations or { };
    in
    ann."kix.dev/capability" or null;

  # Does the resource carry the given substring anywhere capability wiring
  # could plausibly live? We deliberately avoid `builtins.toJSON r`: on
  # resources with deeply-nested specs (CRD OpenAPI schemas, Stackgres
  # cluster specs, etc.) whole-resource JSON encoding blows the default
  # 8 MiB stack. Instead, check a fixed set of string-bearing locations:
  #
  #   - annotation keys and values (where domain-based wiring normally lives)
  #   - label keys and values
  #   - container args / command / image (for annotator Jobs that embed the
  #     domain in a `kubectl annotate ...` shell invocation)
  #   - RBAC rules (resourceNames, apiGroups, nonResourceURLs)
  #
  # This covers every place a capability-domain string realistically
  # appears while keeping the walk shallow and bounded.
  hasInfixInList = needle: xs: builtins.any (s: builtins.isString s && lib.hasInfix needle s) xs;
  containsString =
    needle: r:
    let
      meta = r.metadata or { };
      annotations = meta.annotations or { };
      labels = meta.labels or { };
      annotationHits =
        hasInfixInList needle (builtins.attrNames annotations)
        || hasInfixInList needle (builtins.attrValues annotations);
      labelHits =
        hasInfixInList needle (builtins.attrNames labels)
        || hasInfixInList needle (builtins.attrValues labels);

      podSpec = r.spec.template.spec or (if (r.kind or "") == "Pod" then r.spec or { } else { });
      containers = (podSpec.containers or [ ]) ++ (podSpec.initContainers or [ ]);
      stringsFromContainer = c: (c.args or [ ]) ++ (c.command or [ ]) ++ [ (c.image or "") ];
      containerHits = hasInfixInList needle (builtins.concatMap stringsFromContainer containers);

      rbacRules = r.rules or [ ];
      stringsFromRule =
        rule:
        (rule.resourceNames or [ ])
        ++ (rule.apiGroups or [ ])
        ++ (rule.resources or [ ])
        ++ (rule.nonResourceURLs or [ ]);
      rbacHits = hasInfixInList needle (builtins.concatMap stringsFromRule rbacRules);
    in
    annotationHits || labelHits || containerHits || rbacHits;

  fingerprints = [
    {
      capability = "storage";
      detect = r: (r.kind or "") == "PersistentVolumeClaim";
      describe = r: "PersistentVolumeClaim '${r.metadata.name or "?"}'";
      rationale = ''
        Storage should be a DI concern: cluster operators compose PVC size,
        storageClass, and lifecycle independently of the consuming workload.
        Hand-rolled PVCs prevent teams from swapping backends, sharing volumes
        across workloads, or migrating storage without rebuilding the consumer.
      '';
      suggest = ''
        Declare a `storage` dep arg and mount it via
        `kix.mount.pvc storage { mountPath = "..."; }`. Provision the PVC as
        a sibling instance using `packages.persistent-volume-claim` so the
        cluster definition owns size / storageClass.
      '';
    }
    {
      capability = "reflection";
      # Reflector annotations have a well-known domain. The substring also
      # appears in the annotator Job's `kubectl annotate ...` command, so
      # even the indirect wiring (RBAC + Job that patches a secret) is
      # caught, not just the annotated secret itself.
      detect = containsString "reflector.v1.k8s.emberstack.com";
      describe = r: "${r.kind or "Resource"} '${r.metadata.name or "?"}' carries reflector wiring";
      rationale = ''
        Cross-namespace secret reflection belongs to the reflector package.
        Building the annotator Job, its RBAC, or the annotations inline
        duplicates logic that the reflector owner should expose through a
        builder — otherwise every consumer reimplements the same contract.
      '';
      suggest = ''
        Declare a `reflector` dep arg and call
        `reflector.out.reflectSecret scope { secretName = ...; requires = [...]; }`
        instead of building the annotator bundle by hand. The builder
        stamps `kix.dev/capability: reflection` on its resources so this
        rule sees the consumer as compliant.
      '';
    }
  ];

in
{
  # Single generic rule driven by the fingerprint registry above.
  # Package-level: needs `resources` + `meta` to decide ownership.
  capabilityOwnership = {
    description = "Resources whose capability is owned by another package should be requested via DI, not hand-rolled";
    level = "package";
    severity = "warning";
    tags = [
      "architecture"
      "di"
    ];
    check =
      {
        resources,
        meta,
        instanceName,
        ...
      }:
      let
        # Ownership vocabulary: compiler roles (meta.roles, registry-validated)
        # plus the open scorecard vocabulary (meta.provides, free-form).
        providedCaps = (meta.roles or [ ]) ++ (meta.provides or [ ]);
        ownsCapability = cap: builtins.elem cap providedCaps;

        offendingFor =
          fp:
          if ownsCapability fp.capability then
            [ ]
          else
            let
              matching = builtins.filter (r: fp.detect r && (getCapAnnotation r) != fp.capability) resources;
            in
            map (r: {
              message =
                "${fp.describe r} is hand-rolled in '${instanceName}' but belongs to capability '${fp.capability}'. "
                + lib.replaceStrings [ "\n" ] [ " " ] fp.rationale
                + "→ "
                + lib.replaceStrings [ "\n" ] [ " " ] fp.suggest;
            }) matching;
      in
      builtins.concatLists (map offendingFor fingerprints);
  };

  # v2_discussions/97 §6: cluster-internal FQDNs should originate from a
  # ServiceRef/Service `out.*` value so store-path context carries netpol,
  # DNS, and wave-ordering edges. Hand-rolled `"${name}.${ns}.svc"` strings
  # build succeed, deploy succeeds, runtime fails obscurely.
  #
  # v1 bar is structural: "no context at all". A string whose context is
  # non-empty is trusted — something in the graph carries the edge.
  # Tightening to "context must resolve to a known ServiceRef marker" is
  # a follow-up once we have cross-package registry access inside rules.
  # Services whose selector is a literal `{ ... }` attrset (no store-path
  # context on any value) are hand-wired to the workload's label set
  # instead of derived from the workload itself. This is fragile: changing
  # the workload's labels silently breaks routing.
  #
  # The fix is `kix.service.fromWorkload` (reads workload.out.selector,
  # which carries the workload's own store-path context) or, in cycle
  # cases, `workload.rawSelector` (raw attrset — user must then accept
  # loss of the DAG edge, since context is absent). This rule fires on
  # both the raw-attrset case AND the rawSelector case; the rawSelector
  # form should only appear as an explicit workaround and is thus a
  # reasonable warning surface.
  selectorCoherence = {
    description = "Service selector should be sourced from a workload (kix.service.fromWorkload), not a literal attrset";
    level = "manifest";
    severity = "warning";
    tags = [
      "architecture"
      "composition"
    ];
    appliesTo = { resource, ... }: (resource.kind or "") == "Service";
    check =
      { resource, ... }:
      let
        matchLabels = resource.spec.selector or { };
        values = builtins.attrValues matchLabels;
        anyWithContext = builtins.any (v: builtins.isString v && builtins.getContext v != { }) values;
      in
      if matchLabels == { } || anyWithContext then
        [ ]
      else
        [
          {
            message =
              "Service '${resource.metadata.name or "?"}' has a selector with no store-path context on any value — "
              + "likely a hand-written `{ app = \"...\"; }` literal. "
              + "Source the selector from a workload via `kix.service.fromWorkload` so the Service → Deployment edge is explicit.";
          }
        ];
  };

  fqdnWithoutContext = {
    description = "Cluster-internal FQDNs (*.svc) in workloads should come from a ServiceRef/Service out.* value, not literals";
    level = "manifest";
    severity = "warning";
    tags = [
      "architecture"
      "netpol"
      "composition"
    ];
    appliesTo = { resource, ... }: builtins.elem (resource.kind or "") workloadKinds;
    check =
      { resource, ... }:
      let
        strings = collectStrings resource;
        offending = builtins.filter (s: looksLikeSvcFqdn s && builtins.getContext s == { }) strings;
      in
      map (s: {
        message =
          "string \"${s}\" contains a *.svc FQDN with no store-path context — likely hand-rolled. "
          + "Use `svc.out.fqdn`/`out.host` from a ServiceRef or `scope.augmentEdge` so netpol/DNS/wave edges follow automatically.";
      }) (lib.unique offending);
  };
}
