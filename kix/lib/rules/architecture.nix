# Built-in scorecard rules for architecture and dependency injection.
#
# These rules find operator annotations without matching dependencies, Service
# selectors detached from workloads, internal Service names without dependency
# context, and uses of declared unsafe grants.

{ lib }:

let
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
  # A domain-qualified annotation must use a reserved or configured domain, or
  # a domain declared by a dependency. Inspect resource metadata annotations;
  # pod-template annotations, labels, and container arguments are out of scope.
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
                    "'${instanceName}' uses annotations under domain '${domain}' (${describeCarriers carriers}) "
                    + "but no package in this cluster declares that it handles them. "
                    + "Add the operator package that handles these annotations. If something outside Kix "
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
                    "'${instanceName}' uses annotations under domain '${domain}' (${describeCarriers carriers}), "
                    + "but does not declare a dependency on '${declarer.ns}/${declarer.inst}', which handles them. "
                    + "Add that operator to deps "
                    + "so Kix can check that it is present and deploy it first.";
                }
              ];
      in
      builtins.concatLists (lib.mapAttrsToList findingFor domainCarriers);
  };

  # An untracked reference says "something else creates this". A bare
  # claim is checked by nothing: when nothing creates the object, every eval
  # passes and a pod that mounts it waits in Init with "secret not found".
  # List every bare claim in a build in one place, so a reviewer reads a
  # list instead of finding them one mount at a time. A name is not listed
  # when every reference to it in its namespace names its creator: with
  # `kix.untrackedRef { kind; name; by; }` the referrer depends on the
  # creator and deploy waits for the object, and with `by = "self"` held
  # by exactly one resource in the cluster, that resource is the creator.
  untrackedReferences = {
    description = "Audit: names declared external with kix.untrackedRef that do not name their creator";
    level = "cluster";
    severity = "info";
    tags = [
      "architecture"
      "unsafe"
    ];
    check =
      {
        externalNames ? { },
        ...
      }:
      map (
        ref:
        let
          parts = lib.splitString "/" ref;
          ns = builtins.head parts;
          refName = builtins.concatStringsSep "/" (builtins.tail parts);
        in
        {
          namespace = ns;
          resource = refName;
          message =
            "'${refName}' is declared external with kix.untrackedRef, so Kix does not create it "
            + "and no check confirms that anything else does. Name the creator and the kind "
            + "(kix.untrackedRef { kind; name; by; }) so deploy waits for it, or use by = \"self\" when the "
            + "resource holding the reference creates it. Otherwise check that something really does: "
            + "an operator that mints it at runtime, or a step outside Kix.";
        }
      ) (builtins.attrNames (lib.filterAttrs (_: v: !(v.creatorNamed or false)) externalNames));
  };

  # Report each meta.unsafe grant at info severity so exceptions remain visible
  # in the scorecard without producing a warning.
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
        message = "'${instanceName}' declares the '${grant}' exception in meta.unsafe: ${
          (unsafe.registry.${grant} or { description = "unknown grant"; }).description
        }";
      }) (meta.unsafe or [ ]);
  };

  # Same-kind resources selected by labels must be distinguishable when a
  # consumer uses either resource's full label set.
  #
  # "Indistinguishable" is subset-or-equal, both directions: label matching
  # means "has at least these labels", so if A's labels are a subset of
  # B's, a selector built from A's full label set still matches B. Each
  # resource must carry at least one (key, value) the other lacks.
  #
  # Check kinds commonly discovered by label. Name-selected resources such as
  # ConfigMaps may share labels without ambiguity.
  distinctWorkloadSelectors = {
    description = "One workload's selector must not also match another workload's pods";
    level = "package";
    severity = "error";
    tags = [
      "architecture"
      "identity"
    ];
    check =
      { resources, ... }:
      let
        selectorKinds = [
          "Deployment"
          "StatefulSet"
          "DaemonSet"
          "Job"
        ];
        # CronJob pods can match another workload's selector, but a CronJob has
        # no selector with which to claim other pods.
        targetKinds = selectorKinds ++ [ "CronJob" ];
        podLabels =
          r:
          if (r.kind or "") == "CronJob" then
            r.spec.jobTemplate.spec.template.metadata.labels or { }
          else
            r.spec.template.metadata.labels or { };
        subsetOf =
          needle: hay: builtins.all (k: (hay.${k} or null) == needle.${k}) (builtins.attrNames needle);
        rid = r: "${r.kind or "?"}/${r.metadata.name or "?"}";
        sameIdentity =
          a: b:
          (a.metadata.name or null) == (b.metadata.name or null)
          && (a.metadata.namespace or null) == (b.metadata.namespace or null)
          && (a.kind or null) == (b.kind or null);
        selectors = builtins.filter (r: builtins.elem (r.kind or "") selectorKinds) resources;
        targets = builtins.filter (r: builtins.elem (r.kind or "") targetKinds) resources;
      in
      builtins.concatMap (
        a:
        let
          selector = a.spec.selector.matchLabels or { };
          claims = b: !(sameIdentity a b) && selector != { } && subsetOf selector (podLabels b);
        in
        map (b: {
          message =
            "${rid a} selects on ${builtins.toJSON selector}, which also matches the pods of ${rid b}. "
            + "Both pod sets answer to that selector, so readiness, Services, PodDisruptionBudgets and "
            + "network policy cannot tell them apart. Give each workload a label of its own.";
        }) (builtins.filter claims targets)
      ) selectors;
  };

  # Kubernetes scopes a port name to its pod, so two workloads in one
  # instance may legally name different numbers the same thing. Kix's
  # consumers are wider than a pod: `kix.service.fromWorkload` resolves a
  # name against the one workload it is handed, and cross-resource check 13
  # matches a Service's port names against the container ports of the whole
  # package. Anything that resolves a name without naming the workload it
  # belongs to picks one of the two numbers by accident, and the manifest
  # that results is valid, so nothing downstream catches it.
  consistentPortNames = {
    description = "One port name must mean one number across an instance's workloads";
    level = "package";
    severity = "warning";
    tags = [
      "architecture"
      "identity"
      "networking"
    ];
    check =
      { resources, ... }:
      let
        podSpec =
          r:
          if (r.kind or "") == "CronJob" then
            r.spec.jobTemplate.spec.template.spec or { }
          else if (r.kind or "") == "Pod" then
            r.spec or { }
          else
            r.spec.template.spec or { };
        rid = r: "${r.kind or "?"}/${r.metadata.name or "?"}";
        workloads = builtins.filter (r: builtins.elem (r.kind or "") workloadKinds) resources;
        # Every (name, number, owner) a workload's containers declare.
        portsOf =
          r:
          let
            spec = podSpec r;
            listOr = v: if v == null then [ ] else v;
            containers = listOr (spec.containers or [ ]) ++ listOr (spec.initContainers or [ ]);
          in
          builtins.concatMap (
            c:
            builtins.concatMap (
              p:
              lib.optional (p ? name && p ? containerPort) {
                inherit (p) name containerPort;
                owner = "${rid r} container ${c.name or "?"}";
              }
            ) (c.ports or [ ])
          ) containers;
        declared = builtins.concatMap portsOf workloads;
        names = lib.unique (map (p: p.name) declared);
        conflicts = builtins.filter (
          n:
          builtins.length (lib.unique (map (p: p.containerPort) (builtins.filter (p: p.name == n) declared)))
          > 1
        ) names;
      in
      map (
        n:
        let
          uses = builtins.filter (p: p.name == n) declared;
          spelt = map (p: "${p.owner} = ${toString p.containerPort}") uses;
        in
        {
          message =
            "port name \"${n}\" means more than one number in this instance: "
            + builtins.concatStringsSep ", " spelt
            + ". A consumer that resolves the name without naming the workload picks one of them "
            + "by accident. Give each component a name of its own.";
        }
      ) conflicts;
  };

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
        # Report equality and one-way subsets separately because they require
        # different label changes. A same-name pair is an identity collision,
        # which labels cannot resolve.
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
                        + " in namespace '${a.metadata.namespace or "?"}'. The duplicate name causes one"
                        + " resource to replace the other in the output. Rename one of them.";
                    }
                  ]
                else if rel != null then
                  [
                    {
                      message =
                        "In instance '${instanceName}': ${rel}. "
                        + "To fix it, give each ${kind} in this instance its own label: the same key with a "
                        + "different value on each, for example `labels.\"app.kubernetes.io/component\"`. "
                        + "A label selector matches anything that has at "
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

  # A Service selector should carry context from workload.out.selector so the
  # dependency graph follows label changes. Literal selectors and rawSelector
  # lack this context and trigger the warning. Use kix.service.fromWorkload for
  # the normal case; rawSelector remains available to break evaluation cycles.
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
        # A Service over an operator's pods has no workload to derive from;
        # cross-resource check 4 checks the custom resource it names.
        isOperandService = (resource.metadata.annotations or { }) ? ${kixKeys.operandOf};
      in
      if matchLabels == { } || anyWithContext || isOperandService then
        [ ]
      else
        [
          {
            message =
              "Service '${resource.metadata.name or "?"}' has selector labels that Kix cannot trace to a workload. "
              + "Use `kix.service.fromWorkload` to derive the selector and track the dependency on the workload.";
          }
        ];
  };

  # ServiceMonitor and VMServiceScrape selectors match Service metadata labels,
  # not pod selectors. Require one matching Service with a compatible port.
  #
  # Check only monitors whose target namespaces all contain active Kix
  # instances. Skip matchExpressions and namespaces with incomplete visibility.
  #
  # Namespace ownership is an approximation because external controllers may
  # create Services in managed namespaces. Set the monitorsExternalService
  # annotation when a monitor intentionally targets such a Service.
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

        # Both monitor kinds share prometheus-operator's namespaceSelector
        # semantics: `any = true` selects every namespace, a non-empty
        # matchNames lists them, and an empty selector or empty matchNames
        # means the monitor's own namespace. `any = true` returns null,
        # the sentinel for a target set that includes namespaces kix
        # cannot see; the monitor is then skipped under the scoping
        # contract above, because a missing match cannot be proven there.
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

        # Count a Service only when labels and at least one endpoint port match.
        # This distinguishes an actual duplicate scrape from a label-only match.
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
            # Without an endpoint port filter, any matched Service qualifies.
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
            # Matching labels with no compatible endpoint port produces no
            # scrape target.
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
                  + "so the monitor will not collect metrics from these Services. "
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

  # Report monitorsExternalService exemptions at info severity so reviewers
  # can remove them if Kix later starts rendering the target Service.
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
            + "outside Kix (${kixKeys.monitorsExternalService}), so selector matching is skipped for it. "
            + "Remove this annotation if Kix starts creating the target Service.";
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
          "string \"${s}\" contains a cluster Service address (*.svc) that Kix cannot trace to a Service. "
          + "Use the Service or ServiceRef's `out.fqdn` or `out.host` so Kix can derive network policies and deployment order.";
      }) (lib.unique offending);
  };

  # A string naming cluster.local resolves only on a cluster whose
  # clusterDomain is cluster.local. The rule is inert on such clusters.
  # CustomResourceDefinitions are skipped: their schema text quotes example
  # FQDNs. The configured domain is masked before matching, so a domain
  # such as east.cluster.local is not a hit, and cluster.local counts only
  # as whole labels (mycluster.local and cluster.localhost do not match).
  clusterDomainLiteral = {
    description = "Rendered strings must not name cluster.local when the cluster's clusterDomain is another domain";
    level = "cluster";
    severity = "error";
    tags = [
      "architecture"
      "portability"
    ];
    appliesTo =
      { clusterConfig, ... }: (clusterConfig.clusterDomain or "cluster.local") != "cluster.local";
    check =
      { allResources, clusterConfig, ... }:
      let
        domain = clusterConfig.clusterDomain;
        # Stands in for the configured domain while matching: it is not a
        # label character, so "x.svc.<domain>" never reads as cluster.local.
        sentinel = builtins.fromJSON ''"\u0001"'';
        masked = builtins.replaceStrings [ domain ] [ sentinel ];

        # `builtins.split` output for whole-label occurrences of
        # cluster.local, each match capturing the character on either side.
        # The string is padded with a space at both ends so an occurrence at
        # either end also has a non-label character beside it.
        pieces = s: builtins.split "([^A-Za-z0-9-])cluster\\.local([^A-Za-z0-9-])" (" " + masked s + " ");
        hasHit = s: builtins.length (pieces s) > 1;

        # Up to 80 characters either side of the first hit, on one line.
        excerpt =
          s:
          let
            p = pieces s;
            m = builtins.elemAt p 1;
            rejoin = lib.concatMapStrings (
              x: if builtins.isString x then x else "${builtins.elemAt x 0}cluster.local${builtins.elemAt x 1}"
            );
            padded = builtins.head p + builtins.elemAt m 0;
            before = builtins.substring 1 (builtins.stringLength padded - 1) padded;
            rest = builtins.elemAt m 1 + rejoin (lib.drop 2 p);
            after = builtins.substring 0 (builtins.stringLength rest - 1) rest;
            lb = builtins.stringLength before;
            la = builtins.stringLength after;
          in
          builtins.replaceStrings [ sentinel "\n" ] [ domain "\\n" ] (
            (if lb > 80 then "..." + builtins.substring (lb - 80) 80 before else before)
            + "cluster.local"
            + (if la > 80 then builtins.substring 0 80 after + "..." else after)
          );

        findingFor =
          r:
          let
            offending = builtins.filter hasHit (collectStrings r);
          in
          lib.optional (offending != [ ]) {
            namespace = r.metadata.namespace or null;
            resource = r.metadata.name or "?";
            message =
              "${r.kind or "?"} '${r.metadata.name or "?"}' in namespace '${
                r.metadata.namespace or "(cluster)"
              }' contains \"${builtins.unsafeDiscardStringContext (excerpt (builtins.head offending))}\", which names the DNS domain cluster.local, but this cluster's clusterDomain is \"${domain}\", "
              + "so that address does not resolve. Build in-cluster addresses from a Service's out.fqdn or out.url, "
              + "or read clusterConfig.clusterDomain; for a Helm chart, pass the domain to the chart's cluster-domain value.";
          };
      in
      builtins.concatMap findingFor (
        builtins.filter (r: (r.kind or "") != "CustomResourceDefinition") allResources
      );
  };
}
