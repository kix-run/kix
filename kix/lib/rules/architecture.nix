# Built-in scorecard rules: Architecture / Dependency-Injection hygiene
#
# These rules catch "code smells" where a package hand-wires something that
# should be a declared edge in the graph: annotations that configure an
# operator the package doesn't link against, Service selectors detached from
# their workload, cluster-internal FQDNs with no store-path context.
#
# The old `capabilityOwnership` fingerprint rule (resource-content patterns +
# `kix.run/capability` provenance stamps) was decomposed in
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
  # Kix's own annotation keys and API names, spelled once in
  # core/annotations.nix.
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;
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
  # kubernetes.io / k8s.io suffixes for core components; Kix's own domain,
  # and the ones it has retired, are ours;
  # helm.sh (incl. meta.helm.sh) rides on imported chart resources;
  # kubebuilder.io is build-tooling provenance stamped on chart CRDs and
  # consumed by nothing at runtime. Suffix-matched, so
  # service.beta.kubernetes.io etc. pass.
  reservedAnnotationDomains = [
    "kubernetes.io"
    "k8s.io"
    kixAnnotations.domain
  ]
  ++ kixAnnotations.legacyDomains
  ++ [
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

  # kixpkgs#46, producer side: two same-kind resources in one instance with
  # indistinguishable labels cannot be told apart by ANY label-selecting
  # consumer — present or future. This fires on the ambiguity itself, not
  # on a consumer tripping over it (monitorSelectorMatchesService covers
  # that, including cross-instance), so a package is forced to give each
  # Service its own identity the moment it grows a second one.
  #
  # "Indistinguishable" is subset-or-equal, both directions: label matching
  # means "has at least these labels", so if A's labels are a subset of
  # B's, a selector built from A's full label set still matches B. Each
  # resource must carry at least one (key, value) the other lacks.
  #
  # Kinds checked: only those discovered BY label selector in practice.
  # Extending to every kind would error on harmless twins (two ConfigMaps
  # in one instance are label-identical everywhere and selected by name).
  distinctSameKindLabels = {
    description = "Same-kind label-selectable resources in one instance must be label-distinguishable";
    level = "package";
    severity = "error";
    tags = [
      "architecture"
      "monitoring"
      "identity"
    ];
    check =
      { resources, instanceName, ... }:
      let
        labelSelectedKinds = [ "Service" ];
        subsetOf =
          needle: hay: builtins.all (k: (hay.${k} or null) == needle.${k}) (builtins.attrNames needle);
        rid = r: "${r.kind or "?"}/${r.metadata.name or "?"}";
        sameIdentity =
          a: b:
          (a.metadata.name or null) == (b.metadata.name or null)
          && (a.metadata.namespace or null) == (b.metadata.namespace or null);
        # The first sentence of the finding states the exact relationship,
        # because the reader's fix differs slightly: identical label sets
        # mean neither can be picked out; a one-way subset means the
        # smaller set can never be selected without also hitting the
        # larger. Two resources with the same name are a different problem
        # (a collision, not a label question) and get their own message
        # below, since no label fix can make two same-named Services
        # coexist (kixpkgs#71 item 14).
        relationship =
          a: b:
          let
            la = a.metadata.labels or { };
            lb = b.metadata.labels or { };
          in
          if sameIdentity a b then
            null
          else if la == lb then
            "${rid a} and ${rid b} carry exactly the same labels, so nothing that finds ${a.kind or "?"}s by labels can pick one without the other"
          else if subsetOf la lb then
            "${rid a} carries a subset of ${rid b}'s labels, so any selector that finds ${rid a} also finds ${rid b}"
          else if subsetOf lb la then
            "${rid b} carries a subset of ${rid a}'s labels, so any selector that finds ${rid b} also finds ${rid a}"
          else
            null;
        checkKind =
          kind:
          let
            rs = builtins.filter (r: (r.kind or "") == kind) resources;
            n = builtins.length rs;
            pairFindings = builtins.concatMap (
              i:
              builtins.concatMap (
                j:
                let
                  a = builtins.elemAt rs i;
                  b = builtins.elemAt rs j;
                  rel = relationship a b;
                in
                if sameIdentity a b then
                  [
                    {
                      message =
                        "In instance '${instanceName}': two ${kind}s are both named '${a.metadata.name or "?"}'"
                        + " in namespace '${a.metadata.namespace or "?"}'. That is a name collision, not a label"
                        + " problem: the manifest writer keeps one and drops the other. Rename one of them.";
                    }
                  ]
                else if rel != null then
                  [
                    {
                      message =
                        "In instance '${instanceName}': ${rel}. "
                        + "To fix it, give each ${kind} in this instance its own label: the same key with a "
                        + "different value on each, for example `labels.\"app.kubernetes.io/component\"`. "
                        + "Each one needs its own value. A label selector matches anything that has at "
                        + "least the selected labels, so adding a label to only one of them leaves the "
                        + "other still matching both.";
                    }
                  ]
                else
                  [ ]
              ) (lib.range (i + 1) (n - 1))
            ) (lib.range 0 (n - 1));
          in
          if n < 2 then [ ] else pairFindings;
      in
      builtins.concatMap checkKind labelSelectedKinds;
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

  # The ServiceMonitor selector-mismatch class: three packages (grafana,
  # node-exporter, kube-state-metrics) shipped monitors whose selector was
  # built from the WORKLOAD's pod selector. ServiceMonitor/VMServiceScrape
  # selectors match the target Service's METADATA LABELS, not its
  # spec.selector — every target was dropped at relabeling and the jobs
  # were silently absent from `up` (caught live on kind + stage1,
  # 2026-08-31). This rule makes the class unshippable: a monitor whose
  # selector matches no Service in its target namespaces is always a bug
  # in kix-authored manifests.
  #
  # Scoping: only monitors whose target namespaces are ALL kix-managed
  # (have at least one ACTIVE kix instance) are checked — a monitor aimed
  # at an unmanaged namespace may legitimately select Services kix cannot
  # see. matchExpressions are not evaluated (skip, don't guess).
  #
  # This predicate is a HEURISTIC, permanently: "namespace has an active
  # kix instance" neither implies kix renders every Service there (rke2
  # owns most of stage2's kube-system while kix supplies only coredns) nor
  # covers namespaces kix renders Services into without an instance
  # (prometheus-default-rules' bridge Services via forNamespace). The
  # false-positive relief valves are the annotation below and severity
  # overrides; the false-negative side is accepted.
  #
  # Escape hatch: a monitor that deliberately targets a Service kix does
  # not render (created by an operator at runtime, e.g. prometheus-
  # operator's kubelet Service) declares
  # `annotations.${kixKeys.monitorsExternalService} = "true"` — the claim
  # then rides the resource into the cluster, where it documents itself.
  monitorSelectorMatchesService = {
    description = "ServiceMonitor/VMServiceScrape selectors must match exactly one scrapable Service's metadata labels";
    level = "cluster";
    severity = "error";
    tags = [
      "architecture"
      "monitoring"
      "composition"
    ];
    appliesTo = _: true;
    check =
      { allInstances, allResources, ... }:
      let
        managedNamespaces = builtins.attrNames allInstances;

        # A ServiceRef marker (scope.mkServiceRef) stands for a Service kix
        # does not render. When the ref declares the Service's labels and
        # ports, the marker counts here as that Service, so a self-monitor
        # over an operator-created Service is checked like any other.
        refServices = builtins.concatMap (
          r:
          let
            anns = r.metadata.annotations or { };
          in
          if
            (r.kind or "") == "PackageInstance"
            && (anns.${kixKeys.importKind} or null) == "Service"
            && anns ? ${kixKeys.serviceLabels}
          then
            [
              {
                kind = "Service";
                metadata = {
                  name = anns.${kixKeys.importName};
                  namespace = r.metadata.namespace or null;
                  labels = builtins.fromJSON anns.${kixKeys.serviceLabels};
                };
                spec.ports = builtins.fromJSON (anns.${kixKeys.servicePorts} or "[]");
              }
            ]
          else
            [ ]
        ) allResources;
        # Two refs to the same Service (two instances in one namespace) are
        # one Service, not two candidates.
        uniqueRefServices = builtins.attrValues (
          builtins.listToAttrs (
            map (s: {
              # Attribute names cannot carry string context; the namespace
              # value does (it names the Namespace resource).
              name = builtins.unsafeDiscardStringContext "${s.metadata.namespace or "?"}/${s.metadata.name}";
              value = s;
            }) refServices
          )
        );
        services = builtins.filter (r: (r.kind or "") == "Service") allResources ++ uniqueRefServices;
        monitors = builtins.filter (
          r:
          builtins.elem (r.kind or "") [
            "ServiceMonitor"
            "VMServiceScrape"
          ]
        ) allResources;

        subsetOf =
          needle: hay: builtins.all (k: (hay.${k} or null) == needle.${k}) (builtins.attrNames needle);

        # prometheus-operator NamespaceSelector semantics (the VM operator
        # mirrors them): `any = true` takes precedence and means ALL
        # namespaces; a non-empty matchNames lists them; empty matchNames
        # and the empty selector both mean the monitor's own namespace.
        # `any = true` returns null as a sentinel — the target set includes
        # namespaces kix cannot see, so the monitor is skipped per the
        # scoping contract above (a false-negative surface, but the only
        # honest answer: absence of a match is unprovable there).
        targetNamespaces =
          mon:
          let
            nsSel = mon.spec.namespaceSelector or { };
            own = mon.metadata.namespace or null;
            names = nsSel.matchNames or [ ];
          in
          if (nsSel.any or false) then
            null
          else if names != [ ] then
            names
          else if own != null then
            [ own ]
          else
            [ ];

        # ── Over-match detection (the silent half of the bug class) ──────
        # A selector matching MORE than one Service double-scrapes every
        # pod behind both. But label-matching alone over-counts: a monitor
        # also names the port it scrapes, and a matched Service without
        # that port produces no targets. So a Service only counts if one
        # of the monitor's endpoints can hit one of its ports. Comparison
        # stays within the monitor's target kind (Services) — no
        # cross-kind counting.
        endpointHitsService =
          ep: svc:
          let
            svcPorts = svc.spec.ports or [ ];
            epPort = ep.port or null;
            epTarget = ep.targetPort or null;
          in
          if epPort != null then
            builtins.any (p: (p.name or null) == epPort) svcPorts
          else if epTarget != null then
            builtins.any (
              p: (p.targetPort or p.port or null) == epTarget || (p.name or null) == epTarget
            ) svcPorts
          else
            # No port named at all: prometheus-operator scrapes every
            # endpoint port — any Service counts.
            true;

        scrapesService =
          mon: svc:
          let
            endpoints = mon.spec.endpoints or [ ];
          in
          endpoints == [ ] || builtins.any (ep: endpointHitsService ep svc) endpoints;

        checkMonitor =
          mon:
          let
            sel = mon.spec.selector or { };
            matchLabels = sel.matchLabels or { };
            targets = targetNamespaces mon;
            allTargetsManaged =
              targets != null && targets != [ ] && builtins.all (ns: builtins.elem ns managedNamespaces) targets;
            candidates = builtins.filter (svc: builtins.elem (svc.metadata.namespace or null) targets) services;
            matched = builtins.filter (svc: subsetOf matchLabels (svc.metadata.labels or { })) candidates;
            scraped = builtins.filter (scrapesService mon) matched;
            external = ((mon.metadata.annotations or { }).${kixKeys.monitorsExternalService} or "") == "true";
            skip = external || sel ? matchExpressions || matchLabels == { } || !allTargetsManaged;
            monId = "${mon.kind or "?"}/${mon.metadata.name or "?"}";
            svcId = svc: "${svc.metadata.namespace or "?"}/${svc.metadata.name or "?"}";
          in
          if skip then
            [ ]
          else if matched == [ ] then
            [
              {
                namespace = mon.metadata.namespace or null;
                resource = monId;
                message =
                  "${mon.kind or "?"} '${mon.metadata.name or "?"}' selects "
                  + "{ ${lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k}=${toString v}") matchLabels)} }, "
                  + "but no Service in namespace(s) ${lib.concatStringsSep ", " targets} carries those labels, "
                  + "so this monitor finds nothing and its jobs are silently missing. "
                  + "A monitor's selector is compared with the labels on the Service itself "
                  + "(metadata.labels), not with the Service's own selector, and not with the pods' labels. "
                  + "Build the selector from the target Service's labels: `self.<service>.out.selector`, "
                  + "or use `kix.monitor`, which does this for you.";
              }
            ]
          else if scraped == [ ] then
            # The labels match, the port does not: prometheus-operator keeps
            # the Service and drops every endpoint at relabeling, so the job
            # is just as absent from `up` as with no match at all. Harbor
            # shipped this shape (selector on the redis Service, scrape port
            # only on core/registry/jobservice/exporter) and passed silently
            # before this branch existed (2026-09-18).
            [
              {
                namespace = mon.metadata.namespace or null;
                resource = monId;
                message =
                  "${mon.kind or "?"} '${mon.metadata.name or "?"}' selects "
                  + "${lib.concatStringsSep ", " (map svcId matched)} by labels, but none of "
                  + "${if builtins.length matched == 1 then "its" else "their"} ports match the monitor's endpoint"
                  + "${
                    lib.optionalString (mon.spec.endpoints or [ ] != [ ])
                      " (${
                         lib.concatStringsSep ", " (
                           map (ep: toString (ep.port or ep.targetPort or "?")) (mon.spec.endpoints or [ ])
                         )
                       })"
                  }, "
                  + "so every target is dropped at relabeling and the job is silently missing from `up`. "
                  + "Point the endpoint at a port the Service declares by name, or select the Service that "
                  + "serves metrics: `self.<service>.out.selector`, or use `kix.monitor` with `port = \"<name>\"`.";
              }
            ]
          else if builtins.length scraped > 1 then
            [
              {
                namespace = mon.metadata.namespace or null;
                resource = monId;
                message =
                  "${mon.kind or "?"} '${mon.metadata.name or "?"}' matches ${toString (builtins.length scraped)} Services "
                  + "on its scrape port: ${lib.concatStringsSep ", " (map svcId scraped)}. "
                  + "A pod behind more than one of them is scraped once per Service, so its metrics are "
                  + "counted more than once. "
                  + "Narrow the selector so it matches only the intended Service: select on a label that "
                  + "only that Service carries. If the matched Services come from one package, first give "
                  + "each its own label (the same key with a different value on each), then build the "
                  + "selector from the intended Service's labels: `self.<service>.out.selector`.";
              }
            ]
          else
            [ ];
      in
      builtins.concatMap checkMonitor monitors;
  };

  # Companion audit to monitorSelectorMatchesService's escape hatch: every
  # `kix.run/monitors-external-service` claim is listed at info level, the
  # same "never invisible in review" property the meta.unsafe vocabulary
  # gets from unsafeGrants. A stale claim (the target Service later becomes
  # kix-rendered) is otherwise undetectable — the escape silently disables
  # checking forever.
  externalMonitorTargets = {
    description = "Audit: monitors claiming an external (non-kix-rendered) target Service";
    level = "manifest";
    severity = "info";
    tags = [
      "architecture"
      "monitoring"
      "audit"
    ];
    appliesTo =
      { resource, ... }:
      builtins.elem (resource.kind or "") [
        "ServiceMonitor"
        "VMServiceScrape"
      ]
      && ((resource.metadata.annotations or { }).${kixKeys.monitorsExternalService} or "") == "true";
    check =
      { resource, ... }:
      [
        {
          message =
            "${resource.kind} '${resource.metadata.name or "?"}' claims its target Service is created "
            + "outside kix (${kixKeys.monitorsExternalService}), so selector matching is skipped for it. "
            + "Check that the claim still holds if kix ever starts rendering the target.";
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
