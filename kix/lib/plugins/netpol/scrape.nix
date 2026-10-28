# Derive network policies for the scrape paths from each Prometheus server to
# its selected ServiceMonitors, PodMonitors, and Alertmanagers.
#
# The netpol cluster processor runs this pass after all instances are built
# because scrape discovery is a cluster-wide label join. A Prometheus CR
# selects monitors by label and namespace selectors, while ServiceMonitors
# and PodMonitors select Services and pods by label. Those selectors carry no
# endpoint facts and often cross namespaces, so per-workload edge analysis
# cannot see the connection.
#
# Scraper pods are identified by `factBehavior.podSelector` on the Prometheus
# CRD. Targets are resolved against rendered Services, ServiceRef markers,
# and workloads. A Service backed by pods outside Kix still gets a selector
# egress rule on the pod network, while a monitor targeting an unrendered
# Service without a ServiceRef marker gets no rule.
#
# Unresolvable scrape paths include Prometheus resources without a
# `podSelector`, PodMonitor selectors that use `matchExpressions`, and named
# target ports that no rendered container declares. Under default deny these
# are build errors because the scrape traffic would be blocked. When default
# deny is disabled they are reported as warnings.
#
# When default deny is disabled, adding the first ingress policy to a target
# pod would block all other callers. Target ingress policies are therefore
# emitted only when another policy already isolates all of the target's pods
# for ingress.

{ lib }:

let
  kixKeys = (import ../../core/annotations.nix).keys;
  core = import ../../core/default.nix { inherit lib; };
  inherit (import ../../eval/edges.nix { k8s = core; }) isWorkload isServiceRef;

  monitoringGroup = "monitoring.coreos.com";
  groupOf = r: lib.head (lib.splitString "/" (r.rawManifest.apiVersion or ""));
  isMonitoringKind = kind: r: (r.kind or "") == kind && groupOf r == monitoringGroup;

  # Strip string context so a value can be used in attribute and resource names.
  plain = s: builtins.unsafeDiscardStringContext (toString s);

  nsOfRaw = raw: raw.metadata.namespace or null;

  # Return true when `labels` satisfies a Kubernetes `metav1.LabelSelector`.
  # An empty selector matches every label set.
  matchesSelector =
    selector: labels:
    let
      matchLabels = selector.matchLabels or { };
      exprHolds =
        e:
        let
          has = labels ? ${e.key};
          values = e.values or [ ];
        in
        if e.operator == "In" then
          has && builtins.elem labels.${e.key} values
        else if e.operator == "NotIn" then
          !has || !(builtins.elem labels.${e.key} values)
        else if e.operator == "Exists" then
          has
        else if e.operator == "DoesNotExist" then
          !has
        else
          throw "kix netpol: label selector operator '${toString e.operator}' is not one of In, NotIn, Exists, DoesNotExist";
    in
    builtins.all (k: (labels.${k} or null) == matchLabels.${k}) (builtins.attrNames matchLabels)
    && builtins.all exprHolds (selector.matchExpressions or [ ]);

  isNumeric = p: builtins.isInt p || (builtins.isString p && builtins.match "[0-9]+" p != null);
in
{
  inherit matchesSelector;

  # Derive `{ egressPolicies, ingressPolicies, warnings, errors }` for all
  # Prometheus instances in Kix-managed namespaces. `extraPolicies` supplies
  # additional cluster-level policies (such as platform intents) that count
  # when checking whether target pods are already isolated for ingress.
  # `errors` is populated only when `defaultDeny` is enabled.
  derive =
    {
      resources,
      nsResources,
      realNsNames,
      enforcerApi,
      enforced,
      defaultDeny,
      extraPolicies ? [ ],
    }:
    let

      nsLabels =
        ns:
        (nsResources.${ns}.rawManifest.metadata.labels or { })
        // {
          "kubernetes.io/metadata.name" = ns;
        };

      # Collect Services with pod selectors and ServiceRef markers as
      # `{ namespace, name, labels, selector, ports }`.
      services = builtins.concatMap (
        r:
        let
          raw = r.rawManifest;
          anns = raw.metadata.annotations or { };
        in
        if (r.kind or "") == "Service" && (raw.spec.selector or { }) != { } then
          [
            {
              namespace = nsOfRaw raw;
              name = raw.metadata.name;
              labels = raw.metadata.labels or { };
              selector = raw.spec.selector;
              ports = raw.spec.ports or [ ];
            }
          ]
        else if isServiceRef r && anns ? ${kixKeys.serviceSelector} then
          [
            {
              namespace = nsOfRaw raw;
              name = anns.${kixKeys.importName};
              labels = builtins.fromJSON (anns.${kixKeys.serviceLabels} or "{}");
              selector = builtins.fromJSON anns.${kixKeys.serviceSelector};
              ports = builtins.fromJSON (anns.${kixKeys.servicePorts} or "[]");
            }
          ]
        else
          [ ]
      ) resources;

      workloads = map (
        w:
        let
          podSpec = w.rawManifest.spec.template.spec or { };
        in
        {
          namespace = nsOfRaw w.rawManifest;
          podLabels = w.rawManifest.spec.template.metadata.labels or { };
          hostNetwork = podSpec.hostNetwork or false;
          namedPorts = builtins.listToAttrs (
            builtins.concatMap (
              c:
              map (cp: {
                name = cp.name;
                value = cp.containerPort;
              }) (builtins.filter (cp: cp ? name) (c.ports or [ ]))
            ) (podSpec.containers or [ ])
          );
        }
      ) (builtins.filter isWorkload resources);

      podsOf =
        namespace: podSelector:
        builtins.filter (
          w: w.namespace == namespace && matchesSelector { matchLabels = podSelector; } w.podLabels
        ) workloads;

      # Resolve a port name against the container ports of the backing workloads.
      # Multiple workloads behind one selector may map the same port name to
      # different numbers. Keep the port name unchanged when no workload in the
      # build declares it.
      resolvePort =
        backing: port:
        if isNumeric port then
          [ (toString port) ]
        else
          let
            hits = lib.unique (
              map toString (
                builtins.concatMap (w: lib.optional (w.namedPorts ? ${port}) w.namedPorts.${port}) backing
              )
            );
          in
          if hits == [ ] then [ port ] else hits;

      # Build a scrape target record for pods matching `podSelector` in
      # `namespace`. `key` forms the human-readable policy name segment, and
      # `id` deduplicates targets within a namespace.
      mkTarget =
        {
          key,
          id,
          namespace,
          podSelector,
          ports,
          protocol ? "TCP",
        }:
        let
          backing = podsOf namespace podSelector;
        in
        {
          inherit
            key
            id
            namespace
            podSelector
            ;
          ports = map (port: { inherit port protocol; }) (
            lib.unique (builtins.concatMap (resolvePort backing) ports)
          );
          # Only workloads built by Kix have known `hostNetwork` and pod labels.
          # Pods created at runtime by an operator default to the pod network
          # with an empty `podLabelSets`.
          hostNetwork = backing != [ ] && builtins.all (w: w.hostNetwork) backing;
          podLabelSets = map (w: w.podLabels) backing;
        };

      podPortOf = sp: sp.targetPort or sp.port;

      serviceTarget =
        svc: podPorts:
        mkTarget {
          key = "svc-${svc.name}";
          id = "svc/${svc.name}";
          inherit (svc) namespace;
          podSelector = svc.selector;
          ports = podPorts;
        };

      # Return the namespaces selected by a monitor's `namespaceSelector`. When
      # `any = true`, include all Kix namespaces and any external namespaces
      # referenced by ServiceRef markers.
      monitorNamespaces =
        mon:
        let
          sel = mon.spec.namespaceSelector or { };
          names = sel.matchNames or [ ];
        in
        if sel.any or false then
          lib.unique (
            map plain (
              realNsNames ++ builtins.filter (n: n != null) (map (s: s.namespace) services ++ [ (nsOfRaw mon) ])
            )
          )
        else if names != [ ] then
          names
        else
          [ (nsOfRaw mon) ];

      serviceMonitorTargets =
        mon:
        let
          namespaces = monitorNamespaces mon;
          matched = builtins.filter (
            s: builtins.elem s.namespace namespaces && matchesSelector (mon.spec.selector or { }) s.labels
          ) services;
          endpoints = mon.spec.endpoints or [ ];
          podPortsFor =
            svc:
            lib.unique (
              builtins.concatMap (
                ep:
                if ep ? port then
                  map podPortOf (builtins.filter (sp: (sp.name or null) == ep.port) svc.ports)
                else if ep ? targetPort then
                  [ ep.targetPort ]
                else
                  map podPortOf svc.ports
              ) endpoints
            );
        in
        builtins.concatMap (
          svc:
          let
            ports = podPortsFor svc;
          in
          lib.optional (ports != [ ]) (serviceTarget svc ports)
        ) matched;

      # Build scrape targets for a PodMonitor. Skip monitors whose selector uses
      # `matchExpressions`, which `podMonitorBreakage` reports separately.
      podMonitorTargets =
        mon:
        let
          sel = mon.spec.selector or { };
          podSelector = sel.matchLabels or { };
          monNs = plain (nsOfRaw mon);
          ports = lib.unique (
            builtins.concatMap (
              ep:
              if ep ? portNumber then
                [ ep.portNumber ]
              else if ep ? port then
                [ ep.port ]
              else
                lib.optional (ep ? targetPort) ep.targetPort
            ) (mon.spec.podMetricsEndpoints or [ ])
          );
        in
        if sel ? matchExpressions || ports == [ ] then
          [ ]
        else
          map (
            namespace:
            mkTarget {
              key = "pods-${mon.metadata.name}";
              id = "pods/${monNs}/${mon.metadata.name}";
              inherit namespace podSelector ports;
            }
          ) (monitorNamespaces mon);

      podMonitorBreakage =
        mon:
        lib.optional ((mon.spec.selector or { }) ? matchExpressions)
          "PodMonitor ${plain (nsOfRaw mon)}/${plain mon.metadata.name}: its selector uses matchExpressions, which Kix does not turn into a network policy selector, so no scrape policy opens its pods. Under default deny the scrape is dropped. Select the pods with matchLabels only.";

      alertmanagerTargets =
        prom:
        builtins.concatMap (
          am:
          let
            amNs = am.namespace or (nsOfRaw prom);
            svc = lib.findFirst (s: s.namespace == amNs && s.name == am.name) null services;
            svcPorts = builtins.filter (sp: (sp.name or null) == am.port || (sp.port or null) == am.port) (
              if svc == null then [ ] else svc.ports
            );
          in
          lib.optional (svc != null && svcPorts != [ ]) (serviceTarget svc (map podPortOf svcPorts))
        ) (prom.spec.alerting.alertmanagers or [ ]);

      monitors = {
        serviceMonitor = builtins.filter (isMonitoringKind "ServiceMonitor") resources;
        podMonitor = builtins.filter (isMonitoringKind "PodMonitor") resources;
      };

      # Return true when a Prometheus resource selects a monitor. A null monitor
      # selector matches nothing while `{}` matches all monitors. A null
      # namespace selector matches only the Prometheus namespace while `{}`
      # matches every namespace.
      selects =
        prom: prefix: mon:
        let
          sel = prom.spec."${prefix}Selector" or null;
          nsSel = prom.spec."${prefix}NamespaceSelector" or null;
          monNs = nsOfRaw mon;
        in
        sel != null
        && matchesSelector sel (mon.metadata.labels or { })
        && (if nsSel == null then monNs == nsOfRaw prom else matchesSelector nsSel (nsLabels monNs));

      prometheuses = builtins.filter (
        r: isMonitoringKind "Prometheus" r && nsResources ? ${plain (nsOfRaw r.rawManifest)}
      ) resources;
      hasPodSelector = r: ((r.factBehavior or null).podSelector or null) != null;
      scrapers = builtins.filter hasPodSelector prometheuses;
      unnamedScraperBreakages = map (
        r:
        "Prometheus ${plain (nsOfRaw r.rawManifest)}/${plain r.rawManifest.metadata.name}: the Prometheus CRD declares no factBehavior.podSelector, so Kix cannot name the server pods and derives no scrape policy for them. Under default deny the server reaches no target. Set cluster.factBehavior.\"monitoring.coreos.com/Prometheus\" to { endpoint = \"terminate\"; podSelector = <the server pods' labels>; }."
      ) (builtins.filter (r: !hasPodSelector r) prometheuses);

      # Return true when a policy isolates its selected pods for ingress. This
      # includes enforcer policies with `ingress` or `ingressDeny` rules and
      # Kubernetes NetworkPolicies whose `policyTypes` include `Ingress` (the
      # default when `policyTypes` is omitted).
      isolatesIngress =
        r:
        let
          spec = r.rawManifest.spec or { };
          kind = r.kind or "";
        in
        if kind == "NetworkPolicy" && groupOf r == "networking.k8s.io" then
          builtins.elem "Ingress" (spec.policyTypes or [ "Ingress" ])
        else
          builtins.elem kind (enforcerApi.policyKinds or [ ]) && (spec ? ingress || spec ? ingressDeny);
      namespacePolicies = builtins.concatMap (ns: builtins.attrValues (ns.netpols or { })) (
        builtins.attrValues nsResources
      );
      isolatingPolicies = builtins.filter isolatesIngress (
        resources ++ extraPolicies ++ namespacePolicies
      );

      # Return the pod selectors of all ingress-isolating policies that apply in
      # `namespace`, including cluster-wide policies.
      isolatingSelectorsIn =
        namespace:
        builtins.concatMap (
          p:
          let
            raw = p.rawManifest;
            policyNs = nsOfRaw raw;
            selector = raw.spec.endpointSelector or raw.spec.podSelector or null;
          in
          lib.optional (selector != null && (policyNs == null || plain policyNs == plain namespace)) selector
        ) isolatingPolicies;
      # Add Cilium's namespace label so cluster-wide policy selectors can match
      # on `k8s:io.kubernetes.pod.namespace`.
      withNamespace =
        namespace: labels: labels // { "k8s:io.kubernetes.pod.namespace" = plain namespace; };

      # Return true when `selector` matches `labels` and only inspects keys
      # present in `labels`, guaranteeing that any pod carrying `labels` matches.
      selectorImplied =
        selector: labels:
        builtins.all (k: labels ? ${k}) (
          builtins.attrNames (selector.matchLabels or { })
          ++ map (e: e.key) (selector.matchExpressions or [ ])
        )
        && matchesSelector selector labels;

      # Return whether "all", "some", or "none" of a target's pods are already
      # isolated for ingress by another policy. For Kix-built workloads, check
      # each pod's full label set. For external pods known only by `podSelector`,
      # treat them as "all" only when `podSelector` implies the policy selector,
      # and as "some" when the policy selector could depend on labels outside
      # `podSelector`.
      isolationOf =
        t:
        let
          selectors = isolatingSelectorsIn t.namespace;
          isolated =
            labels: builtins.any (sel: matchesSelector sel (withNamespace t.namespace labels)) selectors;
          count = builtins.length (builtins.filter isolated t.podLabelSets);
          selectorLabels = withNamespace t.namespace t.podSelector;
        in
        if t.podLabelSets == [ ] then
          if builtins.any (sel: selectorImplied sel selectorLabels) selectors then
            "all"
          else if isolated t.podSelector then
            "some"
          else
            "none"
        else if count == 0 then
          "none"
        else if count == builtins.length t.podLabelSets then
          "all"
        else
          "some";

      perScraper =
        r:
        let
          prom = r.rawManifest;
          promNs = plain (nsOfRaw prom);
          promName = plain prom.metadata.name;
          podSelectorDecl = r.factBehavior.podSelector;
          scraperSelector =
            if builtins.isFunction podSelectorDecl then podSelectorDecl prom else podSelectorDecl;

          selectedPodMonitors = builtins.filter (
            m: selects prom "podMonitor" m.rawManifest
          ) monitors.podMonitor;

          rawTargets =
            builtins.concatMap (m: serviceMonitorTargets m.rawManifest) (
              builtins.filter (m: selects prom "serviceMonitor" m.rawManifest) monitors.serviceMonitor
            )
            ++ builtins.concatMap (m: podMonitorTargets m.rawManifest) selectedPodMonitors
            ++ alertmanagerTargets prom;

          # Two monitors on one Service are one target with the union of
          # their ports.
          targets = builtins.attrValues (
            builtins.foldl' (
              acc: t:
              let
                id = "${plain t.namespace}/${t.id}";
              in
              acc
              // {
                ${id} =
                  if acc ? ${id} then acc.${id} // { ports = lib.unique (acc.${id}.ports ++ t.ports); } else t;
              }
            ) { } rawTargets
          );

          # Cilium drops egress on a named port, and a rule without ports
          # admits every port, so an egress rule carries only the numeric
          # ports and a target with none gets no rule.
          numericPorts = t: builtins.filter (p: isNumeric p.port) t.ports;
          namedPorts = t: builtins.filter (p: !isNumeric p.port) t.ports;

          egressRules = lib.unique (
            builtins.concatMap (
              t:
              if numericPorts t == [ ] then
                [ ]
              else if t.hostNetwork then
                [ (enforcerApi.mkHostNetworkEgressRule { ports = numericPorts t; }) ]
              else
                [
                  (enforcerApi.mkServiceEgressRule {
                    selector = t.podSelector;
                    namespace = t.namespace;
                    sourceNamespace = promNs;
                    ports = numericPorts t;
                  })
                ]
            ) targets
          );

          namedPortBreakage =
            t:
            let
              target = "Prometheus ${promNs}/${promName}: target ${plain t.namespace}/${plain t.key}";
              names = lib.concatMapStringsSep ", " (p: toString p.port) (namedPorts t);
              fix = "Give the monitor endpoint a port number: a numeric targetPort on the Service or ServiceMonitor endpoint, or portNumber on a PodMonitor endpoint.";
            in
            if t.hostNetwork then
              "${target} runs on the host network and its port ${names} is a name no Kix container declares, so Kix adds no scrape rule for it. The server reaches it only while its API server rule admits every port on the nodes. ${fix}"
            else
              "${target} has port ${names}, a name no Kix container declares, and Cilium drops egress on a named port, so Kix adds no scrape rule for it. Under default deny the scrape is dropped. ${fix}";

          egressPolicy = enforcerApi.mkPolicy {
            mkResource = core.mkResource;
            extraArgs = {
              name = "${promName}-scrape-egress";
              namespace = nsResources.${promNs};
              labels = {
                ${kixKeys.derived} = "true";
                ${kixKeys.policyType} = "scrape";
                "app.kubernetes.io/managed-by" = "kix";
              };
              spec = {
                endpointSelector.matchLabels = scraperSelector;
                egress = egressRules;
              };
            };
          };

          # Host-network pods are outside Cilium's endpoint policy, so they
          # get no ingress rule.
          ingressCandidates = builtins.filter (
            t: !t.hostNetwork && nsResources ? ${plain t.namespace}
          ) targets;
          ingressTargets = builtins.filter (t: defaultDeny || isolationOf t == "all") ingressCandidates;
          partlyIsolatedTargets = lib.optionals (!defaultDeny) (
            builtins.filter (t: isolationOf t == "some") ingressCandidates
          );

          # Build a unique ingress policy name for a scrape target, appending a
          # hash to disambiguate colliding namespace, Prometheus, and monitor
          # names.
          ingressPolicyName =
            t:
            let
              hash = builtins.substring 0 8 (
                builtins.hashString "sha256" "${promNs}/${promName}/${plain t.namespace}/${plain t.id}"
              );
            in
            "${promNs}-${promName}-scrape-${plain t.key}-${hash}";

          ingressPolicy =
            t:
            enforcerApi.mkPolicy {
              mkResource = core.mkResource;
              extraArgs = {
                name = ingressPolicyName t;
                namespace = nsResources.${plain t.namespace};
                labels = {
                  ${kixKeys.derived} = "true";
                  ${kixKeys.policyType} = "scrape";
                  "app.kubernetes.io/managed-by" = "kix";
                };
                spec = {
                  endpointSelector.matchLabels = t.podSelector;
                  ingress = [
                    (enforcerApi.mkCallerIngressRule {
                      callerSelector = scraperSelector;
                      callerNamespace = promNs;
                      inherit (t) ports;
                    })
                  ];
                };
              };
            };
        in
        {
          egressPolicies = lib.optional (enforced.egress && egressRules != [ ]) egressPolicy;
          ingressPolicies = lib.optionals enforced.ingress (map ingressPolicy ingressTargets);
          warnings = lib.optionals enforced.ingress (
            map (
              t:
              "Prometheus ${promNs}/${promName}: another ingress policy ${
                if t.podLabelSets == [ ] then
                  "may isolate only some of the pods behind target ${plain t.namespace}/${plain t.key}, which Kix did not build, depending on labels outside the target's selector"
                else
                  "isolates only some of the pods behind target ${plain t.namespace}/${plain t.key}"
              }. Without default deny Kix adds scrape ingress only where it can show that every pod is already isolated, so the server cannot reach the isolated pods. Select all of the target's pods in that policy, or turn on networkPolicy.defaultDeny."
            ) partlyIsolatedTargets
          );
          breakages =
            builtins.concatMap (m: podMonitorBreakage m.rawManifest) selectedPodMonitors
            ++ lib.optionals enforced.egress (
              map namedPortBreakage (builtins.filter (t: namedPorts t != [ ]) targets)
            );
        };

      results = map perScraper scrapers;
      breakages = lib.unique (unnamedScraperBreakages ++ builtins.concatMap (r: r.breakages) results);
    in
    {
      egressPolicies = builtins.concatMap (r: r.egressPolicies) results;
      ingressPolicies = builtins.concatMap (r: r.ingressPolicies) results;
      warnings = lib.unique (
        builtins.concatMap (r: r.warnings) results ++ lib.optionals (!defaultDeny) breakages
      );
      errors = lib.optionals defaultDeny breakages;
    };
}
