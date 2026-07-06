# Built-in scorecard rules: Architecture / Dependency-Injection hygiene
#
# These rules catch "code smells" where a package hand-wires something that
# should be a declared edge in the graph: annotations that configure an
# operator the package doesn't link against, Service selectors detached from
# their workload, cluster-internal FQDNs with no store-path context.
#
# The old `capabilityOwnership` fingerprint rule (resource-content patterns +
# `kix.dev/capability` provenance stamps) was decomposed in
# v2_discussions/128 into:
#
#   - an eval-time *error* on raw PersistentVolumeClaims with a
#     `meta.unsafe = [ "raw-pvc" ]` escape (scope/validators.nix
#     checkRawPvc; the closed grant vocabulary lives in kix/lib/unsafe.nix)
#     — audited here by `unsafeGrants`;
#   - the `annotationDomainOwnership` lint below, driven by declared
#     `meta.annotationDomains` + DI edges instead of string fingerprints.

{ lib }:

let
  unsafe = import ../unsafe.nix { inherit lib; };

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

  # Domains whose annotations need no declarer: Kubernetes reserves the
  # kubernetes.io / k8s.io suffixes for core components; kix.dev is our own;
  # helm.sh (incl. meta.helm.sh) rides on imported chart resources;
  # kubebuilder.io is build-tooling provenance stamped on chart CRDs and
  # consumed by nothing at runtime. Suffix-matched, so
  # service.beta.kubernetes.io etc. pass.
  reservedAnnotationDomains = [
    "kubernetes.io"
    "k8s.io"
    "kix.dev"
    "helm.sh"
    "kubebuilder.io"
  ];

  isReservedDomain = d: builtins.any (r: d == r || lib.hasSuffix ".${r}" d) reservedAnnotationDomains;

  # Annotation key → DNS-domain-shaped prefix, or null. Keys without a "/"
  # or with a dot-less prefix ("checksum/config") are not domain-qualified.
  annotationKeyDomain =
    key:
    let
      parts = lib.splitString "/" key;
      prefix = builtins.head parts;
    in
    if builtins.length parts < 2 || !(lib.hasInfix "." prefix) then null else prefix;

in
{
  # v2_discussions/128 mechanism 2: every domain-shaped annotation prefix
  # needs a declarer — the reserved set above, a package in the cluster
  # declaring `meta.annotationDomains` (then a DI dep edge on it too), or the
  # operator's `scorecard.knownAnnotationDomains` list. Two warnings fall
  # out: "declared domain, missing dep edge" (you are writing config for an
  # operator you don't link against) and "unknown domain" (the annotation is
  # dead — you likely forgot to link the operator).
  #
  # v1 scans resource-level `metadata.annotations` keys only: no labels, no
  # pod-template annotations, no container-arg scanning. The old arg-string
  # scan caught runtime `kubectl annotate` Jobs; that loss is accepted —
  # that pattern's real smell is "package runs kubectl against foreign
  # resources", not its domain string.
  annotationDomainOwnership = {
    description = "Annotations under an operator-managed domain require a DI dep on the declaring package";
    level = "package";
    severity = "warning";
    tags = [
      "architecture"
      "di"
    ];
    check =
      {
        resources,
        instanceName,
        namespaceName,
        annotationDomainIndex ? { },
        resolvedDepTargets ? [ ],
        knownAnnotationDomains ? [ ],
        ...
      }:
      let
        resourceDomains =
          r:
          lib.unique (
            builtins.filter (d: d != null) (
              map annotationKeyDomain (builtins.attrNames (r.metadata.annotations or { }))
            )
          );

        # domain → example resources carrying it (findings aggregate per
        # domain so ten resources with one forgotten operator yield one
        # actionable message, not ten).
        domainCarriers = builtins.foldl' (
          acc: r:
          builtins.foldl' (
            acc': d: acc' // { ${d} = (acc'.${d} or [ ]) ++ [ "${r.kind or "?"}/${r.metadata.name or "?"}" ]; }
          ) acc (resourceDomains r)
        ) { } resources;

        describeCarriers =
          carriers:
          let
            shown = lib.take 3 carriers;
            more = builtins.length carriers - builtins.length shown;
          in
          builtins.concatStringsSep ", " shown + lib.optionalString (more > 0) " (+${toString more} more)";

        findingFor =
          domain: carriers:
          if isReservedDomain domain || builtins.elem domain knownAnnotationDomains then
            [ ]
          else
            let
              declarer = annotationDomainIndex.${domain} or null;
            in
            if declarer == null then
              [
                {
                  message =
                    "'${instanceName}' carries annotations under domain '${domain}' (${describeCarriers carriers}) "
                    + "but no package in this cluster declares that domain — the annotations are dead. "
                    + "You likely forgot to add the operator that consumes them; if something outside kix "
                    + "consumes this domain, declare it in `scorecard.knownAnnotationDomains`.";
                }
              ]
            else if declarer.ns == namespaceName && declarer.inst == instanceName then
              [ ]
            else if builtins.elem "${declarer.ns}/${declarer.inst}" resolvedDepTargets then
              [ ]
            else
              [
                {
                  message =
                    "'${instanceName}' carries annotations under domain '${domain}' (${describeCarriers carriers}), "
                    + "which is managed by '${declarer.ns}/${declarer.inst}' — but has no DI dep on it. "
                    + "You are writing config for an operator you don't link against: declare the dep "
                    + "so presence and ordering are checked at eval.";
                }
              ];
      in
      builtins.concatLists (lib.mapAttrsToList findingFor domainCarriers);
  };

  # The `#![allow]` audit (v2_discussions/128 mechanism 1): every
  # `meta.unsafe` grant in the cluster is listed so an escape from a
  # structural rule is visible in review — info severity, it is not a
  # warning to dismiss but a fact to see.
  unsafeGrants = {
    description = "Audit: packages holding unsafe grants (meta.unsafe)";
    level = "package";
    severity = "info";
    tags = [
      "architecture"
      "unsafe"
    ];
    check =
      { meta, instanceName, ... }:
      map (grant: {
        message = "'${instanceName}' holds unsafe grant '${grant}' — ${
          (unsafe.registry.${grant} or { description = "unknown grant"; }).description
        }";
      }) (meta.unsafe or [ ]);
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
