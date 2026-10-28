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

  # Return true when `s` contains a `<name>.<ns>.svc` DNS fragment.
  looksLikeSvcFqdn =
    s: lib.hasInfix ".svc" s && builtins.match ".*[a-zA-Z0-9-]+\\.[a-zA-Z0-9-]+\\.svc.*" s != null;

  # Annotation domains (and their subdomains) that do not require a declaring
  # operator package. This covers standard Kubernetes domains, Kix's own
  # domains, and Helm or Kubebuilder build metadata on imported charts.
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

  # Extract the domain prefix before `/` from an annotation key, or return null
  # when the key has no `/` or its prefix contains no dot.
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
  # a domain declared by a dependency. Only top-level `metadata.annotations`
  # are inspected.
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

        # Group carrying resources by domain so a missing operator dependency
        # produces one finding per domain rather than one per resource.
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

  # Report `kix.untrackedRef` references that do not name a creator. References
  # that set `by` to a resource (or `by = "self"` on a single resource) are
  # ordered and checked during deployment, so they are excluded here.
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

  # Reject workloads whose `spec.selector.matchLabels` is a subset of another
  # workload's pod template labels in the same instance.
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

  # Warn when two workloads in the same instance assign different port numbers
  # to the same port name. Package-level helpers and cross-resource checks
  # resolve port names across the instance, so conflicting numbers make port
  # resolution ambiguous.
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
        # Return `{ name, containerPort, owner }` for each named port in a workload.
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

  # Require same-kind label-selected resources (such as Services) in one
  # instance to have mutually non-subset label sets so label selectors can
  # target one without matching another.
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
        # Services created by `kix.operandService` target operator-managed pods
        # and are validated against their custom resource instead of a workload.
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
              # Strip string context from the namespace resource reference
              # before using it in an attribute name.
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

        # Return the target namespaces for a monitor, or null when `any = true`
        # selects all namespaces (including namespaces outside Kix that this
        # rule cannot verify). An empty selector defaults to the monitor's own
        # namespace.
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

        # Return true when a monitor endpoint's port matches at least one port
        # on the Service.
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

  # Reject hardcoded `cluster.local` domain references when the cluster uses a
  # custom `clusterDomain`. Skip CustomResourceDefinitions because upstream
  # schema descriptions often include example `cluster.local` FQDNs.
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
        # Replace the configured `clusterDomain` with a non-DNS sentinel
        # character so domains like `east.cluster.local` do not trigger false
        # positives.
        sentinel = builtins.fromJSON ''"\u0001"'';
        masked = builtins.replaceStrings [ domain ] [ sentinel ];

        # Split `s` on whole-label occurrences of `cluster.local`, padding both
        # ends so matches at the start or end of the string are captured.
        pieces = s: builtins.split "([^A-Za-z0-9-])cluster\\.local([^A-Za-z0-9-])" (" " + masked s + " ");
        hasHit = s: builtins.length (pieces s) > 1;

        # Extract a single-line snippet of up to 80 characters around the first match.
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
